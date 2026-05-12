defmodule Muse.SubAgentTest do
  use ExUnit.Case, async: false

  alias Muse.SubAgent
  alias Muse.SubAgentPool

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_pool(opts \\ []) do
    name = :"sub_agent_test_pool_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SubAgentPool.start_link(Keyword.put(opts, :name, name))
    {pid, name}
  end

  defp write_file(dir, rel_path, content) do
    full = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "muse_sub_agent_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)
    dir
  end

  setup do
    # Ensure ActiveVFS is running
    if Process.whereis(Muse.ActiveVFS) do
      GenServer.stop(Muse.ActiveVFS, :shutdown, 5000)
    end

    dir = tmp_dir()
    {:ok, _} = Muse.ActiveVFS.start_link(root: dir)

    on_exit(fn ->
      try do
        if pid = Process.whereis(Muse.ActiveVFS), do: GenServer.stop(pid, :shutdown, 5000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)

      try do
        :ets.delete(:sub_agent_pool_config)
      catch
        :error, _ -> :ok
      end
    end)

    %{dir: dir}
  end

  # ── Init and lifecycle ──────────────────────────────────────────────

  describe "init/1" do
    test "sends worker_started to parent on init" do
      {pool, _} = start_pool()

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "init-test",
          files: [],
          instructions: "test"
        })

      # Worker should have sent {:worker_started, pid, :coder, "init-test"} to us
      assert_received {:worker_started, ^pid, :coder, "init-test"}
    end

    test "worker has initialized status" do
      {pool, _} = start_pool()
      {:ok, pid} = SubAgentPool.spawn_worker(pool, :reviewer, %{task_id: "status-test"})
      flush_worker_started()

      assert SubAgent.status(pid) == :initialized
    end

    test "get_info returns worker metadata" do
      {pool, _} = start_pool()
      {:ok, pid} = SubAgentPool.spawn_worker(pool, :scout, %{task_id: "info-test"})
      flush_worker_started()

      info = SubAgent.get_info(pid)
      assert info.type == :scout
      assert info.task_id == "info-test"
      assert info.status == :initialized
    end
  end

  # ── Execute message ─────────────────────────────────────────────────

  describe "{:execute, task}" do
    test "coder worker checks out files and reports progress", %{dir: dir} do
      {pool, _} = start_pool()
      write_file(dir, "lib/foo.ex", "defmodule Foo do end")

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "exec-coder",
          files: ["lib/foo.ex"],
          instructions: "Fix the bug"
        })

      flush_worker_started()

      send(pid, {:execute, %{}})
      Process.sleep(100)

      # Should have received log messages and completion
      assert_received {:worker_log, ^pid, :coder, "Checked out lib/foo.ex"}
      assert_received {:worker_completed, ^pid, :coder, result}
      assert result.files_checked_out == ["lib/foo.ex"]
    end

    test "scout worker reads files without locking", %{dir: dir} do
      {pool, _} = start_pool()
      write_file(dir, "lib/bar.ex", "defmodule Bar do\n  def hello, do: :world\nend")

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :scout, %{
          task_id: "exec-scout",
          files: ["lib/bar.ex"],
          query: "hello function"
        })

      flush_worker_started()

      send(pid, {:execute, %{}})
      Process.sleep(100)

      assert_received {:worker_log, ^pid, :scout, "Read lib/bar.ex"}
      assert_received {:worker_completed, ^pid, :scout, result}
      assert length(result.results) == 1
    end

    test "reviewer worker reads files for review", %{dir: dir} do
      {pool, _} = start_pool()
      write_file(dir, "lib/baz.ex", "defmodule Baz do\nend")

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :reviewer, %{
          task_id: "exec-reviewer",
          review_target: ["lib/baz.ex"]
        })

      flush_worker_started()

      send(pid, {:execute, %{}})
      Process.sleep(100)

      assert_received {:worker_log, ^pid, :reviewer, "Reviewing lib/baz.ex"}
      assert_received {:worker_completed, ^pid, :reviewer, result}
      assert length(result.reviews) == 1
    end

    test "coder reports checkout failure for missing file" do
      {pool, _} = start_pool()

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "exec-fail",
          files: ["nonexistent.ex"],
          instructions: "try"
        })

      flush_worker_started()

      send(pid, {:execute, %{}})
      Process.sleep(100)

      assert_received {:worker_failed, ^pid, :coder, {:checkout_failed, _}}
    end
  end

  # ── Cancel ───────────────────────────────────────────────────────────

  describe "{:cancel}" do
    test "worker terminates on cancel" do
      {pool, _} = start_pool()

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "cancel-test",
          files: [],
          instructions: "cancel me"
        })

      flush_worker_started()

      ref = Process.monitor(pid)
      send(pid, {:cancel})

      # Process should die
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end

    test "sends worker_failed with :cancelled on cancel" do
      {pool, _} = start_pool()

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :reviewer, %{
          task_id: "cancel-msg-test"
        })

      flush_worker_started()

      # Monitor to catch exit (worker is linked to pool, not test process)
      send(pid, {:cancel})

      assert_receive {:worker_failed, ^pid, :reviewer, :cancelled}, 1000
    end
  end

  # ── Timeout ──────────────────────────────────────────────────────────

  describe "timeout" do
    test "worker sends :timeout and fails" do
      {pool, _} = start_pool()

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "timeout-test",
          files: [],
          instructions: "slow task"
        })

      flush_worker_started()

      # Send :timeout directly to simulate the timer firing
      send(pid, :timeout)

      assert_receive {:worker_failed, ^pid, :coder, :timeout}, 1000
    end
  end

  # ── Parent monitoring ────────────────────────────────────────────────

  describe "parent death detection" do
    test "worker terminates when parent dies" do
      {pool, _} = start_pool()

      # Trap exits so the worker's linked exit doesn't crash the test
      Process.flag(:trap_exit, true)

      # Spawn a temporary process to act as parent
      parent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Start a worker directly with the temporary parent.
      # Use start_link via the pool so the pool is the owner, not the test.
      {:ok, worker_pid} =
        SubAgent.start_link(%{
          type: :coder,
          task: %{task_id: "orphan-test", files: [], instructions: "test"},
          parent_pid: parent_pid,
          pool_pid: pool
        })

      flush_worker_started()

      # Unlink from the worker so its death doesn't crash the test
      Process.unlink(worker_pid)
      ref = Process.monitor(worker_pid)

      # Kill the parent
      Process.exit(parent_pid, :kill)
      Process.sleep(100)

      # Worker should have terminated
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}, 1000

      Process.flag(:trap_exit, false)
    end
  end

  # ── VFS lock release ────────────────────────────────────────────────

  describe "VFS integration" do
    test "coder releases locks on completion", %{dir: dir} do
      {pool, _} = start_pool()
      write_file(dir, "lib/locked.ex", "original content")

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "vfs-release",
          files: ["lib/locked.ex"],
          instructions: "edit"
        })

      flush_worker_started()

      send(pid, {:execute, %{}})
      Process.sleep(100)

      # Worker completed — locks should be released
      assert_received {:worker_completed, ^pid, :coder, _}

      # Verify lock is released
      assert {:ok, nil} = Muse.ActiveVFS.lock_status("lib/locked.ex")
    end

    test "release_all_for_agent releases locks by agent_id", %{dir: dir} do
      {pool, _} = start_pool()
      write_file(dir, "lib/cancel_locked.ex", "cancel content")

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :coder, %{
          task_id: "vfs-cancel2",
          files: ["lib/cancel_locked.ex"],
          instructions: "edit"
        })

      flush_worker_started()
      agent_id = SubAgent.get_info(pid).id

      # Manually check out the file as this agent
      {:ok, _} = Muse.ActiveVFS.checkout("lib/cancel_locked.ex", agent_id: agent_id)
      assert {:ok, ^agent_id} = Muse.ActiveVFS.lock_status("lib/cancel_locked.ex")

      # Release all locks for the agent
      released = Muse.ActiveVFS.release_all_for_agent(agent_id)
      assert "lib/cancel_locked.ex" in released

      # Verify lock is released
      assert {:ok, nil} = Muse.ActiveVFS.lock_status("lib/cancel_locked.ex")
    end

    test "scout does not lock files", %{dir: dir} do
      {pool, _} = start_pool()
      write_file(dir, "lib/read_only.ex", "read only content")

      {:ok, pid} =
        SubAgentPool.spawn_worker(pool, :scout, %{
          task_id: "vfs-scout",
          files: ["lib/read_only.ex"],
          query: "search"
        })

      flush_worker_started()

      send(pid, {:execute, %{}})
      Process.sleep(100)

      # File should not be locked after scout reads it
      assert {:ok, nil} = Muse.ActiveVFS.lock_status("lib/read_only.ex")
    end
  end

  # ── get_info edge cases ─────────────────────────────────────────────

  describe "get_info/1" do
    test "returns nil for dead process" do
      {pool, _} = start_pool()
      {:ok, pid} = SubAgentPool.spawn_worker(pool, :reviewer, %{task_id: "dead-info"})
      flush_worker_started()

      :ok = SubAgentPool.terminate_worker(pool, pid)
      Process.sleep(50)

      assert SubAgent.get_info(pid) == nil
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp flush_worker_started do
    receive do
      {:worker_started, _pid, _type, _task_id} -> :ok
    after
      100 -> :ok
    end
  end
end
