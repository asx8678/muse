defmodule Muse.Env do
  @moduledoc """
  Runtime environment flags — the single point of truth for
  environment-dependent behavior that used to rely on `Mix.env()`.

  All flags are read from application config so they work correctly
  in releases (where Mix is not available).  Every function falls back
  to a safe compiled-in default so the app behaves predictably even
  when no config is present.

  ## Available flags

    * `:dev_tools_enabled` — whether dev-only UI tools (simulate buttons,
      dev sidebar) are rendered and their events handled.
      Default: `false`.  Set `true` in dev/test/smoke configs.

    * `:runtime_provider_enabled` — whether runtime LLM provider
      resolution is active.  Default: `true`.  Set `false` in
      test/smoke configs to preserve offline/fake behavior.

  ## App-env structure

      config :muse, :dev_tools_enabled, true
      config :muse, :runtime_provider_enabled, true

  Overrides can also be set at runtime:

      Application.put_env(:muse, :dev_tools_enabled, false)
  """

  @doc """
  Whether dev-only tools (simulate buttons, dev sidebar) are enabled.

  Returns the value of `config :muse, :dev_tools_enabled`, defaulting to
  `false` when unset (safe for production).
  """
  @spec dev_tools_enabled?() :: boolean()
  def dev_tools_enabled? do
    Application.get_env(:muse, :dev_tools_enabled, false) == true
  end

  @doc """
  Whether runtime LLM provider resolution is enabled.

  Returns the value of `config :muse, :runtime_provider_enabled`,
  defaulting to `true` when unset (matching historical dev/prod behavior).

  When disabled, `Muse.RuntimeProvider.resolve_opts/0` returns
  `{:ok, []}` immediately, preserving the fake/offline provider.
  """
  @spec runtime_provider_enabled?() :: boolean()
  def runtime_provider_enabled? do
    Application.get_env(:muse, :runtime_provider_enabled, true) == true
  end
end
