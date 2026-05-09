import Config

config :muse, MuseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"assets/.*(js|css)$",
      ~r"priv/static/.*",
      ~r"lib/muse_web/(live|components|controllers)/.*(ex|heex)$"
    ]
  ]

# Dev uses loopback — browser access enforced for consistency.
config :muse, :browser_access, mode: :local_only
config :muse, :browser_access_enforced, true

# Dev tools (simulate buttons, dev sidebar) enabled in dev.
config :muse, :dev_tools_enabled, true

config :muse, :logger,
  buffer_level: :debug,
  console_level: :warning

config :logger, :default_handler, level: :warning

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []
