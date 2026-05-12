defmodule Muse.Tools.QueryMatrixTest do
  use ExUnit.Case, async: false

  alias Muse.MatrixManager
  alias Muse.Tools.QueryMatrix

  # -- Helpers ------------------------------------------------------------------

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "qm_test_#{:erlang.unique_integer([:positive])}")
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

  setup do
    dir = tmp_dir()
    File.mkdir_p!(dir)

    on_exit(fn ->
      stop_matrix()
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  # -- Tests --------------------------------------------------------------------

  describe "execute/2" do
    test "returns error when query is missing" do
      result = QueryMatrix.execute(%{}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "query is required"
    end

    test "returns error when query is empty string" do
      result = QueryMatrix.execute(%{"query" => ""}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "query is required"
    end

    test "returns error when max_results is invalid" do
      result =
        QueryMatrix.execute(%{"query" => "foo", "max_results" => "abc"}, %{workspace: "/tmp"})

      refute result.success
      assert result.error =~ "max_results"
    end

    test "queries matrix and returns ranked results", %{dir: dir} do
      write_file(dir, "lib/auth.ex", """
      defmodule MyApp.Auth do
        def authenticate(user, password), do: :ok
        def authorize(user, resource), do: :ok
      end
      """)

      write_file(dir, "lib/session.ex", """
      defmodule MyApp.Session do
        def start(opts), do: {:ok, opts}
      end
      """)

      init_git(dir)
      start_matrix(root: dir, max_files: 50)
      :ok = MatrixManager.index_project(dir)

      result = QueryMatrix.execute(%{"query" => "auth"}, %{workspace: dir})
      assert result.success
      assert result.output.query == "auth"
      assert is_list(result.output.results)
      assert length(result.output.results) >= 1
      assert result.output.total >= 1

      # The auth file should rank highest
      paths = Enum.map(result.output.results, & &1.path)
      assert "lib/auth.ex" in paths
    end

    test "respects max_results parameter", %{dir: dir} do
      for i <- 1..5 do
        write_file(dir, "lib/mod_#{i}.ex", """
        defmodule MyApp.Mod#{i} do
          def authenticate(x), do: x
        end
        """)
      end

      init_git(dir)
      start_matrix(root: dir, max_files: 50)
      :ok = MatrixManager.index_project(dir)

      result =
        QueryMatrix.execute(%{"query" => "authenticate", "max_results" => 2}, %{workspace: dir})

      assert result.success
      assert length(result.output.results) <= 2
    end

    test "returns error when matrix manager is not available" do
      stop_matrix()
      result = QueryMatrix.execute(%{"query" => "test"}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "matrix manager not available"
    end

    test "auto-triggers indexing when matrix is empty", %{dir: dir} do
      write_file(dir, "lib/foo.ex", """
      defmodule MyApp.Foo do
        def bar, do: :baz
      end
      """)

      init_git(dir)
      start_matrix(root: dir, max_files: 50)

      # The matrix starts empty because no index_project call yet.
      # QueryMatrix should auto-trigger indexing.
      result = QueryMatrix.execute(%{"query" => "foo"}, %{workspace: dir})
      assert result.success
      assert is_list(result.output.results)
    end
  end
end
