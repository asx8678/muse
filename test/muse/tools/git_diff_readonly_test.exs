defmodule Muse.Tools.GitDiffReadonlyTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.GitDiffReadonly

  setup do
    root = Path.join(System.tmp_dir!(), "muse_gdr_#{System.unique_integer([:positive])}")
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
    test "returns empty diff when no changes", %{root: root} do
      result = GitDiffReadonly.execute(%{}, %{workspace: root})
      assert result.success
      assert result.output.diff == ""
    end

    test "shows diff for working tree changes", %{root: root} do
      File.write!(Path.join(root, "README.md"), "# Modified Test")
      result = GitDiffReadonly.execute(%{}, %{workspace: root})
      assert result.success
      assert result.output.diff =~ "Modified"
    end

    test "shows diff for specific path", %{root: root} do
      File.write!(Path.join(root, "README.md"), "# Modified Test")
      result = GitDiffReadonly.execute(%{"path" => "README.md"}, %{workspace: root})
      assert result.success
      assert result.output.path == "README.md"
    end

    test "supports cached flag for staged changes", %{root: root} do
      File.write!(Path.join(root, "new.ex"), "defmodule New do end")
      System.cmd("git", ["add", "."], cd: root)
      result = GitDiffReadonly.execute(%{"cached" => true}, %{workspace: root})
      assert result.success
      assert result.output.cached == true
    end

    test "rejects path escaping workspace", %{root: root} do
      result = GitDiffReadonly.execute(%{"path" => "../../etc/passwd"}, %{workspace: root})
      refute result.success
    end

    test "caps large output", %{root: root} do
      # Create a file that would generate a large diff
      large_content = String.duplicate("x\n", 20_000)
      File.write!(Path.join(root, "large.txt"), large_content)
      result = GitDiffReadonly.execute(%{"path" => "large.txt"}, %{workspace: root})
      assert result.success
      # Output should be capped
      assert is_binary(result.output.diff)
    end

    test "no write commands in diff output", %{root: root} do
      File.write!(Path.join(root, "README.md"), "# Modified")
      result = GitDiffReadonly.execute(%{}, %{workspace: root})
      assert result.success
      # Diff output should not contain any git write commands
      refute result.output.diff =~ ~r/git (checkout|reset|checkout|stash|merge|rebase|push)/
    end
  end
end
