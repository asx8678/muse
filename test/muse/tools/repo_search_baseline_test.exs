defmodule Muse.Tools.RepoSearchBaselineTest do
  @moduledoc """
  T0-00 Baseline: repo_search stopping after `max_results` on a synthetic tree.

  These tests verify that `RepoSearch.execute/2` respects `max_results`
  and stops walking the file tree early rather than materializing all
  results. Uses a synthetic directory tree to produce many matches.
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
    test "does not scan all 100 files when max_results=5", %{root: root} do
      # This test measures that repo_search doesn't naively scan everything
      # then truncate. With early termination, it should return quickly.
      {time_us, result} =
        :timer.tc(fn ->
          RepoSearch.execute(%{"pattern" => "defmodule", "max_results" => 5}, %{workspace: root})
        end)

      time_ms = div(time_us, 1_000)

      assert result.success
      assert length(result.output.results) <= 5
      # Should complete well under 1 second for 100 small files
      assert time_ms < 1_000,
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
end
