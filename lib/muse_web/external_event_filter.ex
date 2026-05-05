defmodule MuseWeb.ExternalEventFilter do
  @moduledoc """
  Pure security boundary for optional external event channels.

  External transports (WebSocket, SSE, webhook, etc.) should call this module
  before serializing or forwarding a `%Muse.Event{}`. The filter is intentionally
  stricter than the in-process LiveView/CLI event display:

    * only `visibility: :user` is forwarded by default;
    * `visibility: :internal`, `:sensitive`, `:debug`, invalid visibility, and
      nil visibility are denied;
    * nil visibility can be allowed only by an explicit `{source, type}`
      allowlist and still cannot be provider/auth/debug-ish traffic;
    * event data is redacted and plan payloads are summarized via
      `Muse.EventDisplay`; and
    * nested structs/internal terms are omitted instead of inspected.

  The module is pure: it never treats session IDs or path-like values as file
  paths and it performs no filesystem access.
  """

  alias Muse.Event
  alias Muse.EventDisplay

  @redacted_struct "[struct omitted]"
  @nested_event_omitted "[event omitted]"
  @unsupported_omitted "[unsupported term omitted]"
  @truncated "[truncated]"
  @max_depth 8
  @max_list_items 50
  @max_map_keys 50
  @max_string_chars 2_000
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

  @type deny_reason ::
          :invalid_event
          | {:invalid_session_id, term()}
          | {:denied_visibility, term()}
          | :provider_auth_debug_denied

  @type option :: {:nil_visibility_allowlist, [{atom() | String.t(), atom() | String.t()}]}

  @doc """
  Convert an event into a JSON-ready external map, or deny it.

  Returned maps use string keys and contain only bounded, redacted, JSON-safe
  values. Callers that need a JSON string can pass the result to `Jason.encode/1`
  or use `to_external_json/2`.
  """
  @spec to_external_map(Event.t(), [option()]) :: {:ok, map()} | {:error, deny_reason()}
  def to_external_map(event, opts \\ [])

  def to_external_map(%Event{} = event, opts) do
    with :ok <- validate_session_id(event.session_id),
         :ok <- validate_visibility(event, opts) do
      {:ok, build_external_map(event)}
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
  @spec filter(Enumerable.t(), [option()]) :: [map()]
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

  defp validate_session_id(session_id) do
    if valid_session_id?(session_id) do
      :ok
    else
      {:error, {:invalid_session_id, session_id}}
    end
  end

  defp validate_visibility(%Event{visibility: :user}, _opts), do: :ok

  defp validate_visibility(%Event{visibility: nil} = event, opts) do
    cond do
      not nil_visibility_allowlisted?(event, opts) ->
        {:error, {:denied_visibility, nil}}

      provider_auth_debug_event?(event) ->
        {:error, :provider_auth_debug_denied}

      true ->
        :ok
    end
  end

  defp validate_visibility(%Event{visibility: visibility}, _opts) do
    {:error, {:denied_visibility, visibility}}
  end

  defp nil_visibility_allowlisted?(%Event{} = event, opts) do
    allowlist = Keyword.get(opts, :nil_visibility_allowlist, [])
    event_pair = {identifier_to_string(event.source), identifier_to_string(event.type)}

    Enum.any?(allowlist, fn
      {source, type} -> event_pair == {identifier_to_string(source), identifier_to_string(type)}
      _other -> false
    end)
  end

  defp provider_auth_debug_event?(%Event{} = event) do
    source = event.source |> identifier_to_string() |> String.downcase()
    type = event.type |> identifier_to_string() |> String.downcase()
    joined = source <> ":" <> type

    provider_or_auth? = contains_any?(joined, @provider_auth_fragments)
    debugish? = contains_any?(joined, @debug_fragments)

    provider_or_auth? and debugish?
  end

  defp build_external_map(%Event{} = event) do
    data = event.data |> EventDisplay.safe_data() |> external_json_safe()
    summary = %{event | data: data} |> EventDisplay.summary() |> EventDisplay.safe_text()

    %{
      "id" => external_json_safe(event.id),
      "timestamp" => timestamp_to_string(event.timestamp),
      "source" => identifier_to_string(event.source),
      "type" => identifier_to_string(event.type),
      "visibility" => visibility_to_string(event.visibility),
      "summary" => summary,
      "data" => data
    }
    |> maybe_put("session_id", event.session_id)
    |> maybe_put("turn_id", event.turn_id)
    |> maybe_put("seq", event.seq)
    |> maybe_put("parent_id", event.parent_id)
    |> maybe_put("muse_id", event.muse_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, external_json_safe(value))

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

  defp timestamp_to_string(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp_to_string(_timestamp), do: nil

  defp visibility_to_string(nil), do: nil
  defp visibility_to_string(visibility) when is_atom(visibility), do: Atom.to_string(visibility)
  defp visibility_to_string(visibility) when is_binary(visibility), do: visibility
  defp visibility_to_string(_visibility), do: nil

  defp identifier_to_string(identifier) when is_atom(identifier), do: Atom.to_string(identifier)
  defp identifier_to_string(identifier) when is_binary(identifier), do: identifier
  defp identifier_to_string(_identifier), do: "unknown"

  defp contains_any?(text, fragments), do: Enum.any?(fragments, &String.contains?(text, &1))

  defp truncate_string(text) do
    if String.length(text) > @max_string_chars do
      String.slice(text, 0, @max_string_chars) <> "…"
    else
      text
    end
  end
end
