defmodule Muse.Tools.PatchApplyTest do
  use ExUnit.Case, async: false

  alias Muse.{Approval, Patch}
  alias Muse.Tools.PatchApply

  @valid_diff """
  --- a/lib/example.ex
  +++ b/lib/example.ex
  @@ -1,3 +1,4 @@
   defmodule Example do
  +  @moduledoc "Example module"
     def hello, do: :world
   end
  """

  @new_file_diff """
  --- /dev/null
  +++ b/lib/new_file.ex
  @@ -0,0 +1,3 @@
  +defmodule NewFile do
  +  def new, do: true
  +end
  """

  @delete_diff """
  --- a/lib/to_delete.ex
  +++ /dev/null
  @@ -1,3 +0,0 @@
  -defmodule ToDelete do
  -  def gone, do: true
  -end
  """

  # Diff with "/dev/null" in hunk content (not a deletion) — must NOT be rejected
  @dev_null_in_content_diff """
  --- a/lib/example.ex
  +++ b/lib/example.ex
  @@ -1,3 +1,4 @@
   defmodule Example do
  +  # See /dev/null for details
     def hello, do: :world
   end
  """

  @plan_hash String.duplicate("f", 64)

  setup do
    workspace = Path.join(System.tmp_dir!(), "muse_pa_#{System.unique_integer([:positive])}")
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

  defp approved_context(overrides \\ %{}) do
    Map.merge(
      %{
        workspace: "/tmp",
        session_id: "s1",
        muse_id: :coding,
        plan_id: "plan-1",
        plan_version: 1,
        plan_hash: @plan_hash,
        plan_status: :approved,
        approvals: []
      },
      overrides
    )
  end

  describe "execute/2 — authorization" do
    test "rejects without patch_id or patch_hash" do
      result = PatchApply.execute(%{}, approved_context())
      refute result.success
      assert result.error =~ "patch_id or patch_hash is required"
    end

    test "rejects when no approved patch is found" do
      result =
        PatchApply.execute(
          %{"patch_id" => "patch_nonexistent"},
          approved_context()
        )

      refute result.success
      assert result.error =~ "no approved patch"
    end

    test "rejects without Coding Muse context" do
      ctx = approved_context(%{muse_id: :planning})
      result = PatchApply.execute(%{"patch_id" => "p1"}, ctx)
      refute result.success
      assert result.error =~ "Coding Muse"
    end

    test "rejects without approved plan" do
      ctx = approved_context(%{plan_status: nil})
      result = PatchApply.execute(%{"patch_id" => "p1"}, ctx)
      refute result.success
      assert result.error =~ "approved plan"
    end

    test "rejects when plan not approved" do
      ctx = approved_context(%{plan_status: :proposed})
      result = PatchApply.execute(%{"patch_id" => "p1"}, ctx)
      refute result.success
      assert result.error =~ "approved plan"
    end

    test "rejects when no matching approval exists" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      ctx =
        approved_context(%{approvals: []})
        |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "no matching approved patch approval"
    end

    test "rejects mismatched plan_id in approval" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      approval =
        Approval.new(%{
          kind: :patch,
          status: :approved,
          session_id: "s1",
          patch_id: patch.id,
          patch_hash: patch.hash,
          plan_id: "wrong-plan"
        })

      ctx =
        approved_context(%{approvals: [approval]})
        |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "no matching approved patch approval"
    end
  end

  describe "execute/2 — delete/new-file policy (structural)" do
    test "structural detection: delete diffs have new_path == nil and old_path != nil" do
      {:ok, entries} = Muse.Patch.DiffParser.parse(@delete_diff)
      has_deletion = Enum.any?(entries, fn e -> e.new_path == nil and e.old_path != nil end)
      assert has_deletion
    end

    test "structural detection: new-file diffs are NOT deletions" do
      {:ok, entries} = Muse.Patch.DiffParser.parse(@new_file_diff)
      has_deletion = Enum.any?(entries, fn e -> e.new_path == nil and e.old_path != nil end)
      refute has_deletion
    end

    test "structural detection: /dev/null in hunk content is NOT a deletion" do
      {:ok, entries} = Muse.Patch.DiffParser.parse(@dev_null_in_content_diff)
      has_deletion = Enum.any?(entries, fn e -> e.new_path == nil and e.old_path != nil end)
      refute has_deletion
    end

    test "rejects patches containing file deletion diffs" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @delete_diff,
          status: :approved
        })

      approval =
        Approval.new(%{
          kind: :patch,
          status: :approved,
          session_id: "s1",
          patch_id: patch.id,
          patch_hash: patch.hash,
          plan_id: "plan-1"
        })

      ctx =
        approved_context(%{approvals: [approval]})
        |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "deletion" or result.error =~ "delete"
    end
  end

  describe "execute/2 — successful apply" do
    test "creates checkpoint, applies patch, and returns diff preview", %{workspace: workspace} do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s_apply_1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      approval =
        Approval.new(%{
          kind: :patch,
          status: :approved,
          session_id: "s_apply_1",
          patch_id: patch.id,
          patch_hash: patch.hash,
          plan_id: "plan-1"
        })

      :ok = Muse.SessionStore.append_patch("s_apply_1", Patch.to_map(patch))

      ctx =
        approved_context(%{
          session_id: "s_apply_1",
          workspace: workspace,
          approvals: [approval]
        })
        |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)

      assert result.success
      assert is_binary(result.output.checkpoint_id)
      assert String.starts_with?(result.output.checkpoint_id, "chk_")
      assert result.output.patch_id == patch.id
      assert result.output.affected_files == ["lib/example.ex"]
      assert result.output.status == :applied

      content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      assert content =~ "@moduledoc"

      assert is_binary(result.output.git_diff_preview)
    end
  end
end
