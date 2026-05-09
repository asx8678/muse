defmodule Muse.Tools.RepoSearchTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.RepoSearch

  setup do
    root = Path.join(System.tmp_dir!(), "muse_rs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do\n  def hello, do: :world\nend\n")
    File.write!(Path.join(root, "lib/util.ex"), "defmodule Util do\n  def helper, do: :ok\nend\n")
    File.write!(Path.join(root, ".env"), "SECRET_KEY=supersecret\nAPI_TOKEN=abc")
    File.mkdir_p!(Path.join(root, "_build"))

    File.write!(
      Path.join(root, "_build/compiled.ex"),
      "defmodule Compiled do\n  def hello, do: :built\nend\n"
    )

    File.write!(Path.join(root, "README.md"), "# Hello World\nThis is a test project.")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "execute/2" do
    test "finds pattern in workspace files", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      assert result.output.total_matches > 0
      assert length(result.output.results) > 0
    end

    test "reports :elixir backend", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      assert result.output.backend == :elixir
    end

    test "omits secret files from search", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "SECRET_KEY"}, %{workspace: root})
      assert result.success
      # .env is a secret file — should not appear in results
      refute Enum.any?(result.output.results, &String.contains?(&1.file, ".env"))
    end

    test "omits ignored directories from search", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      # _build is ignored
      refute Enum.any?(result.output.results, &String.starts_with?(&1.file, "_build/"))
    end

    test "returns error when pattern is missing" do
      result = RepoSearch.execute(%{}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "pattern is required"
    end

    test "respects max_results", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "do", "max_results" => 1}, %{workspace: root})
      assert result.success
      assert length(result.output.results) <= 1
    end

    test "results include file, line, and excerpt", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule App"}, %{workspace: root})
      assert result.success
      [match | _] = result.output.results
      assert Map.has_key?(match, :file)
      assert Map.has_key?(match, :line)
      assert Map.has_key?(match, :excerpt)
      assert match.excerpt =~ "defmodule App"
    end

    test "returns empty results for no matches", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "ZZZNOTFOUND123"}, %{workspace: root})
      assert result.success
      assert result.output.results == []
      assert result.output.total_matches == 0
    end

    test "skips binary files", %{root: root} do
      File.write!(Path.join(root, "data.bin"), <<0, 1, 2, 0, 4, 5>>)
      result = RepoSearch.execute(%{"pattern" => "anything"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "data.bin"))
    end
  end

  describe "execute/2 — symlink escape prevention (PR06 Blocker 2)" do
    test "does not search through symlinks that escape workspace" do
      root = Path.join(System.tmp_dir!(), "muse_rs_symlink_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      outside =
        Path.join(System.tmp_dir!(), "muse_rs_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)

      File.write!(
        Path.join(outside, "escaped.ex"),
        "defmodule Escaped do\n  def secret, do: :leaked\nend\n"
      )

      try do
        link = Path.join(root, "outside_link")
        File.rm(link)
        :ok = File.ln_s(outside, link)

        result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
        assert result.success

        # Symlink escape should be blocked by safe_to_access?
        refute Enum.any?(result.output.results, &String.contains?(&1.file, "escaped"))
      after
        File.rm_rf(root)
        File.rm_rf(outside)
      end
    end

    test "never searches .git directory even with allow_hidden semantics", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/config"), "[core]\nrepositoryformatversion = 0\n")

      result = RepoSearch.execute(%{"pattern" => "repositoryformatversion"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.contains?(&1.file, ".git"))
    end

    test "never searches _build or deps even when pattern matches", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.starts_with?(&1.file, "_build/"))
      refute Enum.any?(result.output.results, &String.starts_with?(&1.file, "deps/"))
    end

    test "bounded reads — skips files larger than max_per_file_bytes", %{root: root} do
      # Create a file that's larger than @max_per_file_bytes (100_000)
      large_content = String.duplicate("line with defmodule\n", 10_000)
      File.write!(Path.join(root, "large_search.ex"), large_content)

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      # Should find matches but not crash on the large file
      assert length(result.output.results) > 0
    end

    test "stops at max_results", %{root: root} do
      # Create many files with the same pattern
      for i <- 1..20 do
        File.write!(Path.join(root, "file_#{i}.ex"), "defmodule File#{i} do\nend\n")
      end

      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 3}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 3
    end
  end

  describe "execute/2 — UTF-8 and binary safety (muse-qw4.13)" do
    test "skips invalid UTF-8 files without crashing", %{root: root} do
      # 0xFF is never valid UTF-8
      File.write!(Path.join(root, "bad_utf8.txt"), <<0xFF, 0xFE, 0xFD>>)
      # Also include a valid file with the search pattern to prove search still works
      File.write!(Path.join(root, "good_utf8.ex"), "defmodule Good do\nend\n")

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      # bad_utf8.txt should be silently skipped
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "bad_utf8"))
      # good file still found
      assert Enum.any?(result.output.results, &String.contains?(&1.file, "good_utf8"))
    end

    test "skips NUL-containing files without crashing", %{root: root} do
      File.write!(Path.join(root, "nul_file.txt"), "defmodule" <> <<0>> <> "rest")

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "nul_file"))
    end

    test "skips files with excessive control characters", %{root: root} do
      control_bytes = for _ <- 1..200, into: <<>>, do: <<0x01>>
      text = String.duplicate("a", 3000)
      File.write!(Path.join(root, "ctrl_chars.bin"), control_bytes <> text)

      result = RepoSearch.execute(%{"pattern" => "a"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "ctrl_chars"))
    end

    test "skips invalid UTF-8 after the first 8KB sample without crashing", %{root: root} do
      File.write!(Path.join(root, "late_bad_utf8.txt"), String.duplicate("a", 9000) <> <<0xFF>>)
      File.write!(Path.join(root, "late_good.ex"), "defmodule LateGood do\nend\n")

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "late_bad_utf8"))
      assert Enum.any?(result.output.results, &String.contains?(&1.file, "late_good"))
    end

    test "skips NUL bytes after the first 8KB sample", %{root: root} do
      File.write!(
        Path.join(root, "late_nul.txt"),
        String.duplicate("a", 9000) <> <<0>> <> "defmodule"
      )

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "late_nul"))
    end

    test "handles valid UTF-8 files with multibyte characters", %{root: root} do
      File.write!(
        Path.join(root, "utf8_jp.ex"),
        "defmodule 日本語 do\n  def hello, do: :world\nend\n"
      )

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      jp_results = Enum.filter(result.output.results, &String.contains?(&1.file, "utf8_jp"))
      assert length(jp_results) > 0
    end

    test "excerpt in results uses safe_slice for multibyte characters", %{root: root} do
      # Create a file with multibyte chars so excerpts test grapheme-aware slicing
      long_line = String.duplicate("日本語", 100)
      File.write!(Path.join(root, "long_utf8.ex"), "defmodule #{long_line} do\nend\n")

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
      assert result.success
      # Excerpts should be valid UTF-8 (grapheme-aware slicing)
      Enum.each(result.output.results, fn match ->
        assert String.valid?(match.excerpt)
        assert byte_size(match.excerpt) <= 800
      end)
    end
  end
end
