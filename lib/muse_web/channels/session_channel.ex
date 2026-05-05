defmodule MuseWeb.SessionChannel do
  @moduledoc """
  Phoenix Channel for real-time session event streaming.

  Clients join on `"session:<id>"` topics. On join, all existing events for
  that session are replayed (subject to visibility filtering). While
  connected, any new `%Muse.Event{}` broadcast on `Muse.PubSub` that matches
  the session ID is forwarded to the client.

  ## Visibility filtering

  Events with `visibility: :internal` or `visibility: :sensitive` are never
  pushed to the client. All pushed payloads are run through
  `Muse.EventPayloadRedactor.redact/1` for safety.
  """
  use Phoenix.Channel

  alias Muse.{EventPayloadRedactor, State}

  @doc """
  Validates and joins a session topic.

  Accepts `"session:<id>"` where `<id>` is a non-empty string without path
  traversal characters (`/`, `\\`, NUL). Returns `{:ok, socket}` on success
  and schedules a replay of matching events. Returns `{:error, %{reason: ...}}`
  for invalid topics.
  """
  @impl true
  def join("session:" <> session_id, _payload, socket) do
    with :ok <- validate_session_id(session_id) do
      socket = assign(socket, :session_id, session_id)

      # Subscribe to the global Muse event bus for live forwarding
      Phoenix.PubSub.subscribe(Muse.PubSub, "muse:events")

      # Schedule an asynchronous replay of existing events
      send(self(), {:replay_events, session_id})

      {:ok, socket}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: :invalid_topic}}
  end

  @doc """
  Handles the asynchronous replay message sent from `join/3`.

  Queries `Muse.State.events/0` and pushes only those events that match
  the session_id and pass visibility filtering.
  """
  @impl true
  def handle_info({:replay_events, session_id}, socket) do
    session_id
    |> replay_events()
    |> Enum.each(fn event ->
      push(socket, "muse_event", serialize_event(event))
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:muse_event, %Muse.Event{} = event}, socket) do
    if event.session_id == socket.assigns.session_id and visible?(event) do
      push(socket, "muse_event", serialize_event(event))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_other, socket) do
    {:noreply, socket}
  end

  # -- Private helpers ----------------------------------------------------------

  defp validate_session_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error, %{reason: :invalid_session_id}}

      id in [".", ".."] ->
        {:error, %{reason: :invalid_session_id}}

      String.contains?(id, "/") or String.contains?(id, "\\") or String.contains?(id, "\0") ->
        {:error, %{reason: :invalid_session_id}}

      true ->
        :ok
    end
  end

  defp validate_session_id(_other) do
    {:error, %{reason: :invalid_session_id}}
  end

  defp replay_events(session_id) do
    State.events()
    |> Enum.filter(fn event -> event.session_id == session_id end)
    |> Enum.filter(&visible?/1)
  end

  defp visible?(%Muse.Event{visibility: visibility}) do
    visibility not in [:internal, :sensitive]
  end

  defp visible?(%{visibility: visibility}) do
    visibility not in [:internal, :sensitive]
  end

  defp serialize_event(%Muse.Event{} = event) do
    %{
      id: event.id,
      timestamp: DateTime.to_iso8601(event.timestamp),
      source: event.source,
      type: event.type,
      data: EventPayloadRedactor.redact(event.data),
      session_id: event.session_id,
      turn_id: event.turn_id,
      seq: event.seq,
      parent_id: event.parent_id,
      visibility: event.visibility,
      muse_id: event.muse_id
    }
  end

  defp serialize_event(event) when is_map(event) do
    %{
      id: event.id,
      timestamp: event.timestamp,
      source: event.source,
      type: event.type,
      data: EventPayloadRedactor.redact(event.data),
      session_id: event.session_id,
      turn_id: event.turn_id,
      seq: event.seq,
      parent_id: event.parent_id,
      visibility: event.visibility,
      muse_id: event.muse_id
    }
  end
end
