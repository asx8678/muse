defmodule Muse.Tools.PatchProposeTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.PatchPropose
  alias Muse.Tool.Result

  @valid_diff """
  --- a/lib/example.ex
  +++ b/lib/example.ex
  @@ -1,3 +1,4 @@
   defmodule Example do
  +  @moduledoc "Example module"
     def hello, do: :world
   end
  """

  @binary_patch_diff """
  diff --git a/lib/example.ex b/lib/example.ex
  GIT binary patch
  literal 100
  zcmeow
  """

  @diff_with_traversal """
  --- a/../../etc/passwd
  +++ b/../../etc/passwd
  @@ -1,1 +1,1 @@
  -root:x:0:0
  +root:x:0:0:hacked
  """

  setup do
    root = Path.join(System.tmp_dir!(), "muse_pp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "lib/example.ex"), """
    defmodule Example do
      def hello, do: :world
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    %{workspace: root}
  end

  describe "execute/2 — valid proposals" do
    test "returns successful proposal metadata with hash, affected_files, and approval guidance",
         %{workspace: ws} do
      context = %{
        workspace: ws,
        session_id: "sess-1",
        plan_id: "plan-1",
        plan_version: 1,
        plan_hash: String.duplicate("a", 64)
      }

      result =
        PatchPropose.execute(
          %{"diff" => @valid_diff, "affected_files" => ["lib/example.ex"]},
          context
        )

      assert result.success
      assert result.tool_name == "patch_propose"
      assert is_struct(result, Result)

      output = result.output
      assert is_binary(output.patch_id)
      assert String.starts_with?(output.patch_id, "patch_")
      assert is_binary(output.hash)
      assert byte_size(output.hash) == 64
      assert output.diff_size == byte_size(@valid_diff)
      assert output.affected_files == ["lib/example.ex"]
      assert is_binary(output.summary)
      assert output.approval_required == true
      assert is_binary(output.message)
      assert output.message =~ "approve patch"
      assert output.message =~ "No files have been modified"
    end

    test "auto-discovers affected_files from diff when not provided",
         %{workspace: ws} do
      context = %{
        workspace: ws,
        session_id: "sess-2",
        plan_id: "plan-2",
        plan_version: 1,
        plan_hash: String.duplicate("b", 64)
      }

      result = PatchPropose.execute(%{"diff" => @valid_diff}, context)

      assert result.success
      assert result.output.affected_files == ["lib/example.ex"]
    end

    test "uses provided summary over auto-generated one",
         %{workspace: ws} do
      context = %{
        workspace: ws,
        session_id: "sess-3",
        plan_id: "plan-3",
        plan_version: 1,
        plan_hash: String.duplicate("c", 64)
      }

      result =
        PatchPropose.execute(%{"diff" => @valid_diff, "summary" => "My custom summary"}, context)

      assert result.success
      assert result.output.summary == "My custom summary"
    end

    test "includes plan context in metadata", %{workspace: ws} do
      context = %{
        workspace: ws,
        session_id: "sess-4",
        plan_id: "plan-42",
        plan_version: 2,
        plan_hash: String.duplicate("d", 64)
      }

      result = PatchPropose.execute(%{"diff" => @valid_diff}, context)

      assert result.success
      assert result.metadata.patch_proposal.plan_id == "plan-42"
      assert result.metadata.patch_proposal.plan_version == 2
      assert result.metadata.patch_proposal.plan_hash == String.duplicate("d", 64)
    end
  end

  describe "execute/2 — input validation" do
    test "rejects missing diff", %{workspace: ws} do
      result = PatchPropose.execute(%{}, %{workspace: ws})
      assert result.success == false
      assert result.error =~ "required"
    end

    test "rejects empty diff string", %{workspace: ws} do
      result = PatchPropose.execute(%{"diff" => ""}, %{workspace: ws})
      assert result.success == false
      assert result.error =~ "empty"
    end

    test "rejects non-string diff", %{workspace: ws} do
      result = PatchPropose.execute(%{"diff" => 123}, %{workspace: ws})
      assert result.success == false
      assert result.error =~ "must be a string"
    end

    test "rejects binary patch via Validator", %{workspace: ws} do
      result = PatchPropose.execute(%{"diff" => @binary_patch_diff}, %{workspace: ws})
      assert result.success == false
      assert result.error =~ "binary patch" or result.error =~ "not allowed"
    end

    test "rejects diff with unsafe path traversal", %{workspace: ws} do
      result = PatchPropose.execute(%{"diff" => @diff_with_traversal}, %{workspace: ws})
      assert result.success == false
      assert result.error =~ "unsafe" or result.error =~ "traversal"
    end
  end

  describe "execute/2 — workspace safety" do
    test "does not modify any workspace files", %{workspace: ws} do
      original = File.read!(Path.join(ws, "lib/example.ex"))

      context = %{
        workspace: ws,
        session_id: "sess-5",
        plan_id: "plan-5",
        plan_version: 1,
        plan_hash: String.duplicate("e", 64)
      }

      result = PatchPropose.execute(%{"diff" => @valid_diff}, context)
      assert result.success

      # File content must be unchanged
      after_read = File.read!(Path.join(ws, "lib/example.ex"))
      assert after_read == original

      # No new files created by the proposal
      refute File.exists?(Path.join(ws, "lib/example_new.ex"))
    end

    test "does not create any files in workspace at all", %{workspace: ws} do
      before_set =
        MapSet.new(for f <- Path.wildcard(Path.join(ws, "**/*")), do: Path.relative_to(f, ws))

      context = %{
        workspace: ws,
        session_id: "sess-6",
        plan_id: "plan-6",
        plan_version: 1,
        plan_hash: String.duplicate("f", 64)
      }

      result = PatchPropose.execute(%{"diff" => @valid_diff}, context)
      assert result.success

      after_set =
        MapSet.new(for f <- Path.wildcard(Path.join(ws, "**/*")), do: Path.relative_to(f, ws))

      assert after_set == before_set
    end
  end

  describe "execute/2 — output safety" do
    test "output does not contain raw diff key", %{workspace: ws} do
      context = %{
        workspace: ws,
        session_id: "sess-7",
        plan_id: "plan-7",
        plan_version: 1,
        plan_hash: String.duplicate("g", 64)
      }

      result = PatchPropose.execute(%{"diff" => @valid_diff}, context)
      assert result.success

      # Public output must only expose structured metadata, never the raw diff
      refute Map.has_key?(result.output, :diff)

      # Only these keys belong in the public output
      assert Map.has_key?(result.output, :patch_id)
      assert Map.has_key?(result.output, :hash)
      assert Map.has_key?(result.output, :diff_size)
      assert Map.has_key?(result.output, :affected_files)
      assert Map.has_key?(result.output, :summary)
      assert Map.has_key?(result.output, :approval_required)
      assert Map.has_key?(result.output, :message)

      # The raw diff is stored in metadata.patch_proposal, not in output
      assert result.metadata.patch_proposal.diff == @valid_diff
    end
  end

  describe "execute/2 — no workspace" do
    test "falls back to basic text validation when workspace is missing" do
      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{})
      # Without workspace, the diff is validated as text only — valid text diffs pass
      assert is_struct(result, Result)
      assert result.success
      assert is_binary(result.output.patch_id)
    end
  end
end
