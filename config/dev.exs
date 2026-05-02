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

config :muse, :logger, level: :debug
