defmodule MuseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :muse

  # Session options are read from endpoint config at runtime so that
  # production releases can set the signing_salt via config/runtime.exs
  # instead of baking in a dev-only compile-time value.
  #
  # The LiveView socket uses an MFA tuple ({__MODULE__, :session_options, []})
  # so Phoenix evaluates it per-connection, reading the current signing_salt
  # from application config at WebSocket upgrade time.

  socket("/socket", MuseWeb.UserSocket, websocket: [log: false])

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}], log: false]
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.Static,
    at: "/assets",
    from: {:muse, "priv/static/assets"},
    gzip: false,
    only: ~w(app.js css)
  )

  plug(Plug.Static,
    at: "/images",
    from: {:muse, "priv/static/images"},
    gzip: false
  )

  plug(Plug.RequestId)
  plug(:plug_session)
  plug(MuseWeb.Router)

  # -- Runtime session configuration -------------------------------------------

  @doc """
  Returns session options for the cookie store, reading `signing_salt`
  from the endpoint config at runtime.

  Called per-request by `:plug_session` and per-WebSocket-connection
  by the LiveView socket's `connect_info` MFA tuple.
  """
  @spec session_options() :: keyword()
  def session_options do
    [
      store: :cookie,
      key: "_muse_key",
      signing_salt: signing_salt()
    ]
  end

  defp signing_salt do
    endpoint_config = Application.get_env(:muse, MuseWeb.Endpoint, [])
    Keyword.get(endpoint_config, :signing_salt, "dev-salt")
  end

  # Function plug: reads session options at request time so the
  # signing_salt is always the current value from application config,
  # even in releases where config/runtime.exs overrides it at boot.
  defp plug_session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end
end
