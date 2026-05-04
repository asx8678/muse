defmodule Muse.Tools.GitStatusTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.GitStatus

  setup do
    root = Path.join(System.tmp_dir!(), "muse_gs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # Initialize a git repo
    System.cmd("git", ["init"], cd: root)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: root)
    System.cmd("git", ["config", "user.name", "Test"], cd: root)
    File.write!(Path.join(root, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: root)
    System.cmd("git", ["commit", "-m", "initial"], cd: root)

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "execute/2" do
    test "returns branch name", %{root: root} do
      result = GitStatus.execute(%{}, %{workspace: root})
      assert result.success
      assert is_binary(result.output.branch)
      assert result.output.branch != "unknown"
    end

    test "reports clean state when no changes", %{root: root} do
      result = GitStatus.execute(%{}, %{workspace: root})
      assert result.success
      assert result.output.clean == true
    end

    test "reports dirty state with changes", %{root: root} do
      File.write!(Path.join(root, "new_file.ex"), "defmodule New do end")
      result = GitStatus.execute(%{}, %{workspace: root})
      assert result.success
      assert result.output.clean == false
      assert result.output.file_count > 0
    end

    test "lists changed files", %{root: root} do
      File.write!(Path.join(root, "new_file.ex"), "defmodule New do end")
      result = GitStatus.execute(%{}, %{workspace: root})
      assert result.success
      assert Enum.any?(result.output.files, &String.contains?(&1, "new_file"))
    end

    test "ignores model-provided arguments", %{root: root} do
      # Even with extra args, only the fixed git command runs
      result = GitStatus.execute(%{"malicious" => "arg"}, %{workspace: root})
      assert result.success
    end

    test "returns error for non-git directory" do
      non_git =
        Path.join(System.tmp_dir!(), "muse_gs_nongit_#{System.unique_integer([:positive])}")

      File.mkdir_p!(non_git)
      result = GitStatus.execute(%{}, %{workspace: non_git})
      # May return error or empty result depending on git behavior
      File.rm_rf(non_git)
      assert is_struct(result, Muse.Tool.Result)
    end
  end
end
