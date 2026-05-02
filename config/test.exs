import Config

config :muse, MuseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :muse, :logger, level: :warning

# Prevent the Application supervisor from starting runtime children
# (Workspace, State, CLI.Repl, Endpoint, DevReloader) during mix test.
# Existing tests manually start/stop those globally-named processes,
# so automatic supervision would cause name conflicts.
config :muse, :start_runtime_children?, false
