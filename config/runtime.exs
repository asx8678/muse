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

  # --- Primary secret --------------------------------------------------------
  # MUSE_SECRET_KEY_BASE is the single required production secret.
  # Cookie signing_salt and LiveView signing_salt are derived from it
  # using Plug.Crypto.KeyGenerator with stable labels, so redeployments
  # preserve session validity.  Override individually with
  # MUSE_SIGNING_SALT / MUSE_LV_SIGNING_SALT if needed.

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

  # --- Derived salts ----------------------------------------------------------
  # These are deterministic given the same secret_key_base, so sessions
  # survive restarts.  Labels are stable and should never be changed
  # (changing a label invalidates all existing sessions).

  signing_salt =
    System.get_env("MUSE_SIGNING_SALT") ||
      MuseWeb.Endpoint.Secrets.derive_salt(secret_key_base, "muse-cookie-signing-salt")

  lv_signing_salt =
    System.get_env("MUSE_LV_SIGNING_SALT") ||
      MuseWeb.Endpoint.Secrets.derive_salt(secret_key_base, "muse-liveview-signing-salt")

  config :muse, MuseWeb.Endpoint,
    secret_key_base: secret_key_base,
    signing_salt: signing_salt,
    live_view: [signing_salt: lv_signing_salt]

  # --- Final validation -------------------------------------------------------
  # Catches any remaining placeholder/dev values and enforces minimum lengths.
  # We pass the endpoint config explicitly so validation checks the runtime
  # values we just assembled, not the compiled-in defaults.
  endpoint_config =
    [
      secret_key_base: secret_key_base,
      signing_salt: signing_salt,
      live_view: [signing_salt: lv_signing_salt]
    ]

  MuseWeb.Endpoint.Secrets.validate_production!(endpoint_config)
end
