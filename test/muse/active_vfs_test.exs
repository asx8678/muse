defmodule Muse.ActiveVFSTest do
  use ExUnit.Case, async: false

  alias Muse.ActiveVFS
  alias Muse.ActiveVFS.FileVersion

  # ── Helpers ──────────────────────────────────────────────────────────

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "muse_active_vfs_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_file(dir, rel_path, content) do
    full = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  setup context do
    dir = tmp_dir()

    # Stop any existing ActiveVFS process (from prior test)
    if Process.whereis(ActiveVFS) do
      GenServer.stop(ActiveVFS, :shutdown, 5000)
    end

    lock_ttl_ms = Map.get(context, :lock_ttl_ms, 5_000)
    {:ok, _pid} = ActiveVFS.start_link(root: dir, lock_ttl_ms: lock_ttl_ms)

    on_exit(fn ->
      try do
        if pid = Process.whereis(ActiveVFS), do: GenServer.stop(pid, :shutdown, 5000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # ── FileVersion struct ───────────────────────────────────────────────

  describe "FileVersion struct" do
    test "creates a valid FileVersion" do
      v = %FileVersion{
        path: "foo.ex",
        content: "hello",
        version_number: 0,
        agent_id: "system",
        reason: "base",
        timestamp: DateTime.utc_now()
      }

      assert v.path == "foo.ex"
      assert v.content == "hello"
      assert v.version_number == 0
    end
  end

  # ── Lazy loading ────────────────────────────────────────────────────

  describe "read/1 — lazy loading" do
    test "loads file from disk as V0 on first read", %{dir: dir} do
      write_file(dir, "lib/foo.ex", "original content")
      assert {:ok, "original content"} = ActiveVFS.read("lib/foo.ex")
    end

    test "returns error for non-existent file" do
      assert {:error, :not_found} = ActiveVFS.read("nonexistent.ex")
    end
  end

  # ── Checkout / Commit ────────────────────────────────────────────────

  describe "checkout/2" do
    test "acquires lock and returns latest version", %{dir: dir} do
      write_file(dir, "lib/bar.ex", "content")

      assert {:ok, %FileVersion{version_number: 0}} =
               ActiveVFS.checkout("lib/bar.ex", agent_id: "agent-1")
    end

    test "returns error when file is already locked by another agent", %{dir: dir} do
      write_file(dir, "lib/locked.ex", "content")
      assert {:ok, _} = ActiveVFS.checkout("lib/locked.ex", agent_id: "agent-1")
      assert {:error, :locked} = ActiveVFS.checkout("lib/locked.ex", agent_id: "agent-2")
    end

    test "allows same agent to re-checkout (refreshes lock)", %{dir: dir} do
      write_file(dir, "lib/recheck.ex", "content")
      assert {:ok, _} = ActiveVFS.checkout("lib/recheck.ex", agent_id: "agent-1")
      assert {:ok, _} = ActiveVFS.checkout("lib/recheck.ex", agent_id: "agent-1")
    end

    test "returns error for non-existent file" do
      assert {:error, :not_found} = ActiveVFS.checkout("nope.ex", agent_id: "agent-1")
    end
  end

  describe "commit/4" do
    test "creates new version and releases lock", %{dir: dir} do
      write_file(dir, "lib/commit.ex", "v0")
      assert {:ok, _} = ActiveVFS.checkout("lib/commit.ex", agent_id: "agent-1")

      assert {:ok, %FileVersion{version_number: 1, content: "v1"}} =
               ActiveVFS.commit("lib/commit.ex", "v1", "agent-1", "edit")

      # Lock should be released — another agent can now check out
      assert {:ok, _} = ActiveVFS.checkout("lib/commit.ex", agent_id: "agent-2")
    end

    test "returns error if file not locked" do
      # File not in VFS at all
      assert {:error, :not_found} = ActiveVFS.commit("unknown.ex", "x", "agent-1", "reason")
    end

    test "returns error if wrong agent commits", %{dir: dir} do
      write_file(dir, "lib/wrong.ex", "v0")
      assert {:ok, _} = ActiveVFS.checkout("lib/wrong.ex", agent_id: "agent-1")
      assert {:error, :wrong_agent} = ActiveVFS.commit("lib/wrong.ex", "v1", "agent-2", "hack")
    end

    test "returns not_locked if commit attempted on unlocked file", %{dir: dir} do
      write_file(dir, "lib/unlocked.ex", "v0")
      # Read loads it but doesn't lock
      assert {:ok, _} = ActiveVFS.read("lib/unlocked.ex")

      assert {:error, :not_locked} =
               ActiveVFS.commit("lib/unlocked.ex", "v1", "agent-1", "reason")
    end
  end

  # ── Version history ─────────────────────────────────────────────────

  describe "list_versions/1" do
    test "returns all versions newest-first", %{dir: dir} do
      write_file(dir, "lib/hist.ex", "v0")
      assert {:ok, _} = ActiveVFS.checkout("lib/hist.ex", agent_id: "a1")
      assert {:ok, _} = ActiveVFS.commit("lib/hist.ex", "v1", "a1", "edit 1")
      assert {:ok, _} = ActiveVFS.checkout("lib/hist.ex", agent_id: "a2")
      assert {:ok, _} = ActiveVFS.commit("lib/hist.ex", "v2", "a2", "edit 2")

      assert {:ok, versions} = ActiveVFS.list_versions("lib/hist.ex")
      assert length(versions) == 3

      assert [
               %FileVersion{version_number: 2},
               %FileVersion{version_number: 1},
               %FileVersion{version_number: 0}
             ] = versions
    end

    test "lazy loads file on list_versions", %{dir: dir} do
      write_file(dir, "lib/lazy_list.ex", "base")

      assert {:ok, [%FileVersion{version_number: 0}]} =
               ActiveVFS.list_versions("lib/lazy_list.ex")
    end
  end

  # ── Rollback ────────────────────────────────────────────────────────

  describe "rollback/2" do
    test "reverts to specified version by pushing new version", %{dir: dir} do
      write_file(dir, "lib/rollback.ex", "v0")
      assert {:ok, _} = ActiveVFS.checkout("lib/rollback.ex", agent_id: "a1")
      assert {:ok, _} = ActiveVFS.commit("lib/rollback.ex", "v1", "a1", "edit 1")
      assert {:ok, _} = ActiveVFS.checkout("lib/rollback.ex", agent_id: "a1")
      assert {:ok, _} = ActiveVFS.commit("lib/rollback.ex", "v2", "a1", "edit 2")

      assert {:ok, %FileVersion{content: "v0", version_number: 3}} =
               ActiveVFS.rollback("lib/rollback.ex", 0)

      # Read reflects the rollback
      assert {:ok, "v0"} = ActiveVFS.read("lib/rollback.ex")
    end

    test "returns error for non-existent version", %{dir: dir} do
      write_file(dir, "lib/rb_err.ex", "v0")
      assert {:ok, _} = ActiveVFS.read("lib/rb_err.ex")
      assert {:error, :version_not_found} = ActiveVFS.rollback("lib/rb_err.ex", 99)
    end

    test "returns error for non-existent file" do
      assert {:error, :not_found} = ActiveVFS.rollback("nope.ex", 0)
    end
  end

  # ── Lock expiry ─────────────────────────────────────────────────────

  describe "lock TTL expiry" do
    @tag lock_ttl_ms: 500
    test "auto-releases lock after TTL", %{dir: dir} do
      write_file(dir, "lib/ttl.ex", "content")
      assert {:ok, _} = ActiveVFS.checkout("lib/ttl.ex", agent_id: "agent-1")
      assert {:error, :locked} = ActiveVFS.checkout("lib/ttl.ex", agent_id: "agent-2")

      # Force lock expiry check — TTL is 500ms
      # We need to advance past the TTL. Sleep briefly then trigger check.
      Process.sleep(600)
      send(ActiveVFS, :check_lock_expiry)
      Process.sleep(50)

      assert {:ok, _} = ActiveVFS.checkout("lib/ttl.ex", agent_id: "agent-2")
    end
  end

  # ── Lock status ─────────────────────────────────────────────────────

  describe "lock_status/1" do
    test "returns nil when file is not locked", %{dir: dir} do
      write_file(dir, "lib/status.ex", "content")
      assert {:ok, _} = ActiveVFS.read("lib/status.ex")
      assert {:ok, nil} = ActiveVFS.lock_status("lib/status.ex")
    end

    test "returns agent_id when file is locked", %{dir: dir} do
      write_file(dir, "lib/locked_status.ex", "content")
      assert {:ok, _} = ActiveVFS.checkout("lib/locked_status.ex", agent_id: "agent-1")
      assert {:ok, "agent-1"} = ActiveVFS.lock_status("lib/locked_status.ex")
    end

    test "returns not_found for unknown file" do
      assert {:error, :not_found} = ActiveVFS.lock_status("nope.ex")
    end
  end

  # ── Flush ───────────────────────────────────────────────────────────

  describe "flush/0" do
    test "writes latest version to disk", %{dir: dir} do
      write_file(dir, "lib/flush.ex", "original")
      assert {:ok, _} = ActiveVFS.checkout("lib/flush.ex", agent_id: "a1")
      assert {:ok, _} = ActiveVFS.commit("lib/flush.ex", "updated", "a1", "edit")

      assert :ok = ActiveVFS.flush()

      # Read directly from disk
      assert File.read!(Path.join(dir, "lib/flush.ex")) == "updated"
    end

    test "creates parent directories if needed", %{dir: dir} do
      write_file(dir, "deep/nested/file.ex", "base")
      assert {:ok, _} = ActiveVFS.checkout("deep/nested/file.ex", agent_id: "a1")
      assert {:ok, _} = ActiveVFS.commit("deep/nested/file.ex", "new", "a1", "edit")

      assert :ok = ActiveVFS.flush()
      assert File.read!(Path.join(dir, "deep/nested/file.ex")) == "new"
    end

    test "flush with no files is a no-op" do
      assert :ok = ActiveVFS.flush()
    end
  end

  # ── Root ────────────────────────────────────────────────────────────

  describe "root/0" do
    test "returns the configured root path", %{dir: dir} do
      assert ActiveVFS.root() == dir
    end
  end
end
