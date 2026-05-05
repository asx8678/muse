defmodule Muse.EventStream do
  @moduledoc """
  Streaming and replay helpers for the Muse event model.

  Centralizes subscription, replay, and chat-message derivation so that
  CLI and LiveView can render/replay events consistently from the same
  structured event stream.

  ## Key functions

    * `subscribe/0` — subscribe to real-time event broadcasts.
    * `replay/2` — filter existing events by session and visibility.
    * `chat_messages/1` — derive chat messages from an event stream,
      handling streaming assistant deltas and deduplicating final messages.

  ## Deduplication of streamed assistant messages

  When assistant deltas (`:assistant_delta`) have been emitted for a turn,
  the final `:assistant_message` is marked `streamed?: true`. The
  `chat_messages/1` helper renders the concatenated deltas as the
  assistant message and suppresses the duplicate final message.

  ## Legacy events

  Events created with `Event.new/3` (no metadata) have `nil` `turn_id`
  and `seq`. The `chat_messages/1` helper handles these defensively:
  each nil-turn event is treated as its own single-event group, rendered
  chronologically without grouping all nil-turn events together.
  """

  alias Muse.Event
  alias MuseWeb.ExternalEventFilter

  @chat_event_types [
    :user_message,
    :assistant_delta,
    :assistant_message,
    :plan_created,
    :plan_approved,
    :plan_rejected,
    :approval_requested,
    :approval_approved,
    :approval_rejected
  ]

  @system_event_types [
    :plan_created,
    :plan_approved,
    :plan_rejected,
    :approval_requested,
    :approval_approved,
    :approval_rejected
  ]

  @default_external_replay_limit 100

  @doc """
  Subscribe to real-time event broadcasts via `Muse.State.subscribe/0`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Muse.State.subscribe()
  end

  @doc """
  Replay events from `Muse.State`, optionally filtering by session_id
  and visibility.

  Events are returned in oldest-first order (matching `Muse.State.events/0`).

  ## Options

    * `:session_id` — only events belonging to this session (default: all)
    * `:visibility` — only events with this visibility (default: all)
  """
  @spec replay(keyword()) :: [Event.t()]
  def replay(opts) do
    session_id = Keyword.get(opts, :session_id)
    visibility = Keyword.get(opts, :visibility)

    Muse.State.events()
    |> maybe_filter_by_session(session_id)
    |> maybe_filter_by_visibility(visibility)
  end

  @doc """
  Replay externally-visible events for one session as JSON-safe envelopes.

  This is intended for external WebSocket clients that need a bounded replay
  before subscribing to live events. It delegates filtering to
  `MuseWeb.ExternalEventFilter.to_external_map/2` so replay and live push
  share the same security policy.

  ## Options

    * `:session_id` — **required**; must be a valid, non-nil session ID per
      `MuseWeb.ExternalEventFilter.valid_session_id?/1`. Missing, blank, or
      invalid session IDs cause an immediate empty return — no nil-session
      events are ever replayed.
    * `:replay_limit` / `:limit` — maximum number of most-recent events to
      replay. Defaults to `MuseWeb.ExternalSocketConfig.replay_limit/0` then
      #{@default_external_replay_limit}.
    * `:events` — optional event list for pure/offline use; if omitted, events
      are read from `Muse.State.events/0`.

  The returned envelopes use string keys and JSON-safe values so callers can
  pass them directly to Phoenix channel `push/3` or Jason encoding.
  """
  @spec external_replay(keyword() | map()) :: [map()]
  def external_replay(opts) when is_list(opts) or is_map(opts) do
    session_id =
      case fetch_opt(opts, :session_id) do
        {:ok, sid} -> sid
        :error -> nil
      end

    # Short-circuit before reading State when session_id is invalid.
    # This avoids crashing when Muse.State is not running and also skips
    # the unnecessary work of loading all events just to filter them out.
    if not ExternalEventFilter.valid_session_id?(session_id) do
      []
    else
      events =
        case fetch_opt(opts, :events) do
          {:ok, events} when is_list(events) -> events
          _ -> Muse.State.events()
        end

      external_replay(events, opts)
    end
  end

  @doc """
  Pure variant of `external_replay/1` for callers that already have an event log.
  """
  @spec external_replay([Event.t()], keyword() | map()) :: [map()]
  def external_replay(events, opts) when is_list(events) and (is_list(opts) or is_map(opts)) do
    session_id =
      case fetch_opt(opts, :session_id) do
        {:ok, sid} -> sid
        :error -> nil
      end

    # Reject missing, blank, or invalid session IDs — no nil-session replay.
    if not ExternalEventFilter.valid_session_id?(session_id) do
      []
    else
      limit = external_replay_limit(opts)

      events
      |> Enum.filter(&(&1.session_id == session_id))
      |> apply_external_replay_limit(limit)
      |> Enum.flat_map(fn event ->
        case ExternalEventFilter.to_external_map(event, session_id: session_id) do
          {:ok, envelope} -> [envelope]
          {:error, _reason} -> []
        end
      end)
    end
  end

  @doc """
  Return an external envelope for one live event, or `nil` if it is not visible.

  `SessionChannel`-style callers can use this on `{:muse_event, event}` messages
  and push only when a map is returned:

      case Muse.EventStream.external_envelope(event, session_id: session_id) do
        nil -> :ok
        envelope -> push(socket, "muse_event", envelope)
      end
  """
  @spec external_envelope(Event.t(), keyword()) :: map() | nil
  def external_envelope(%Event{} = event, opts) when is_list(opts) or is_map(opts) do
    case ExternalEventFilter.to_external_map(event, opts) do
      {:ok, envelope} -> envelope
      {:error, _reason} -> nil
    end
  end

  def external_envelope(_event, _opts), do: nil

  @doc """
  Derive chat messages from an event stream.

  Converts the structured event stream into a list of chat messages suitable
  for CLI/LiveView rendering. Handles:

    * `:user_message` events → user chat messages
    * `:assistant_delta` events → streaming assistant chunks
    * `:assistant_message` events → final assistant messages
    * plan/approval lifecycle events → concise system status messages
    * Deduplication: if deltas were streamed (`streamed?: true` in data),
      the final `:assistant_message` is suppressed

  Each chat message is a map with keys:

    * `:id` — event ID
    * `:role` — `:user`, `:assistant`, or `:system`
    * `:text` — message text (concatenated deltas or final text)
    * `:timestamp` — formatted timestamp string
    * `:source` — event source
    * `:streaming?` — whether the message is still streaming (has deltas
      but no final `:assistant_message` yet)

  Legacy events with `nil` `turn_id` are rendered individually in
  chronological order. Multiple `:assistant_message` finals in a turn
  are handled gracefully (first wins for dedup).
  """
  @spec chat_messages([Event.t()]) :: [map()]
  def chat_messages(events) when is_list(events) do
    events
    |> Enum.filter(&(&1.type in @chat_event_types))
    |> Enum.reject(&internal_event?/1)
    |> group_by_turn_preserving_order()
    |> Enum.flat_map(&turn_to_messages/1)
  end

  # -- Private helpers ----------------------------------------------------------

  defp external_replay_limit(opts) do
    case fetch_first_opt(opts, [:replay_limit, :limit]) do
      {:ok, limit} when is_integer(limit) and limit >= 0 ->
        limit

      {:ok, limit} when is_binary(limit) ->
        case Integer.parse(String.trim(limit)) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> configured_external_replay_limit()
        end

      _ ->
        configured_external_replay_limit()
    end
  end

  defp configured_external_replay_limit do
    MuseWeb.ExternalSocketConfig.replay_limit()
  end

  defp apply_external_replay_limit(_events, 0), do: []

  defp apply_external_replay_limit(events, limit) when is_integer(limit) and limit > 0 do
    Enum.take(events, -limit)
  end

  defp fetch_first_opt(opts, keys) do
    Enum.find_value(keys, :error, fn key ->
      case fetch_opt(opts, key) do
        {:ok, _value} = found -> found
        :error -> false
      end
    end)
  end

  defp fetch_opt(opts, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_opt(opts, key) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        string_key = Atom.to_string(key)
        if Map.has_key?(opts, string_key), do: {:ok, Map.fetch!(opts, string_key)}, else: :error
    end
  end

  # Group events by turn_id while preserving the temporal order of first
  # appearance of each turn_id. Events with nil turn_id are each placed
  # in their own single-event group (keyed by a unique reference) so they
  # don't all get lumped together.
  defp group_by_turn_preserving_order(events) do
    {groups, _seen, _nil_counter} =
      Enum.reduce(events, {[], MapSet.new(), 0}, fn event, {acc, seen, nil_count} ->
        turn_id = event.turn_id

        if turn_id == nil do
          # Each nil-turn event gets its own unique group
          key = {:nil_turn, nil_count}
          {[{key, [event]} | acc], seen, nil_count + 1}
        else
          if MapSet.member?(seen, turn_id) do
            {acc, seen, nil_count}
          else
            turn_events = Enum.filter(events, &(&1.turn_id == turn_id))
            {[{turn_id, turn_events} | acc], MapSet.put(seen, turn_id), nil_count}
          end
        end
      end)

    Enum.reverse(groups)
  end

  defp maybe_filter_by_session(events, nil), do: events

  defp maybe_filter_by_session(events, session_id) do
    Enum.filter(events, &(&1.session_id == session_id))
  end

  defp maybe_filter_by_visibility(events, nil), do: events

  defp maybe_filter_by_visibility(events, visibility) do
    Enum.filter(events, &(&1.visibility == visibility))
  end

  # Convert a group of events for a single turn into chat messages.
  # Handles: nil-turn single events, normal turns, multiple finals, nil seqs.
  defp turn_to_messages({_turn_id, events}) do
    # Sort by seq, treating nil seq as 0 (comes first)
    events = Enum.sort_by(events, fn e -> e.seq || 0 end)

    user_events = Enum.filter(events, &(&1.type == :user_message))
    assistant_deltas = Enum.filter(events, &(&1.type == :assistant_delta))
    assistant_finals = Enum.filter(events, &(&1.type == :assistant_message))
    system_events = Enum.filter(events, &(&1.type in @system_event_types))

    user_messages = Enum.map(user_events, &event_to_chat_message/1)

    assistant_messages =
      case {assistant_deltas, assistant_finals} do
        # No deltas, no final — nothing to render
        {[], []} ->
          []

        # No deltas, just final(s) — render the first final only
        {[], [final | _rest]} ->
          [event_to_chat_message(final)]

        # Deltas present with one or more finals — check first final for streamed?
        {deltas, [final | _rest]} ->
          if streamed?(final) do
            # Deltas were streamed — render concatenated deltas, suppress final
            [deltas_to_message(deltas)]
          else
            # Deltas present but final not marked streamed — render both
            [deltas_to_message(deltas), event_to_chat_message(final)]
          end

        # Deltas with no final — still streaming
        {deltas, []} ->
          [deltas_to_streaming_message(deltas)]
      end

    system_messages = Enum.map(system_events, &event_to_system_message/1)

    user_messages ++ assistant_messages ++ system_messages
  end

  defp internal_event?(%Event{visibility: visibility}), do: visibility in [:internal, :sensitive]

  defp event_to_chat_message(%Event{} = event) do
    %{
      id: event.id,
      role: chat_role(event.type),
      text: chat_text(event),
      timestamp: format_timestamp(event.timestamp),
      source: event.source,
      streaming?: false
    }
  end

  defp event_to_system_message(%Event{} = event) do
    %{
      id: event.id,
      role: :system,
      text: Muse.EventDisplay.summary(event),
      timestamp: format_timestamp(event.timestamp),
      source: event.source,
      streaming?: false
    }
  end

  defp deltas_to_message(deltas) do
    text =
      deltas
      |> Enum.sort_by(fn e -> e.seq || 0 end)
      |> Enum.map_join("", &delta_text/1)
      |> Muse.EventDisplay.safe_text()

    first = hd(deltas)

    %{
      id: first.id,
      role: :assistant,
      text: text,
      timestamp: format_timestamp(first.timestamp),
      source: first.source,
      streaming?: false
    }
  end

  defp deltas_to_streaming_message(deltas) do
    text =
      deltas
      |> Enum.sort_by(fn e -> e.seq || 0 end)
      |> Enum.map_join("", &delta_text/1)
      |> Muse.EventDisplay.safe_text()

    first = hd(deltas)

    %{
      id: first.id,
      role: :assistant,
      text: text,
      timestamp: format_timestamp(first.timestamp),
      source: first.source,
      streaming?: true
    }
  end

  # Extract text from delta event data, handling both atom and string keys.
  # This is important for SessionStore JSON replay where keys become strings.
  defp delta_text(%Event{data: data}) when is_map(data) do
    Map.get(data, :text) || Map.get(data, "text") || ""
  end

  defp delta_text(%Event{data: data}) when is_binary(data), do: data
  defp delta_text(_), do: ""

  defp chat_role(:user_message), do: :user
  defp chat_role(:assistant_message), do: :assistant
  defp chat_role(:assistant_delta), do: :assistant
  defp chat_role(_), do: :system

  defp chat_text(%Event{data: data}) when is_map(data) do
    data
    |> Map.get(:text, Map.get(data, "text", ""))
    |> safe_chat_text()
  end

  defp chat_text(%Event{data: data}) when is_binary(data), do: Muse.EventDisplay.safe_text(data)
  defp chat_text(%Event{data: nil}), do: ""

  defp chat_text(%Event{data: data}) do
    data
    |> Muse.EventDisplay.safe_data()
    |> inspect()
  end

  defp safe_chat_text(text) when is_binary(text), do: Muse.EventDisplay.safe_text(text)
  defp safe_chat_text(nil), do: ""
  defp safe_chat_text(other), do: other |> Muse.EventDisplay.safe_data() |> inspect()

  defp streamed?(%Event{data: data}) when is_map(data) do
    Map.get(data, :streamed?) == true or Map.get(data, "streamed?") == true
  end

  defp streamed?(_), do: false

  defp format_timestamp(%DateTime{} = ts) do
    ts
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  defp format_timestamp(_), do: "—"
end
