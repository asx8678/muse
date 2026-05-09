import Config

# Smoke test environment — used by `script/liveview-browser-smoke`.
#
# Starts the full runtime (unlike test env) but with no watchers,
# no code reloader, and a non-default port. Fake provider is the
# default so no API keys or network calls are needed.
#
# Usage:
#   MIX_ENV=smoke mix muse --web-only --port 4101 --no-watch
#   ./script/liveview-browser-smoke

config :muse, MuseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4101],
  url: [host: "127.0.0.1"],
  server: true,
  code_reloader: false,
  debug_errors: false,
  watchers: []

# Ensure runtime children start (only test env disables this).
config :muse, :start_runtime_children?, true

# Dev tools enabled in smoke for interactive testing.
config :muse, :dev_tools_enabled, true

# Runtime provider disabled in smoke to preserve offline/fake behavior.
config :muse, :runtime_provider_enabled, false

# Quiet logging — smoke output should be assertion-focused, not log-spammy.
config :muse, :logger,
  buffer_level: :warning,
  console_level: :error

config :logger, :default_handler, level: :error

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []
