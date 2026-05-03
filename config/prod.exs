import Config

config :muse, MuseWeb.Endpoint,
  # Production secrets are loaded at runtime in config/runtime.exs so releases
  # can be assembled without embedding secrets into build artifacts.
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4000]

config :muse, :logger,
  buffer_level: :warning,
  console_level: :warning

config :logger, :default_handler, level: :warning

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []

# In production releases, source mode is always off.
config :muse, :source_mode?, false
