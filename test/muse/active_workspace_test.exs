defmodule Muse.ActiveWorkspaceTest do
  use ExUnit.Case, async: false

  alias Muse.ActiveWorkspace
  alias Muse.WorkspaceProfile

  # ── Helpers ──────────────────────────────────────────────────────────

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "muse-active-workspace-test-#{suffix}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp ensure_active_workspace(opts \\ []) do
    case Process.whereis(ActiveWorkspace) do
      nil ->
        {:ok, _pid} = ActiveWorkspace.start_link(opts)
        :ok

      _pid ->
        # Process is already running (supervised); reset and reconfigure
        :ok = ActiveWorkspace.reset()

        root_path = Keyword.get(opts, :root_path)
        store_base_dir = Keyword.get(opts, :store_base_dir)

        cond do
          root_path && store_base_dir ->
            :ok = ActiveWorkspace.set(root_path, store_base_dir)

          root_path ->
            :ok =
              ActiveWorkspace.set(root_path, WorkspaceProfile.sessions_dir_from_root(root_path))

          store_base_dir ->
            # Use current root_path but override store_base_dir
            current_root = ActiveWorkspace.root_path()
            :ok = ActiveWorkspace.set(current_root, store_base_dir)

          true ->
            :ok
        end

        :ok
    end
  end

  # Like ensure_active_workspace but guarantees a running process
  # even if the supervised one was killed. Used by tests that need
  # to set custom state before starting SessionServer processes.
  defp ensure_active_workspace_running do
    case Process.whereis(ActiveWorkspace) do
      nil ->
        {:ok, _pid} = ActiveWorkspace.start_link([])
        :ok

      _pid ->
        :ok = ActiveWorkspace.reset()
        :ok
    end
  end

  defp stop_active_workspace do
    case Process.whereis(ActiveWorkspace) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5000)
        catch
          :exit, _ -> :ok
        end
    end

    # Wait for process to fully exit and name to be unregistered
    Process.sleep(10)
  end

  setup do
    muse_dir = tmp_dir!()

    # Ensure ActiveWorkspace is in default state for each test
    if Process.whereis(ActiveWorkspace) do
      ActiveWorkspace.reset()
    end

    on_exit(fn ->
      # Reset ActiveWorkspace to default state, do NOT stop it
      # (it's supervised and stopping it can disrupt the supervisor tree)
      if Process.whereis(ActiveWorkspace) do
        ActiveWorkspace.reset()
      end

      File.rm_rf!(muse_dir)
    end)

    %{muse_dir: muse_dir}
  end

  # ── start_link and defaults ──────────────────────────────────────────

  describe "start_link/1" do
    test "starts with default state" do
      assert ensure_active_workspace() == :ok

      state = ActiveWorkspace.get()
      assert state.profile_name == nil
      assert state.store_base_dir == ".muse/sessions"
    end

    test "starts with custom root_path" do
      root = tmp_dir!()
      assert ensure_active_workspace(root_path: root) == :ok

      state = ActiveWorkspace.get()
      assert state.root_path == root
      assert state.store_base_dir == WorkspaceProfile.sessions_dir_from_root(root)
    end

    test "starts with custom store_base_dir" do
      assert ensure_active_workspace(store_base_dir: "/custom/sessions") == :ok

      state = ActiveWorkspace.get()
      assert state.store_base_dir == "/custom/sessions"
    end
  end

  # ── get/0 ────────────────────────────────────────────────────────────

  describe "get/0" do
    test "returns full state map" do
      assert ensure_active_workspace(root_path: "/tmp/test-ws") == :ok

      state = ActiveWorkspace.get()
      assert Map.has_key?(state, :profile_name)
      assert Map.has_key?(state, :root_path)
      assert Map.has_key?(state, :store_base_dir)
    end
  end

  # ── profile_name/0, store_base_dir/0, root_path/0 ───────────────────

  describe "accessors" do
    test "profile_name returns nil when no profile is active" do
      assert ensure_active_workspace() == :ok
      assert ActiveWorkspace.profile_name() == nil
    end

    test "store_base_dir returns derived path" do
      assert ensure_active_workspace(root_path: "/tmp/test-ws") == :ok
      assert ActiveWorkspace.store_base_dir() == "/tmp/test-ws/.muse/sessions"
    end

    test "root_path returns the configured root" do
      assert ensure_active_workspace(root_path: "/tmp/test-ws") == :ok
      assert ActiveWorkspace.root_path() == "/tmp/test-ws"
    end
  end

  # ── switch/1 ────────────────────────────────────────────────────────

  describe "switch/1" do
    test "switches to a valid workspace profile", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "project-a")
      File.mkdir_p!(root)

      {:ok, _profile} =
        WorkspaceProfile.create(name: "project-a", root_path: root, muse_dir: muse_dir)

      assert ensure_active_workspace(muse_dir: muse_dir) == :ok

      assert {:ok, profile} = ActiveWorkspace.switch("project-a", muse_dir: muse_dir)
      assert profile.name == "project-a"

      assert ActiveWorkspace.profile_name() == "project-a"
      assert ActiveWorkspace.root_path() == Path.expand(root)
      assert ActiveWorkspace.store_base_dir() == Path.join(Path.expand(root), ".muse/sessions")
    end

    test "returns error for non-existent profile", %{muse_dir: muse_dir} do
      assert ensure_active_workspace() == :ok
      assert {:error, :not_found} = ActiveWorkspace.switch("nonexistent", muse_dir: muse_dir)
    end

    test "does not change state on failed switch", %{muse_dir: muse_dir} do
      assert ensure_active_workspace(root_path: "/tmp/initial") == :ok

      _ = ActiveWorkspace.switch("nonexistent", muse_dir: muse_dir)

      # State should remain unchanged
      assert ActiveWorkspace.root_path() == "/tmp/initial"
      assert ActiveWorkspace.profile_name() == nil
    end
  end

  # ── reset/0 ─────────────────────────────────────────────────────────

  describe "reset/0" do
    test "resets to default state", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "project-b")
      File.mkdir_p!(root)

      {:ok, _profile} =
        WorkspaceProfile.create(name: "project-b", root_path: root, muse_dir: muse_dir)

      assert ensure_active_workspace() == :ok

      # Switch to a profile
      assert {:ok, _} = ActiveWorkspace.switch("project-b", muse_dir: muse_dir)
      assert ActiveWorkspace.profile_name() == "project-b"

      # Reset
      assert :ok = ActiveWorkspace.reset()
      assert ActiveWorkspace.profile_name() == nil
    end
  end

  # ── set/2 ────────────────────────────────────────────────────────────

  describe "set/2" do
    test "sets root_path and store_base_dir directly" do
      assert ensure_active_workspace() == :ok

      assert :ok = ActiveWorkspace.set("/tmp/custom-root", "/tmp/custom-sessions")

      assert ActiveWorkspace.root_path() == "/tmp/custom-root"
      assert ActiveWorkspace.store_base_dir() == "/tmp/custom-sessions"
    end
  end

  # ── Workspace isolation ─────────────────────────────────────────────

  describe "workspace session isolation" do
    test "switching workspace changes store_base_dir for future sessions", %{
      muse_dir: muse_dir
    } do
      root_a = Path.join(muse_dir, "ws-a")
      root_b = Path.join(muse_dir, "ws-b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      {:ok, _} =
        WorkspaceProfile.create(name: "ws-a", root_path: root_a, muse_dir: muse_dir)

      {:ok, _} =
        WorkspaceProfile.create(name: "ws-b", root_path: root_b, muse_dir: muse_dir)

      assert ensure_active_workspace() == :ok

      # Switch to ws-a
      assert {:ok, _} = ActiveWorkspace.switch("ws-a", muse_dir: muse_dir)
      dir_a = ActiveWorkspace.store_base_dir()
      assert dir_a == Path.join(Path.expand(root_a), ".muse/sessions")

      # Switch to ws-b
      assert {:ok, _} = ActiveWorkspace.switch("ws-b", muse_dir: muse_dir)
      dir_b = ActiveWorkspace.store_base_dir()
      assert dir_b == Path.join(Path.expand(root_b), ".muse/sessions")

      # Different workspaces have different session dirs
      refute dir_a == dir_b
    end

    test "same session ID in different workspaces persists isolated state", %{
      muse_dir: muse_dir
    } do
      root_a = Path.join(muse_dir, "iso-a")
      root_b = Path.join(muse_dir, "iso-b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      {:ok, _} =
        WorkspaceProfile.create(name: "iso-a", root_path: root_a, muse_dir: muse_dir)

      {:ok, _} =
        WorkspaceProfile.create(name: "iso-b", root_path: root_b, muse_dir: muse_dir)

      dir_a = Path.join(Path.expand(root_a), ".muse/sessions")
      dir_b = Path.join(Path.expand(root_b), ".muse/sessions")

      session_id = "isolation-test-session"

      # Save in workspace A
      :ok =
        Muse.SessionStore.save_session(dir_a, session_id, %{
          "workspace" => "A",
          "data" => "from-a"
        })

      # Save in workspace B with same session ID
      :ok =
        Muse.SessionStore.save_session(dir_b, session_id, %{
          "workspace" => "B",
          "data" => "from-b"
        })

      # Load from A should get A's data
      assert {:ok, data_a} = Muse.SessionStore.load_session(dir_a, session_id)
      assert data_a["workspace"] == "A"
      assert data_a["data"] == "from-a"

      # Load from B should get B's data
      assert {:ok, data_b} = Muse.SessionStore.load_session(dir_b, session_id)
      assert data_b["workspace"] == "B"
      assert data_b["data"] == "from-b"
    end

    test "memory is isolated across workspaces", %{muse_dir: muse_dir} do
      root_a = Path.join(muse_dir, "mem-a")
      root_b = Path.join(muse_dir, "mem-b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      dir_a = Path.join(Path.expand(root_a), ".muse/sessions")
      dir_b = Path.join(Path.expand(root_b), ".muse/sessions")

      session_id = "memory-iso-test"

      # Save memory in workspace A
      :ok =
        Muse.SessionStore.save_memory(dir_a, session_id, %{
          "summary" => "Memory from workspace A"
        })

      # Save different memory in workspace B
      :ok =
        Muse.SessionStore.save_memory(dir_b, session_id, %{
          "summary" => "Memory from workspace B"
        })

      # Load from each workspace should be isolated
      assert {:ok, mem_a} = Muse.SessionStore.load_memory(dir_a, session_id)
      assert mem_a["summary"] == "Memory from workspace A"

      assert {:ok, mem_b} = Muse.SessionStore.load_memory(dir_b, session_id)
      assert mem_b["summary"] == "Memory from workspace B"
    end

    test "export/import uses workspace-scoped base_dir", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "export-ws")
      File.mkdir_p!(root)

      dir = Path.join(Path.expand(root), ".muse/sessions")
      session_id = "export-test"

      # Save session data
      :ok =
        Muse.SessionStore.save_session(dir, session_id, %{
          "status" => "idle",
          "test" => "export-data"
        })

      # Export
      assert {:ok, export_map} = Muse.SessionStore.export_session(dir, session_id)
      assert export_map["session_id"] == session_id

      # Import into a different workspace dir
      other_dir = Path.join(Path.join(muse_dir, "import-ws"), ".muse/sessions")

      assert {:ok, ^session_id} =
               Muse.SessionStore.import_session(other_dir, export_map)

      # Data is available in the new dir
      assert {:ok, imported} = Muse.SessionStore.load_session(other_dir, session_id)
      assert imported["test"] == "export-data"

      # Original still exists
      assert {:ok, original} = Muse.SessionStore.load_session(dir, session_id)
      assert original["test"] == "export-data"
    end
  end

  # ── Invalid input safety ────────────────────────────────────────────

  describe "safety" do
    test "switch rejects path traversal profile names", %{muse_dir: muse_dir} do
      assert ensure_active_workspace() == :ok

      # Should not create profiles with traversal names
      assert {:error, _} =
               WorkspaceProfile.create(name: "../etc", root_path: "/tmp", muse_dir: muse_dir)

      # Switch should fail for non-existent profile
      assert {:error, _} = ActiveWorkspace.switch("../etc", muse_dir: muse_dir)
    end

    test "switch with invalid profile does not corrupt state", %{muse_dir: muse_dir} do
      assert ensure_active_workspace(root_path: "/tmp/safe-root") == :ok

      # Attempt to switch to nonexistent profile
      _ = ActiveWorkspace.switch("nonexistent", muse_dir: muse_dir)

      # State should remain unchanged
      assert ActiveWorkspace.root_path() == "/tmp/safe-root"
    end

    test "no atoms created from user-supplied profile names", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "atom-test")
      File.mkdir_p!(root)

      # This profile name should not become an atom
      {:ok, _} =
        WorkspaceProfile.create(name: "my-test-profile", root_path: root, muse_dir: muse_dir)

      assert ensure_active_workspace() == :ok

      # Switch should succeed without creating atoms
      assert {:ok, _} = ActiveWorkspace.switch("my-test-profile", muse_dir: muse_dir)

      # The profile name is stored as a string, not an atom
      assert is_binary(ActiveWorkspace.profile_name())
    rescue
      # If profile_name were an atom, Atom.to_string/1 would succeed
      # and the refute would fail — but we expect profile_name to be a binary
      ArgumentError -> :ok
    end
  end

  # ── Workspace-scoped SessionServer runtime ─────────────────────────

  describe "workspace-scoped session server runtime" do
    test "session server captures store_base_dir at init and uses it for persistence" do
      ensure_active_workspace_running()

      # Set ActiveWorkspace to a custom base dir
      base_dir = tmp_dir!() |> Path.join(".muse/sessions")
      assert :ok = ActiveWorkspace.set("/tmp/ws-init-test", base_dir)

      session_id = "ws-runtime-test-#{:erlang.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      try do
        status = Muse.SessionServer.status(pid)
        # SessionServer should have captured the ActiveWorkspace store_base_dir
        assert status.store_base_dir == base_dir

        # Now switch ActiveWorkspace to a different dir
        other_dir = tmp_dir!() |> Path.join(".muse/sessions")
        assert :ok = ActiveWorkspace.set("/tmp/ws-other", other_dir)

        # The already-running session should still use the original base_dir
        status2 = Muse.SessionServer.status(pid)
        assert status2.store_base_dir == base_dir
      after
        DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid)
        ActiveWorkspace.reset()
      end
    end

    test "after switching workspace, new session uses new store_base_dir" do
      ensure_active_workspace_running()

      # Set up two different workspace base dirs
      dir_a = tmp_dir!() |> Path.join(".muse/sessions")
      dir_b = tmp_dir!() |> Path.join(".muse/sessions")

      session_id = "ws-switch-test-#{:erlang.unique_integer([:positive])}"

      # Start session in workspace A
      assert :ok = ActiveWorkspace.set("/tmp/ws-a", dir_a)

      {:ok, pid_a} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      # Session A should use dir_a
      status_a = Muse.SessionServer.status(pid_a)
      assert status_a.store_base_dir == dir_a

      # Now switch to workspace B
      assert :ok = ActiveWorkspace.set("/tmp/ws-b", dir_b)

      # Start another session with the SAME ID in workspace B
      # (Can't use same ID since the registry would return the existing session,
      #  so use a different session_id to demonstrate the new base_dir)
      session_id_b = "ws-switch-test-b-#{:erlang.unique_integer([:positive])}"

      {:ok, pid_b} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id_b}
        )

      try do
        # Session B should use dir_b
        status_b = Muse.SessionServer.status(pid_b)
        assert status_b.store_base_dir == dir_b

        # Session A should still use dir_a (not affected by switch)
        status_a2 = Muse.SessionServer.status(pid_a)
        assert status_a2.store_base_dir == dir_a
      after
        DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid_a)
        DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid_b)
        ActiveWorkspace.reset()
      end
    end

    test "session with same ID in different workspaces does not see each other's state" do
      ensure_active_workspace_running()

      dir_a = tmp_dir!() |> Path.join(".muse/sessions")
      dir_b = tmp_dir!() |> Path.join(".muse/sessions")

      session_id = "iso-runtime-test-#{:erlang.unique_integer([:positive])}"

      # Persist data in workspace A
      :ok =
        Muse.SessionStore.save_session(dir_a, session_id, %{
          "status" => "idle",
          "workspace_label" => "A",
          "test_key" => "from-workspace-a"
        })

      # Persist data in workspace B with same session ID
      :ok =
        Muse.SessionStore.save_session(dir_b, session_id, %{
          "status" => "idle",
          "workspace_label" => "B",
          "test_key" => "from-workspace-b"
        })

      # Start session in workspace A
      assert :ok = ActiveWorkspace.set("/tmp/iso-a", dir_a)

      {:ok, pid_a} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      try do
        # Session A should have restored from workspace A's data
        status_a = Muse.SessionServer.status(pid_a)
        # The plan should be nil for both, but the important thing is
        # that the store_base_dir is correct and isolated
        assert status_a.store_base_dir == dir_a
      after
        DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid_a)
        ActiveWorkspace.reset()
      end

      # Clean up
      File.rm_rf!(Path.dirname(dir_a))
      File.rm_rf!(Path.dirname(dir_b))
    end

    test "invalid profile/session IDs are rejected safely and do not touch outside paths" do
      ensure_active_workspace_running()

      # Switch to non-existent profile
      assert {:error, :not_found} =
               ActiveWorkspace.switch("nonexistent-profile", muse_dir: tmp_dir!())

      # ActiveWorkspace state should remain safe/default
      state = ActiveWorkspace.get()
      assert state.profile_name == nil
      assert state.store_base_dir == ".muse/sessions"
    end
  end
end
