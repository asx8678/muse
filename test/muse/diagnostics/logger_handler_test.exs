defmodule Muse.Diagnostics.LoggerHandlerTest do
  use ExUnit.Case, async: false

  require Logger

  alias Muse.Diagnostics
  alias Muse.Diagnostics.LoggerHandler

  # -- Helpers -----------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp start_diagnostics do
    stop_named(Muse.Diagnostics)
    {:ok, _} = Diagnostics.start_link(install_logger_handler?: false)
    :ok
  end

  # -- Setup -------------------------------------------------------------------

  setup do
    ensure_pubsub()
    LoggerHandler.remove()
    start_diagnostics()

    on_exit(fn ->
      LoggerHandler.remove()
      stop_named(Muse.Diagnostics)
    end)

    :ok
  end

  # -- Tests -------------------------------------------------------------------

  describe "format_message/1" do
    test "formats {:string, chardata}" do
      assert LoggerHandler.format_message({:string, ~c"plain warning"}) == "plain warning"
    end

    test "formats {format, args}" do
      assert LoggerHandler.format_message({~c"hello ~p", [:world]}) == "hello world"
    end

    test "formats reports defensively" do
      formatted = LoggerHandler.format_message({:report, %{error: :boom, file: "lib/muse.ex"}})

      assert formatted =~ "error: :boom"
      assert formatted =~ "file:"
    end
  end

  describe "normalize_level/1" do
    test "maps warning and severe levels" do
      assert LoggerHandler.normalize_level(:warn) == :warning
      assert LoggerHandler.normalize_level(:warning) == :warning
      assert LoggerHandler.normalize_level(:error) == :error
      assert LoggerHandler.normalize_level(:critical) == :critical
      assert LoggerHandler.normalize_level(:alert) == :critical
      assert LoggerHandler.normalize_level(:emergency) == :critical
    end

    test "ignores lower levels" do
      assert LoggerHandler.normalize_level(:notice) == :ignore
      assert LoggerHandler.normalize_level(:info) == :ignore
      assert LoggerHandler.normalize_level(:debug) == :ignore
    end
  end

  describe "install/0 and remove/0" do
    test "are idempotent" do
      assert :ok = LoggerHandler.install()
      assert :ok = LoggerHandler.install()
      assert :ok = LoggerHandler.remove()
      assert :ok = LoggerHandler.remove()
    end
  end

  describe "log/2" do
    test "direct callback forwards warning events" do
      :ok = Diagnostics.subscribe()

      assert :ok =
               LoggerHandler.log(
                 %{level: :warning, msg: {:string, "direct warning"}, meta: %{line: 10}},
                 %{}
               )

      assert_receive {:muse_diagnostic, diagnostic}, 500
      assert diagnostic.level == :warning
      assert diagnostic.message == "direct warning"
      assert diagnostic.metadata == %{line: 10}
    end

    test "direct callback ignores info and debug events" do
      assert :ok = LoggerHandler.log(%{level: :info, msg: {:string, "info"}, meta: %{}}, %{})
      assert :ok = LoggerHandler.log(%{level: :debug, msg: {:string, "debug"}, meta: %{}}, %{})

      assert Diagnostics.list() == []
    end

    test "direct callback is safe when diagnostics process is not running" do
      stop_named(Muse.Diagnostics)

      assert :ok =
               LoggerHandler.log(
                 %{level: :error, msg: {:string, "safe without process"}, meta: %{}},
                 %{}
               )
    end
  end

  describe "installed handler" do
    test "captures Logger.warning/1 when diagnostics is running" do
      :ok = Diagnostics.subscribe()
      assert :ok = LoggerHandler.install()

      Logger.warning("installed handler warning")

      assert_receive {:muse_diagnostic, diagnostic}, 1_000
      assert diagnostic.level == :warning
      assert diagnostic.message =~ "installed handler warning"
    end

    test "does not capture Logger.info/1 or Logger.debug/1" do
      assert :ok = LoggerHandler.install()
      assert :ok = Diagnostics.clear()

      Logger.info("ignored diagnostics info")
      Logger.debug("ignored diagnostics debug")

      Process.sleep(50)
      assert Diagnostics.list() == []
    end
  end
end
