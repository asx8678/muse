defmodule Muse.LoggingTest do
  use ExUnit.Case, async: false

  alias Muse.Logging

  setup do
    original_default_handler = get_handler_config(:default)
    original_log_buffer_handler = get_handler_config(:muse_log_buffer)
    original_logger_env = Application.get_env(:muse, :logger)

    on_exit(fn ->
      restore_handler(:default, original_default_handler)
      restore_handler(:muse_log_buffer, original_log_buffer_handler)
      restore_logger_env(original_logger_env)
    end)

    :ok
  end

  describe "configure/1 — :tui" do
    test "sets default handler level to :none" do
      :logger.set_handler_config(:default, :level, :warning)
      assert :ok == Logging.configure(:tui)

      {:ok, config} = :logger.get_handler_config(:default)
      assert Map.get(config, :level) == :none
    end

    test "does not crash when default handler is absent" do
      :logger.remove_handler(:default)

      assert :ok == Logging.configure(:tui)
    end

    test "does not modify LogBuffer logger handler level" do
      Muse.LogBuffer.LoggerHandler.remove()
      assert :ok == Muse.LogBuffer.LoggerHandler.install(level: :debug)

      assert :ok == Logging.configure(:tui)

      {:ok, config} = :logger.get_handler_config(:muse_log_buffer)
      assert Map.get(config, :level) == :debug
    end
  end

  describe "configure/1 — :repl" do
    test "sets default handler level from console_level config" do
      Application.put_env(:muse, :logger, console_level: :debug)

      :logger.set_handler_config(:default, :level, :warning)
      assert :ok == Logging.configure(:repl)

      {:ok, config} = :logger.get_handler_config(:default)
      assert Map.get(config, :level) == :debug
    end

    test "defaults to :warning when console_level is not set" do
      Application.delete_env(:muse, :logger)

      :logger.set_handler_config(:default, :level, :error)
      assert :ok == Logging.configure(:repl)

      {:ok, config} = :logger.get_handler_config(:default)
      assert Map.get(config, :level) == :warning
    end
  end

  describe "configure/1 — :verbose" do
    test "sets default handler level to :debug" do
      :logger.set_handler_config(:default, :level, :warning)
      assert :ok == Logging.configure(:verbose)

      {:ok, config} = :logger.get_handler_config(:default)
      assert Map.get(config, :level) == :debug
    end

    test "overrides TUI :none when verbose is requested" do
      # First set to :none as TUI would
      :logger.set_handler_config(:default, :level, :none)
      assert :ok == Logging.configure(:verbose)

      {:ok, config} = :logger.get_handler_config(:default)
      assert Map.get(config, :level) == :debug
    end

    test "does not crash when default handler is absent" do
      :logger.remove_handler(:default)
      assert :ok == Logging.configure(:verbose)
    end
  end

  describe "configure/1 — :none" do
    test "behaves identically to :repl" do
      Application.put_env(:muse, :logger, console_level: :error)

      :logger.set_handler_config(:default, :level, :warning)
      assert :ok == Logging.configure(:none)

      {:ok, config} = :logger.get_handler_config(:default)
      assert Map.get(config, :level) == :error
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp get_handler_config(handler_id) do
    case :logger.get_handler_config(handler_id) do
      {:ok, config} -> config
      {:error, _} -> nil
    end
  end

  defp restore_handler(handler_id, nil) do
    :logger.remove_handler(handler_id)
    :ok
  end

  defp restore_handler(handler_id, config) do
    :logger.remove_handler(handler_id)
    :logger.add_handler(handler_id, Map.fetch!(config, :module), config)
    :ok
  end

  defp restore_logger_env(nil), do: Application.delete_env(:muse, :logger)
  defp restore_logger_env(val), do: Application.put_env(:muse, :logger, val)
end
