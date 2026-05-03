defmodule Muse.LogBufferTest do
  use ExUnit.Case, async: false

  alias Muse.LogBuffer
  alias Muse.LogEntry

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

      _pid ->
        :ok
    end
  end

  defp stop_log_buffer do
    case Process.whereis(Muse.LogBuffer) do
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

  setup do
    ensure_pubsub()
    stop_log_buffer()

    {:ok, _} = LogBuffer.start_link(install_logger_handler?: false)

    on_exit(fn ->
      stop_log_buffer()
    end)

    :ok
  end

  describe "append/4" do
    test "appends a log entry and returns it" do
      entry = LogBuffer.append(:info, "test message")
      assert %LogEntry{} = entry
      assert entry.level == :info
      assert entry.message == "test message"
      assert entry.source == :app
    end

    test "appends with custom metadata and source" do
      entry = LogBuffer.append(:error, "error msg", %{key: "val"}, :runtime)
      assert entry.level == :error
      assert entry.metadata == %{key: "val"}
      assert entry.source == :runtime
    end

    test "normalizes :warn level to :warning" do
      entry = LogBuffer.append(:warn, "warning msg")
      assert entry.level == :warning
    end
  end

  describe "list/0" do
    test "returns entries newest first" do
      LogBuffer.append(:info, "first")
      LogBuffer.append(:info, "second")
      LogBuffer.append(:info, "third")

      entries = LogBuffer.list()
      assert length(entries) == 3
      # Newest first
      assert Enum.at(entries, 0).message == "third"
      assert Enum.at(entries, 2).message == "first"
    end
  end

  describe "clear/0" do
    test "clears all entries" do
      LogBuffer.append(:info, "will be cleared")
      assert length(LogBuffer.list()) == 1

      :ok = LogBuffer.clear()
      assert LogBuffer.list() == []
    end
  end

  describe "max entries cap" do
    test "caps entries to configured max" do
      stop_log_buffer()
      {:ok, _} = LogBuffer.start_link(max_entries: 5, install_logger_handler?: false)

      for i <- 1..10 do
        LogBuffer.append(:info, "entry #{i}")
      end

      entries = LogBuffer.list()
      assert length(entries) == 5
      # Newest entries retained
      assert Enum.at(entries, 0).message == "entry 10"
      assert Enum.at(entries, 4).message == "entry 6"
    end
  end

  describe "subscribe/0" do
    test "broadcasts new log entries to subscribers" do
      :ok = LogBuffer.subscribe()

      LogBuffer.append(:info, "broadcast test")

      assert_received {:muse_log, entry}
      assert entry.message == "broadcast test"
    end

    test "broadcasts cleared event" do
      :ok = LogBuffer.subscribe()

      LogBuffer.clear()

      assert_received {:muse_logs_cleared}
    end
  end

  describe "snapshot/0" do
    test "returns entries and count" do
      LogBuffer.append(:info, "snap1")
      LogBuffer.append(:error, "snap2")

      snap = LogBuffer.snapshot()
      assert snap.count == 2
      assert length(snap.entries) == 2
    end
  end
end
