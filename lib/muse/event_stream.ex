defmodule Muse.EventStream do
  @moduledoc """
  Streaming and replay helpers for the Muse event model.

  Centralizes subscription, replay, and chat-message derivation so that
  CLI and LiveView can render/replay events consistently from the same
  structured event stream.

  ## Key functions

    * `subscribe/0` — subscribe to real-time event broadcasts.
    * `replay/1` — filter existing events by session and visibility.
    * `external_replay/1` — replay a JSON-safe, externally-visible event
      envelope for one session with allowlist filtering and a replay limit.
    * `external_envelope/2` — apply the same external filter to one live
      event for WebSocket channel pushes.
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

  @external_event_types @chat_event_types
  @external_visibilities [:user]
  @default_external_replay_limit 100

  @type external_opts :: keyword() | map()

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
  before subscribing to live events. It applies the same safety rules that
  `external_envelope/2` uses for live pushes:

    * `:session_id` is required; omitting it returns an empty list.
    * Only `:user` visibility is exposed.
    * Only `external_event_types/0` are exposed; optional `:event_types` or
      `:types` opts can further narrow the allowlist, but never expand it.
    * Replay is returned oldest-first after applying a newest-N replay limit.

  ## Options

    * `:session_id` — required session identifier.
    * `:replay_limit` / `:limit` — maximum number of most-recent events to
      replay. Defaults to `config :muse, :external_event_stream,
      replay_limit: ...`, then #{@default_external_replay_limit}.
    * `:event_types` / `:types` — optional atom/string type or list of types.
    * `:visibility` / `:visibilities` — optional visibility filter, intersected
      with the externally-safe visibility allowlist (`[:user]`).
    * `:events` — optional oldest/newest-mixed event list for pure/offline use;
      if omitted, events are read from `Muse.State.events/0`.

  The returned envelopes use string keys and JSON-safe values so callers can
  pass them directly to Phoenix channel `push/3` or Jason encoding.
  """
  @spec external_replay(external_opts()) :: [map()]
  def external_replay(opts) when is_list(opts) or is_map(opts) do
    events =
      case fetch_external_opt(opts, :events) do
        {:ok, events} when is_list(events) -> events
        _ -> Muse.State.events()
      end

    external_replay(events, opts)
  end

  @doc """
  Pure variant of `external_replay/1` for callers that already have an event log.
  """
  @spec external_replay([Event.t()], external_opts()) :: [map()]
  def external_replay(events, opts) when is_list(events) and (is_list(opts) or is_map(opts)) do
    events
    |> Enum.filter(&external_event?(&1, opts))
    |> order_external_oldest_first()
    |> apply_external_replay_limit(external_replay_limit(opts))
    |> Enum.map(&event_to_external_envelope/1)
  end

  @doc """
  Return an external envelope for one live event, or `nil` if it is not visible.

  `SessionChannel`-style callers can use this on `{:muse_event, event}` messages
  and push only when a map is returned:

      case Muse.EventStream.external_envelope(event, session_id: session_id) do
        nil -> :ok
        envelope -> push(socket, "event", envelope)
      end
  """
  @spec external_envelope(Event.t(), external_opts()) :: map() | nil
  def external_envelope(event, opts \\ [])

  def external_envelope(%Event{} = event, opts) when is_list(opts) or is_map(opts) do
    if external_event?(event, opts), do: event_to_external_envelope(event)
  end

  def external_envelope(_event, _opts), do: nil

  @doc "Return true when an event passes the external session/type/visibility filters."
  @spec external_event?(Event.t(), external_opts()) :: boolean()
  def external_event?(event, opts \\ [])

  def external_event?(%Event{} = event, opts) when is_list(opts) or is_map(opts) do
    session_id = external_session_id(opts)

    is_binary(session_id) and event.session_id == session_id and
      event.visibility in requested_external_visibilities(opts) and
      event.type in requested_external_event_types(opts)
  end

  def external_event?(_event, _opts), do: false

  @doc "Return the externally-visible event type allowlist."
  @spec external_event_types() :: [atom()]
  def external_event_types, do: @external_event_types

  @doc "Return the externally-visible visibility allowlist."
  @spec external_visibilities() :: [atom()]
  def external_visibilities, do: @external_visibilities

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

  # -- External replay/envelope helpers ---------------------------------------

  defp external_session_id(opts) do
    case fetch_external_opt(opts, :session_id) do
      {:ok, value} -> normalize_external_string(value)
      :error -> nil
    end
  end

  defp requested_external_event_types(opts) do
    case fetch_first_external_opt(opts, [:event_types, :types]) do
      {:ok, value} -> normalize_requested_values(value, &normalize_external_event_type/1)
      :error -> @external_event_types
    end
  end

  defp requested_external_visibilities(opts) do
    case fetch_first_external_opt(opts, [:visibilities, :visibility]) do
      {:ok, value} -> normalize_requested_values(value, &normalize_external_visibility/1)
      :error -> @external_visibilities
    end
  end

  defp external_replay_limit(opts) do
    raw_limit =
      case fetch_first_external_opt(opts, [:replay_limit, :limit]) do
        {:ok, value} -> value
        :error -> configured_external_replay_limit()
      end

    parse_external_replay_limit(raw_limit, @default_external_replay_limit)
  end

  defp configured_external_replay_limit do
    config = Application.get_env(:muse, :external_event_stream, [])

    case fetch_first_external_opt(config, [:replay_limit, :limit]) do
      {:ok, value} -> value
      :error -> @default_external_replay_limit
    end
  end

  defp parse_external_replay_limit(limit, _default) when is_integer(limit) and limit >= 0,
    do: limit

  defp parse_external_replay_limit(limit, default) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_external_replay_limit(_limit, default), do: default

  defp apply_external_replay_limit(_events, 0), do: []

  defp apply_external_replay_limit(events, limit) when is_integer(limit) and limit > 0 do
    Enum.take(events, -limit)
  end

  defp order_external_oldest_first(events) do
    events
    |> Enum.with_index()
    |> Enum.sort_by(fn {event, index} -> {external_order_key(event), index} end)
    |> Enum.map(fn {event, _index} -> event end)
  end

  defp external_order_key(%Event{id: id}) when is_integer(id), do: {0, id}

  defp external_order_key(%Event{timestamp: %DateTime{} = timestamp}) do
    {1, DateTime.to_unix(timestamp, :microsecond)}
  end

  defp external_order_key(_event), do: {2, 0}

  defp event_to_external_envelope(%Event{} = event) do
    %{
      "id" => json_safe(event.id),
      "timestamp" => external_timestamp(event.timestamp),
      "source" => external_name(event.source),
      "type" => external_name(event.type),
      "data" => event.data |> Muse.EventDisplay.safe_data() |> json_safe()
    }
    |> maybe_put_external("session_id", event.session_id)
    |> maybe_put_external("turn_id", event.turn_id)
    |> maybe_put_external("seq", event.seq)
    |> maybe_put_external("parent_id", event.parent_id)
    |> maybe_put_external("visibility", external_optional_name(event.visibility))
    |> maybe_put_external("muse_id", event.muse_id)
  end

  defp maybe_put_external(map, _key, nil), do: map
  defp maybe_put_external(map, key, value), do: Map.put(map, key, json_safe(value))

  defp external_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp external_timestamp(nil), do: nil
  defp external_timestamp(other), do: json_safe(other)

  defp external_optional_name(nil), do: nil
  defp external_optional_name(value), do: external_name(value)

  defp external_name(value) when is_atom(value), do: Atom.to_string(value)
  defp external_name(value) when is_binary(value), do: value
  defp external_name(value), do: inspect(value)

  defp normalize_external_string(value) when is_binary(value) do
    value
  end

  defp normalize_external_string(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_external_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_external_string(_value), do: nil

  defp normalize_requested_values(value, normalizer) do
    value
    |> external_value_list()
    |> Enum.flat_map(normalizer)
    |> Enum.uniq()
  end

  defp external_value_list(nil), do: []

  defp external_value_list(value) when is_list(value) do
    Enum.flat_map(value, &external_value_list/1)
  end

  defp external_value_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp external_value_list(value), do: [value]

  defp normalize_external_event_type(type) when is_atom(type) do
    if type in @external_event_types, do: [type], else: []
  end

  defp normalize_external_event_type(type) when is_binary(type) do
    Enum.filter(@external_event_types, &(Atom.to_string(&1) == type))
  end

  defp normalize_external_event_type(_type), do: []

  defp normalize_external_visibility(visibility) when is_atom(visibility) do
    if visibility in @external_visibilities, do: [visibility], else: []
  end

  defp normalize_external_visibility(visibility) when is_binary(visibility) do
    Enum.filter(@external_visibilities, &(Atom.to_string(&1) == visibility))
  end

  defp normalize_external_visibility(_visibility), do: []

  defp fetch_first_external_opt(opts, keys) do
    Enum.find_value(keys, :error, fn key ->
      case fetch_external_opt(opts, key) do
        {:ok, _value} = found -> found
        :error -> false
      end
    end)
  end

  defp fetch_external_opt(opts, key) when is_list(opts) do
    string_key = Atom.to_string(key)

    case Enum.find(opts, fn
           {^key, _value} -> true
           {^string_key, _value} -> true
           _other -> false
         end) do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp fetch_external_opt(opts, key) when is_map(opts) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(opts, key) -> Map.fetch(opts, key)
      Map.has_key?(opts, string_key) -> Map.fetch(opts, string_key)
      true -> :error
    end
  end

  defp fetch_external_opt(_opts, _key), do: :error

  defp json_safe(term) when is_binary(term), do: term
  defp json_safe(term) when is_boolean(term), do: term
  defp json_safe(term) when is_number(term), do: term
  defp json_safe(nil), do: nil

  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%Date{} = date), do: Date.to_iso8601(date)
  defp json_safe(%Time{} = time), do: Time.to_iso8601(time)

  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp json_safe(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&json_safe/1)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(%{__struct__: struct_name} = struct) do
    safe_fields =
      struct
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {json_key(key), json_safe(value)} end)

    Map.put(safe_fields, "__struct__", external_name(struct_name))
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(other), do: inspect(other)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_key(%Date{} = date), do: Date.to_iso8601(date)
  defp json_key(%Time{} = time), do: Time.to_iso8601(time)
  defp json_key(key) when is_number(key), do: to_string(key)
  defp json_key(key), do: inspect(key)

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
