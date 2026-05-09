import Config

if config_env() == :prod do
  # External WebSocket channel — opt-in via env var for production.
  # Without this var the socket remains disabled.
  # When enabled, token hashes MUST be configured or the app fails to start.
  if System.get_env("MUSE_EXTERNAL_WS") == "true" do
    config :muse, :external_ws, enabled: true
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
