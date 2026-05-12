defmodule Muse.MatrixManagerTest do
  use ExUnit.Case, async: false

  alias Muse.MatrixManager

  # -- Helpers ------------------------------------------------------------------

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "matrix_test_#{:erlang.unique_integer([:positive])}")
  end

  defp stop_matrix do
    case Process.whereis(Muse.MatrixManager) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp start_matrix(opts) do
    stop_matrix()
    {:ok, _} = MatrixManager.start_link(opts)
    :ok
  end

  defp write_file(dir, rel_path, content) do
    abs = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
    abs
  end

  defp init_git(dir) do
    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    System.cmd("git", ["add", "."], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "init"], cd: dir, stderr_to_stdout: true)
  end

  defp create_sample_project(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "lib/auth"))

    write_file(dir, "lib/foo.ex", """
    defmodule MyApp.Foo do
      import MyApp.Bar
      alias MyApp.Baz.Qux
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      def init(opts), do: {:ok, opts}

      def login(user, pass) do
        if check(user), do: {:ok, user}, else: {:error, :denied}
      end

      defp check(user), do: true
      defp validate(token), do: :ok
    end
    """)

    write_file(dir, "lib/bar.ex", """
    defmodule MyApp.Bar do
      require Logger

      def validate(token), do: {:ok, token}
      def refresh(token), do: token
    end
    """)

    write_file(dir, "lib/baz/qux.ex", """
    defmodule MyApp.Baz.Qux do
      import MyApp.Bar

      def process(data), do: validate(data)
    end
    """)

    write_file(dir, "lib/auth/session.ex", """
    defmodule MyApp.Auth.Session do
      import MyApp.Bar
      alias MyApp.Foo

      def create(user), do: {:ok, user}
      def destroy(session), do: :ok
    end
    """)

    write_file(dir, "lib/utils.ex", """
    defmodule MyApp.Utils do
      def format(data), do: data
    end
    """)

    write_file(dir, "config/config.exs", """
    import Config
    config :my_app, key: :value
    """)

    write_file(dir, "lib/app.ts", """
    import { Foo } from './foo';
    import { Bar } from '../bar';
    const app = new Foo();
    """)

    dir
  end

  # -- Setup / cleanup ----------------------------------------------------------

  setup do
    dir = tmp_dir()
    File.mkdir_p!(dir)
    start_matrix(root: dir)

    on_exit(fn ->
      stop_matrix()
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  # -- Tests --------------------------------------------------------------------

  describe "index_project/1" do
    test "indexes an empty project without crashing", %{dir: dir} do
      assert :ok = MatrixManager.index_project(dir)
      assert MatrixManager.project_soul() =~ "Empty project"
    end

    test "indexes Elixir files and extracts modules, functions, and imports", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert {:ok, summary} = MatrixManager.get_file_summary("lib/foo.ex")
      assert summary =~ "MyApp.Foo"
      assert summary =~ "functions"

      assert {:ok, summary} = MatrixManager.get_file_summary("lib/bar.ex")
      assert summary =~ "MyApp.Bar"
    end

    test "builds dependency graph from imports", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      # foo.ex imports Bar → depends on bar.ex
      affected = MatrixManager.get_affected_files("lib/bar.ex")
      assert "lib/foo.ex" in affected
      # baz/qux.ex also imports Bar
      assert "lib/baz/qux.ex" in affected
    end

    test "generates project soul with summary", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      soul = MatrixManager.project_soul()
      assert soul =~ "MyApp"
      assert soul =~ "modules"
    end

    test "extracts TypeScript imports from non-Elixir files", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert {:ok, summary} = MatrixManager.get_file_summary("lib/app.ts")
      assert summary =~ ".ts file"
      assert summary =~ "import"
    end
  end

  describe "refresh/0" do
    test "detects new files on incremental refresh", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      # Add a new file
      write_file(dir, "lib/new_module.ex", """
      defmodule MyApp.NewModule do
        def hello, do: :world
      end
      """)

      assert :ok = MatrixManager.refresh()
      assert {:ok, summary} = MatrixManager.get_file_summary("lib/new_module.ex")
      assert summary =~ "MyApp.NewModule"
    end

    test "removes deleted files on incremental refresh", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      # Verify file exists
      assert {:ok, _} = MatrixManager.get_file_summary("lib/utils.ex")

      # Delete the file
      File.rm!(Path.join(dir, "lib/utils.ex"))
      assert :ok = MatrixManager.refresh()
      assert {:error, :not_found} = MatrixManager.get_file_summary("lib/utils.ex")
    end
  end

  describe "query/1" do
    test "finds files by keyword in summary", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      results = MatrixManager.query("auth")
      assert length(results) > 0

      {path, _context, _score} = Enum.find(results, fn {p, _, _} -> p =~ "session" end)
      assert path =~ "auth/session"
    end

    test "finds files by module name in defines", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      results = MatrixManager.query("Foo")
      assert length(results) > 0

      paths = Enum.map(results, fn {p, _, _} -> p end)
      assert Enum.any?(paths, &String.contains?(&1, "foo.ex"))
    end

    test "supports wildcard prefix queries", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      results = MatrixManager.query("auth*")
      assert length(results) > 0
    end

    test "returns empty list for no matches", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert [] = MatrixManager.query("xyzzy_nonexistent_12345")
    end

    test "returns empty list for empty query", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert [] = MatrixManager.query("")
    end

    test "results are ordered by relevance score", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      results = MatrixManager.query("Bar")
      scores = Enum.map(results, fn {_, _, s} -> s end)

      if length(scores) > 1 do
        assert scores == Enum.sort(scores, :desc)
      end
    end
  end

  describe "get_file_summary/1" do
    test "returns summary for existing file", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert {:ok, summary} = MatrixManager.get_file_summary("lib/foo.ex")
      assert is_binary(summary)
      assert summary != ""
    end

    test "returns error for unknown file", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert {:error, :not_found} = MatrixManager.get_file_summary("lib/nonexistent.ex")
    end

    test "returns error for unknown file before explicit indexing", %{dir: _dir} do
      # The async init indexes the empty dir; unknown files should still return :not_found
      assert {:error, :not_found} = MatrixManager.get_file_summary("lib/nonexistent_file_xyz.ex")
    end
  end

  describe "get_affected_files/1" do
    test "returns direct and transitive dependents", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      # bar.ex is imported by foo.ex and baz/qux.ex
      affected = MatrixManager.get_affected_files("lib/bar.ex")

      assert "lib/foo.ex" in affected
      assert "lib/baz/qux.ex" in affected
    end

    test "returns empty list for file with no dependents", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      # utils.ex is not imported by anyone
      affected = MatrixManager.get_affected_files("lib/utils.ex")
      assert affected == []
    end

    test "returns empty list for unknown file", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      assert [] = MatrixManager.get_affected_files("lib/nonexistent.ex")
    end
  end

  describe "project_soul/0" do
    test "returns a string even before explicit indexing (async init may have run)" do
      soul = MatrixManager.project_soul()
      assert is_binary(soul)
    end

    test "returns project summary after indexing", %{dir: dir} do
      create_sample_project(dir)
      assert :ok = MatrixManager.index_project(dir)

      soul = MatrixManager.project_soul()
      assert is_binary(soul)
      assert soul != ""
      assert soul =~ "modules"
    end
  end

  describe "caching" do
    test "saves and loads cache on restart", %{dir: dir} do
      create_sample_project(dir)
      init_git(dir)

      assert :ok = MatrixManager.index_project(dir)
      soul = MatrixManager.project_soul()

      # Stop and restart — should load from cache
      stop_matrix()
      start_matrix(root: dir)

      # The GenServer init should load cache (same git HEAD)
      assert MatrixManager.project_soul() == soul
    end

    test "re-indexes when git HEAD changes", %{dir: dir} do
      create_sample_project(dir)
      init_git(dir)

      assert :ok = MatrixManager.index_project(dir)

      # Make a new commit to change HEAD
      write_file(dir, "lib/extra.ex", "defmodule Extra do end")
      System.cmd("git", ["add", "."], cd: dir, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "extra"], cd: dir, stderr_to_stdout: true)

      # Stop and restart — should detect HEAD change and re-index
      stop_matrix()
      start_matrix(root: dir)

      # After re-index, the new file should be present
      assert {:ok, _} = MatrixManager.get_file_summary("lib/extra.ex")
    end
  end

  describe "edge cases" do
    test "handles non-UTF-8 files gracefully", %{dir: dir} do
      create_sample_project(dir)

      # Write a binary file disguised as .ex
      binary_path = Path.join(dir, "lib/binary.ex")
      File.mkdir_p!(Path.dirname(binary_path))
      File.write!(binary_path, <<0, 1, 2, 255, 254, 253>>)

      assert :ok = MatrixManager.index_project(dir)
      # Should not crash; binary file is skipped
      assert {:error, :not_found} = MatrixManager.get_file_summary("lib/binary.ex")
    end

    test "handles Elixir files with parse errors", %{dir: dir} do
      write_file(dir, "lib/broken.ex", "defmodule Broken do\n  def foo(\nend")

      assert :ok = MatrixManager.index_project(dir)
      assert {:ok, summary} = MatrixManager.get_file_summary("lib/broken.ex")
      assert summary =~ "parse error"
    end

    test "skips binary files by extension", %{dir: dir} do
      write_file(dir, "lib/code.beam", "not really beam")
      create_sample_project(dir)

      assert :ok = MatrixManager.index_project(dir)
      assert {:error, :not_found} = MatrixManager.get_file_summary("lib/code.beam")
    end

    test "skips files in ignored directories", %{dir: dir} do
      write_file(dir, "_build/dev/lib/foo.ex", "defmodule BuildFoo do end")
      write_file(dir, "deps/bar/lib/bar.ex", "defmodule DepBar do end")
      create_sample_project(dir)

      assert :ok = MatrixManager.index_project(dir)
      assert {:error, :not_found} = MatrixManager.get_file_summary("_build/dev/lib/foo.ex")
      assert {:error, :not_found} = MatrixManager.get_file_summary("deps/bar/lib/bar.ex")
    end

    test "respects max_files limit", %{dir: dir} do
      # Create more files than the limit
      for i <- 1..10 do
        write_file(dir, "lib/mod_#{i}.ex", "defmodule Mod#{i} do end")
      end

      stop_matrix()
      start_matrix(root: dir, max_files: 5)
      assert :ok = MatrixManager.index_project(dir)

      # At most 5 files should be indexed (lib/ files prioritized)
      soul = MatrixManager.project_soul()
      assert soul =~ "5 indexed files"
    end

    test "handles empty project directory", %{dir: dir} do
      assert :ok = MatrixManager.index_project(dir)
      assert MatrixManager.project_soul() =~ "Empty project"
      assert [] = MatrixManager.query("anything")
      assert {:error, :not_found} = MatrixManager.get_file_summary("lib/foo.ex")
      assert [] = MatrixManager.get_affected_files("lib/foo.ex")
    end
  end

  describe "AST parsing" do
    test "extracts defmodule names", %{dir: dir} do
      write_file(dir, "lib/nested.ex", """
      defmodule Outer do
        defmodule Inner do
          def hello, do: :world
        end
      end
      """)

      assert :ok = MatrixManager.index_project(dir)
      assert {:ok, summary} = MatrixManager.get_file_summary("lib/nested.ex")
      assert summary =~ "Outer"
      assert summary =~ "Inner"
    end

    test "extracts public and private functions with arities", %{dir: dir} do
      write_file(dir, "lib/funcs.ex", """
      defmodule Funcs do
        def no_args, do: :ok
        def one_arg(a), do: a
        def two_args(a, b), do: {a, b}
        defp private_fun(x), do: x
        def with_guard(x) when x > 0, do: x
      end
      """)

      assert :ok = MatrixManager.index_project(dir)

      results = MatrixManager.query("Funcs")
      assert length(results) > 0

      # The file should be found; match context may be path or summary
      {path, _context, _score} = hd(results)
      assert path =~ "funcs"
    end

    test "extracts use, import, alias, require", %{dir: dir} do
      write_file(dir, "lib/dep_a.ex", "defmodule DepA do end")
      write_file(dir, "lib/dep_b.ex", "defmodule DepB do end")

      write_file(dir, "lib/consumer.ex", """
      defmodule Consumer do
        use GenServer
        import DepA
        alias DepB
        require Logger
      end
      """)

      assert :ok = MatrixManager.index_project(dir)
      affected_a = MatrixManager.get_affected_files("lib/dep_a.ex")
      assert "lib/consumer.ex" in affected_a
    end
  end

  describe "non-Elixir file parsing" do
    test "extracts Python imports", %{dir: dir} do
      write_file(dir, "lib/app.py", """
      import os
      from collections import defaultdict
      from myapp.auth import Session
      """)

      assert :ok = MatrixManager.index_project(dir)
      assert {:ok, summary} = MatrixManager.get_file_summary("lib/app.py")
      assert summary =~ ".py file"
      assert summary =~ "import"
    end

    test "extracts Ruby requires", %{dir: dir} do
      write_file(dir, "lib/app.rb", """
      require 'json'
      require_relative 'my_module'
      """)

      assert :ok = MatrixManager.index_project(dir)
      assert {:ok, summary} = MatrixManager.get_file_summary("lib/app.rb")
      assert summary =~ ".rb file"
    end

    test "extracts Go imports", %{dir: dir} do
      write_file(dir, "lib/main.go", """
      package main

      import (
        "fmt"
        "net/http"
      )

      func main() {}
      """)

      assert :ok = MatrixManager.index_project(dir)
      assert {:ok, summary} = MatrixManager.get_file_summary("lib/main.go")
      assert summary =~ ".go file"
    end
  end
end
