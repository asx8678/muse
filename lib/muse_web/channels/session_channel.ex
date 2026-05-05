defmodule MuseWeb.SessionChannel do
  @moduledoc """
  Phoenix Channel for streaming Muse events to external WebSocket clients.

  ## Topic format

      session:<session_id>

  Only this exact topic format is accepted. Invalid topics, empty session
  IDs, path-traversal patterns, or malformed session IDs are rejected on join.

  ## Event flow

  On successful join the channel process subscribes to `Muse.State.subscribe/0`
  and receives:

    * `{:muse_event, %Muse.Event{}}` — broadcast for every new event.
    * `{:muse_events_cleared}` — broadcast when the event log is cleared.

  ## Safety

  * All events pass through `MuseWeb.ExternalEventFilter.to_external_map/2`
    before being pushed — only `:user` visibility and explicitly allowlisted
    nil-visibility events are forwarded.
  * Only events with an exact session ID match are forwarded; nil session_id
    events are NOT forwarded on session-scoped topics.
  * Event payloads are redacted and JSON-safe — secrets, raw plan JSON, and
    non-encodable terms are omitted.
  * The `"events_cleared"` push carries no internal state details.
  * The channel is disabled by default — join succeeds only when
    `MuseWeb.ExternalSocketConfig.enabled?/0` is `true`.
  """

  use Phoenix.Channel

  alias Muse.EventStream
  alias MuseWeb.{ExternalEventFilter, ExternalSocketConfig}

  @live_event "muse_event"
  @replay_event "muse_event"
  @cleared_event "events_cleared"

  # -- Join -------------------------------------------------------------------

  @impl true
  def join("session:" <> session_id, _payload, socket) do
    if ExternalSocketConfig.enabled?() and ExternalEventFilter.valid_session_id?(session_id) do
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
    replay_limit = ExternalSocketConfig.replay_limit()

    replay =
      EventStream.external_replay(
        session_id: session_id,
        replay_limit: replay_limit
      )

    push(socket, @replay_event, %{"events" => replay})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:muse_event, %Muse.Event{} = event}, socket) do
    session_id = socket.assigns.session_id

    case ExternalEventFilter.to_external_map(event, session_id: session_id) do
      {:ok, envelope} ->
        push(socket, @live_event, envelope)

      {:error, _reason} ->
        :ok
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
end
