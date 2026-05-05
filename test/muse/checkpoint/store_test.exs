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

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(".muse/sessions")
    end)

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

      assert {:ok, loaded} = Store.load("test-session-3", created.id)
      assert loaded.session_id == "test-session-3"
      assert loaded.patch_id == "patch-1"

      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

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

      modified_content = "MODIFIED CONTENT"
      File.write!(Path.join([workspace, "lib", "example.ex"]), modified_content)

      assert {:ok, rolled_back} = Store.rollback(created)
      assert rolled_back.status == :rolled_back

      restored_content = File.read!(Path.join([workspace, "lib", "example.ex"]))
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

      new_file = Path.join([workspace, "lib", "brand_new.ex"])
      File.write!(new_file, "new content")
      assert File.exists?(new_file)

      {:ok, _rolled_back} = Store.rollback(created)

      refute File.exists?(new_file)
    end

    test "returns error on restore failure, not false success", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session-6",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("g", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test diff"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      # Delete the snapshot to simulate corruption
      snap_dir =
        Path.join([".muse/sessions", "test-session-6", "checkpoints", active.id, "snapshots"])

      File.rm_rf!(Path.join(snap_dir, "lib"))

      result = Store.rollback(active)
      assert {:error, {:rollback_failed, _errors}} = result
    end

    test "marks checkpoint as :failed not :rolled_back on restore failure", %{
      workspace: workspace
    } do
      checkpoint =
        Checkpoint.new(%{
          session_id: "test-session-7",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("h", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test diff"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      # Delete snapshots
      snap_dir =
        Path.join([".muse/sessions", "test-session-7", "checkpoints", active.id, "snapshots"])

      File.rm_rf!(Path.join(snap_dir, "lib"))

      {:error, {:rollback_failed, _}} = Store.rollback(active)

      # Load and check status
      {:ok, reloaded} = Store.load("test-session-7", active.id)
      assert reloaded.status == :failed
    end
  end

  describe "rollback/2 — path safety (issue 2 regression)" do
    test "rejects traversal in session_id" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "../../etc",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("i", 64),
          workspace: "/tmp"
        })

      assert {:error, {:rollback_failed, [{:path_traversal, "session_id"}]}} =
               Store.rollback(checkpoint)
    end

    test "rejects traversal in checkpoint_id" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "valid-session",
          id: "../../etc",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("j", 64),
          workspace: "/tmp"
        })

      assert {:error, {:rollback_failed, [{:path_traversal, "checkpoint_id"}]}} =
               Store.rollback(checkpoint)
    end

    test "rejects snapshot_path that escapes checkpoints dir", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "safety-test-1",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("k", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      # Tamper manifest: change snapshot_path to escape the snapshots dir
      {:ok, loaded} = Store.load("safety-test-1", active.id)

      tampered_snapshots =
        Enum.map(loaded.file_snapshots, fn s ->
          %{s | snapshot_path: "../../etc/passwd"}
        end)

      tampered = %{loaded | file_snapshots: tampered_snapshots}
      {:ok, _} = Store.update_manifest(tampered)

      result = Store.rollback(tampered)
      assert {:error, {:rollback_failed, [{:snapshot_path_escape, "../../etc/passwd"}]}} = result
    end

    test "rejects secret path in restore", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "safety-test-2",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("l", 64),
          workspace: workspace,
          affected_files: [".env"],
          metadata: %{diff: "test"}
        })

      # .env is a secret path — create should reject it
      result = Store.create(checkpoint)
      # The snapshot should fail because .env is a secret path
      assert match?({:error, _}, result)
    end

    test "detects hash mismatch on restore", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "safety-test-3",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("m", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      # Tamper the snapshot file content to create hash mismatch
      snap_dir =
        Path.join([".muse/sessions", "safety-test-3", "checkpoints", active.id, "snapshots"])

      snap_file = Path.join([snap_dir, "lib", "example.ex"])
      File.write!(snap_file, "TAMPERED CONTENT")

      result = Store.rollback(active)
      assert {:error, {:rollback_failed, errors}} = result

      assert Enum.any?(errors, fn
               {:hash_mismatch, _, _, _} -> true
               _ -> false
             end)
    end
  end
end
