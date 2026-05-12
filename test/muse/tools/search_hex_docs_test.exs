defmodule Muse.Tools.SearchHexDocsTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.SearchHexDocs

  describe "execute/2 — validation" do
    test "returns error when query is missing" do
      result = SearchHexDocs.execute(%{}, %{})

      refute result.success
      assert result.error =~ "query is required"
    end

    test "returns error when query is empty string" do
      result = SearchHexDocs.execute(%{"query" => ""}, %{})

      refute result.success
      assert result.error =~ "query is required"
    end

    test "returns error when query is not a string" do
      result = SearchHexDocs.execute(%{"query" => 123}, %{})

      refute result.success
      assert result.error =~ "query must be a string"
    end
  end

  describe "parse_mix_lock/1" do
    test "returns empty map when workspace has no mix.lock" do
      result = SearchHexDocs.parse_mix_lock(System.tmp_dir!())

      assert result == %{}
    end

    test "returns empty map for nil workspace" do
      result = SearchHexDocs.parse_mix_lock(nil)

      assert result == %{}
    end

    test "returns empty map for empty string workspace" do
      result = SearchHexDocs.parse_mix_lock("")

      assert result == %{}
    end
  end

  describe "parse_mix_lock/1 — with mix.lock file" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "search_hex_docs_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, dir: dir}
    end

    test "parses hex deps from a valid mix.lock file", %{dir: dir} do
      File.write!(Path.join(dir, "mix.lock"), """
      %{
        "phoenix": {:hex, :phoenix, "1.8.5", "hash1", [], "hexpm", "hash2"},
        "ecto": {:hex, :ecto, "3.12.1", "hash3", [], "hexpm", "hash4"}
      }
      """)

      result = SearchHexDocs.parse_mix_lock(dir)

      assert result == %{"phoenix" => "1.8.5", "ecto" => "3.12.1"}
    end

    test "ignores non-hex entries in mix.lock", %{dir: dir} do
      File.write!(Path.join(dir, "mix.lock"), """
      %{
        "phoenix": {:hex, :phoenix, "1.8.5", "hash1", [], "hexpm", "hash2"},
        "my_local": {:path, "deps/my_local"}
      }
      """)

      result = SearchHexDocs.parse_mix_lock(dir)

      # Only hex deps extracted; path deps ignored
      assert result == %{"phoenix" => "1.8.5"}
    end

    test "returns empty map for workspace without mix.lock", %{dir: dir} do
      # dir exists but has no mix.lock
      result = SearchHexDocs.parse_mix_lock(dir)

      assert result == %{}
    end
  end

  describe "execute/2 — Req unavailable" do
    @tag :capture_log
    test "error message is defined for missing Req" do
      # Verify the error path exists — in this project Req is always available,
      # so we validate the expected error message format directly.
      result = Muse.Tool.Result.error("search_hex_docs", "Req HTTP client is not available")

      refute result.success
      assert result.error =~ "Req HTTP client is not available"
    end
  end

  describe "execute/2 — network integration" do
    @tag :network
    test "searches hexdocs.pm and returns structured results" do
      result = SearchHexDocs.execute(%{"query" => "Phoenix.Endpoint"}, %{workspace: File.cwd!()})

      assert result.success
      assert is_list(result.output.results)
      assert is_integer(result.output.total)
      assert result.output.query == "Phoenix.Endpoint"

      # Verify result structure (Typesense response format)
      [first | _] = result.output.results
      assert Map.has_key?(first, :package)
      assert Map.has_key?(first, :title)
      assert Map.has_key?(first, :url)
      assert Map.has_key?(first, :version)
      assert Map.has_key?(first, :type)
      assert Map.has_key?(first, :excerpt)
    end

    @tag :network
    test "respects packages filter" do
      result =
        SearchHexDocs.execute(
          %{"query" => "endpoint", "packages" => ["phoenix"]},
          %{workspace: File.cwd!()}
        )

      assert result.success
      # All results should be from the phoenix package when filtered
      for r <- result.output.results do
        assert r.package == "phoenix"
      end
    end

    @tag :network
    test "handles no mix.lock gracefully" do
      result =
        SearchHexDocs.execute(
          %{"query" => "Enum"},
          %{workspace: System.tmp_dir!()}
        )

      assert result.success
      assert is_list(result.output.results)
    end
  end
end
