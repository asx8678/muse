defmodule MuseWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for external WebSocket clients (non-LiveView).

  Routes `session:*` topics to `MuseWeb.SessionChannel`.

  The LiveView socket at `/live` remains unchanged — this is a separate
  mount point for programmatic consumers (bots, IDE extensions, etc.).

  When the external WebSocket channel is disabled (the default), `connect/3`
  rejects all connections.
  """

  use Phoenix.Socket

  channel("session:*", MuseWeb.SessionChannel)

  @impl true
  def connect(_params, socket, _connect_info) do
    if MuseWeb.ExternalSocketConfig.enabled?() do
      {:ok, socket}
    else
      :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
