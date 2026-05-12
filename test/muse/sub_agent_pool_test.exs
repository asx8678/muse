defmodule Muse.SubAgentPoolTest do
  use ExUnit.Case, async: false

  alias Muse.SubAgentPool

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_pool(opts \\ []) do
    name = :"pool_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SubAgentPool.start_link(Keyword.put(opts, :name, name))
    {pid, name}
  end

  defp spawn_coder(pool, task_id) do
    SubAgentPool.spawn_worker(pool, :coder, %{task_id: task_id, files: [], instructions: "test"})
  end

  setup do
    # Ensure ActiveVFS is running for tests that need it
    if Process.whereis(Muse.ActiveVFS) do
      GenServer.stop(Muse.ActiveVFS, :shutdown, 5000)
    end

    dir = Path.join(System.tmp_dir!(), "muse_sub_agent_pool_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)

    {:ok, _} = Muse.ActiveVFS.start_link(root: dir)

    on_exit(fn ->
      try do
        if pid = Process.whereis(Muse.ActiveVFS), do: GenServer.stop(pid, :shutdown, 5000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)

      # Clean up ETS config table
      try do
        :ets.delete(:sub_agent_pool_config)
      catch
        :error, _ -> :ok
      end
    end)

    %{dir: dir}
  end

  # ── Start / stop ────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts with default options" do
      {pid, _name} = start_pool()
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "starts with custom max_workers" do
      {pid, _name} = start_pool(max_workers: 3)
      assert SubAgentPool.worker_count(pid) == 0
    end
  end

  # ── spawn_worker/3 ──────────────────────────────────────────────────

  describe "spawn_worker/3" do
    test "spawns a coder worker" do
      {pool, _} = start_pool()
      {:ok, pid} = spawn_coder(pool, "t1")
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "spawns a reviewer worker" do
      {pool, _} = start_pool()
      {:ok, pid} = SubAgentPool.spawn_worker(pool, :reviewer, %{task_id: "r1"})
      assert is_pid(pid)
    end

    test "spawns a scout worker" do
      {pool, _} = start_pool()
      {:ok, pid} = SubAgentPool.spawn_worker(pool, :scout, %{task_id: "s1"})
      assert is_pid(pid)
    end

    test "returns error when pool is full" do
      {pool, _} = start_pool(max_workers: 2)
      {:ok, _} = spawn_coder(pool, "t1")
      {:ok, _} = spawn_coder(pool, "t2")
      assert {:error, :pool_full} = spawn_coder(pool, "t3")
    end

    test "returns error for duplicate task_id" do
      {pool, _} = start_pool()
      {:ok, _} = spawn_coder(pool, "dup-task")
      assert {:error, :already_spawned} = spawn_coder(pool, "dup-task")
    end

    test "allows same task_id after worker terminates" do
      {pool, _} = start_pool()
      {:ok, pid} = spawn_coder(pool, "reusable-task")
      :ok = SubAgentPool.terminate_worker(pool, pid)

      # Give the supervisor time to clean up
      Process.sleep(50)

      {:ok, pid2} = spawn_coder(pool, "reusable-task")
      assert is_pid(pid2)
    end

    test "increments worker_count" do
      {pool, _} = start_pool()
      assert SubAgentPool.worker_count(pool) == 0

      {:ok, _} = spawn_coder(pool, "t1")
      assert SubAgentPool.worker_count(pool) == 1

      {:ok, _} = spawn_coder(pool, "t2")
      assert SubAgentPool.worker_count(pool) == 2
    end
  end

  # ── list_workers/1 ──────────────────────────────────────────────────

  describe "list_workers/1" do
    test "lists workers with their types" do
      {pool, _} = start_pool()
      {:ok, _} = SubAgentPool.spawn_worker(pool, :coder, %{task_id: "c1"})
      {:ok, _} = SubAgentPool.spawn_worker(pool, :reviewer, %{task_id: "r1"})
      {:ok, _} = SubAgentPool.spawn_worker(pool, :scout, %{task_id: "s1"})

      workers = SubAgentPool.list_workers(pool)
      types = Enum.map(workers, fn {_pid, type} -> type end) |> Enum.sort()
      assert types == [:coder, :reviewer, :scout]
    end

    test "returns empty list for empty pool" do
      {pool, _} = start_pool()
      assert SubAgentPool.list_workers(pool) == []
    end
  end

  # ── terminate_worker/2 ──────────────────────────────────────────────

  describe "terminate_worker/2" do
    test "terminates a specific worker" do
      {pool, _} = start_pool()
      {:ok, pid} = spawn_coder(pool, "t1")
      assert SubAgentPool.worker_count(pool) == 1

      :ok = SubAgentPool.terminate_worker(pool, pid)

      # Allow process to die
      Process.sleep(50)
      assert SubAgentPool.worker_count(pool) == 0
    end

    test "returns error for unknown pid" do
      {pool, _} = start_pool()
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert {:error, :not_found} = SubAgentPool.terminate_worker(pool, fake_pid)
    end
  end

  # ── terminate_all/1 ────────────────────────────────────────────────

  describe "terminate_all/1" do
    test "terminates all workers" do
      {pool, _} = start_pool()
      {:ok, _} = spawn_coder(pool, "t1")
      {:ok, _} = spawn_coder(pool, "t2")
      {:ok, _} = spawn_coder(pool, "t3")

      assert SubAgentPool.worker_count(pool) == 3
      :ok = SubAgentPool.terminate_all(pool)

      Process.sleep(50)
      assert SubAgentPool.worker_count(pool) == 0
    end
  end

  # ── Worker isolation ────────────────────────────────────────────────

  describe "worker isolation" do
    test "crash of one worker does not affect others" do
      {pool, _} = start_pool()
      {:ok, pid1} = spawn_coder(pool, "t1")
      {:ok, pid2} = spawn_coder(pool, "t2")

      # Kill one worker
      Process.exit(pid1, :kill)
      Process.sleep(50)

      # Other worker should still be alive
      assert Process.alive?(pid2)
      assert SubAgentPool.worker_count(pool) == 1
    end
  end

  # ── max_workers config ──────────────────────────────────────────────

  describe "max_workers configuration" do
    test "respects custom max_workers" do
      {pool, _} = start_pool(max_workers: 1)
      {:ok, _} = spawn_coder(pool, "t1")
      assert {:error, :pool_full} = spawn_coder(pool, "t2")
    end

    test "allows spawning after workers complete" do
      {pool, _} = start_pool(max_workers: 1)
      {:ok, pid} = spawn_coder(pool, "t1")
      :ok = SubAgentPool.terminate_worker(pool, pid)
      Process.sleep(50)

      {:ok, _} = spawn_coder(pool, "t2")
    end
  end
end
