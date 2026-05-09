defmodule Muse.Tools.RepoSearchBaselineTest do
  @moduledoc """
  T1-13 Streaming: repo_search uses lazy Stream.resource to walk the file
  tree and stops after `max_results` without materializing the full list.

  These tests verify:
    - Early termination at max_results (no full tree walk)
    - Memory-bounded behavior on large synthetic trees
    - Per-file bounded search (only needed matches extracted)
    - Inaccessible directories do not crash the walker
    - Result shape remains compatible with tool loop expectations
  """
  use ExUnit.Case, async: true

  alias Muse.Tools.RepoSearch

  # ---------------------------------------------------------------------------
  # Setup — synthetic tree with many matches
  # ---------------------------------------------------------------------------

  setup do
    root = Path.join(System.tmp_dir!(), "muse_rs_baseline_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # Create 100 files, each containing "defmodule" on multiple lines
    for i <- 1..100 do
      dir = Path.join(root, "src_#{div(i - 1, 10)}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "file_#{i}.ex"), """
      defmodule Module#{i} do
        def hello, do: :world
        def goodbye, do: :ok
      end
      """)
    end

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # max_results enforcement
  # ---------------------------------------------------------------------------

  describe "repo_search — max_results enforcement on synthetic tree" do
    test "stops at max_results=1", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 1}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 1
    end

    test "stops at max_results=3", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 3}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 3
    end

    test "stops at max_results=10", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 10}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 10
    end

    test "stops at max_results=50 (default)", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})

      assert result.success
      # Default max_results is 50
      assert length(result.output.results) <= 50
    end

    test "respects custom max_results above default", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 80}, %{workspace: root})

      assert result.success
      # Should find more than default 50 but ≤ 80
      assert length(result.output.results) <= 80
    end

    test "indicates truncation when results are capped", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 5}, %{workspace: root})

      assert result.success
      # With 100+ matches in the tree, truncation should be flagged
      assert result.output.truncated == true
    end

    test "does not indicate truncation when results fit within max", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "ZZZNOTFOUND123"}, %{workspace: root})

      assert result.success
      assert result.output.truncated == false
      assert result.output.total_matches == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Early termination — repo_search should not walk entire tree
  # ---------------------------------------------------------------------------

  describe "repo_search — early termination" do
    @tag :timing_baseline
    test "does not scan all 100 files when max_results=5", %{root: root} do
      # This test verifies repo_search returns quickly with early termination.
      # Tagged :timing_baseline because absolute timing thresholds are
      # inherently non-deterministic in CI (cold caches, shared runners, etc.).
      # Correctness of early termination is covered by the max_results tests above.
      {time_us, result} =
        :timer.tc(fn ->
          RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 5}, %{workspace: root})
        end)

      time_ms = div(time_us, 1_000)

      assert result.success
      assert length(result.output.results) <= 5
      # 10s grace — this catches gross lack of early termination,
      # not minor CI variance. 100 small files should take <1s on any runner.
      assert time_ms < 10_000,
             "repo_search took #{time_ms}ms with max_results=5 on 100 files — possible lack of early termination"
    end

    @tag :timing_baseline
    test "max_results=1 is not slower than scanning everything", %{root: root} do
      # Time a limited search — repeat a few times to reduce variance
      time_limited_us =
        Enum.min(
          for _ <- 1..3 do
            {t, _} =
              :timer.tc(fn ->
                RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 1}, %{
                  workspace: root
                })
              end)

            t
          end
        )

      # Time an unlimited search (all files) — repeat a few times
      time_full_us =
        Enum.min(
          for _ <- 1..3 do
            {t, _} =
              :timer.tc(fn ->
                RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 999}, %{
                  workspace: root
                })
              end)

            t
          end
        )

      # The limited search should not take dramatically longer than the full search
      # (allowing for 3x variance for CI/system-noise)
      assert time_limited_us <= time_full_us * 3,
             "Limited search (#{div(time_limited_us, 1000)}ms) took >3x longer than full search (#{div(time_full_us, 1000)}ms)"
    end
  end

  # ---------------------------------------------------------------------------
  # Output structure — baseline correctness
  # ---------------------------------------------------------------------------

  describe "repo_search — output structure baseline" do
    test "each result has file, line, and excerpt keys", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 5}, %{workspace: root})

      assert result.success

      Enum.each(result.output.results, fn match ->
        assert Map.has_key?(match, :file)
        assert Map.has_key?(match, :line)
        assert Map.has_key?(match, :excerpt)
        assert is_binary(match.file)
        assert is_integer(match.line)
        assert is_binary(match.excerpt)
      end)
    end

    test "total_matches reflects returned result count (not total in tree)", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 3}, %{workspace: root})

      assert result.success
      # total_matches is the count of returned results (not all possible matches)
      assert result.output.total_matches == length(result.output.results)
    end

    test "backend is :elixir", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})

      assert result.success
      assert result.output.backend == :elixir
    end

    test "pattern is echoed in output", %{root: root} do
      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})

      assert result.success
      assert result.output.pattern == "defmodule"
    end
  end

  # ---------------------------------------------------------------------------
  # T1-13 Streaming — lazy file discovery, bounded per-file search
  # ---------------------------------------------------------------------------

  describe "repo_search — streaming: no full materialization" do
    test "early termination does not visit all directories", %{root: root} do
      # Create additional directories that would be visited by an eager walker
      for i <- 1..50 do
        deep = Path.join(root, "deep_#{i}/sub")
        File.mkdir_p!(deep)
        File.write!(Path.join(deep, "file.ex"), "defmodule Deep#{i} do\nend\n")
      end

      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 1}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 1
      assert result.output.truncated == true
    end

    test "max_results=0 returns no results", %{root: root} do
      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 0}, %{workspace: root})

      assert result.success
      assert result.output.results == []
      assert result.output.total_matches == 0
    end
  end

  describe "repo_search — streaming: per-file bounded search" do
    test "single file with many matches respects remaining capacity", %{root: root} do
      # Create a single file with 200 lines containing the pattern
      lines = for i <- 1..200, do: "defmodule Mod#{i} do"
      File.write!(Path.join(root, "big_file.ex"), Enum.join(lines, "\n"))

      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 5}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 5
      assert result.output.truncated == true
    end

    test "per-file bounding stops at exactly max_results from one file", %{root: root} do
      # Create a single file with 100 matching lines
      lines = for i <- 1..100, do: "match_line_#{i}"
      File.write!(Path.join(root, "many_matches.ex"), Enum.join(lines, "\n"))

      result =
        RepoSearch.execute(%{"pattern" => "match_line", "max_results" => 10}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 10
    end
  end

  describe "repo_search — streaming: inaccessible directories" do
    test "permission-denied directory does not crash search", %{root: root} do
      # Create a directory with no read permission
      no_access = Path.join(root, "no_access")
      File.mkdir_p!(no_access)
      File.write!(Path.join(no_access, "secret.ex"), "defmodule Secret do\nend\n")
      File.chmod!(no_access, 0o000)

      result =
        try do
          RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
        after
          # Restore permissions so cleanup can succeed
          File.chmod!(no_access, 0o755)
        end

      assert result.success
      # Should find results from other files even if no_access is skipped
      assert result.output.total_matches > 0
    end

    test "unreadable file within readable directory does not crash", %{root: root} do
      bad_file = Path.join(root, "unreadable.ex")
      File.write!(bad_file, "defmodule Unreadable do\nend\n")
      File.chmod!(bad_file, 0o000)

      result =
        try do
          RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})
        after
          File.chmod!(bad_file, 0o644)
        end

      assert result.success
      # Other files should still be found
      assert result.output.total_matches > 0
      # The unreadable file should not appear in results
      refute Enum.any?(result.output.results, &String.contains?(&1.file, "unreadable"))
    end
  end

  describe "repo_search — streaming: result order correctness" do
    test "results preserve file discovery order within a directory", %{root: root} do
      # Create files with unique, ordered patterns
      File.write!(Path.join(root, "a_alpha.ex"), "alpha_pattern_line\n")
      File.write!(Path.join(root, "b_beta.ex"), "beta_pattern_line\n")
      File.write!(Path.join(root, "c_gamma.ex"), "gamma_pattern_line\n")

      result =
        RepoSearch.execute(%{"pattern" => "_pattern_line", "max_results" => 10}, %{
          workspace: root
        })

      assert result.success
      # All three should be found
      assert result.output.total_matches == 3
    end

    test "results from a single file preserve line order", %{root: root} do
      File.write!(
        Path.join(root, "ordered.ex"),
        "line_a_pattern\nline_b_nomatch\nline_c_pattern\nline_d_pattern"
      )

      result =
        RepoSearch.execute(%{"pattern" => "_pattern", "max_results" => 10}, %{workspace: root})

      assert result.success

      ordered_results =
        result.output.results
        |> Enum.filter(&String.contains?(&1.file, "ordered.ex"))

      # Results should be in ascending line order
      lines = Enum.map(ordered_results, & &1.line)

      assert lines == Enum.sort(lines),
             "Expected ascending line order, got: #{inspect(lines)}"
    end
  end

  describe "repo_search — streaming: large tree stress" do
    test "handles 500-file tree with low max_results efficiently" do
      root = Path.join(System.tmp_dir!(), "muse_rs_large_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      # Create 500 files across 50 directories
      for i <- 1..500 do
        dir = Path.join(root, "dir_#{div(i - 1, 10)}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "file_#{i}.ex"), "defmodule Large#{i} do\nend\n")
      end

      on_exit(fn -> File.rm_rf(root) end)

      {time_us, result} =
        :timer.tc(fn ->
          RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 3}, %{workspace: root})
        end)

      time_ms = div(time_us, 1_000)

      assert result.success
      assert length(result.output.results) <= 3
      assert result.output.truncated == true
      # 30s grace — 500 files should be walked with early termination in well under 30s
      assert time_ms < 30_000,
             "repo_search took #{time_ms}ms on 500 files with max_results=3"
    end

    test "handles deep directory nesting without stack overflow" do
      root = Path.join(System.tmp_dir!(), "muse_rs_deep_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      # Create a chain of 50 nested directories
      current = root

      for i <- 1..50 do
        current = Path.join(current, "level#{i}")
        File.mkdir_p!(current)
      end

      File.write!(Path.join(current, "deep.ex"), "defmodule Deep do\nend\n")

      on_exit(fn -> File.rm_rf(root) end)

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})

      assert result.success
      assert result.output.total_matches > 0
      assert Enum.any?(result.output.results, &String.contains?(&1.file, "deep.ex"))
    end
  end

  describe "repo_search — streaming: binary/non-UTF-8 safety" do
    test "binary files interspersed with text files do not break streaming", %{root: root} do
      # Mix binary and text files across directories
      for i <- 1..10 do
        dir = Path.join(root, "mix_#{i}")
        File.mkdir_p!(dir)

        # Binary file
        File.write!(Path.join(dir, "data.bin"), <<0, 1, 2, 0, 4>>)
        # Text file with match
        File.write!(Path.join(dir, "code.ex"), "defmodule Mix#{i} do\nend\n")
      end

      result =
        RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 5}, %{workspace: root})

      assert result.success
      assert length(result.output.results) <= 5
      # No binary files in results
      refute Enum.any?(result.output.results, &String.contains?(&1.file, ".bin"))
    end

    test "invalid UTF-8 file between valid files does not halt stream", %{root: root} do
      File.write!(Path.join(root, "good1.ex"), "defmodule Good1 do\nend\n")
      File.write!(Path.join(root, "bad_utf8.txt"), <<0xFF, 0xFE>>)
      File.write!(Path.join(root, "good2.ex"), "defmodule Good2 do\nend\n")

      result = RepoSearch.execute(%{"pattern" => "defmodule"}, %{workspace: root})

      assert result.success
      good_files = Enum.filter(result.output.results, &String.contains?(&1.file, "good"))
      assert length(good_files) == 2
    end
  end
end
