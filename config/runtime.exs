import Config

if config_env() == :prod do
  # Browser LiveView access control — validate safe configuration.
  # Fails closed if endpoint is bound to a non-loopback address
  # without explicit acknowledgement.
  MuseWeb.BrowserAccessConfig.assert_safe!()

  # External WebSocket channel — opt-in via config or truthy env var for production.
  # Without an explicit opt-in the socket remains disabled.
  # When enabled, valid token hashes MUST be configured or the app fails to start.
  if MuseWeb.ExternalSocketConfig.enabled?() do
    MuseWeb.ExternalSocketAuth.assert_configured!()
  end

  # WebSocket client for LLM transport — opt-in via env var for production.
  # When set to "mint", enables the Mint-backed WebSocket client.
  # Without this var the client remains unconfigured (safe for air-gapped
  # or SSE-only deployments).
  if System.get_env("MUSE_WS_CLIENT") == "mint" do
    config :muse, :websocket_client, Muse.LLM.Transport.WebSocket.MintAdapter
  end

  secret_key_base =
    System.get_env("MUSE_SECRET_KEY_BASE") ||
      raise """
      environment variable MUSE_SECRET_KEY_BASE is missing.

      Generate one with:

          mix phx.gen.secret

      Set MUSE_SECRET_KEY_BASE before starting the production release.
      """

  if byte_size(secret_key_base) < 64 do
    raise """
    environment variable MUSE_SECRET_KEY_BASE must be at least 64 bytes.

    Generate a strong value with:

        mix phx.gen.secret
    """
  end

  config :muse, MuseWeb.Endpoint, secret_key_base: secret_key_base
end
