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

  The `MUSE_EXTERNAL_WS` environment variable is checked **in addition** to app
  config. If the app config is `enabled: false` (the default in
  `config/config.exs`) but the env var is set to one of the truthy values below,
  the env var **wins** — this allows developers to opt in at runtime without
  modifying config files.

  Accepted truthy values are `"true"`, `"1"`, `"yes"`, and `"on"`
  (case-sensitive). All other values (including `"TRUE"`, `"Yes"`) are treated
  as disabled.

  The only case where app config truly overrides the env var is
  `enabled: true` — that unconditionally enables the socket.
  `enabled: false` does **not** mask a runtime env opt-in.

  ## Safe defaults

  By default the external WebSocket is **disabled** (enabled: false).  This
  protects production deployments that bind the Phoenix endpoint to `127.0.0.1`
  from accidentally exposing a raw WebSocket to the network.

  When enabled, `replay_limit` caps the number of recent session events that
  will be replayed to a reconnecting client.
  """

  @default_replay_limit 100

  @env_true_values ["true", "1", "yes", "on"]

  @doc """
  Returns `true` if the external WebSocket channel is enabled.

  The channel is enabled when **either** of the following is true:

    * Application config `config :muse, :external_ws, enabled: true` is set.
    * Environment variable `MUSE_EXTERNAL_WS` is set to one of
      `#{Enum.join(@env_true_values, "`, `")}` (case-sensitive).

  App config `enabled: true` unconditionally enables the socket.
  App config `enabled: false` (the default) does **not** block an env var
  opt-in — the env var is checked regardless. If neither is truthy, the
  channel remains disabled.
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
    app_env()
    |> Keyword.get(:replay_limit, @default_replay_limit)
    |> normalize_replay_limit()
  end

  @doc """
  Returns the configured token hash entries for external WebSocket auth.

  Each entry is a map with `:id`, `:hash`, `:scopes`, and `:allowed_sessions`.
  Returns an empty list when no token hashes are configured.
  """
  @spec token_hashes() :: [map()]
  def token_hashes do
    app_env()
    |> Keyword.get(:token_hashes, [])
    |> List.wrap()
  end

  # -- Helpers -----------------------------------------------------------------

  defp app_env, do: Application.get_env(:muse, :external_ws, [])

  defp normalize_replay_limit(limit) when is_integer(limit) and limit >= 0, do: limit

  defp normalize_replay_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> @default_replay_limit
    end
  end

  defp normalize_replay_limit(_limit), do: @default_replay_limit

  # App config enabled: true unconditionally enables.
  defp resolve_enabled(true), do: true

  # App config enabled: false (the safe default) does NOT mask env var.
  # Also handles nil/missing — always check env var as a fallback.
  defp resolve_enabled(_) do
    System.get_env("MUSE_EXTERNAL_WS") in @env_true_values
  end
end
