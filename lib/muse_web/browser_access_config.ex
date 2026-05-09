defmodule MuseWeb.BrowserAccessConfig do
  @moduledoc """
  Configuration for browser LiveView access control.

  Determines whether the browser UI (LiveView) accepts connections from
  non-loopback addresses.  The default is `:local_only`, which restricts
  the browser UI to loopback (127.0.0.1 / ::1) only — safe for local
  development and single-machine production deployments.

  ## Modes

    * `:local_only`  — Only loopback-originating requests reach the
      browser UI.  Non-loopback requests receive 403 Forbidden.
      This is the **default** and safest mode.

    * `:authenticated` — Browser requests require valid authentication.
      (Reserved for future implementation; currently falls back to
      `:local_only` behaviour with a diagnostic warning.)

    * `:open` — Browser UI is accessible from any address.
      **Dangerous** — only valid when the endpoint binds to a trusted
      network (e.g. loopback) or when an upstream reverse proxy
      provides authentication.

  ## Configuration

  The underlying application env key is `:browser_access` under `:muse`:

      config :muse, :browser_access, mode: :local_only

  ## Environment variable

  The `MUSE_BROWSER_ACCESS` environment variable overrides app config
  in production.  Accepted values: `local_only`, `authenticated`, `open`.

  ## Production fail-fast

  When the endpoint HTTP bind address is a non-loopback address (e.g.
  `{0, 0, 0, 0}`, `{192, 168, 1, 10}`) and `mode` is `:local_only`,
  the application will refuse to start — this prevents an unsafe
  deployment where the browser UI is accidentally exposed on non-loopback
  interfaces with no authentication.

  Any non-loopback bind + `mode: :open` is also rejected because it
  exposes the browser UI to non-loopback networks without authentication.

  To bind non-loopback in production, set `MUSE_BROWSER_UNSAFE_BIND=1`
  to explicitly acknowledge the risk. Use this ONLY when a reverse proxy
  provides upstream authentication.

  ## Runtime validation ordering

  The CLI `--host` flag can override the endpoint bind address after
  `config/runtime.exs` runs.  Therefore, `assert_safe!/0` validates
  the config-time IP, and `assert_safe_for_ip!/1` should be called
  after `maybe_configure_endpoint/1` applies the effective bind IP.
  Both checks must pass for safe startup.

  ## LiveView socket boundary

  This module and the `BrowserAccessControl` plug guard the router
  browser pipeline (HTML/LiveView routes).  The Phoenix LiveView
  WebSocket transport (`/live`) is mounted at the endpoint level
  and is not filtered by the router plug.  For `:local_only` mode,
  the endpoint should bind to a loopback address so that the
  WebSocket transport is also unreachable from non-loopback clients.
  """

  @type mode :: :local_only | :authenticated | :open

  @valid_modes [:local_only, :authenticated, :open]

  @env_mapping %{
    "local_only" => :local_only,
    "authenticated" => :authenticated,
    "open" => :open
  }

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns the effective browser access mode.

  Resolution order:
    1. Environment variable `MUSE_BROWSER_ACCESS` (production override).
    2. Application config `config :muse, :browser_access, mode: <atom>`.
    3. Default: `:local_only`.
  """
  @spec mode() :: mode()
  def mode do
    env_mode() || app_mode() || :local_only
  end

  @doc """
  Returns `true` if the browser UI should reject non-loopback requests.
  """
  @spec local_only?() :: boolean()
  def local_only?, do: mode() == :local_only

  @doc """
  Returns `true` if the browser UI is fully open to all addresses.
  """
  @spec open?() :: boolean()
  def open?, do: mode() == :open

  @doc """
  Returns `true` if the given IP address is a loopback address.

  Handles both IPv4 (`{127, 0, 0, 1}`) and IPv6 (`{0, 0, 0, 0, 0, 0, 0, 1}`)
  loopback, as well as IPv4-mapped IPv6 loopback
  (`{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}`).
  """
  @spec loopback?(:inet.ip_address()) :: boolean()
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped IPv6 loopback: ::ffff:127.0.0.1
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}), do: true

  def loopback?({0, 0, 0, 0, 0, 0xFFFF, byte3, byte4})
      when byte3 in 0x7F00..0x7FFF and byte4 in 0..255,
      do: true

  def loopback?(_), do: false

  @doc """
  Returns the endpoint HTTP bind IP tuple from application config.

  Falls back to `{127, 0, 0, 1}` if not configured.
  """
  @spec endpoint_ip() :: :inet.ip_address()
  def endpoint_ip do
    http = Application.get_env(:muse, MuseWeb.Endpoint, []) |> Keyword.get(:http, [])
    Keyword.get(http, :ip, {127, 0, 0, 1})
  end

  @doc """
  Validates the browser access configuration for production.

  Reads the endpoint IP from application config and delegates to
  `assert_safe_for_ip!/1`.

  This should be called in `config/runtime.exs` for config-time
  validation.  For post-startup validation (after `--host` CLI
  override), call `assert_safe_for_ip!/1` with the effective IP.
  """
  @spec assert_safe!() :: :ok
  def assert_safe!, do: assert_safe_for_ip!(endpoint_ip())

  @doc """
  Validates the browser access configuration for a specific IP.

  Raises if an unsafe combination is detected:
    * IP is non-loopback with `:local_only` mode — requests from
      non-loopback would be rejected, but the endpoint itself is
      reachable, creating confusing partial access.
    * IP is non-loopback with `:open` mode — browser UI exposed
      to non-loopback networks without authentication.

  The `MUSE_BROWSER_UNSAFE_BIND` env var (value `"1"`) explicitly
  acknowledges the risk and bypasses the check.  Use this ONLY when
  a reverse proxy provides upstream authentication.

  Call this after `maybe_configure_endpoint/1` applies the CLI
  `--host` override so the effective bind IP is validated.
  """
  @spec assert_safe_for_ip!(:inet.ip_address()) :: :ok
  def assert_safe_for_ip!(ip) do
    current_mode = mode()

    cond do
      unsafe_bind_acknowledged?() ->
        :ok

      non_loopback_ip?(ip) and current_mode == :local_only ->
        raise_unsafe_config(ip, current_mode)

      non_loopback_ip?(ip) and current_mode == :open ->
        raise_unsafe_config(ip, current_mode)

      true ->
        :ok
    end
  end

  @doc """
  Returns `true` if the endpoint IP is a wildcard (0.0.0.0 or ::).
  """
  @spec wildcard_ip?(:inet.ip_address()) :: boolean()
  def wildcard_ip?({0, 0, 0, 0}), do: true
  def wildcard_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def wildcard_ip?(_), do: false

  @doc """
  Returns `true` if the IP is non-loopback (including wildcard and
  link-local).

  Only actual loopback addresses are considered safe for `:local_only`
  mode.  Link-local addresses (169.254.x.x) are reachable by other
  machines on the local link and are therefore non-loopback for
  access-control purposes.
  """
  @spec non_loopback_ip?(:inet.ip_address()) :: boolean()
  def non_loopback_ip?(ip), do: not loopback?(ip)

  @doc """
  Returns the list of valid mode atoms.
  """
  @spec valid_modes() :: [mode()]
  def valid_modes, do: @valid_modes

  # -- Private -----------------------------------------------------------------

  defp env_mode do
    case System.get_env("MUSE_BROWSER_ACCESS") do
      nil -> nil
      value -> Map.get(@env_mapping, value)
    end
  end

  defp app_mode do
    case Application.get_env(:muse, :browser_access, []) |> Keyword.get(:mode) do
      nil -> nil
      mode when mode in @valid_modes -> mode
      _invalid -> nil
    end
  end

  defp unsafe_bind_acknowledged? do
    System.get_env("MUSE_BROWSER_UNSAFE_BIND") == "1"
  end

  defp raise_unsafe_config(ip, mode) do
    ip_str = ip_to_string(ip)

    raise """
    Unsafe browser access configuration detected.

    Endpoint IP : #{ip_str}
    Access mode  : #{mode}

    The browser LiveView UI would be reachable from non-loopback addresses
    without adequate protection. This is a security risk.

    To resolve, choose ONE of:

      1. Bind to loopback (recommended for single-machine use):
         Set --host 127.0.0.1 or MUSE_HOST=127.0.0.1

      2. Explicitly acknowledge the risk (use ONLY with a reverse proxy
         that provides upstream authentication):
         Set MUSE_BROWSER_UNSAFE_BIND=1

      3. Use authenticated mode (once implemented):
         Set MUSE_BROWSER_ACCESS=authenticated

    Current config:
      Endpoint http.ip = #{inspect(ip)}
      Browser access mode = #{inspect(mode)}
    """
  end

  defp ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp ip_to_string({a, b, c, d, e, f, g, h}) do
    # Format abbreviated IPv6
    groups = [a, b, c, d, e, f, g, h]
    formatted = groups |> Enum.map(&Integer.to_string(&1, 16)) |> Enum.join(":")
    "[#{formatted}]"
  end

  defp ip_to_string(ip), do: inspect(ip)
end
