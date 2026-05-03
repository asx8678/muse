defmodule MuseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :muse

  @session_options [
    store: :cookie,
    key: "_muse_key",
    signing_salt: "dev-salt"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], log: false]
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
  plug(Plug.Session, @session_options)
  plug(MuseWeb.Router)
end
