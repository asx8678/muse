defmodule MuseWeb.ExternalSocketConfig do
  @moduledoc """
  Runtime configuration for the optional external WebSocket channel.

  Provides safe defaults for `enabled?/0` (default `false`) and `replay_limit/0`
  (default `100`) so that callers (`UserSocket`, `SessionChannel`, etc.) can
  check whether an externally-facing WebSocket is allowed, and how many recent
  messages to replay on reconnect.

  ## Configuration

  The underlying application env key is `:external_ws` under the `:muse` OTP app:

      config :muse, :external_ws,
        enabled: true,
        replay_limit: 200

  ## Environment variable

  The `MUSE_EXTERNAL_WS` environment variable is also checked when no explicit
  app config `enabled:` key is set. Accepted truthy values are `"true"`, `"1"`,
  `"yes"`, and `"on"` (case-sensitive). All other values (including `"TRUE"`,
  `"Yes"`) are treated as disabled.

  App config `enabled: true/false` takes priority over the env var when both
  are present.

  ## Safe defaults

  By default the external WebSocket is **disabled** (enabled: false).  This
  protects production deployments that bind the Phoenix endpoint to `127.0.0.1`
  from accidentally exposing a raw WebSocket to the network.

  When enabled, `replay_limit` caps the number of recent session events that
  will be replayed to a reconnecting client.
  """

  @default_enabled false
  @default_replay_limit 100

  @env_true_values ["true", "1", "yes", "on"]

  @doc """
  Returns `true` if the external WebSocket channel is enabled.

  The channel is enabled when **either** of the following is true:

    * Application config `config :muse, :external_ws, enabled: true` is set.
    * Environment variable `MUSE_EXTERNAL_WS` is set to one of
      `#{Enum.join(@env_true_values, "`, `")}` (case-sensitive).

  App config takes precedence over env var when both are present. If neither
  is explicitly truthy, the channel remains disabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    app_env() |> Keyword.get(:enabled) |> resolve_enabled()
  end

  @doc """
  Returns the maximum number of recent messages to replay when an external
  WebSocket client reconnects.
  """
  @spec replay_limit() :: non_neg_integer()
  def replay_limit do
    app_env() |> Keyword.get(:replay_limit, @default_replay_limit)
  end

  # -- Helpers -----------------------------------------------------------------

  defp app_env, do: Application.get_env(:muse, :external_ws, [])

  # When app config has an explicit boolean, use it directly.
  defp resolve_enabled(true), do: true
  defp resolve_enabled(false), do: false

  # When app config is nil or missing, fall back to env var.
  defp resolve_enabled(nil) do
    case System.get_env("MUSE_EXTERNAL_WS") do
      value when value in @env_true_values -> true
      _ -> @default_enabled
    end
  end
end
