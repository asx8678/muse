import Config

config :muse, MuseWeb.Endpoint,
  # The secret_key_base must be set for releases. In production, override
  # via env var: RELEASE_NODE, MUSE_SECRET_KEY_BASE, etc.
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: System.get_env("MUSE_SECRET_KEY_BASE") ||
                     "production-secret-key-base-override-in-env-000000000000"

config :muse, :logger,
  buffer_level: :warning,
  console_level: :warning

config :logger, :default_handler, level: :warning

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []

# In production releases, source mode is always off.
config :muse, :source_mode?, false
