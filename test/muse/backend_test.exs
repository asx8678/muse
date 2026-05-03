defmodule Muse.BackendTest do
  use ExUnit.Case, async: false

  alias Muse.Backend

  # Backend calls globally-named processes → async: false

  describe "safe_workspace_root/0" do
    test "returns fallback when Workspace not running" do
      ensure_stopped(Muse.Workspace)
      assert Backend.safe_workspace_root() == "unknown"
    end

    test "returns workspace root when Workspace is running" do
      ensure_stopped(Muse.Workspace)

      root = Path.join(System.tmp_dir!(), "muse_backend_ws_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      {:ok, pid} = Muse.Workspace.start_link(root: root)
      Process.unlink(pid)

      try do
        assert Backend.safe_workspace_root() =~ Path.expand(root)
      after
        ensure_stopped(Muse.Workspace)
      end
    end
  end

  describe "safe_reload_status/0" do
    test "returns unavailable when DevReloader not running" do
      ensure_stopped(Muse.DevReloader)
      assert Backend.safe_reload_status() == %{status: :unavailable}
    end
  end

  describe "safe_diagnostics/0" do
    test "returns empty list when Diagnostics not running" do
      ensure_stopped(Muse.Diagnostics)
      assert Backend.safe_diagnostics() == []
    end
  end

  describe "safe_self_healing_issues/0" do
    test "returns empty list when SelfHealingQueue not running" do
      ensure_stopped(Muse.SelfHealingQueue)
      assert Backend.safe_self_healing_issues() == []
    end
  end

  describe "safe_agent_snapshot/0" do
    test "returns :unavailable when AgentRegistry not running" do
      ensure_stopped(Muse.AgentRegistry)
      assert Backend.safe_agent_snapshot() == :unavailable
    end
  end

  describe "safe_logs/0" do
    test "returns empty list when LogBuffer not running" do
      ensure_stopped(Muse.LogBuffer)
      assert Backend.safe_logs() == []
    end
  end

  describe "safe_log_snapshot/0" do
    test "returns empty snapshot when LogBuffer not running" do
      ensure_stopped(Muse.LogBuffer)
      assert Backend.safe_log_snapshot() == %{entries: [], count: 0}
    end
  end

  describe "safe_clear_logs/0" do
    test "returns error when LogBuffer not running" do
      ensure_stopped(Muse.LogBuffer)
      assert Backend.safe_clear_logs() == {:error, :log_buffer_unavailable}
    end
  end

  describe "safe_agent_runtime_snapshot/0" do
    test "returns disconnected snapshot when AgentRuntime not running" do
      ensure_stopped(Muse.AgentRuntime)
      snapshot = Backend.safe_agent_runtime_snapshot()
      assert snapshot.status == :disconnected
      assert snapshot.health == :inactive
    end
  end

  describe "safe_connect_agent_runtime/0" do
    test "returns error when AgentRuntime not running" do
      ensure_stopped(Muse.AgentRuntime)
      assert Backend.safe_connect_agent_runtime() == {:error, :agent_runtime_unavailable}
    end
  end

  describe "safe_disconnect_agent_runtime/0" do
    test "returns error when AgentRuntime not running" do
      ensure_stopped(Muse.AgentRuntime)
      assert Backend.safe_disconnect_agent_runtime() == {:error, :agent_runtime_unavailable}
    end
  end

  describe "safe_force_reload/0" do
    test "returns error when DevReloader not running" do
      ensure_stopped(Muse.DevReloader)
      assert Backend.safe_force_reload() == {:error, :not_running}
    end
  end

  describe "safe_queue_diagnostic/1" do
    test "returns error when SelfHealingQueue not running" do
      ensure_stopped(Muse.SelfHealingQueue)
      assert Backend.safe_queue_diagnostic(%{}) == {:error, :queue_unavailable}
    end
  end

  describe "safe_append_log/4" do
    test "returns error when LogBuffer not running" do
      ensure_stopped(Muse.LogBuffer)
      assert Backend.safe_append_log(:info, "test") == {:error, :log_buffer_unavailable}
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp ensure_stopped(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)

        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
