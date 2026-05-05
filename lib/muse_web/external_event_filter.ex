defmodule MuseWeb.ExternalEventFilter do
  @moduledoc """
  Pure, offline-testable filter and envelope builder for external event consumers.

  Takes a `%Muse.Event{}` and options (e.g. `session_id: ...`, `allow_debug?: false`)
  and applies three layers of filtering:

    1. **Session filter** — when a `session_id` option is present, only events
       whose `session_id` exactly matches pass. Events with a different or nil
       `session_id` are denied for session-scoped topics.

    2. **Visibility filter** — `:internal` and `:sensitive` events are always
       denied. `:user` events are allowed. Events with nil visibility are
       allowed only if their type appears on a conservative safe-allowlist.

    3. **Payload redaction** — data is passed through
       `Muse.EventDisplay.safe_data/1` (which redacts secrets and omits raw
       plan JSON) then `MuseWeb.ExportJSON.json_safe/1` for Jason encoding.

  Returns `{:ok, envelope}` or `:error` with a reason atom.

  ## Envelope shape

  The envelope is a map with string keys, suitable for `Jason.encode!/1`:

      %{
        "type"       => event.type,
        "session_id" => event.session_id,
        "turn_id"    => event.turn_id,
        "seq"        => event.seq,
        "source"     => event.source,
        "visibility" => event.visibility,
        "timestamp"  => ISO8601 string,
        "payload"    => redacted, json-safe data
      }

  Only fields with non-nil values are included.
  """

  alias Muse.{Event, EventDisplay}
  alias MuseWeb.ExportJSON

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

  @type filter_reason ::
          :session_mismatch
          | :visibility_denied
          | :nil_visibility_type_not_allowed

  @type envelope :: %{
          required(String.t()) => term()
        }

  @type filter_result :: {:ok, envelope()} | {:error, filter_reason()}

  @doc """
  Filter and build an envelope for a single event.

  ## Options

    * `:session_id`    — when set, only events matching this session pass
    * `:allow_debug?`  — if `true`, `:debug` visibility events are also
                         allowed (default `false`)

  Returns `{:ok, envelope}` on success or `{:error, reason}` when the event
  is denied.
  """
  @spec filter(Event.t(), keyword()) :: filter_result()
  def filter(%Event{} = event, opts \\ []) do
    with :ok <- check_session(event, opts),
         :ok <- check_visibility(event, opts) do
      {:ok, build_envelope(event)}
    end
  end

  # -- Session filter -----------------------------------------------------------

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
    {:error, :visibility_denied}
  end

  defp check_visibility(%Event{visibility: :user}, _opts), do: :ok

  defp check_visibility(%Event{visibility: :debug}, opts) do
    if Keyword.get(opts, :allow_debug?, false) do
      :ok
    else
      {:error, :visibility_denied}
    end
  end

  defp check_visibility(%Event{visibility: nil, type: type}, _opts) do
    if MapSet.member?(@nil_visibility_safe_types, type) do
      :ok
    else
      {:error, :nil_visibility_type_not_allowed}
    end
  end

  # Known visibility values not explicitly handled above (future-proofing).
  defp check_visibility(%Event{visibility: _other}, _opts) do
    {:error, :visibility_denied}
  end

  # -- Envelope builder ---------------------------------------------------------

  defp build_envelope(event) do
    payload =
      event.data
      |> EventDisplay.safe_data()
      |> ExportJSON.json_safe()

    base = %{
      "type" => to_string(event.type),
      "source" => to_string(event.source),
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "payload" => payload
    }

    base
    |> maybe_put("session_id", event.session_id)
    |> maybe_put("turn_id", event.turn_id)
    |> maybe_put("seq", event.seq)
    |> maybe_put("visibility", event.visibility && to_string(event.visibility))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
end
