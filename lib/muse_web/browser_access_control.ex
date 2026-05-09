defmodule MuseWeb.BrowserAccessControl do
  @moduledoc """
  Plug that enforces browser LiveView access control based on remote IP.

  When `MuseWeb.BrowserAccessConfig.local_only?/0` returns `true` (the
  default), only requests originating from loopback addresses are allowed
  through the browser pipeline.  Non-loopback requests receive a 403
  Forbidden response with a clear but non-leaking error message.

  This plug is inserted into the `:browser` pipeline in the router,
  **after** `:fetch_session` so that session data is available for
  future authenticated-mode checks, but **before** the LiveView routes
  so that unauthorized routed requests never reach LiveView handlers.

  **Note:** The Phoenix LiveView WebSocket transport (`/live`) is
  mounted at the endpoint level and bypasses the router pipeline.
  For `:local_only` mode, ensure the endpoint binds to a loopback
  address so the WebSocket transport is also unreachable remotely.
  The router plug guards HTML/LiveView routes and their initial
  HTTP connections; the transport-layer boundary is the bind IP.

  ## Error responses

  Non-loopback requests receive a plain-text 403 response:

      403 Forbidden — browser UI is restricted to local access.

  The error message does not leak internal addresses, configuration
  values, or any other sensitive information.

  ## Bypass in test environment

  In the `:test` environment, `browser_access_enforced` defaults to
  `false` (see `config/test.exs`) so that LiveView tests using
  `build_conn()` and integration tests with custom remote IPs continue
  to work without additional setup.  The access control policy is still
  unit-tested directly via `enforce_local_only/1`.

  ## Future: authenticated mode

  When `MuseWeb.BrowserAccessConfig.mode/0` is `:authenticated`, this
  plug will check for a valid browser session token.  Until that mode
  is implemented, `:authenticated` falls through to `:local_only`
  behaviour.
  """

  import Plug.Conn
  alias MuseWeb.BrowserAccessConfig

  @behaviour Plug

  @forbidden_body "403 Forbidden — browser UI is restricted to local access.\n"

  # -- Plug callback ------------------------------------------------------------

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if enforced?() do
      check_access(conn)
    else
      conn
    end
  end

  # -- Public (testable) helpers ------------------------------------------------

  @doc """
  Enforce local-only access on the given connection.

  Returns the connection unchanged if `remote_ip` is loopback.
  Sends a 403 Forbidden and halts otherwise.

  This function is public so that tests can exercise the enforcement
  logic without needing to set the `:browser_access_enforced` flag.
  """
  @spec enforce_local_only(Plug.Conn.t()) :: Plug.Conn.t()
  def enforce_local_only(conn) do
    if BrowserAccessConfig.loopback?(conn.remote_ip) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, @forbidden_body)
      |> halt()
    end
  end

  # -- Private ------------------------------------------------------------------

  defp enforced? do
    Application.get_env(:muse, :browser_access_enforced, true)
  end

  defp check_access(conn) do
    cond do
      BrowserAccessConfig.open?() ->
        conn

      BrowserAccessConfig.local_only?() ->
        enforce_local_only(conn)

      true ->
        # :authenticated or unknown mode — fall through to local_only
        # for now (authenticated mode not yet implemented).
        enforce_local_only(conn)
    end
  end
end
