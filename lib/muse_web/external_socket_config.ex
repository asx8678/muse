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

  ## Safe defaults

  By default the external WebSocket is **disabled** (enabled: false).  This
  protects production deployments that bind the Phoenix endpoint to `127.0.0.1`
  from accidentally exposing a raw WebSocket to the network.

  When enabled, `replay_limit` caps the number of recent session events that
  will be replayed to a reconnecting client.
  """

  @default_enabled false
  @default_replay_limit 100

  @doc """
  Returns `true` if the external WebSocket channel is enabled.

  ## Examples

      iex> MuseWeb.ExternalSocketConfig.enabled?()
      false

  Config values propagate through `Application.get_env/2` so tests may
  temporarily set `Application.put_env(:muse, :external_ws, enabled: true)`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    app_env() |> Keyword.get(:enabled, @default_enabled)
  end

  @doc """
  Returns the maximum number of recent messages to replay when an external
  WebSocket client reconnects.

  ## Examples

      iex> MuseWeb.ExternalSocketConfig.replay_limit()
      100
  """
  @spec replay_limit() :: non_neg_integer()
  def replay_limit do
    app_env() |> Keyword.get(:replay_limit, @default_replay_limit)
  end

  # -- Helpers -----------------------------------------------------------------

  defp app_env, do: Application.get_env(:muse, :external_ws, [])
end
