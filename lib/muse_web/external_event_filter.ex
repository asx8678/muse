defmodule MuseWeb.ExternalEventFilter do
  @moduledoc """
  Pure security boundary for optional external event channels.

  External transports (WebSocket, SSE, webhook, etc.) should call this module
  before serializing or forwarding a `%Muse.Event{}`. The filter is intentionally
  stricter than the in-process LiveView/CLI event display:

    * only `visibility: :user` is forwarded by default;
    * `visibility: :internal`, `:sensitive`, `:debug`, invalid visibility, and
      nil visibility are denied;
    * nil visibility can be allowed only if the event type appears on a
      conservative safe-allowlist AND it is not a provider/auth/debug-ish event;
    * event data is redacted via `Muse.EventDisplay.safe_data/1`, then converted
      to JSON-safe data without dumping arbitrary structs or raw internals;
    * no `String.to_atom/1` on client input;
    * session IDs are validated to prevent path traversal — they are never used
      as filesystem paths.

  ## APIs

    * `to_external_map/2` — convert one event to a JSON-ready map or deny it.
    * `to_external_json/2` — convert one event to encoded JSON or deny it.
    * `filter/2` — filter a list of events, returning only allowed envelopes.
    * `valid_session_id?/1` — validate an external session id.
    * `nil_visibility_safe_types/0` — return the conservative type allowlist.
    * `nil_visibility_type_allowed?/1` — check if a type is on the allowlist.

  ## Envelope shape

  Allowed events are returned as maps with string keys:

      %{
        "id"         => ...,
        "type"       => ...,
        "session_id" => ...,
        "turn_id"    => ...,
        "seq"        => ...,
        "source"     => ...,
        "visibility" => ...,
        "timestamp"  => "2025-06-15T12:00:00Z",
        "payload"    => %{...},
        "muse_id"    => ...
      }

  Only fields with non-nil values are included.
  """

  alias Muse.{Event, EventDisplay}

  # Conservative allowlist for event types whose nil visibility is considered
  # safe for external consumers. Only user-facing lifecycle and chat types.
  @nil_visibility_safe_types MapSet.new([
                               :user_message,
                               :assistant_delta,
                               :assistant_message,
                               :plan_created,
                               :plan_approved,
                               :plan_rejected,
                               :approval_requested,
                               :approval_approved,
                               :approval_rejected,
                               :turn_completed,
                               :turn_failed,
                               :session_status_changed
                             ])

  # Visibility values that are always denied for external consumers.
  @denied_visibilities MapSet.new([:internal, :sensitive])

  @path_traversal_chars ~r([/\\\0])
  @provider_auth_fragments [
    "auth",
    "bearer",
    "codex",
    "credential",
    "oauth",
    "openai",
    "provider",
    "token"
  ]
  @debug_fragments ["debug", "raw", "request", "response"]

  # JSON safety limits
  @redacted_struct "[struct omitted]"
  @nested_event_omitted "[event omitted]"
  @unsupported_omitted "[unsupported term omitted]"
  @truncated "[truncated]"
  @max_depth 8
  @max_list_items 50
  @max_map_keys 50
  @max_string_chars 2_000

  @type deny_reason ::
          :invalid_event
          | {:invalid_session_id, term()}
          | {:denied_visibility, term()}
          | :session_mismatch
          | :nil_visibility_type_not_allowed
          | :provider_auth_debug_denied

  @type option ::
          {:session_id, String.t()}
          | {:allow_debug?, boolean()}

  @type envelope :: %{required(String.t()) => term()}

  @doc """
  Convert an event into a JSON-ready external map, or deny it.

  Returned maps use string keys and contain only bounded, redacted, JSON-safe
  values. Callers that need a JSON string can pass the result to `Jason.encode/1`
  or use `to_external_json/2`.
  """
  @spec to_external_map(Event.t(), [option()]) :: {:ok, envelope()} | {:error, deny_reason()}
  def to_external_map(event, opts \\ [])

  def to_external_map(%Event{} = event, opts) do
    with :ok <- validate_event_session_id(event),
         :ok <- check_session(event, opts),
         :ok <- check_visibility(event, opts) do
      {:ok, build_envelope(event)}
    end
  end

  def to_external_map(_event, _opts), do: {:error, :invalid_event}

  @doc """
  Convert an allowed event to encoded JSON.
  """
  @spec to_external_json(Event.t(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def to_external_json(event, opts \\ [])

  def to_external_json(%Event{} = event, opts) do
    with {:ok, map} <- to_external_map(event, opts),
         {:ok, json} <- Jason.encode(map) do
      {:ok, json}
    end
  end

  def to_external_json(_event, _opts), do: {:error, :invalid_event}

  @doc """
  Filter a list of events down to JSON-ready external maps.

  Denied or invalid events are silently dropped so channel code can keep a simple
  broadcast pipeline while the drop decision remains centralized and testable.
  """
  @spec filter(Enumerable.t(), [option()]) :: [envelope()]
  def filter(events, opts \\ []) do
    events
    |> Enum.flat_map(fn event ->
      case to_external_map(event, opts) do
        {:ok, map} -> [map]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Validate an external session id without using it as a filesystem path.

  Returns `true` for `nil` (nil session_id is valid as a value — it just won't
  pass session-scoped topic filtering) and for non-empty binary strings that
  contain no path-traversal characters (`/`, `\\`, NUL) and are not `.` or `..`.
  """
  @spec valid_session_id?(term()) :: boolean()
  def valid_session_id?(nil), do: true

  def valid_session_id?(session_id) when is_binary(session_id) do
    cond do
      session_id == "" -> false
      session_id in [".", ".."] -> false
      Regex.match?(@path_traversal_chars, session_id) -> false
      true -> true
    end
  end

  def valid_session_id?(_session_id), do: false

  @doc """
  Returns the set of event types allowed when visibility is nil.

  Useful for documentation or configuration validation.
  """
  @spec nil_visibility_safe_types() :: MapSet.t(atom())
  def nil_visibility_safe_types, do: @nil_visibility_safe_types

  @doc """
  Check whether an event type is on the nil-visibility safe allowlist.
  """
  @spec nil_visibility_type_allowed?(atom()) :: boolean()
  def nil_visibility_type_allowed?(type) do
    MapSet.member?(@nil_visibility_safe_types, type)
  end

  # -- Session filter -----------------------------------------------------------

  defp validate_event_session_id(%Event{session_id: nil}), do: :ok

  defp validate_event_session_id(%Event{session_id: session_id}) do
    if valid_session_id?(session_id) do
      :ok
    else
      {:error, {:invalid_session_id, session_id}}
    end
  end

  defp check_session(event, opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        :ok

      requested ->
        if event.session_id == requested do
          :ok
        else
          {:error, :session_mismatch}
        end
    end
  end

  # -- Visibility filter --------------------------------------------------------

  @denied_visibility_list MapSet.to_list(@denied_visibilities)

  defp check_visibility(%Event{visibility: visibility}, _opts)
       when visibility in @denied_visibility_list do
    {:error, {:denied_visibility, visibility}}
  end

  defp check_visibility(%Event{visibility: :user}, _opts), do: :ok

  defp check_visibility(%Event{visibility: :debug}, opts) do
    if Keyword.get(opts, :allow_debug?, false) do
      :ok
    else
      {:error, {:denied_visibility, :debug}}
    end
  end

  defp check_visibility(%Event{visibility: nil, type: type, source: source}, _opts) do
    cond do
      not MapSet.member?(@nil_visibility_safe_types, type) ->
        {:error, :nil_visibility_type_not_allowed}

      provider_auth_debug_event?(source, type) ->
        {:error, :provider_auth_debug_denied}

      true ->
        :ok
    end
  end

  # Known visibility values not explicitly handled above (future-proofing).
  defp check_visibility(%Event{visibility: _other}, _opts) do
    {:error, :denied_visibility}
  end

  defp provider_auth_debug_event?(source, type) do
    source_str = source |> identifier_to_string() |> String.downcase()
    type_str = type |> identifier_to_string() |> String.downcase()
    joined = source_str <> ":" <> type_str

    provider_or_auth? = contains_any?(joined, @provider_auth_fragments)
    debugish? = contains_any?(joined, @debug_fragments)

    provider_or_auth? and debugish?
  end

  # -- Envelope builder ---------------------------------------------------------

  defp build_envelope(event) do
    payload =
      event.data
      |> EventDisplay.safe_data()
      |> external_json_safe()

    base = %{
      "id" => external_json_safe(event.id),
      "type" => identifier_to_string(event.type),
      "source" => identifier_to_string(event.source),
      "timestamp" => timestamp_to_string(event.timestamp),
      "payload" => payload
    }

    base
    |> maybe_put("session_id", event.session_id)
    |> maybe_put("turn_id", event.turn_id)
    |> maybe_put("seq", event.seq)
    |> maybe_put("visibility", event.visibility && Atom.to_string(event.visibility))
    |> maybe_put("muse_id", event.muse_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, external_json_safe(value))

  # -- JSON safety --------------------------------------------------------------

  defp external_json_safe(term), do: external_json_safe(term, 0)

  defp external_json_safe(_term, depth) when depth > @max_depth, do: @truncated

  defp external_json_safe(term, _depth) when is_binary(term) do
    term
    |> EventDisplay.safe_text()
    |> truncate_string()
  end

  defp external_json_safe(term, _depth) when is_boolean(term), do: term
  defp external_json_safe(term, _depth) when is_number(term), do: term
  defp external_json_safe(nil, _depth), do: nil

  defp external_json_safe(%DateTime{} = dt, _depth), do: DateTime.to_iso8601(dt)
  defp external_json_safe(%Date{} = date, _depth), do: Date.to_iso8601(date)
  defp external_json_safe(%Time{} = time, _depth), do: Time.to_iso8601(time)
  defp external_json_safe(%NaiveDateTime{} = ndt, _depth), do: NaiveDateTime.to_iso8601(ndt)
  defp external_json_safe(%Event{}, _depth), do: @nested_event_omitted
  defp external_json_safe(%{__struct__: _struct_name}, _depth), do: @redacted_struct

  defp external_json_safe(atom, _depth) when is_atom(atom), do: Atom.to_string(atom)

  defp external_json_safe(list, depth) when is_list(list) do
    list
    |> Enum.take(@max_list_items)
    |> Enum.map(&external_json_safe(&1, depth + 1))
  end

  defp external_json_safe(tuple, depth) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> external_json_safe(depth + 1)
  end

  defp external_json_safe(map, depth) when is_map(map) do
    map
    |> Enum.take(@max_map_keys)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, external_json_key(key), external_json_safe(value, depth + 1))
    end)
  end

  defp external_json_safe(_term, _depth), do: @unsupported_omitted

  defp external_json_key(key) when is_binary(key) do
    key |> EventDisplay.safe_text() |> truncate_string()
  end

  defp external_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp external_json_key(key) when is_integer(key), do: Integer.to_string(key)
  defp external_json_key(key) when is_float(key), do: Float.to_string(key)
  defp external_json_key(_key), do: "unsupported_key"

  # -- Helpers ------------------------------------------------------------------

  defp timestamp_to_string(%DateTime{} = ts), do: DateTime.to_iso8601(ts)
  defp timestamp_to_string(_ts), do: nil

  defp identifier_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp identifier_to_string(value) when is_binary(value), do: value
  defp identifier_to_string(_value), do: "unknown"

  defp contains_any?(text, fragments), do: Enum.any?(fragments, &String.contains?(text, &1))

  defp truncate_string(text) do
    if String.length(text) > @max_string_chars do
      String.slice(text, 0, @max_string_chars) <> "…"
    else
      text
    end
  end
end
