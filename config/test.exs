import Config

config :muse, MuseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :muse, :logger,
  buffer_level: :warning,
  console_level: :warning

config :logger, :default_handler, level: :warning

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []

# Enable external WebSocket channel for test coverage.
config :muse, :external_ws,
  enabled: true,
  replay_limit: 50

# Prevent the Application supervisor from starting runtime children
# (Workspace, State, CLI.Repl, Endpoint, DevReloader) during mix test.
# Existing tests manually start/stop those globally-named processes,
# so automatic supervision would cause name conflicts.
config :muse, :start_runtime_children?, false
