defmodule Muse.Tools.RollbackCheckpointTest do
  use ExUnit.Case, async: false

  alias Muse.{Checkpoint, Checkpoint.Store}
  alias Muse.Tools.RollbackCheckpoint

  @plan_hash String.duplicate("f", 64)

  defp approved_context(overrides \\ %{}) do
    Map.merge(
      %{
        workspace: "/tmp",
        session_id: "s1",
        muse_id: :coding,
        plan_id: "plan-1",
        plan_version: 1,
        plan_hash: @plan_hash,
        plan_status: :approved
      },
      overrides
    )
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

    session_id = "rb-test-#{:erlang.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(Path.join(".muse/sessions", session_id))
    end)

    %{workspace: workspace, session_id: session_id}
  end

  defp make_checkpoint(overrides, workspace, session_id) do
    defaults = %{
      session_id: session_id,
      plan_id: "plan-1",
      plan_hash: @plan_hash,
      patch_id: "patch-1",
      patch_hash: String.duplicate("a", 64),
      workspace: workspace,
      affected_files: ["lib/example.ex"],
      metadata: %{diff: "test"}
    }

    Checkpoint.new(Map.merge(defaults, overrides))
  end

  describe "execute/2 — authorization" do
    test "requires Coding Muse context" do
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => "chk_1"},
          approved_context(%{muse_id: :planning})
        )

      refute result.success
      assert result.error =~ "Coding Muse"
    end

    test "requires approved plan" do
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => "chk_1"},
          approved_context(%{plan_status: nil})
        )

      refute result.success
      assert result.error =~ "approved plan"
    end

    test "requires plan_hash in context" do
      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => "chk_1"},
          approved_context(%{plan_hash: nil})
        )

      refute result.success
      assert result.error =~ "plan_hash"
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

  describe "execute/2 — ownership and plan binding" do
    test "rejects cross-session rollback", %{workspace: workspace, session_id: session_id} do
      checkpoint = make_checkpoint(%{}, workspace, session_id)

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: "different-session",
            workspace: workspace
          })
        )

      refute result.success
      assert result.error =~ "session" or result.error =~ "belongs to"
    end

    test "rejects mismatched context plan_hash", %{
      workspace: workspace,
      session_id: session_id
    } do
      checkpoint = make_checkpoint(%{}, workspace, session_id)

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      wrong_hash = String.duplicate("e", 64)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: session_id,
            workspace: workspace,
            plan_hash: wrong_hash
          })
        )

      refute result.success
      assert result.error =~ "plan_hash"
    end

    test "rejects checkpoint with missing plan_hash", %{
      workspace: workspace,
      session_id: session_id
    } do
      checkpoint = make_checkpoint(%{plan_hash: nil}, workspace, session_id)

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: session_id,
            workspace: workspace
          })
        )

      refute result.success
      assert result.error =~ "plan_hash"
    end

    test "rejects checkpoint with tampered (empty string) plan_hash", %{
      workspace: workspace,
      session_id: session_id
    } do
      checkpoint = make_checkpoint(%{plan_hash: ""}, workspace, session_id)

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: session_id,
            workspace: workspace
          })
        )

      refute result.success
      assert result.error =~ "plan_hash"
    end
  end

  describe "execute/2 — successful rollback" do
    test "restores workspace to pre-apply state from the scoped store", %{
      workspace: workspace,
      session_id: session_id
    } do
      checkpoint = make_checkpoint(%{}, workspace, session_id)
      store_base_dir = Path.join(workspace, ".muse/sessions")

      {:ok, created} = Store.create(checkpoint, base_dir: store_base_dir)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active, base_dir: store_base_dir)

      original_content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      File.write!(Path.join([workspace, "lib", "example.ex"]), "MODIFIED CONTENT")

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: session_id,
            workspace: workspace,
            plan_id: "plan-1",
            plan_hash: @plan_hash,
            store_base_dir: store_base_dir
          })
        )

      assert result.success
      assert result.output.checkpoint_id == created.id
      assert result.output.status == :rolled_back

      restored = File.read!(Path.join([workspace, "lib", "example.ex"]))
      assert restored == original_content

      # Verify rollback audit record persisted in the scoped store, not the default store.
      {:ok, patches, _} = Muse.SessionStore.load_patches(store_base_dir, session_id)

      assert Enum.any?(patches, fn p ->
               p["event"] == "rollback_completed" or p[:event] == :rollback_completed
             end)
    end

    test "removes new files created by patch", %{
      workspace: workspace,
      session_id: session_id
    } do
      checkpoint = make_checkpoint(%{affected_files: ["lib/brand_new.ex"]}, workspace, session_id)

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      new_file = Path.join([workspace, "lib", "brand_new.ex"])
      File.write!(new_file, "new content")
      assert File.exists?(new_file)

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: session_id,
            workspace: workspace,
            plan_id: "plan-1",
            plan_hash: @plan_hash
          })
        )

      assert result.success
      refute File.exists?(new_file)
    end
  end

  describe "execute/2 — failure cases" do
    test "rollback with missing snapshot returns error not success", %{
      workspace: workspace,
      session_id: session_id
    } do
      checkpoint = make_checkpoint(%{}, workspace, session_id)

      {:ok, created} = Store.create(checkpoint)
      {:ok, active} = Checkpoint.transition(created, :active)
      {:ok, _} = Store.update_manifest(active)

      snapshot_dir =
        Path.join([".muse/sessions", session_id, "checkpoints", active.id, "snapshots"])

      File.rm_rf!(Path.join(snapshot_dir, "lib"))

      result =
        RollbackCheckpoint.execute(
          %{"checkpoint_id" => created.id},
          approved_context(%{
            session_id: session_id,
            workspace: workspace,
            plan_id: "plan-1",
            plan_hash: @plan_hash
          })
        )

      refute result.success
      assert result.error =~ "rollback" or result.error =~ "failed"
    end
  end
end
