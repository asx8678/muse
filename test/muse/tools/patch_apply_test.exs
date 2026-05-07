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
    base_dir =
      Path.join(System.tmp_dir!(), "muse_pa_#{System.unique_integer([:positive])}")

    workspace = Path.join(base_dir, "workspace")
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

    # Unique session id per test for targeted cleanup
    session_id = "pa-test-#{:erlang.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      File.rm_rf!(base_dir)
      File.rm_rf!(Path.join(".muse/sessions", session_id))
    end)

    %{workspace: workspace, base_dir: base_dir, session_id: session_id}
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

  defp make_approval(patch, overrides \\ %{}) do
    defaults = %{
      kind: :patch,
      status: :approved,
      session_id: "s1",
      patch_id: patch.id,
      patch_hash: patch.hash,
      plan_id: "plan-1",
      plan_hash: @plan_hash
    }

    Approval.new(Map.merge(defaults, overrides))
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

      approval = make_approval(patch, %{plan_id: "wrong-plan"})
      ctx = approved_context(%{approvals: [approval]}) |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "no matching approved patch approval"
    end

    test "rejects approval with missing plan_hash" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      approval = make_approval(patch, %{plan_hash: nil})
      ctx = approved_context(%{approvals: [approval]}) |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "no matching approved patch approval"
    end

    test "rejects approval with mismatched plan_hash" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      wrong_hash = String.duplicate("e", 64)
      approval = make_approval(patch, %{plan_hash: wrong_hash})
      ctx = approved_context(%{approvals: [approval]}) |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "no matching approved patch approval"
    end

    test "rejects when context plan_hash is missing" do
      {:ok, patch} =
        Patch.new(%{
          session_id: "s1",
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      approval = make_approval(patch)

      ctx =
        approved_context(%{plan_hash: nil, approvals: [approval]})
        |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "plan_hash"
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

      approval = make_approval(patch)
      ctx = approved_context(%{approvals: [approval]}) |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)
      refute result.success
      assert result.error =~ "deletion" or result.error =~ "delete"
    end
  end

  # Diff with mismatched context lines — passes structural validation but
  # git apply --check rejects it because context doesn't match the file.
  @mismatched_context_diff """
  --- a/lib/example.ex
  +++ b/lib/example.ex
  @@ -1,3 +1,4 @@
   defmodule Example do
  +  @moduledoc "Example module"
     def goodbye, do: :universe
   end
  """

  describe "execute/2 — git apply check failure (regression muse-1ki.4.6)" do
    test "git apply --check failure does not mark patch as applied", %{
      workspace: workspace,
      base_dir: base_dir,
      session_id: session_id
    } do
      {:ok, patch} =
        Patch.new(%{
          session_id: session_id,
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @mismatched_context_diff,
          status: :approved
        })

      approval = make_approval(patch, %{session_id: session_id})

      store_base_dir = Path.join(base_dir, "workspace-sessions")
      :ok = Muse.SessionStore.append_patch(store_base_dir, session_id, Patch.to_map(patch))

      ctx =
        approved_context(%{
          session_id: session_id,
          workspace: workspace,
          approvals: [approval],
          store_base_dir: store_base_dir
        })
        |> Map.put(:pending_patch, patch)

      result = PatchApply.execute(%{"patch_id" => patch.id}, ctx)

      # The patch must NOT be marked as applied
      refute result.success
      assert result.error =~ "apply --check failed"

      # Verify the file was NOT modified
      content = File.read!(Path.join([workspace, "lib", "example.ex"]))
      refute content =~ "@moduledoc"
      assert content =~ "def hello"
    end
  end

  describe "execute/2 — successful apply" do
    test "creates checkpoint, applies patch, and returns diff preview in the scoped store", %{
      workspace: workspace,
      base_dir: base_dir,
      session_id: session_id
    } do
      {:ok, patch} =
        Patch.new(%{
          session_id: session_id,
          plan_id: "plan-1",
          plan_version: 1,
          plan_hash: @plan_hash,
          diff: @valid_diff,
          status: :approved
        })

      approval = make_approval(patch, %{session_id: session_id})

      store_base_dir = Path.join(base_dir, "workspace-sessions")
      :ok = Muse.SessionStore.append_patch(store_base_dir, session_id, Patch.to_map(patch))

      ctx =
        approved_context(%{
          session_id: session_id,
          workspace: workspace,
          approvals: [approval],
          store_base_dir: store_base_dir
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

      # Verify audit record persisted in the scoped store, not the default store.
      {:ok, patches, _} = Muse.SessionStore.load_patches(store_base_dir, session_id)

      assert Enum.any?(patches, fn p ->
               p["event"] == "patch_applied" or p[:event] == :patch_applied
             end)
    end
  end
end
