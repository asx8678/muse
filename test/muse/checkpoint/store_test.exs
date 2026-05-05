defmodule Muse.Checkpoint.StoreTest do
  use ExUnit.Case, async: false

  alias Muse.Checkpoint
  alias Muse.Checkpoint.Store

  setup do
    workspace = Path.join(System.tmp_dir!(), "muse_chk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(Path.join([workspace, "lib", "example.ex"]), """
    defmodule Example do
      def hello, do: :world
    end
    """)

    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  describe "create/2" do
    test "creates checkpoint with file snapshots", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("a", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "some diff content"}
        })

      assert {:ok, created} = Store.create(checkpoint)
      assert created.status == :created
      assert length(created.file_snapshots) == 1

      snapshot = hd(created.file_snapshots)
      assert snapshot.path == "lib/example.ex"
      assert snapshot.existed == true
      assert is_binary(snapshot.content_hash)
      assert is_binary(snapshot.snapshot_path)
    end

    test "snapshots non-existent files as did_not_exist", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session-2",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("b", 64),
          workspace: workspace,
          affected_files: ["lib/new_file.ex"],
          metadata: %{diff: "some diff content"}
        })

      assert {:ok, created} = Store.create(checkpoint)
      snapshot = hd(created.file_snapshots)
      assert snapshot.existed == false
      assert snapshot.content_hash == nil
    end

    test "fails with invalid session_id" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "../traversal",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("c", 64),
          workspace: "/tmp"
        })

      assert {:error, {:path_traversal, "session_id"}} = Store.create(checkpoint)
    end
  end

  describe "load/3 and update_manifest/2" do
    test "round-trips checkpoint through create/load/update", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session-3",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("d", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test diff"}
        })

      {:ok, created} = Store.create(checkpoint)

      # Load it back
      assert {:ok, loaded} = Store.load("test-session-3", created.id)
      assert loaded.session_id == "test-session-3"
      assert loaded.patch_id == "patch-1"

      # Update status
      {:ok, active} = Checkpoint.transition(created, :active)
      :ok = Store.update_manifest(active)

      {:ok, reloaded} = Store.load("test-session-3", created.id)
      assert reloaded.status == :active
    end
  end

  describe "rollback/2" do
    test "restores file content from snapshot", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session-4",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("e", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test diff"}
        })

      {:ok, created} = Store.create(checkpoint)

      # Modify the file
      modified_content = "MODIFIED CONTENT"
      File.write!(Path.join(workspace, "lib/example.ex"), modified_content)

      # Rollback
      assert {:ok, rolled_back} = Store.rollback(created)
      assert rolled_back.status == :rolled_back

      # File should be restored
      restored_content = File.read!(Path.join(workspace, "lib/example.ex"))
      assert restored_content != modified_content
    end

    test "removes new files that did not exist before", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session-5",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("f", 64),
          workspace: workspace,
          affected_files: ["lib/brand_new.ex"],
          metadata: %{diff: "test diff"}
        })

      {:ok, created} = Store.create(checkpoint)

      # Create the new file (simulating what patch apply would do)
      new_file = Path.join(workspace, "lib/brand_new.ex")
      File.write!(new_file, "new content")
      assert File.exists?(new_file)

      # Rollback
      {:ok, _rolled_back} = Store.rollback(created)

      # New file should be deleted
      refute File.exists?(new_file)
    end
  end
end
