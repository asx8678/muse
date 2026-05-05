defmodule Muse.Tools.RollbackCheckpointTest do
  use ExUnit.Case, async: false

  alias Muse.{Checkpoint, Checkpoint.Store}
  alias Muse.Tools.RollbackCheckpoint

  @plan_hash String.duplicate("f", 64)

  defp approved_context(overrides \\ %{}) do
    %{
      workspace: overrides[:workspace] || "/tmp",
      session_id: overrides[:session_id] || "s1",
      muse_id: :coding,
      plan_id: overrides[:plan_id] || "plan-1",
      plan_version: 1,
      plan_hash: overrides[:plan_hash] || @plan_hash,
      plan_status: :approved
    }
  end

  setup do
    workspace = Path.join(System.tmp_dir!(), "muse_rb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(Path.join([workspace, "lib", "example.ex"]), """
    defmodule Example do
      def hello, do: :world
    end
    """)

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

  describe "execute/2 — authorization" do
    test "requires Coding Muse context" do
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => "chk_1"},
          %{approved_context() | muse_id: :planning}
        )

      refute result.success
      assert result.error =~ "Coding Muse"
    end

    test "requires approved plan" do
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => "chk_1"},
          %{approved_context() | plan_status: nil}
        )

      refute result.success
      assert result.error =~ "approved plan"
    end
  end

  describe "execute/2 — input validation" do
    test "requires checkpoint_id" do
      result = RollbackCheckpoint.execute(%{}, approved_context())
      refute result.success
      assert result.error =~ "checkpoint_id is required"
    end

    test "rejects empty checkpoint_id" do
      result = RollbackCheckpoint.execute(%{"checkpoint_id" => ""}, approved_context())
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
          plan_hash: @plan_hash,
          patch_id: "patch-1",
          patch_hash: String.duplicate("a", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(session_id: "different-session", workspace: workspace)
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
          plan_hash: @plan_hash,
          patch_id: "patch-1",
          patch_hash: String.duplicate("b", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      original_content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      File.write!(Path.join([workspace, "lib", "example.ex"]), "MODIFIED CONTENT")

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(
            session_id: "rb-ok-test",
            workspace: workspace,
            plan_id: "plan-1",
            plan_hash: @plan_hash
          )
        )

      assert result.success
      assert result.output.checkpoint_id == created.id
      assert result.output.status == :rolled_back

      restored = File.read!(Path.join([workspace, "lib", "example.ex"]))
      assert restored == original_content
    end

    test "removes new files created by patch", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "rb-new-test",
          plan_id: "plan-1",
          plan_hash: @plan_hash,
          patch_id: "patch-1",
          patch_hash: String.duplicate("c", 64),
          workspace: workspace,
          affected_files: ["lib/brand_new.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      new_file = Path.join([workspace, "lib", "brand_new.ex"])
      File.write!(new_file, "new content")
      assert File.exists?(new_file)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(
            session_id: "rb-new-test",
            workspace: workspace,
            plan_id: "plan-1",
            plan_hash: @plan_hash
          )
        )

      assert result.success
      refute File.exists?(new_file)
    end
  end

  describe "execute/2 — failure cases" do
    test "rollback with missing snapshot returns error not success", %{workspace: workspace} do
      checkpoint =
        Checkpoint.new(%{
          session_id: "rb-missing-test",
          plan_id: "plan-1",
          plan_hash: @plan_hash,
          patch_id: "patch-1",
          patch_hash: String.duplicate("d", 64),
          workspace: workspace,
          affected_files: ["lib/example.ex"],
          metadata: %{diff: "test"}
        })

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      # Delete the snapshot file to simulate corruption
      snapshot_dir =
        Path.join([".muse/sessions", "rb-missing-test", "checkpoints", active.id, "snapshots"])

      File.rm_rf!(Path.join(snapshot_dir, "lib"))

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(
            session_id: "rb-missing-test",
            workspace: workspace,
            plan_id: "plan-1",
            plan_hash: @plan_hash
          )
        )

      refute result.success
      assert result.error =~ "rollback" or result.error =~ "failed"
    end
  end
end
