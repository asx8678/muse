defmodule Muse.Logging do
  @moduledoc """
  Configures the Erlang logger handlers based on the active UI mode.

  `Muse.Application.start/2` calls `configure/1` early in boot so that
  noisy Phoenix / Bandit / LiveView Logger messages are suppressed
  before any supervised process starts writing to the terminal.

  This module is intentionally a thin, testable shell over the OTP
  `:logger` API.
  """

  @doc """
  Configure the default console logger handler for the given UI mode.

  - `:verbose` — force default handler level to `:debug`, even in TUI mode.
  - `:repl` / `:none` — set default handler level from application env
    `console_level` (default `:warning`).
  - `:tui` — set default handler level to `:none` to prevent log lines
    from corrupting the terminal UI.

  Returns `:ok` unconditionally.  Errors (missing handler, unknown
  level) are silently swallowed so boot is never blocked by logging
  configuration.
  """
  @spec configure(:verbose | :repl | :tui | :none) :: :ok
  def configure(:verbose) do
    set_handler_level(:default, :debug)
  end

  def configure(:tui) do
    set_handler_level(:default, :none)
  end

  def configure(mode) when mode in [:repl, :none] do
    level =
      :muse
      |> Application.get_env(:logger, [])
      |> Keyword.get(:console_level, :warning)

    set_handler_level(:default, level)
  end

  # -- Helpers -----------------------------------------------------------------

  defp set_handler_level(handler_id, level) do
    case :logger.get_handler_config(handler_id) do
      {:ok, _config} ->
        :logger.set_handler_config(handler_id, :level, level)

      {:error, {:not_found, _id}} ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
