defmodule MuseWeb.Router do
  use MuseWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(MuseWeb.BrowserAccessControl)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/" do
    pipe_through(:api)
    forward("/socket/mcp-remote-client", Muse.Weft.Endpoints.McpClientHandler)
    forward("/proxy", Muse.Weft.Proxy.Http)
    forward("/download", Muse.Weft.Proxy.Download)
  end

  scope "/", MuseWeb do
    pipe_through(:browser)

    live_session :default, root_layout: {MuseWeb.Layouts, :root} do
      live("/", HomeLive)
    end
  end
end
