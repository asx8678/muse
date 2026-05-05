defmodule MuseWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for external WebSocket clients (non-LiveView).

  Routes `session:*` topics to `MuseWeb.SessionChannel`.

  The LiveView socket at `/live` remains unchanged — this is a separate
  mount point for programmatic consumers (bots, IDE extensions, etc.).
  """

  use Phoenix.Socket

  channel("session:*", MuseWeb.SessionChannel)

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
