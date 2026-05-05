defmodule Muse.Checkpoint.StoreTest do
  use ExUnit.Case, async: false

  alias Muse.Checkpoint
  alias Muse.Checkpoint.Store

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "muse_chk_#{System.unique_integer([:positive])}")

    workspace = Path.join(base_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(Path.join([workspace, "lib", "example.ex"]), """
    defmodule Example do
      def hello, do: :world
    end
    """)

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    %{workspace: workspace, base_dir: base_dir}
  end

  defp make_checkpoint(overrides, workspace) do
    uid = System.unique_integer([:positive])

    defaults = %{
      session_id: "test-session-#{uid}",
      plan_id: "plan-1",
      plan_hash: String.duplicate("f", 64),
      patch_id: "patch-1",
      patch_hash: String.duplicate("a", 64),
      workspace: workspace,
      affected_files: ["lib/example.ex"],
      metadata: %{diff: "some diff content"}
    }

    Checkpoint.new(Map.merge(defaults, overrides))
  end

  describe "create/2" do
    test "creates checkpoint with file snapshots", %{workspace: workspace, base_dir: base_dir} do
      checkpoint = make_checkpoint(%{}, workspace)

      assert {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      assert created.status == :created
      assert length(created.file_snapshots) == 1

      snapshot = hd(created.file_snapshots)
      assert snapshot.path == "lib/example.ex"
      assert snapshot.existed == true
      assert is_binary(snapshot.content_hash)
      assert is_binary(snapshot.snapshot_path)
    end

    test "snapshots non-existent files as did_not_exist", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{affected_files: ["lib/new_file.ex"]}, workspace)

      assert {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      snapshot = hd(created.file_snapshots)
      assert snapshot.existed == false
      assert snapshot.content_hash == nil
    end

    test "fails with invalid session_id", %{workspace: workspace, base_dir: base_dir} do
      checkpoint = make_checkpoint(%{session_id: "../traversal"}, workspace)

      assert {:error, {:path_traversal, "session_id"}} =
               Store.create(checkpoint, base_dir: base_dir)
    end
  end

  describe "load/3 — id validation and identity verification" do
    test "round-trips checkpoint through create/load/update", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)

      assert {:ok, loaded} =
               Store.load(checkpoint.session_id, created.id, base_dir: base_dir)

      assert loaded.session_id == checkpoint.session_id
      assert loaded.patch_id == "patch-1"

      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      {:ok, reloaded} =
        Store.load(checkpoint.session_id, created.id, base_dir: base_dir)

      assert reloaded.status == :active
    end

    test "rejects traversal in session_id", %{base_dir: base_dir} do
      assert {:error, {:path_traversal, "session_id"}} =
               Store.load("../../etc", "chk_1", base_dir: base_dir)
    end

    test "rejects traversal in checkpoint_id", %{base_dir: base_dir} do
      assert {:error, {:path_traversal, "checkpoint_id"}} =
               Store.load("s1", "../../etc", base_dir: base_dir)
    end

    test "rejects null byte in session_id", %{base_dir: base_dir} do
      assert {:error, {:path_traversal, "session_id"}} =
               Store.load("s\0x", "chk_1", base_dir: base_dir)
    end

    test "rejects backslash in checkpoint_id", %{base_dir: base_dir} do
      assert {:error, {:path_traversal, "checkpoint_id"}} =
               Store.load("s1", "chk\\1", base_dir: base_dir)
    end

    test "detects tampered manifest with mismatched session_id", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)
      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)

      # Tamper the manifest to change session_id
      manifest_path =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", created.id, "manifest.json"])

      {:ok, content} = File.read(manifest_path)
      {:ok, decoded} = Jason.decode(content)
      tampered = Map.put(decoded, "session_id", "tampered-session")
      :ok = File.write(manifest_path, Jason.encode!(tampered))

      assert {:error, {:identity_mismatch, details}} =
               Store.load(checkpoint.session_id, created.id, base_dir: base_dir)

      assert details.requested_session_id == checkpoint.session_id
      assert details.loaded_session_id == "tampered-session"
    end

    test "detects tampered manifest with mismatched checkpoint_id", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)
      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)

      manifest_path =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", created.id, "manifest.json"])

      {:ok, content} = File.read(manifest_path)
      {:ok, decoded} = Jason.decode(content)
      tampered = Map.put(decoded, "id", "tampered-chk-id")
      :ok = File.write(manifest_path, Jason.encode!(tampered))

      assert {:error, {:identity_mismatch, details}} =
               Store.load(checkpoint.session_id, created.id, base_dir: base_dir)

      assert details.requested_checkpoint_id == created.id
      assert details.loaded_checkpoint_id == "tampered-chk-id"
    end
  end

  describe "rollback/2" do
    test "restores file content from snapshot", %{workspace: workspace, base_dir: base_dir} do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)

      modified_content = "MODIFIED CONTENT"
      File.write!(Path.join([workspace, "lib", "example.ex"]), modified_content)

      assert {:ok, rolled_back} = Store.rollback(created, base_dir: base_dir)
      assert rolled_back.status == :rolled_back

      restored_content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      assert restored_content != modified_content
    end

    test "removes new files that did not exist before", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{affected_files: ["lib/brand_new.ex"]}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)

      new_file = Path.join([workspace, "lib", "brand_new.ex"])
      File.write!(new_file, "new content")
      assert File.exists?(new_file)

      {:ok, _rolled_back} = Store.rollback(created, base_dir: base_dir)
      refute File.exists?(new_file)
    end

    test "returns error on restore failure, not false success", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      snap_dir =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", active.id, "snapshots"])

      File.rm_rf!(Path.join(snap_dir, "lib"))

      result = Store.rollback(active, base_dir: base_dir)
      assert {:error, {:rollback_failed, _errors}} = result
    end

    test "marks checkpoint as :failed not :rolled_back on restore failure", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      snap_dir =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", active.id, "snapshots"])

      File.rm_rf!(Path.join(snap_dir, "lib"))

      {:error, {:rollback_failed, _}} = Store.rollback(active, base_dir: base_dir)

      {:ok, reloaded} =
        Store.load(checkpoint.session_id, active.id, base_dir: base_dir)

      assert reloaded.status == :failed
    end
  end

  describe "rollback/2 — path safety" do
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

    test "rejects snapshot_path that escapes checkpoints dir", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      {:ok, loaded} =
        Store.load(checkpoint.session_id, active.id, base_dir: base_dir)

      tampered_snapshots =
        Enum.map(loaded.file_snapshots, fn s ->
          %{s | snapshot_path: "../../etc/passwd"}
        end)

      tampered = %{loaded | file_snapshots: tampered_snapshots}
      {:ok, _} = Store.update_manifest(tampered, base_dir: base_dir)

      result = Store.rollback(tampered, base_dir: base_dir)

      assert {:error, {:rollback_failed, [{:snapshot_path_escape, "../../etc/passwd"}]}} = result
    end

    test "rejects secret path in restore", %{workspace: workspace, base_dir: base_dir} do
      checkpoint = make_checkpoint(%{affected_files: [".env"]}, workspace)

      result = Store.create(checkpoint, base_dir: base_dir)
      assert match?({:error, _}, result)
    end

    test "detects hash mismatch on restore", %{workspace: workspace, base_dir: base_dir} do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      snap_dir =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", active.id, "snapshots"])

      snap_file = Path.join([snap_dir, "lib", "example.ex"])
      File.write!(snap_file, "TAMPERED CONTENT")

      result = Store.rollback(active, base_dir: base_dir)
      assert {:error, {:rollback_failed, errors}} = result

      assert Enum.any?(errors, fn
               {:hash_mismatch, _, _, _} -> true
               _ -> false
             end)
    end

    test "rejects nil snapshot_path without crash", %{workspace: workspace, base_dir: base_dir} do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      {:ok, loaded} =
        Store.load(checkpoint.session_id, active.id, base_dir: base_dir)

      # Tamper: set snapshot_path to nil
      tampered_snapshots =
        Enum.map(loaded.file_snapshots, fn s -> %{s | snapshot_path: nil} end)

      tampered = %{loaded | file_snapshots: tampered_snapshots}
      {:ok, _} = Store.update_manifest(tampered, base_dir: base_dir)

      result = Store.rollback(tampered, base_dir: base_dir)
      assert {:error, {:rollback_failed, errors}} = result

      assert Enum.any?(errors, fn
               {:invalid_snapshot_path, _} -> true
               _ -> false
             end)
    end

    test "rejects snapshot file replaced by symlink", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      snap_dir =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", active.id, "snapshots"])

      snap_file = Path.join([snap_dir, "lib", "example.ex"])

      # Replace the snapshot file with a symlink
      File.rm!(snap_file)

      # :file.make_symlink may not work on all platforms; skip if unsupported
      try do
        :ok = :file.make_symlink("/etc/passwd", String.to_charlist(snap_file))

        result = Store.rollback(active, base_dir: base_dir)
        assert {:error, {:rollback_failed, errors}} = result

        assert Enum.any?(errors, fn
                 {:snapshot_symlink, _} -> true
                 _ -> false
               end)
      rescue
        # Skip on platforms that don't support symlinks
        _ -> :ok
      end
    end

    test "rejects existed=true with nil content_hash", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      {:ok, loaded} =
        Store.load(checkpoint.session_id, active.id, base_dir: base_dir)

      # Tamper: set content_hash to nil on existed=true snapshot
      tampered_snapshots =
        Enum.map(loaded.file_snapshots, fn s -> %{s | content_hash: nil} end)

      tampered = %{loaded | file_snapshots: tampered_snapshots}
      {:ok, _} = Store.update_manifest(tampered, base_dir: base_dir)

      result = Store.rollback(tampered, base_dir: base_dir)
      assert {:error, {:rollback_failed, errors}} = result

      assert Enum.any?(errors, fn
               {:invalid_snapshot_hash, _} -> true
               _ -> false
             end)
    end
  end

  describe "rollback/2 — symlink write-through safety" do
    test "blocks restore through symlink parent directory", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      # Create a symlink: workspace/lib/linked -> /tmp/some_dir
      link_path = Path.join([workspace, "lib", "linked"])
      target_dir = Path.join(base_dir, "symlink_target")
      File.mkdir_p!(target_dir)

      try do
        :ok = :file.make_symlink(String.to_charlist(target_dir), String.to_charlist(link_path))

        # Create file under the symlink path
        file_under = Path.join(link_path, "file.ex")
        File.write!(file_under, "content through symlink")

        checkpoint =
          make_checkpoint(%{affected_files: ["lib/linked/file.ex"]}, workspace)

        # Capture should reject symlink component in path
        result = Store.create(checkpoint, base_dir: base_dir)
        assert match?({:error, _}, result)
      rescue
        # Skip on platforms without symlink support
        _ -> :ok
      end
    end

    test "blocks delete through symlink target on rollback", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      # Create a file and checkpoint it normally
      checkpoint = make_checkpoint(%{affected_files: ["lib/brand_new.ex"]}, workspace)

      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      new_file = Path.join([workspace, "lib", "brand_new.ex"])
      File.write!(new_file, "new content")

      # Replace with a symlink
      File.rm!(new_file)

      try do
        :ok =
          :file.make_symlink(
            String.to_charlist(Path.join(base_dir, "outside")),
            String.to_charlist(new_file)
          )

        result = Store.rollback(active, base_dir: base_dir)
        # Should reject deleting through a symlink
        assert match?({:error, {:rollback_failed, _}}, result)
      rescue
        # Skip on platforms without symlink support
        _ -> :ok
      end
    end
  end

  describe "snapshot symlink component safety" do
    test "blocks capture write through symlink parent in snapshots dir", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)
      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      # Find the snapshots directory
      snap_dir =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", active.id, "snapshots"])

      # Replace snapshots/lib with a symlink pointing outside
      lib_dir = Path.join(snap_dir, "lib")
      File.rm_rf!(lib_dir)

      try do
        :ok =
          :file.make_symlink(
            String.to_charlist(Path.join(base_dir, "outside_target")),
            String.to_charlist(lib_dir)
          )

        # Attempt to read the snapshot file through the symlinked parent
        # should fail with symlink component error
        result = Store.rollback(active, base_dir: base_dir)

        assert {:error, {:rollback_failed, errors}} = result

        assert Enum.any?(errors, fn
                 {:snapshot_symlink_component, _} -> true
                 _ -> false
               end)
      rescue
        # Skip on platforms without symlink support
        _ -> :ok
      end
    end

    test "blocks restore read through symlink parent in snapshots dir", %{
      workspace: workspace,
      base_dir: base_dir
    } do
      checkpoint = make_checkpoint(%{}, workspace)
      {:ok, created} = Store.create(checkpoint, base_dir: base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: base_dir)

      # Modify file so rollback needs to restore
      File.write!(Path.join([workspace, "lib", "example.ex"]), "MODIFIED")

      # Replace snapshots/lib with a symlink after initial snapshot was created
      snap_dir =
        Path.join([base_dir, checkpoint.session_id, "checkpoints", active.id, "snapshots"])

      lib_dir = Path.join(snap_dir, "lib")
      # Save the original snapshot content
      original_snap = File.read!(Path.join([snap_dir, "lib", "example.ex"]))
      File.rm_rf!(lib_dir)

      try do
        # Create symlink to outside dir and put the snapshot content there
        outside = Path.join(base_dir, "outside_snap")
        File.mkdir_p!(Path.join(outside, "lib"))
        File.write!(Path.join([outside, "lib", "example.ex"]), original_snap)

        :ok =
          :file.make_symlink(String.to_charlist(outside), String.to_charlist(lib_dir))

        # Rollback should reject the symlink component in the snapshot path
        result = Store.rollback(active, base_dir: base_dir)

        assert {:error, {:rollback_failed, errors}} = result

        assert Enum.any?(errors, fn
                 {:snapshot_symlink_component, _} -> true
                 _ -> false
               end)
      rescue
        # Skip on platforms without symlink support
        _ -> :ok
      end
    end
  end
end
