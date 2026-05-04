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
  """

  alias Muse.Event

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

  ## Examples

      iex> events = Muse.EventStream.replay(session_id: "sess_1", visibility: :user)
      iex> Enum.all?(events, &(&1.session_id == "sess_1" and &1.visibility == :user))
      true
  """
  @spec replay(keyword()) :: [Event.t()]
  def replay(opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    visibility = Keyword.get(opts, :visibility)

    Muse.State.events()
    |> maybe_filter_by_session(session_id)
    |> maybe_filter_by_visibility(visibility)
  end

  @doc """
  Derive chat messages from an event stream.

  Converts the structured event stream into a list of chat messages suitable
  for CLI/LiveView rendering. Handles:

    * `:user_message` events → user chat messages
    * `:assistant_delta` events → streaming assistant chunks
    * `:assistant_message` events → final assistant messages
    * Deduplication: if deltas were streamed (`streamed?: true` in data),
      the final `:assistant_message` is suppressed

  Each chat message is a map with keys:

    * `:id` — event ID
    * `:role` — `:user` or `:assistant`
    * `:text` — message text (concatenated deltas or final text)
    * `:timestamp` — formatted timestamp string
    * `:source` — event source
    * `:streaming?` — whether the message is still streaming (has deltas
      but no final `:assistant_message` yet)

  Incomplete streams (deltas without a final `:assistant_message`) are
  included as streaming assistant messages with `streaming?: true`.
  """
  @spec chat_messages([Event.t()]) :: [map()]
  def chat_messages(events) when is_list(events) do
    events
    |> Enum.filter(&(&1.type in [:user_message, :assistant_delta, :assistant_message]))
    |> group_by_turn_preserving_order()
    |> Enum.flat_map(&turn_to_messages/1)
  end

  # -- Private helpers ----------------------------------------------------------

  # Group events by turn_id while preserving the temporal order of first
  # appearance of each turn_id. This is important because turn_ids are
  # random strings, so lexicographic sorting would not match time order.
  defp group_by_turn_preserving_order(events) do
    {groups, _seen} =
      Enum.reduce(events, {[], MapSet.new()}, fn event, {acc, seen} ->
        turn_id = event.turn_id

        if MapSet.member?(seen, turn_id) do
          {acc, seen}
        else
          turn_events = Enum.filter(events, &(&1.turn_id == turn_id))
          {[{turn_id, turn_events} | acc], MapSet.put(seen, turn_id)}
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
  # A turn has exactly one user message and zero or more assistant
  # events (deltas + optional final).
  defp turn_to_messages({_turn_id, events}) do
    events = Enum.sort_by(events, & &1.seq)

    user_events = Enum.filter(events, &(&1.type == :user_message))
    assistant_deltas = Enum.filter(events, &(&1.type == :assistant_delta))
    assistant_finals = Enum.filter(events, &(&1.type == :assistant_message))

    user_messages = Enum.map(user_events, &event_to_chat_message/1)

    assistant_messages =
      case {assistant_deltas, assistant_finals} do
        # No deltas, no final — nothing to render
        {[], []} ->
          []

        # No deltas, just final message — render the final
        {[], [final]} ->
          [event_to_chat_message(final)]

        # Deltas present, final has streamed?: true — render concatenated
        # deltas, suppress duplicate final
        {deltas, [final]} ->
          if streamed?(final) do
            [deltas_to_message(deltas, final)]
          else
            # Deltas present but final not marked streamed — render both
            [deltas_to_message(deltas, final), event_to_chat_message(final)]
          end

        # Deltas with no final — still streaming
        {deltas, []} ->
          [deltas_to_streaming_message(deltas)]
      end

    user_messages ++ assistant_messages
  end

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

  defp deltas_to_message(deltas, _final) do
    text =
      deltas
      |> Enum.sort_by(& &1.seq)
      |> Enum.map_join("", &Map.get(&1.data, :text, ""))

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
      |> Enum.sort_by(& &1.seq)
      |> Enum.map_join("", &Map.get(&1.data, :text, ""))

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

  defp chat_role(:user_message), do: :user
  defp chat_role(:assistant_message), do: :assistant
  defp chat_role(:assistant_delta), do: :assistant
  defp chat_role(_), do: :system

  defp chat_text(%Event{data: data}) when is_map(data),
    do: Map.get(data, :text) || Map.get(data, "text") || ""

  defp chat_text(%Event{data: data}) when is_binary(data), do: data
  defp chat_text(%Event{data: nil}), do: ""
  defp chat_text(%Event{data: data}), do: inspect(data)

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
