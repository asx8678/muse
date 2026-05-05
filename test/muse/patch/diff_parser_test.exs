defmodule Muse.Patch.DiffParserTest do
  use ExUnit.Case, async: true

  alias Muse.Patch.DiffParser

  # -- parse/1 — single-file diff -----------------------------------------------

  describe "parse/1 — single-file diff" do
    test "parses a minimal single-hunk diff" do
      diff = """
      diff --git a/foo.ex b/foo.ex
      --- a/foo.ex
      +++ b/foo.ex
      @@ -1,3 +1,4 @@
       line1
      -old
      +new
      +extra
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert entry.old_path == "foo.ex"
      assert entry.new_path == "foo.ex"
      assert length(entry.hunks) == 1

      [hunk] = entry.hunks
      assert hunk.old_start == 1
      assert hunk.old_count == 3
      assert hunk.new_start == 1
      assert hunk.new_count == 4
      assert length(hunk.lines) == 4
    end

    test "parses a diff without git diff header" do
      diff = """
      --- a/bar.ex
      +++ b/bar.ex
      @@ -5,2 +5,2 @@
       keep
      -remove
      +add
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert entry.old_path == "bar.ex"
      assert entry.new_path == "bar.ex"
      assert length(entry.hunks) == 1
    end

    test "parses hunk with optional counts omitted" do
      diff = """
      --- a/single.ex
      +++ b/single.ex
      @@ -10 +10 @@
      -old_line
      +new_line
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      [hunk] = entry.hunks
      assert hunk.old_start == 10
      assert hunk.old_count == 1
      assert hunk.new_start == 10
      assert hunk.new_count == 1
    end

    test "parses hunk with only old count specified" do
      diff = """
      --- a/file.ex
      +++ b/file.ex
      @@ -1,3 +1 @@
      -line1
      -line2
      -line3
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      [hunk] = entry.hunks
      assert hunk.old_count == 3
      assert hunk.new_count == 1
    end

    test "parses new file (old path /dev/null)" do
      diff = """
      diff --git a/new_file.ex b/new_file.ex
      --- /dev/null
      +++ b/new_file.ex
      @@ -0,0 +1,3 @@
      +line1
      +line2
      +line3
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert entry.old_path == nil
      assert entry.new_path == "new_file.ex"
    end

    test "parses deleted file (new path /dev/null)" do
      diff = """
      diff --git a/deleted.ex b/deleted.ex
      --- a/deleted.ex
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -line1
      -line2
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert entry.old_path == "deleted.ex"
      assert entry.new_path == nil
    end
  end

  # -- parse/1 — multi-file diff ------------------------------------------------

  describe "parse/1 — multi-file diff" do
    test "parses a diff with multiple files" do
      diff = """
      diff --git a/first.ex b/first.ex
      --- a/first.ex
      +++ b/first.ex
      @@ -1,2 +1,2 @@
       ctx
      -old1
      +new1
      diff --git a/second.ex b/second.ex
      --- a/second.ex
      +++ b/second.ex
      @@ -10,3 +10,4 @@
       ctx2
      -old2
      +new2
      +extra2
      """

      assert {:ok, [first, second]} = DiffParser.parse(diff)
      assert first.old_path == "first.ex"
      assert second.old_path == "second.ex"
      assert length(first.hunks) == 1
      assert length(second.hunks) == 1
    end

    test "parses a file with multiple hunks" do
      diff = """
      diff --git a/multi.ex b/multi.ex
      --- a/multi.ex
      +++ b/multi.ex
      @@ -1,3 +1,3 @@
       ctx1
      -old1
      +new1
      @@ -20,2 +20,2 @@
       ctx2
      -old2
      +new2
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert length(entry.hunks) == 2
      assert Enum.at(entry.hunks, 0).old_start == 1
      assert Enum.at(entry.hunks, 1).old_start == 20
    end
  end

  # -- parse/1 — line types -----------------------------------------------------

  describe "parse/1 — line types" do
    test "classifies context, add, remove, and no-newline lines" do
      diff = """
      --- a/types.ex
      +++ b/types.ex
      @@ -1,4 +1,4 @@
       context_line
      -removed_line
      +added_line
      +another_added
      \\ No newline at end of file
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      [hunk] = entry.hunks
      types = Enum.map(hunk.lines, &elem(&1, 0))
      assert types == [:context, :remove, :add, :add, :no_newline]
    end

    test "preserves content for each line" do
      diff = """
      --- a/content.ex
      +++ b/content.ex
      @@ -1,2 +1,2 @@
       keep this
      -remove this
      +add this
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      [hunk] = entry.hunks
      contents = Enum.map(hunk.lines, &elem(&1, 1))
      assert contents == [" keep this", "remove this", "add this"]
    end
  end

  # -- parse/1 — binary patch rejection -----------------------------------------

  describe "parse/1 — binary patch rejection" do
    test "rejects diff containing GIT binary patch marker" do
      diff = """
      diff --git a/image.png b/image.png
      GIT binary patch
      literal 0
      HcmV?d00001
      """

      assert {:error, :binary_patch} = DiffParser.parse(diff)
    end
  end

  # -- affected_paths/1 ---------------------------------------------------------

  describe "affected_paths/1" do
    test "extracts new_path for each file entry" do
      diff = """
      diff --git a/lib/app.ex b/lib/app.ex
      --- a/lib/app.ex
      +++ b/lib/app.ex
      @@ -1 +1 @@
      -old
      +new
      diff --git a/lib/helper.ex b/lib/helper.ex
      --- a/lib/helper.ex
      +++ b/lib/helper.ex
      @@ -5 +5 @@
      -old2
      +new2
      """

      assert {:ok, paths} = DiffParser.affected_paths(diff)
      assert paths == ["lib/app.ex", "lib/helper.ex"]
    end

    test "falls back to old_path for deletion diffs" do
      diff = """
      diff --git a/gone.ex b/gone.ex
      --- a/gone.ex
      +++ /dev/null
      @@ -1 +0,0 @@
      -last_line
      """

      assert {:ok, paths} = DiffParser.affected_paths(diff)
      assert paths == ["gone.ex"]
    end

    test "returns empty list for empty diff" do
      assert {:ok, []} = DiffParser.affected_paths("")
    end
  end

  # -- binary_patch?/1 ----------------------------------------------------------

  describe "binary_patch?/1" do
    test "returns true for diff containing binary marker" do
      assert DiffParser.binary_patch?("GIT binary patch\nliteral 0")
    end

    test "returns false for text diff" do
      refute DiffParser.binary_patch?("diff --git a/foo.ex b/foo.ex\n")
    end

    test "returns false for empty string" do
      refute DiffParser.binary_patch?("")
    end
  end

  # -- validate/1 ---------------------------------------------------------------

  describe "validate/1" do
    test "returns :ok for valid text diff" do
      diff = """
      --- a/ok.ex
      +++ b/ok.ex
      @@ -1 +1 @@
      -old
      +new
      """

      assert :ok = DiffParser.validate(diff)
    end

    test "returns :ok for empty diff" do
      assert :ok = DiffParser.validate("")
    end

    test "returns error for binary patch" do
      assert {:error, :binary_patch} = DiffParser.validate("GIT binary patch\n")
    end
  end

  # -- canonicalize/1 -----------------------------------------------------------

  describe "canonicalize/1" do
    test "normalizes CRLF to LF" do
      diff = "--- a/f.ex\r\n+++ b/f.ex\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n"
      canonical = DiffParser.canonicalize(diff)
      refute String.contains?(canonical, "\r")
      assert String.ends_with?(canonical, "\n")
    end

    test "trims trailing whitespace per line" do
      diff = "--- a/f.ex\n+++ b/f.ex\n@@ -1 +1 @@\n-old   \n+new  \n"
      canonical = DiffParser.canonicalize(diff)
      # Each line should have no trailing spaces
      for line <- String.split(canonical, "\n"), line != "" do
        refute String.ends_with?(line, " "), "Line has trailing whitespace: #{inspect(line)}"
      end
    end

    test "drops trailing blank lines" do
      diff = "--- a/f.ex\n+++ b/f.ex\n@@ -1 +1 @@\n-old\n+new\n\n\n"
      canonical = DiffParser.canonicalize(diff)
      refute String.ends_with?(canonical, "\n\n")
    end

    test "ensures trailing newline" do
      diff = "--- a/f.ex\n+++ b/f.ex\n@@ -1 +1 @@\n-old\n+new"
      canonical = DiffParser.canonicalize(diff)
      assert String.ends_with?(canonical, "\n")
    end

    test "is idempotent" do
      diff = "--- a/f.ex\r\n+++ b/f.ex\n@@ -1 +1 @@\n-old  \r\n+new\r\n"
      once = DiffParser.canonicalize(diff)
      twice = DiffParser.canonicalize(once)
      assert once == twice
    end

    test "handles empty string" do
      assert DiffParser.canonicalize("") == ""
    end
  end

  # -- Edge cases ---------------------------------------------------------------

  describe "parse/1 — edge cases" do
    test "parses empty diff" do
      assert {:ok, []} = DiffParser.parse("")
    end

    test "ignores git index lines" do
      diff = """
      diff --git a/foo.ex b/foo.ex
      index abc1234..def5678 100644
      --- a/foo.ex
      +++ b/foo.ex
      @@ -1 +1 @@
      -old
      +new
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert entry.new_path == "foo.ex"
    end

    test "handles hunk header with trailing context" do
      diff = """
      --- a/fn.ex
      +++ b/fn.ex
      @@ -1,3 +1,4 @@ fn some_function/0
       ctx
      -old
      +new
      +extra
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      [hunk] = entry.hunks
      assert hunk.old_start == 1
      assert hunk.old_count == 3
    end

    test "handles deeply nested file paths" do
      diff = """
      diff --git a/lib/muse/some/deep/path.ex b/lib/muse/some/deep/path.ex
      --- a/lib/muse/some/deep/path.ex
      +++ b/lib/muse/some/deep/path.ex
      @@ -1 +1 @@
      -old
      +new
      """

      assert {:ok, [entry]} = DiffParser.parse(diff)
      assert entry.new_path == "lib/muse/some/deep/path.ex"
    end

    test "handles diff without --- and +++ headers gracefully" do
      # A diff starting with just a hunk (unusual but possible)
      diff = """
      @@ -1,2 +1,2 @@
       ctx
      -old
      +new
      """

      # Should parse but may not have file paths
      assert {:ok, entries} = DiffParser.parse(diff)
      assert length(entries) <= 1
    end
  end
end
