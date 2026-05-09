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
# Test token: "test-token-16chars-ok" → hash below
# Test restricted token: "test-restricted-token" → hash below
config :muse, :external_ws,
  enabled: true,
  replay_limit: 50,
  token_hashes: [
    %{
      id: "test-token",
      hash: "3ab60f846fe880a6219f207e08a2435c8726750b20d27da02b3e935766d2cdde",
      scopes: ["events:read"],
      allowed_sessions: :all
    },
    %{
      id: "test-restricted",
      hash: "7cdcb3f377512175d3b82d7be5891f93458fcdc595f3189cbe8e6f2b30c0c454",
      scopes: ["events:read"],
      allowed_sessions: ["sess-allowed"]
    }
  ]

# Browser access control is not enforced in test so LiveView tests
# using build_conn() (remote_ip: 127.0.0.1 by default) and integration
# tests with custom remote IPs work without additional setup.
# The enforcement logic is tested directly via enforce_local_only/1.
config :muse, :browser_access, mode: :local_only
config :muse, :browser_access_enforced, false

# Prevent the Application supervisor from starting runtime children
# (Workspace, State, CLI.Repl, Endpoint, DevReloader) during mix test.
# Existing tests manually start/stop those globally-named processes,
# so automatic supervision would cause name conflicts.
config :muse, :start_runtime_children?, false

# Tighter bounds for deterministic cap-enforcement tests
config :muse, :bounds, %{
  session_events: 50,
  command_history: 5,
  toasts: 3,
  streaming_buffer_bytes: 256,
  diagnostics: 10
}
