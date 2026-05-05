defmodule MuseWeb.SessionChannel do
  @moduledoc """
  Phoenix Channel for streaming Muse events to external WebSocket clients.

  ## Topic format

      session:<session_id>

  Only this exact topic format is accepted. Invalid topics, empty session
  IDs, or malformed patterns are rejected on join.

  ## Event flow

  On successful join the channel process subscribes to
  `Muse.State.subscribe/0` and receives:

    * `{:muse_event, %Muse.Event{}}` — broadcast for every new event.
    * `{:muse_events_cleared}` — broadcast when the event log is cleared.

  ## Safety

  * Only events with `visibility` of `:user` or `nil` (legacy) are
    forwarded.  `:debug`, `:internal`, and `:sensitive` events are
    silently dropped.
  * Only events matching the joined session ID **or** global events
    (where `session_id` is `nil`) are forwarded.
  * Event payloads pass through `Muse.EventDisplay.safe_data/1` and
    `MuseWeb.ExportJSON.json_safe/1` before being pushed — secrets,
    raw plan JSON, and non-encodable terms are redacted.
  * The `"events_cleared"` push carries no internal state details.
  """

  use Phoenix.Channel

  alias Muse.Event
  alias Muse.EventDisplay
  alias MuseWeb.ExportJSON

  @replay_event "muse_event"
  @live_event "muse_event"
  @cleared_event "events_cleared"

  @visible [:user, nil]

  # -- Join -------------------------------------------------------------------

  @impl true
  def join("session:" <> session_id, _payload, socket) do
    session_id = String.trim(session_id)

    if valid_session_id?(session_id) do
      :ok = Muse.State.subscribe()

      socket = Phoenix.Socket.assign(socket, :session_id, session_id)

      # Defer replay push to handle_info — Phoenix forbids push during join
      send(self(), :after_join)

      {:ok, socket}
    else
      {:error, %{reason: "invalid_session_id"}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  # -- Info -------------------------------------------------------------------

  @impl true
  def handle_info(:after_join, socket) do
    session_id = socket.assigns.session_id

    # Replay includes session-scoped and global (nil session_id) events
    # to be consistent with live event forwarding behavior.
    replay =
      Muse.State.events()
      |> Enum.filter(&(event_matches_session?(&1, session_id) and event_visibility_allowed?(&1)))
      |> Enum.map(&safe_event_envelope/1)

    push(socket, @replay_event, %{"events" => replay})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:muse_event, %Event{} = event}, socket) do
    session_id = socket.assigns.session_id

    if event_matches_session?(event, session_id) and
         event_visibility_allowed?(event) do
      push(socket, @live_event, safe_event_envelope(event))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:muse_events_cleared}, socket) do
    push(socket, @cleared_event, %{})
    {:noreply, socket}
  end

  # Allow unknown info messages to pass through without crashing
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Private helpers --------------------------------------------------------

  defp valid_session_id?(session_id) when is_binary(session_id) do
    String.length(session_id) > 0 and String.length(session_id) <= 256 and
      not String.contains?(session_id, "\n")
  end

  defp valid_session_id?(_), do: false

  defp event_matches_session?(%Event{session_id: nil}, _session_id), do: true
  defp event_matches_session?(%Event{session_id: sid}, session_id), do: sid == session_id

  defp event_visibility_allowed?(%Event{visibility: v}), do: v in @visible

  defp safe_event_envelope(%Event{} = event) do
    %{
      "id" => event.id,
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "source" => to_string(event.source),
      "type" => to_string(event.type),
      "data" => event.data |> EventDisplay.safe_data() |> ExportJSON.json_safe(),
      "session_id" => event.session_id,
      "turn_id" => event.turn_id,
      "seq" => event.seq,
      "muse_id" => event.muse_id
    }
    |> drop_nils()
  end

  defp drop_nils(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
