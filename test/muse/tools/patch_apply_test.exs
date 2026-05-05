defmodule Muse.Tools.PatchApplyTest do
  use ExUnit.Case, async: false

  alias Muse.{Approval, Patch}
  alias Muse.Tools.PatchApply

  @valid_diff """
  --- a/lib/example.ex
  +++ b/lib/example.ex
  @@ -1,3 +1,4 @@
   defmodule Example do
  +  @moduledoc \"Example module\"
     def hello, do: :world
   end
  """

  @delete_diff """
  --- a/lib/to_delete.ex
  +++ /dev/null
  @@ -1,3 +0,0 @@
  -defmodule ToDelete do
  -  def gone, do: true
  -end
  """

  setup do
    workspace = Path.join(System.tmp_dir!(), "muse_pa_#{System.unique_integer([:positive])}")
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

  describe "execute/2 — authorization" do
    test "rejects without patch_id or patch_hash" do
      result = PatchApply.execute(%{}, %{workspace: "/tmp", muse_id: :coding})
      refute result.success
      assert result.error =~ "patch_id or patch_hash is required"
    end

    test "rejects when no approved patch is found" do
      result =
        PatchApply.execute(
          %{"patch_id" => "patch_nonexistent"},
          %{workspace: "/tmp", session_id: "s1", muse_id: :coding}
        )

      refute result.success
      assert result.error =~ "no approved patch"
    end

    test "rejects when no matching approval exists" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s_auth_1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: String.duplicate("a", 64),
          diff: @valid_diff,
          status: :approved
        })

      result =
        PatchApply.execute(
          %{"patch_id" => patch.id},
          %{
            workspace: "/tmp",
            session_id: "s_auth_1",
            muse_id: :coding,
            approvals: [],
            pending_patch: patch
          }
        )

      refute result.success
      assert result.error =~ "no matching approved patch approval"
    end
  end

  describe "execute/2 — delete rejection" do
    test "rejects patches containing file deletion diffs" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s_del_1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: String.duplicate("b", 64),
          diff: @delete_diff,
          status: :approved
        })

      approval =
        Approval.new(%{
          kind: :patch,
          status: :approved,
          session_id: "s_del_1",
          patch_id: patch.id,
          patch_hash: patch.hash
        })

      result =
        PatchApply.execute(
          %{"patch_id" => patch.id},
          %{
            workspace: "/tmp",
            session_id: "s_del_1",
            muse_id: :coding,
            approvals: [approval],
            pending_patch: patch
          }
        )

      refute result.success
      assert result.error =~ "deletion" or result.error =~ "delete"
    end
  end

  describe "execute/2 — successful apply" do
    test "creates checkpoint, applies patch, and returns diff preview", %{workspace: workspace} do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s_apply_1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: String.duplicate("c", 64),
          diff: @valid_diff,
          status: :approved
        })

      approval =
        Approval.new(%{
          kind: :patch,
          status: :approved,
          session_id: "s_apply_1",
          patch_id: patch.id,
          patch_hash: patch.hash
        })

      :ok = Muse.SessionStore.append_patch("s_apply_1", Patch.to_map(patch))

      result =
        PatchApply.execute(
          %{"patch_id" => patch.id},
          %{
            workspace: workspace,
            session_id: "s_apply_1",
            muse_id: :coding,
            approvals: [approval],
            pending_patch: patch
          }
        )

      assert result.success
      assert is_binary(result.output.checkpoint_id)
      assert String.starts_with?(result.output.checkpoint_id, "chk_")
      assert result.output.patch_id == patch.id
      assert result.output.affected_files == ["lib/example.ex"]
      assert result.output.status == :applied

      # Verify the file was actually modified
      content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      assert content =~ "@moduledoc"

      # Verify git diff is present
      assert is_binary(result.output.git_diff_preview)
    end
  end
end
