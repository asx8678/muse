defmodule Muse.PatchSessionStoreTest do
  use ExUnit.Case, async: false

  alias Muse.{SessionStore, Patch}

  setup do
    base_dir = tmp_dir!()
    session_id = "test-session-patch-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    %{base_dir: base_dir, session_id: session_id}
  end

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "muse-patch-store-test-#{suffix}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  describe "append_patch/3 and load_patches/2" do
    test "append and reload patch proposals", %{base_dir: base_dir, session_id: session_id} do
      patch =
        Patch.new(
          id: "patch_store_1",
          session_id: session_id,
          plan_id: "plan_1",
          plan_version: 1,
          plan_hash: "abc123",
          summary: "Add feature"
        )

      assert :ok = SessionStore.append_patch(base_dir, session_id, Patch.to_map(patch))

      assert {:ok, patches, %{skipped: 0}} = SessionStore.load_patches(base_dir, session_id)
      assert length(patches) == 1

      loaded = hd(patches)
      assert loaded["id"] == "patch_store_1"
      assert loaded["session_id"] == session_id
      assert loaded["plan_id"] == "plan_1"
      assert loaded["summary"] == "Add feature"
    end

    test "multiple patches load in order", %{base_dir: base_dir, session_id: session_id} do
      p1 =
        Patch.new(
          id: "patch_1",
          session_id: session_id,
          plan_id: "plan_1",
          plan_version: 1,
          plan_hash: "abc",
          summary: "First"
        )

      p2 =
        Patch.new(
          id: "patch_2",
          session_id: session_id,
          plan_id: "plan_1",
          plan_version: 1,
          plan_hash: "abc",
          summary: "Second"
        )

      :ok = SessionStore.append_patch(base_dir, session_id, Patch.to_map(p1))
      :ok = SessionStore.append_patch(base_dir, session_id, Patch.to_map(p2))

      assert {:ok, patches, %{skipped: 0}} = SessionStore.load_patches(base_dir, session_id)
      assert length(patches) == 2
      assert hd(patches)["id"] == "patch_1"
      assert List.last(patches)["id"] == "patch_2"
    end

    test "missing patches file returns empty list", %{base_dir: base_dir, session_id: session_id} do
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_patches(base_dir, session_id)
    end

    test "patches are separate from events and messages", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      SessionStore.append_event(base_dir, session_id, %{"type" => "test_event"})
      SessionStore.append_message(base_dir, session_id, %{"role" => "user", "content" => "hi"})

      patch =
        Patch.new(
          id: "patch_sep",
          session_id: session_id,
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc"
        )

      SessionStore.append_patch(base_dir, session_id, Patch.to_map(patch))

      assert {:ok, events, _} = SessionStore.load_events(base_dir, session_id)
      assert {:ok, messages, _} = SessionStore.load_messages(base_dir, session_id)
      assert {:ok, patches, _} = SessionStore.load_patches(base_dir, session_id)

      assert length(events) == 1
      assert length(messages) == 1
      assert length(patches) == 1
    end

    test "skips corrupt lines in patches.jsonl", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "patches.jsonl")

      File.write!(path, ~s|{"id":"p1"}\nCORRUPT\n{"id":"p2"}\n|)

      assert {:ok, patches, %{skipped: 1}} = SessionStore.load_patches(base_dir, session_id)
      assert length(patches) == 2
    end

    test "validates session id for append_patch", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.append_patch(base_dir, "../escape", %{"id" => "p1"})
    end

    test "validates session id for load_patches", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.load_patches(base_dir, "../escape")
    end
  end

  describe "session snapshot with pending_patch" do
    test "round-trips pending patch in session.json", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      patch =
        Patch.new(
          id: "patch_snap",
          session_id: session_id,
          plan_id: "plan_snap",
          plan_version: 1,
          plan_hash: "snap123",
          workspace: "/tmp/project",
          status: :awaiting_approval,
          summary: "Snapshot test patch"
        )

      data = %{
        "status" => "awaiting_patch_approval",
        "active_plan_id" => "plan_snap",
        "pending_patch" => Patch.to_map(patch)
      }

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["status"] == "awaiting_patch_approval"
      assert loaded["pending_patch"]["id"] == "patch_snap"
      assert loaded["pending_patch"]["plan_id"] == "plan_snap"
      assert loaded["pending_patch"]["status"] == "awaiting_approval"
      assert loaded["pending_patch"]["summary"] == "Snapshot test patch"
    end

    test "pending_patch is nil when not in snapshot", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      data = %{
        "status" => "idle"
      }

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["pending_patch"] == nil
    end
  end

  describe "workspace safety" do
    test "patch storage does not create files outside session dir", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      patch =
        Patch.new(
          id: "patch_safe",
          session_id: session_id,
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          workspace: "/tmp/should_not_write_here"
        )

      assert :ok = SessionStore.append_patch(base_dir, session_id, Patch.to_map(patch))

      # The workspace path in the patch data should NOT cause any files to be created
      refute File.exists?("/tmp/should_not_write_here")

      # Only session storage files should exist
      dir = SessionStore.session_dir(base_dir, session_id)
      files = File.ls!(dir)
      assert "patches.jsonl" in files
    end
  end
end
