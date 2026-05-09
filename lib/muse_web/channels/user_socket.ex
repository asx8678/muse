defmodule MuseWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for external WebSocket clients (non-LiveView).

  Routes `session:*` topics to `MuseWeb.SessionChannel`.

  The LiveView socket at `/live` remains unchanged — this is a separate
  mount point for programmatic consumers (bots, IDE extensions, etc.).

  ## Authentication

  When the external WebSocket channel is disabled (the default), `connect/3`
  rejects all connections.

  When enabled, clients must supply a `token` parameter during connection.
  The token is authenticated against configured token hashes using
  `MuseWeb.ExternalSocketAuth.authenticate/1`.  On success, an external
  principal (token id, scopes, allowed sessions) is assigned to the socket.

  ## Socket ID

  The socket id is derived from the authenticated token id only — never from
  the raw token value.
  """

  use Phoenix.Socket

  alias MuseWeb.{ExternalSocketAuth, ExternalSocketConfig}

  channel("session:*", MuseWeb.SessionChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    cond do
      not ExternalSocketConfig.enabled?() ->
        :error

      true ->
        case ExternalSocketAuth.authenticate(params) do
          {:ok, principal} ->
            socket =
              socket
              |> Phoenix.Socket.assign(:external_principal, principal)

            {:ok, socket}

          {:error, _reason} ->
            # Do not leak reason details to the client
            :error
        end
    end
  end

  @impl true
  def id(socket) do
    case Map.get(socket.assigns, :external_principal) do
      %{token_id: token_id} when is_binary(token_id) ->
        "external_socket:#{token_id}"

      _ ->
        nil
    end
  end
end
