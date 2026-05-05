defmodule MuseWeb.UserSocket do
  @moduledoc """
  Socket for Phoenix Channels on the Muse web interface.

  Currently accepts all connections without authentication (auth will be
  added in a future iteration). Channels are scoped under `/socket`.
  """
  use Phoenix.Socket

  ## Channels
  channel("session:*", MuseWeb.SessionChannel)

  ## Socket API

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
