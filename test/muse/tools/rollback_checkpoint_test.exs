defmodule Muse.Tools.RollbackCheckpointTest do
  use ExUnit.Case, async: false

  alias Muse.{Checkpoint, Checkpoint.Store}
  alias Muse.Tools.RollbackCheckpoint

  setup do
    workspace = Path.join(System.tmp_dir!(), "muse_rb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(Path.join([workspace, "lib", "example.ex"]), """
    defmodule Example do
      def hello, do: :world
    end
    """)

    # Initialize git repo
    System.cmd("git", ["init"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@muse.dev"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(".muse/sessions")
    end)

    %{workspace: workspace}
  end

  describe "execute/2 — input validation" do
    test "requires checkpoint_id" do
      result = RollbackCheckpoint.execute(%{}, %{workspace: "/tmp", session_id: "s1"})
      refute result.success
      assert result.error =~ "checkpoint_id is required"
    end

    test "rejects empty checkpoint_id" do
      result =
        RollbackCheckpoint.execute(%{"checkpoint_id" => ""}, %{
          workspace: "/tmp",
          session_id: "s1"
        })

      refute result.success
      assert result.error =~ "checkpoint_id is required"
    end
  end

  describe "execute/2 — ownership verification" do
    test "rejects cross-session rollback", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "rb-cross-test",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("a", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      :ok = Store.update_manifest(active)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          %{workspace: workspace, session_id: "different-session"}
        )

      refute result.success
      assert result.error =~ "session" or result.error =~ "belongs to"
    end
  end

  describe "execute/2 — successful rollback" do
    test "restores workspace to pre-apply state", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "rb-ok-test",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("b", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      :ok = Store.update_manifest(active)

      # Modify the file (simulating patch apply)
      original_content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      File.write!(Path.join([workspace, "lib", "example.ex"]), "MODIFIED CONTENT")

      # Rollback
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          %{workspace: workspace, session_id: "rb-ok-test", muse_id: :coding}
        )

      assert result.success
      assert result.output.checkpoint_id == created.id
      assert result.output.status == :rolled_back

      # File should be restored to original
      restored = File.read!(Path.join([workspace, "lib", "example.ex"]))
      assert restored == original_content
    end

    test "removes new files created by patch", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "rb-new-test",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("c", 64),
          workspace: workspace,
          affected_files: ["lib/brand_new.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      :ok = Store.update_manifest(active)

      # Create the new file (simulating patch apply)
      new_file = Path.join([workspace, "lib", "brand_new.ex"])
      File.write!(new_file, "new content")
      assert File.exists?(new_file)

      # Rollback
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          %{workspace: workspace, session_id: "rb-new-test", muse_id: :coding}
        )

      assert result.success
      refute File.exists?(new_file)
    end
  end
end
