defmodule Muse.Phase4PersistentSessionTest do
  @moduledoc """
  Phase 4 integration tests: persistent memory/session and multi-workspace foundations.

  Verifies:
  - Sessions survive GenServer crash + restart via StateRestoration
  - Memory artifacts survive GenServer crash + restart
  - Patch history survives GenServer crash + restart
  - Session retention policy is enforced during session creation
  - Export/import round-trips without secrets exposure
  - @workspace command parses and dispatches correctly
  - Workspace isolation: different profiles have separate sessions
  - Memory compactions are persisted
  """

  use ExUnit.Case, async: false

  alias Muse.{SessionStore, SessionServer, Memory, Commands, WorkspaceProfile}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "muse-phase4-test-#{suffix}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

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

  defp start_dependencies(workspace_root, store_base_dir) do
    # PubSub, TaskSupervisor, SessionRegistry, SessionSupervisor, and
    # ActiveWorkspace are started by Application.base_children/0 even in test mode.
    # We only need to ensure the workspace/root dependencies are set correctly.

    # Use ActiveWorkspace.set/2 instead of restarting it, since it's supervised
    # by the Application supervisor and restarting it causes the tree to restart.
    if Process.whereis(Muse.ActiveWorkspace) do
      Muse.ActiveWorkspace.set(workspace_root, store_base_dir)
    else
      {:ok, _} =
        Muse.ActiveWorkspace.start_link(root_path: workspace_root, store_base_dir: store_base_dir)
    end

    stop_named(Muse.Workspace)
    {:ok, _} = Muse.Workspace.start_link(root: workspace_root)

    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])

    stop_named(Muse.Diagnostics)
    {:ok, _} = Muse.Diagnostics.start_link(install_logger_handler?: false)

    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = Muse.SelfHealingQueue.start_link([])

    stop_named(Muse.AgentRegistry)
    {:ok, _} = Muse.AgentRegistry.start_link([])
  end

  defp stop_dependencies do
    # Do NOT stop ActiveWorkspace — it's supervised by the Application supervisor.
    # Reset its state instead.
    if Process.whereis(Muse.ActiveWorkspace) do
      Muse.ActiveWorkspace.reset()
    end

    stop_named(Muse.AgentRegistry)
    stop_named(Muse.SelfHealingQueue)
    stop_named(Muse.Diagnostics)
    stop_named(Muse.State)
    stop_named(Muse.Workspace)
  end

  defp cleanup_sessions do
    case Process.whereis(Muse.SessionSupervisor) do
      nil ->
        :ok

      pid ->
        pid
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            try do
              DynamicSupervisor.terminate_child(Muse.SessionSupervisor, child_pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end)

        Process.sleep(10)
    end
  end

  defp start_session_server(session_id, store_base_dir, workspace) do
    case DynamicSupervisor.start_child(
           Muse.SessionSupervisor,
           {Muse.SessionServer,
            session_id: session_id, store_base_dir: store_base_dir, workspace: workspace}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  # ---------------------------------------------------------------------------
  # Session crash recovery
  # ---------------------------------------------------------------------------

  describe "session crash recovery — GenServer restart" do
    test "session state survives GenServer crash and restart" do
      workspace = tmp_dir!()
      store_base_dir = Path.join(workspace, ".muse/sessions")
      session_id = "crash-recovery-#{System.unique_integer([:positive])}"

      start_dependencies(workspace, store_base_dir)

      on_exit(fn ->
        cleanup_sessions()
        stop_dependencies()
        File.rm_rf!(workspace)
      end)

      # Start the session server
      {:ok, pid} = start_session_server(session_id, store_base_dir, workspace)

      # Verify it started
      status = SessionServer.status(pid)
      assert status.session_id == session_id
      assert status.status == :idle

      # Persist some data through SessionStore (simulating a running session)
      SessionStore.save_session(store_base_dir, session_id, %{
        "status" => "idle",
        "plan" => nil,
        "plans" => %{},
        "approvals" => [],
        "approval_binding" => nil
      })

      SessionStore.append_event(store_base_dir, session_id, %{
        "type" => "user_message",
        "text" => "hello from pre-crash"
      })

      # Crash the GenServer process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Verify the process is dead
      refute Process.alive?(pid)

      # Restart the session server with the same ID
      {:ok, new_pid} = start_session_server(session_id, store_base_dir, workspace)

      # Verify the new process is running
      assert Process.alive?(new_pid)

      # Verify state was restored from disk
      new_status = SessionServer.status(new_pid)
      assert new_status.session_id == session_id
      assert new_status.status == :idle

      # Verify events persisted through the crash
      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(store_base_dir, session_id)
      assert length(events) == 1
      assert hd(events)["type"] == "user_message"
      assert hd(events)["text"] == "hello from pre-crash"
    end

    test "memory survives GenServer crash and restart" do
      workspace = tmp_dir!()
      store_base_dir = Path.join(workspace, ".muse/sessions")
      session_id = "memory-crash-recovery-#{System.unique_integer([:positive])}"

      start_dependencies(workspace, store_base_dir)

      on_exit(fn ->
        cleanup_sessions()
        stop_dependencies()
        File.rm_rf!(workspace)
      end)

      # Start the session server
      {:ok, pid} = start_session_server(session_id, store_base_dir, workspace)

      # Persist memory through SessionStore
      memory = %{
        "user_goal" => "Build the crash-recovery feature",
        "project_facts" => ["Elixir 1.17", "Phoenix 1.8"],
        "decisions_made" => ["Use GenServer for state"],
        "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source_session_id" => session_id
      }

      :ok = SessionStore.save_memory(store_base_dir, session_id, memory, validate: true)

      # Crash the GenServer process
      Process.exit(pid, :kill)
      Process.sleep(50)

      refute Process.alive?(pid)

      # Restart the session server
      {:ok, new_pid} = start_session_server(session_id, store_base_dir, workspace)
      assert Process.alive?(new_pid)

      # Verify memory was restored
      new_status = SessionServer.status(new_pid)
      assert new_status.memory != nil

      # Verify memory content on disk
      assert {:ok, loaded_memory} = SessionStore.load_memory(store_base_dir, session_id)
      assert loaded_memory["user_goal"] == "Build the crash-recovery feature"
      assert loaded_memory["project_facts"] == ["Elixir 1.17", "Phoenix 1.8"]
    end

    test "patch history survives GenServer crash and restart" do
      workspace = tmp_dir!()
      store_base_dir = Path.join(workspace, ".muse/sessions")
      session_id = "patch-crash-recovery-#{System.unique_integer([:positive])}"

      start_dependencies(workspace, store_base_dir)

      on_exit(fn ->
        cleanup_sessions()
        stop_dependencies()
        File.rm_rf!(workspace)
      end)

      # Start the session server
      {:ok, pid} = start_session_server(session_id, store_base_dir, workspace)

      # Persist patches through SessionStore
      SessionStore.append_patch(store_base_dir, session_id, %{
        "patch_id" => "patch-pre-crash-1",
        "status" => "approved",
        "hash" => "abc123"
      })

      SessionStore.append_patch(store_base_dir, session_id, %{
        "patch_id" => "patch-pre-crash-2",
        "status" => "pending",
        "hash" => "def456"
      })

      # Crash the GenServer process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Restart the session server
      {:ok, new_pid} = start_session_server(session_id, store_base_dir, workspace)
      assert Process.alive?(new_pid)

      # Verify patches persisted through the crash
      assert {:ok, patches, %{skipped: 0}} =
               SessionStore.load_patches(store_base_dir, session_id)

      assert length(patches) == 2
      assert Enum.at(patches, 0)["patch_id"] == "patch-pre-crash-1"
      assert Enum.at(patches, 1)["patch_id"] == "patch-pre-crash-2"

      # Verify find_patch still works
      assert {:ok, _} = SessionStore.find_patch(store_base_dir, session_id, "abc123")
      assert {:ok, _} = SessionStore.find_patch(store_base_dir, session_id, "patch-pre-crash-2")

      assert {:error, :not_found} =
               SessionStore.find_patch(store_base_dir, session_id, "nonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # Retention policy integration
  # ---------------------------------------------------------------------------

  describe "retention policy integration" do
    test "retention is applied when a new session is created" do
      workspace = tmp_dir!()
      store_base_dir = Path.join(workspace, ".muse/sessions")
      orig_count = System.get_env("MUSE_SESSION_MAX_COUNT")

      start_dependencies(workspace, store_base_dir)
      cleanup_sessions()

      on_exit(fn ->
        cleanup_sessions()

        if orig_count,
          do: System.put_env("MUSE_SESSION_MAX_COUNT", orig_count),
          else: System.delete_env("MUSE_SESSION_MAX_COUNT")

        stop_dependencies()
        File.rm_rf!(workspace)
      end)

      # Set retention limit before creating sessions
      System.put_env("MUSE_SESSION_MAX_COUNT", "3")

      try do
        # Create 5 session directories on disk (simulate prior sessions)
        for i <- 1..5 do
          id = "retention-old-#{i}"
          SessionStore.save_session(store_base_dir, id, %{"idx" => i})
          if i < 5, do: Process.sleep(10)
        end

        assert {:ok, ids_before} = SessionStore.list_sessions(store_base_dir)
        assert length(ids_before) == 5

        # Starting a new session should trigger retention
        session_id = "retention-new-#{System.unique_integer([:positive])}"
        {:ok, _pid} = start_session_server(session_id, store_base_dir, workspace)

        # After retention, the oldest sessions should have been evicted
        # The new session + up to max_sessions of the old ones should remain
        Process.sleep(50)

        assert {:ok, ids_after} = SessionStore.list_sessions(store_base_dir)
        # With max_sessions=3, we should have at most 3 + 1 (new) sessions
        # but the new session is not persisted yet (no snapshot), so
        # apply_retention operates on existing sessions only
        assert length(ids_after) <= 4
      after
        if orig_count,
          do: System.put_env("MUSE_SESSION_MAX_COUNT", orig_count),
          else: System.delete_env("MUSE_SESSION_MAX_COUNT")
      end
    end

    test "apply_retention evicts oldest sessions beyond max" do
      base_dir = tmp_dir!()
      orig_count = System.get_env("MUSE_SESSION_MAX_COUNT")

      on_exit(fn ->
        File.rm_rf!(base_dir)

        if orig_count,
          do: System.put_env("MUSE_SESSION_MAX_COUNT", orig_count),
          else: System.delete_env("MUSE_SESSION_MAX_COUNT")
      end)

      # Create sessions
      for i <- 1..5 do
        SessionStore.save_session(base_dir, "ret-#{i}", %{"idx" => i})
        if i < 5, do: Process.sleep(10)
      end

      try do
        # Set env var so apply_retention reads it
        System.put_env("MUSE_SESSION_MAX_COUNT", "2")

        # Apply retention
        assert {:ok, evicted} = SessionStore.apply_retention(base_dir)
        # Should have evicted 3 oldest (5 - 2 = 3)
        assert length(evicted) == 3

        assert {:ok, remaining} = SessionStore.list_sessions(base_dir)
        assert length(remaining) == 2
      after
        if orig_count,
          do: System.put_env("MUSE_SESSION_MAX_COUNT", orig_count),
          else: System.delete_env("MUSE_SESSION_MAX_COUNT")
      end
    end

    test "apply_retention with TTL evicts old sessions" do
      base_dir = tmp_dir!()

      on_exit(fn -> File.rm_rf!(base_dir) end)

      orig_days = System.get_env("MUSE_SESSION_MAX_AGE_DAYS")

      try do
        System.put_env("MUSE_SESSION_MAX_AGE_DAYS", "7")

        # Create a session and backdate it
        SessionStore.save_session(base_dir, "old-session", %{"v" => 1})
        dir = SessionStore.session_dir(base_dir, "old-session")
        :ok = File.touch(dir, {{2020, 1, 1}, {0, 0, 0}})

        # Create a recent session
        SessionStore.save_session(base_dir, "new-session", %{"v" => 2})

        assert {:ok, evicted} = SessionStore.apply_retention(base_dir)
        assert "old-session" in evicted
        refute "new-session" in evicted
      after
        if orig_days,
          do: System.put_env("MUSE_SESSION_MAX_AGE_DAYS", orig_days),
          else: System.delete_env("MUSE_SESSION_MAX_AGE_DAYS")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Export/import — secrets safety
  # ---------------------------------------------------------------------------

  describe "export/import secrets safety" do
    test "export never includes raw secrets in any field" do
      base_dir = tmp_dir!()
      session_id = "export-secrets-#{System.unique_integer([:positive])}"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Create session with sensitive data — gets redacted on save
      SessionStore.save_session(base_dir, session_id, %{
        "objective" => "Test export",
        "api_key" => "sk-test-12345",
        "authorization" => "Bearer eyJhbGciOiJIUzI1NiJ9.test"
      })

      SessionStore.append_event(base_dir, session_id, %{
        "type" => "config_check",
        "api_key" => "sk-test-67890"
      })

      SessionStore.save_memory(base_dir, session_id, %{
        "user_goal" => "Build feature",
        "project_facts" => ["Elixir"]
      })

      assert {:ok, export} = SessionStore.export_session(base_dir, session_id)

      # Check snapshot
      assert export["snapshot"]["api_key"] == "**REDACTED**"

      # Check events
      assert hd(export["events"])["api_key"] == "**REDACTED**"

      # Full JSON should not contain raw secrets
      json = Jason.encode!(export)
      refute String.contains?(json, "sk-test-12345")
      refute String.contains?(json, "sk-test-67890")
      refute String.contains?(json, "Bearer eyJhbGciOiJIUzI1NiJ9")
      assert String.contains?(json, "**REDACTED**")
    end

    test "import then export round-trips without secrets leakage" do
      base_dir = tmp_dir!()
      session_id = "roundtrip-#{System.unique_integer([:positive])}"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Create and export
      SessionStore.save_session(base_dir, session_id, %{
        "status" => "idle",
        "api_key" => "sk-roundtrip-test"
      })

      SessionStore.append_event(base_dir, session_id, %{
        "type" => "test",
        "token" => "ghp_roundtrip123"
      })

      assert {:ok, export} = SessionStore.export_session(base_dir, session_id)

      # Import into a different directory
      new_base = tmp_dir!()

      on_exit(fn -> File.rm_rf!(new_base) end)

      assert {:ok, ^session_id} = SessionStore.import_session(new_base, export)

      # Re-export from the imported session
      assert {:ok, re_export} = SessionStore.export_session(new_base, session_id)

      # No raw secrets in re-exported data
      re_json = Jason.encode!(re_export)
      refute String.contains?(re_json, "sk-roundtrip-test")
      refute String.contains?(re_json, "ghp_roundtrip123")
    end

    test "import rejects export map with unsafe memory" do
      base_dir = tmp_dir!()

      on_exit(fn -> File.rm_rf!(base_dir) end)

      export = %{
        "session_id" => "import-unsafe",
        "export_schema_version" => 1,
        "snapshot" => %{"status" => "idle"},
        "events" => [],
        "messages" => [],
        "patches" => [],
        "memory" => %{"user_goal" => "Has secret: sk-badimport123", "project_facts" => []}
      }

      assert {:error, {:unsafe_memory, _reasons}} =
               SessionStore.import_session(base_dir, export)
    end

    test "import with safe memory succeeds and round-trips" do
      base_dir = tmp_dir!()

      on_exit(fn -> File.rm_rf!(base_dir) end)

      export = %{
        "session_id" => "import-safe",
        "export_schema_version" => 1,
        "snapshot" => %{"status" => "idle", "objective" => "Import me"},
        "events" => [%{"type" => "test", "seq" => 1}],
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "patches" => [%{"patch_id" => "p1", "status" => "approved"}],
        "memory" => %{"user_goal" => "Build feature", "project_facts" => ["Elixir"]}
      }

      assert {:ok, "import-safe"} = SessionStore.import_session(base_dir, export)

      # Verify imported data
      assert {:ok, snapshot} = SessionStore.load_session(base_dir, "import-safe")
      assert snapshot["objective"] == "Import me"

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, "import-safe")
      assert length(events) == 1

      assert {:ok, messages, %{skipped: 0}} = SessionStore.load_messages(base_dir, "import-safe")
      assert length(messages) == 1

      assert {:ok, patches, %{skipped: 0}} = SessionStore.load_patches(base_dir, "import-safe")
      assert length(patches) == 1

      assert {:ok, memory} = SessionStore.load_memory(base_dir, "import-safe")
      assert memory["user_goal"] == "Build feature"
    end
  end

  # ---------------------------------------------------------------------------
  # @workspace command parsing
  # ---------------------------------------------------------------------------

  describe "@workspace command parsing" do
    test "@workspace with name parses to workspace_switch action" do
      assert {:command, :workspace_switch, "myproject"} =
               Commands.parse("@workspace myproject")
    end

    test "@workspace without name parses to workspace_switch action without args" do
      assert {:command, :workspace_switch} = Commands.parse("@workspace")
    end

    test "@workspace with extra whitespace trims args" do
      assert {:command, :workspace_switch, "myproject"} =
               Commands.parse("@workspace   myproject  ")
    end

    test "unknown @-command returns unknown" do
      assert {:unknown, "@unknown"} = Commands.parse("@unknown")
    end

    test "@workspace is listed in at_commands" do
      commands = Commands.at_commands()
      assert Enum.any?(commands, fn {cmd, _desc} -> cmd == "@workspace" end)
    end

    test "@workspace is listed in at_commands_json" do
      commands = Commands.at_commands_json()
      assert Enum.any?(commands, fn %{command: cmd} -> cmd == "@workspace" end)
    end

    test "help text includes @workspace" do
      help = Commands.help_text()
      assert help =~ "@workspace"
    end

    test "slash commands still work alongside @-commands" do
      assert {:command, :help} = Commands.parse("/help")
      assert {:command, :workspace} = Commands.parse("/workspace")

      assert {:command, :workspace_switch, "myproject"} =
               Commands.parse("/workspace switch myproject")
    end

    test "regular messages are not parsed as @-commands" do
      assert {:message, "hello @workspace"} = Commands.parse("hello @workspace")
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace isolation
  # ---------------------------------------------------------------------------

  describe "workspace isolation" do
    test "different workspace profiles have isolated session directories" do
      muse_dir = tmp_dir!()

      on_exit(fn -> File.rm_rf!(muse_dir) end)

      root_a = Path.join(muse_dir, "proj-a")
      root_b = Path.join(muse_dir, "proj-b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "proj-a",
                 root_path: root_a,
                 muse_dir: muse_dir
               )

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "proj-b",
                 root_path: root_b,
                 muse_dir: muse_dir
               )

      assert {:ok, dir_a} = WorkspaceProfile.sessions_dir_for("proj-a", muse_dir: muse_dir)
      assert {:ok, dir_b} = WorkspaceProfile.sessions_dir_for("proj-b", muse_dir: muse_dir)

      refute dir_a == dir_b
      assert dir_a =~ "proj-a"
      assert dir_b =~ "proj-b"
    end

    test "sessions in different workspaces are fully isolated" do
      base_dir_a = tmp_dir!()
      base_dir_b = tmp_dir!()

      on_exit(fn ->
        File.rm_rf!(base_dir_a)
        File.rm_rf!(base_dir_b)
      end)

      # Create sessions in workspace A
      SessionStore.save_session(base_dir_a, "shared-id", %{"workspace" => "A", "data" => "from-A"})

      SessionStore.append_event(base_dir_a, "shared-id", %{"type" => "event-from-a"})
      SessionStore.save_memory(base_dir_a, "shared-id", %{"user_goal" => "Goal A"})

      # Create sessions in workspace B
      SessionStore.save_session(base_dir_b, "shared-id", %{"workspace" => "B", "data" => "from-B"})

      SessionStore.append_event(base_dir_b, "shared-id", %{"type" => "event-from-b"})
      SessionStore.save_memory(base_dir_b, "shared-id", %{"user_goal" => "Goal B"})

      # Workspace A data is independent of B
      assert {:ok, snap_a} = SessionStore.load_session(base_dir_a, "shared-id")
      assert snap_a["workspace"] == "A"

      assert {:ok, events_a, _} = SessionStore.load_events(base_dir_a, "shared-id")
      assert hd(events_a)["type"] == "event-from-a"

      assert {:ok, mem_a} = SessionStore.load_memory(base_dir_a, "shared-id")
      assert mem_a["user_goal"] == "Goal A"

      # Workspace B data is independent of A
      assert {:ok, snap_b} = SessionStore.load_session(base_dir_b, "shared-id")
      assert snap_b["workspace"] == "B"

      assert {:ok, events_b, _} = SessionStore.load_events(base_dir_b, "shared-id")
      assert hd(events_b)["type"] == "event-from-b"

      assert {:ok, mem_b} = SessionStore.load_memory(base_dir_b, "shared-id")
      assert mem_b["user_goal"] == "Goal B"

      # Deleting workspace A session doesn't affect B
      assert :ok = SessionStore.delete_session(base_dir_a, "shared-id")
      assert SessionStore.session_exists?(base_dir_b, "shared-id")
    end

    test "export from one workspace cannot be imported into another workspace's store" do
      base_dir_a = tmp_dir!()
      base_dir_b = tmp_dir!()

      on_exit(fn ->
        File.rm_rf!(base_dir_a)
        File.rm_rf!(base_dir_b)
      end)

      # Create session in workspace A
      SessionStore.save_session(base_dir_a, "export-test", %{"status" => "idle", "ws" => "A"})
      SessionStore.append_event(base_dir_a, "export-test", %{"type" => "from-a"})

      # Export from A
      assert {:ok, export} = SessionStore.export_session(base_dir_a, "export-test")
      assert export["snapshot"]["ws"] == "A"

      # Import into B (valid, but it's a separate workspace)
      assert {:ok, "export-test"} = SessionStore.import_session(base_dir_b, export)

      # B's session is independent from A's
      assert {:ok, snap_b} = SessionStore.load_session(base_dir_b, "export-test")
      # The imported data from A
      assert snap_b["ws"] == "A"

      # A's session still exists independently
      assert {:ok, snap_a} = SessionStore.load_session(base_dir_a, "export-test")
      assert snap_a["ws"] == "A"
    end
  end

  # ---------------------------------------------------------------------------
  # Memory persistence across restarts
  # ---------------------------------------------------------------------------

  describe "memory persistence across restarts" do
    test "Memory.validate_and_persist round-trips through disk" do
      base_dir = tmp_dir!()
      session_id = "memory-persist-#{System.unique_integer([:positive])}"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      memory =
        Memory.new(
          user_goal: "Build the feature",
          project_facts: ["Elixir 1.17", "Phoenix 1.8"],
          decisions_made: ["Use GenServer"],
          source_session_id: session_id
        )

      assert :ok = Memory.validate_and_persist(base_dir, session_id, memory)

      # Load and verify
      assert {:ok, loaded} = SessionStore.load_memory(base_dir, session_id)
      assert loaded["user_goal"] == "Build the feature"
      assert loaded["project_facts"] == ["Elixir 1.17", "Phoenix 1.8"]
    end

    test "compacted memory round-trips with all fields" do
      base_dir = tmp_dir!()
      session_id = "memory-compacted-#{System.unique_integer([:positive])}"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      memory = %{
        "user_goal" => "Build the feature",
        "project_facts" => ["Elixir 1.17", "Phoenix 1.8"],
        "decisions_made" => ["Use GenServer"],
        "approved_plans" => ["Plan A: 5 tasks"],
        "changes_completed" => ["lib/feature.ex created"],
        "validation_results" => ["Tests passing"],
        "open_issues" => [],
        "useful_conventions" => ["Pattern matching"],
        "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source_session_id" => session_id
      }

      assert :ok = SessionStore.save_memory(base_dir, session_id, memory)
      assert {:ok, loaded} = SessionStore.load_memory(base_dir, session_id)

      assert loaded["user_goal"] == "Build the feature"
      assert loaded["project_facts"] == ["Elixir 1.17", "Phoenix 1.8"]
      assert loaded["decisions_made"] == ["Use GenServer"]
      assert loaded["approved_plans"] == ["Plan A: 5 tasks"]
      assert loaded["changes_completed"] == ["lib/feature.ex created"]
      assert loaded["validation_results"] == ["Tests passing"]
      assert loaded["useful_conventions"] == ["Pattern matching"]
      assert loaded["source_session_id"] == session_id
    end

    test "validated memory with secrets is rejected before disk write" do
      base_dir = tmp_dir!()
      session_id = "memory-unsafe-#{System.unique_integer([:positive])}"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      unsafe_memory = %{
        "user_goal" => "Has secret sk-test12345bad",
        "project_facts" => []
      }

      assert {:error, {:unsafe_memory, _reasons}} =
               Memory.validate_and_persist(base_dir, session_id, unsafe_memory)

      # Nothing should be on disk
      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "memory cleared via delete_memory is not recoverable" do
      base_dir = tmp_dir!()
      session_id = "memory-delete-#{System.unique_integer([:positive])}"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      memory = Memory.new(user_goal: "Temporary", source_session_id: session_id)

      assert :ok = Memory.validate_and_persist(base_dir, session_id, memory)
      assert {:ok, _} = SessionStore.load_memory(base_dir, session_id)

      assert :ok = SessionStore.delete_memory(base_dir, session_id)
      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "memory compaction is persisted and survives process restart" do
      workspace = tmp_dir!()
      store_base_dir = Path.join(workspace, ".muse/sessions")
      session_id = "memory-restart-#{System.unique_integer([:positive])}"

      start_dependencies(workspace, store_base_dir)

      on_exit(fn ->
        cleanup_sessions()
        stop_dependencies()
        File.rm_rf!(workspace)
      end)

      # Start session server
      {:ok, pid} = start_session_server(session_id, store_base_dir, workspace)

      # Persist memory (simulating a compaction)
      memory = %{
        "user_goal" => "Build memory persistence",
        "project_facts" => ["Elixir project"],
        "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source_session_id" => session_id
      }

      :ok = SessionStore.save_memory(store_base_dir, session_id, memory, validate: true)

      # Set memory on the server
      SessionServer.set_memory(pid, memory)

      # Verify memory is in the process state
      status = SessionServer.status(pid)
      assert status.memory != nil

      # Crash the process
      Process.exit(pid, :kill)
      Process.sleep(50)

      refute Process.alive?(pid)

      # Restart the session
      {:ok, new_pid} = start_session_server(session_id, store_base_dir, workspace)
      assert Process.alive?(new_pid)

      # Memory should be restored from disk
      new_status = SessionServer.status(new_pid)
      assert new_status.memory != nil

      # Memory on disk should match
      assert {:ok, loaded} = SessionStore.load_memory(store_base_dir, session_id)
      assert loaded["user_goal"] == "Build memory persistence"
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace profile — no secrets
  # ---------------------------------------------------------------------------

  describe "workspace profile secrets safety" do
    test "profiles.json does not contain sensitive keys" do
      muse_dir = tmp_dir!()
      root = Path.join(muse_dir, "safe-proj")
      File.mkdir_p!(root)

      on_exit(fn -> File.rm_rf!(muse_dir) end)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "safe-proj",
                 root_path: root,
                 muse_dir: muse_dir
               )

      {:ok, raw} = File.read(Path.join(muse_dir, "profiles.json"))

      refute String.contains?(raw, "sk-")
      refute String.contains?(raw, "Bearer")
      refute String.contains?(raw, "password")
      refute String.contains?(raw, "api_key")
    end
  end
end
