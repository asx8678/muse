defmodule Muse.Tools.PatchProposeTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.PatchPropose

  @valid_diff """
  --- a/lib/hello.ex
  +++ b/lib/hello.ex
  @@ -1,3 +1,4 @@
   defmodule Hello do
  -  def world, do: :ok
  +  def world, do: :hello
  +  def greet, do: :hi
   end
  """

  @empty_diff ""

  @non_diff_text "This is just some random text without diff markers"

  @dangerous_diff """
  --- a/x.sh
  +++ b/x.sh
  @@ -1 +1 @@
  -echo hello
  +sudo rm -rf /
  """

  describe "execute/2" do
    test "returns success with valid unified diff" do
      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})
      assert result.success
      assert result.tool_name == "patch_propose"
      assert result.output.patch_id =~ "patch_"
      assert is_binary(result.output.hash)
      assert result.output.diff_size > 0
      assert result.output.approval_required == true
    end

    test "includes stable patch_id and hash in output" do
      result1 = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})
      result2 = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})

      assert result1.output.patch_id == result2.output.patch_id
      assert result1.output.hash == result2.output.hash
    end

    test "includes approval guidance message" do
      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})
      assert result.success
      assert result.output.message =~ "Patch proposal"
      assert result.output.message =~ "approve patch"
      assert result.output.message =~ "No files have been modified"
    end

    test "parses affected files from diff" do
      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})
      assert result.success
      assert "lib/hello.ex" in result.output.affected_files
    end

    test "accepts explicit affected_files" do
      result =
        PatchPropose.execute(
          %{"diff" => @valid_diff, "affected_files" => ["lib/hello.ex", "lib/world.ex"]},
          %{workspace: "/tmp"}
        )

      assert result.success
      assert result.output.affected_files == ["lib/hello.ex", "lib/world.ex"]
    end

    test "accepts explicit summary" do
      result =
        PatchPropose.execute(
          %{"diff" => @valid_diff, "summary" => "Add greet function to Hello module"},
          %{workspace: "/tmp"}
        )

      assert result.success
      assert result.output.summary == "Add greet function to Hello module"
    end

    test "auto-generates summary from diff header" do
      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})
      assert result.success
      assert is_binary(result.output.summary)
    end

    test "NEVER writes files or modifies workspace" do
      workspace =
        Path.join(System.tmp_dir!(), "muse_patch_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: workspace})
      assert result.success

      # Verify no files were created in workspace
      assert File.ls!(workspace) == []
      File.rm_rf!(workspace)
    end

    test "returns success with diff --git format header" do
      diff = """
      diff --git a/lib/app.ex b/lib/app.ex
      --- a/lib/app.ex
      +++ b/lib/app.ex
      @@ -1 +1 @@
      -:ok
      +:hello
      """

      result = PatchPropose.execute(%{"diff" => diff}, %{workspace: "/tmp"})
      assert result.success
      assert result.output.diff_size > 0
    end

    test "detects affected files from ---/+++ markers" do
      diff = """
      diff --git a/src/a.ex b/src/a.ex
      --- a/src/a.ex
      +++ b/src/a.ex
      @@ -1 +1 @@
      -old
      +new
      """

      result = PatchPropose.execute(%{"diff" => diff}, %{workspace: "/tmp"})
      assert result.success
      assert "src/a.ex" in result.output.affected_files
    end

    test "rejects multi-file diff with all files parsed" do
      diff = """
      --- a/a.ex
      +++ b/a.ex
      @@ -1 +1 @@
      -a
      +b
      --- a/b.ex
      +++ b/b.ex
      @@ -1 +1 @@
      -x
      +y
      """

      result = PatchPropose.execute(%{"diff" => diff}, %{workspace: "/tmp"})
      assert result.success
      assert "a.ex" in result.output.affected_files
      assert "b.ex" in result.output.affected_files
    end
  end

  describe "execute/2 — validation" do
    test "rejects empty diff" do
      result = PatchPropose.execute(%{"diff" => @empty_diff}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "empty"
    end

    test "rejects non-diff text" do
      result = PatchPropose.execute(%{"diff" => @non_diff_text}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "does not appear to be a valid unified diff"
    end

    test "rejects missing diff key" do
      result = PatchPropose.execute(%{}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "empty"
    end

    test "rejects dangerous patterns in diff" do
      result = PatchPropose.execute(%{"diff" => @dangerous_diff}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "dangerous"
    end

    test "rejects non-string diff" do
      result = PatchPropose.execute(%{"diff" => 123}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "must be a string"
    end

    test "rejects excessively large diff" do
      large_diff = "--- a/x\n+++ b/x\n" <> String.duplicate("+line\n", 200_000)
      result = PatchPropose.execute(%{"diff" => large_diff}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "exceeds maximum size"
    end
  end

  describe "execute/2 — context independence" do
    test "workspace context is accepted but not used for writes" do
      result =
        PatchPropose.execute(%{"diff" => @valid_diff}, %{
          workspace: "/tmp",
          session_id: "sess_1",
          turn_id: "turn_1"
        })

      assert result.success
    end

    test "result contains no file path or write instructions" do
      result = PatchPropose.execute(%{"diff" => @valid_diff}, %{workspace: "/tmp"})
      refute Map.has_key?(result.output, :path)
      refute Map.has_key?(result.output, :written)
      refute result.output.message =~ ~r/files? (written|modified|created|changed)/i
    end
  end
end
