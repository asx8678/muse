defmodule Muse.Tools.SpawnSubAgentsTest do
  use ExUnit.Case, async: false

  alias Muse.SubAgentPool
  alias Muse.Tools.SpawnSubAgents

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_pool(opts \\ []) do
    name = :"pool_#{:erlang.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SubAgentPool.start_link(Keyword.put(opts, :name, name))
    pid
  end

  defp start_pool_with_name(session_id) do
    name = :"muse_sub_agent_pool_#{session_id}"
    {:ok, pid} = SubAgentPool.start_link(name: name, max_workers: 10)
    pid
  end

  defp context_with_pool(pool_pid) do
    %{sub_agent_pool: pool_pid, workspace: "/tmp/test", session_id: "test-session"}
  end

  defp context_with_session_id(session_id) do
    %{workspace: "/tmp/test", session_id: session_id}
  end

  setup do
    # Ensure ActiveVFS is running (SubAgent workers need it)
    if Process.whereis(Muse.ActiveVFS) do
      GenServer.stop(Muse.ActiveVFS, :shutdown, 5000)
    end

    dir = Path.join(System.tmp_dir!(), "muse_spawn_sub_agents_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)

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

  # ── execute/2 — context validation ───────────────────────────────────

  describe "execute/2 — context validation" do
    test "returns error when pool is not available" do
      result = SpawnSubAgents.execute(%{"workers" => []}, %{workspace: "/tmp"})
      assert result.success == false
      assert result.error =~ "sub_agent_pool not available"
    end

    test "returns error when pool is not alive" do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result =
        SpawnSubAgents.execute(
          %{"workers" => []},
          %{sub_agent_pool: dead_pid, workspace: "/tmp"}
        )

      assert result.success == false
      assert result.error =~ "not alive"
    end
  end

  # ── execute/2 — pool from session_id lookup ──────────────────────────

  describe "execute/2 — pool from session_id lookup" do
    test "resolves pool by session_id when sub_agent_pool key is absent" do
      session_id = "lookup_test_#{System.unique_integer([:positive])}"

      {:ok, pool_pid} =
        SubAgentPool.start_link(name: :"muse_sub_agent_pool_#{session_id}", max_workers: 10)

      result =
        SpawnSubAgents.execute(
          %{"workers" => []},
          context_with_session_id(session_id)
        )

      assert result.success == true
      assert result.output.spawned_count == 0

      # Cleanup: unlink before stopping to prevent test process exit cascade
      Process.unlink(pool_pid)
      SubAgentPool.terminate_all(pool_pid)
      GenServer.stop(pool_pid, :shutdown)
    end

    test "prefers direct :sub_agent_pool key over session_id lookup" do
      session_id = "direct-pref-#{System.unique_integer([:positive])}"
      _other_pool = start_pool_with_name(session_id)
      direct_pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{"workers" => []},
          Map.merge(context_with_session_id(session_id), %{sub_agent_pool: direct_pool})
        )

      assert result.success == true
      assert result.output.spawned_count == 0
    end
  end

  # ── execute/2 — argument validation ───────────────────────────────────

  describe "execute/2 — argument validation" do
    test "returns error when workers is not a list" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{"workers" => "not a list"},
          context_with_pool(pool)
        )

      assert result.success == false
      assert result.error =~ "workers must be a list"
    end

    test "returns error when task_id is missing" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [%{"type" => "scout", "instructions" => "search"}]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 0
      assert length(result.output.errors) == 1
      assert hd(result.output.errors).error =~ "task_id is required"
    end

    test "returns error for invalid worker type" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [%{"type" => "invalid", "task_id" => "t1", "instructions" => "do stuff"}]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 0
      assert length(result.output.errors) == 1
      assert hd(result.output.errors).error =~ "invalid type"
    end

    test "returns error when instructions is missing" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [%{"type" => "scout", "task_id" => "t1"}]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 0
      assert length(result.output.errors) == 1
      assert hd(result.output.errors).error =~ "instructions is required"
    end
  end

  # ── execute/2 — happy path ───────────────────────────────────────────

  describe "execute/2 — happy path" do
    test "spawns a scout worker successfully" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{
                "type" => "scout",
                "task_id" => "scout-1",
                "instructions" => "search for patterns"
              }
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 1
      assert length(result.output.worker_ids) == 1
      assert length(result.output.errors) == 0

      worker = hd(result.output.worker_ids)
      assert worker.task_id == "scout-1"
      assert worker.type == "scout"
      assert is_binary(worker.pid)
    end

    test "spawns a reviewer worker successfully" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{"type" => "reviewer", "task_id" => "rev-1", "instructions" => "review code"}
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 1
    end

    test "spawns a coder worker successfully" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{
                "type" => "coder",
                "task_id" => "coder-1",
                "instructions" => "implement feature",
                "files" => ["lib/foo.ex"]
              }
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 1
    end

    test "spawns multiple workers" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{"type" => "scout", "task_id" => "s1", "instructions" => "search 1"},
              %{"type" => "reviewer", "task_id" => "r1", "instructions" => "review 1"}
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 2
      assert length(result.output.worker_ids) == 2
    end

    test "returns empty results for empty workers list" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{"workers" => []},
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 0
      assert result.output.worker_ids == []
      assert result.output.errors == []
    end
  end

  # ── execute/2 — pool capacity ────────────────────────────────────────

  describe "execute/2 — pool capacity" do
    test "reports pool_full error when pool is at capacity" do
      pool = start_pool(max_workers: 1)

      # Fill the pool
      {:ok, _existing} =
        SubAgentPool.spawn_worker(pool, :scout, %{task_id: "existing", instructions: "busy"})

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{"type" => "scout", "task_id" => "overflow", "instructions" => "too many"}
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 0
      assert length(result.output.errors) == 1
      assert hd(result.output.errors).error =~ "pool is full"
    end

    test "reports already_spawned error for duplicate task_id" do
      pool = start_pool()

      # Spawn first worker
      {:ok, _pid} =
        SubAgentPool.spawn_worker(pool, :scout, %{task_id: "dup-task", instructions: "first"})

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{"type" => "scout", "task_id" => "dup-task", "instructions" => "duplicate"}
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 0
      assert length(result.output.errors) == 1
      assert hd(result.output.errors).error =~ "already spawned"
    end
  end

  # ── execute/2 — mixed success and errors ──────────────────────────────

  describe "execute/2 — mixed success and errors" do
    test "spawns valid workers while reporting invalid ones" do
      pool = start_pool()

      result =
        SpawnSubAgents.execute(
          %{
            "workers" => [
              %{"type" => "scout", "task_id" => "good-1", "instructions" => "search"},
              %{"type" => "bogus", "task_id" => "bad-1", "instructions" => "invalid type"},
              %{"type" => "reviewer", "task_id" => "good-2", "instructions" => "review"}
            ]
          },
          context_with_pool(pool)
        )

      assert result.success == true
      assert result.output.spawned_count == 2
      assert length(result.output.errors) == 1
      assert hd(result.output.errors).task_id == "bad-1"
    end
  end
end
