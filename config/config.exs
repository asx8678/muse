import Config

# --- Phoenix Endpoint (Bandit adapter) ---
# MuseWeb.Endpoint module will be added in a later step.
# Config is safe to declare now — it only sets application env at runtime.
config :phoenix, :filter_parameters, ["_csrf_token", "csrf_token", "token", "secret", "password"]

config :muse, MuseWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  secret_key_base:
    "placeholder-secret-key-base-for-dev-do-not-use-in-prod-0000000000000000000000",
  pubsub_server: Muse.PubSub,
  live_view: [signing_salt: "placeholder-signing-salt"],
  render_errors: [
    formats: [html: MuseWeb.ErrorHTML],
    layout: false
  ]

# --- Asset bundling ---
config :esbuild,
  version: "0.25.0",
  default: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# --- JSON library ---
config :phoenix, :json_library, Jason

# --- Optional external WebSocket channel ---
# Disabled by default.  When enabled, provides an externally-facing
# Phoenix WebSocket (UserSocket / SessionChannel) bound to whatever
# address the endpoint listens on.
#
# Production endpoints bind to 127.0.0.1 (see prod.exs) so the
# socket is still local-only unless the endpoint config is changed.
# Enable this with care — the external socket bypasses LiveView.
config :muse, :external_ws,
  enabled: false,
  replay_limit: 100

# --- Environment-specific overrides ---
import_config "#{config_env()}.exs"
