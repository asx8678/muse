defmodule Muse.Tools.TestInShadowTest do
  use ExUnit.Case, async: false

  alias Muse.ActiveVFS
  alias Muse.Tools.TestInShadow
  alias Muse.Tool.Result

  @moduletag :unix
  @moduletag timeout: 300_000

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_elixir_project! do
    dir = Path.join(System.tmp_dir!(), "muse_tis_elixir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule TestProject.MixProject do
      use Mix.Project
      def project, do: [app: :test_project, version: "0.1.0"]
    end
    """)

    File.mkdir_p!(Path.join(dir, "test"))
    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(dir, "test/dummy_test.exs"), """
    defmodule DummyTest do
      use ExUnit.Case
      test "always passes", do: assert(true)
    end
    """)

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/dummy.ex"), "defmodule Dummy, do: nil")

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp create_js_project! do
    dir = Path.join(System.tmp_dir!(), "muse_tis_js_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "package.json"), """
    {
      "name": "test-project",
      "scripts": {
        "test": "echo '1 passing'"
      }
    }
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp create_python_project! do
    dir = Path.join(System.tmp_dir!(), "muse_tis_py_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "pyproject.toml"), """
    [tool.pytest.ini_options]
    testpaths = ["tests"]
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp create_empty_project! do
    dir = Path.join(System.tmp_dir!(), "muse_tis_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README.md"), "# No framework here\n")

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp start_vfs!(root) do
    try do
      GenServer.stop(ActiveVFS, :shutdown)
    catch
      :exit, _ -> :ok
    end

    {:ok, _pid} = ActiveVFS.start_link(root: root, name: ActiveVFS)
    :ok
  end

  defp stop_vfs! do
    try do
      GenServer.stop(ActiveVFS, :shutdown)
    catch
      :exit, _ -> :ok
    end
  end

  defp context_for(workspace) do
    %{workspace: workspace, muse_id: :coding, session_id: "sess_test", turn_id: "turn_1"}
  end

  # ---------------------------------------------------------------------------
  # Argument validation
  # ---------------------------------------------------------------------------

  describe "execute/2 — argument validation" do
    test "returns error for invalid workspace" do
      result = TestInShadow.execute(%{}, %{workspace: "/nonexistent/xyz"})
      refute result.success
      assert result.error =~ "workspace"
    end
  end

  # ---------------------------------------------------------------------------
  # Framework detection
  # ---------------------------------------------------------------------------

  describe "execute/2 — framework detection" do
    test "detects Elixir project via mix.exs" do
      project = create_elixir_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      assert %Result{tool_name: "test_in_shadow"} = result
      assert result.success
      assert result.output.framework == :elixir
      assert result.output.command == "mix test"
    end

    test "detects JavaScript project via package.json with test script" do
      project = create_js_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      assert result.success
      assert result.output.framework == :javascript
      assert result.output.command == "npm test"
    end

    test "detects Python project via pyproject.toml" do
      project = create_python_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      assert result.success
      assert result.output.framework == :python
      assert result.output.command == "pytest"
    end

    test "returns error when no test framework detected" do
      project = create_empty_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      refute result.success
      assert result.error =~ "no test framework detected"
    end

    test "allows forcing a specific framework" do
      project = create_elixir_project!()

      result =
        TestInShadow.execute(
          %{"framework" => "elixir"},
          context_for(project)
        )

      assert result.success
      assert result.output.framework == :elixir
    end

    test "returns error for unknown forced framework" do
      project = create_empty_project!()

      result =
        TestInShadow.execute(
          %{"framework" => "ruby"},
          context_for(project)
        )

      refute result.success
      assert result.error =~ "unknown framework"
    end
  end

  # ---------------------------------------------------------------------------
  # Elixir test execution
  # ---------------------------------------------------------------------------

  describe "execute/2 — Elixir test execution" do
    test "runs mix test and returns structured result" do
      project = create_elixir_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      assert result.success
      output = result.output
      assert is_integer(output.exit_code)
      assert is_integer(output.duration_ms)
      assert output.duration_ms >= 0
      assert output.framework == :elixir
      assert is_map(output.test_counts)
      assert is_binary(output.summary)
      assert is_boolean(output.passed)
      assert is_boolean(output.timed_out)
    end

    test "test_counts map has expected keys" do
      project = create_elixir_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      assert result.success
      counts = result.output.test_counts
      assert Map.has_key?(counts, :total)
      assert Map.has_key?(counts, :passed)
      assert Map.has_key?(counts, :failed)
      assert Map.has_key?(counts, :skipped)
    end

    test "shadow is destroyed after test execution" do
      project = create_elixir_project!()

      before_count = count_shadow_dirs()
      TestInShadow.execute(%{}, context_for(project))
      after_count = count_shadow_dirs()
      assert after_count == before_count
    end
  end

  # ---------------------------------------------------------------------------
  # VFS overlay
  # ---------------------------------------------------------------------------

  describe "execute/2 — VFS overlay in test" do
    setup do
      project = create_elixir_project!()
      start_vfs!(project)

      on_exit(fn ->
        stop_vfs!()
      end)

      {:ok, project: project}
    end

    test "overlays VFS-modified files for test execution", %{project: project} do
      # Modify a test file via VFS
      {:ok, _v0} = ActiveVFS.checkout("test/dummy_test.exs", agent_id: "test-agent")

      new_content = """
      defmodule DummyTest do
        use ExUnit.Case
        test "modified test passes", do: assert(1 + 1 == 2)
      end
      """

      {:ok, _v1} =
        ActiveVFS.commit("test/dummy_test.exs", new_content, "test-agent", "modify test")

      result =
        TestInShadow.execute(
          %{"files_to_include" => ["test/dummy_test.exs"]},
          context_for(project)
        )

      assert result.success
      assert result.output.passed == true
      # Original test file should still be the old one
      assert File.read!(Path.join(project, "test/dummy_test.exs")) =~ "always passes"
    end
  end

  # ---------------------------------------------------------------------------
  # Output parsing
  # ---------------------------------------------------------------------------

  describe "output parsing" do
    test "parses Elixir ExUnit output" do
      output = "12 tests, 0 failures\n\nFinished in 0.03 seconds\n"
      counts = TestInShadow.parse_elixir_output(output)
      assert counts.total == 12
      assert counts.passed == 12
      assert counts.failed == 0
    end

    test "parses Elixir output with failures" do
      output = "8 tests, 2 failures\n\nFinished in 0.05 seconds\n"
      counts = TestInShadow.parse_elixir_output(output)
      assert counts.total == 8
      assert counts.failed == 2
      assert counts.passed == 6
    end

    test "parses Elixir output with skipped" do
      output = "10 tests, 1 failures, 2 skipped\n\nFinished in 0.04 seconds\n"
      counts = TestInShadow.parse_elixir_output(output)
      assert counts.total == 10
      assert counts.failed == 1
      assert counts.skipped == 2
      assert counts.passed == 7
    end

    test "parses Jest-style JavaScript output" do
      output = "Tests:  12 passed, 0 failed, 12 total"
      counts = TestInShadow.parse_javascript_output(output)
      assert counts.total == 12
      assert counts.passed == 12
      assert counts.failed == 0
    end

    test "parses Mocha-style JavaScript output" do
      output = "  5 passing\n  1 failing\n"
      counts = TestInShadow.parse_javascript_output(output)
      assert counts.passed == 5
      assert counts.failed == 1
      assert counts.total == 6
    end

    test "parses pytest output with passed only" do
      output = "12 passed in 1.23s"
      counts = TestInShadow.parse_python_output(output)
      assert counts.passed == 12
      assert counts.failed == 0
    end

    test "parses pytest output with failures" do
      output = "10 passed, 2 failed in 1.23s"
      counts = TestInShadow.parse_python_output(output)
      assert counts.passed == 10
      assert counts.failed == 2
      assert counts.total == 12
    end

    test "parses pytest output with skipped" do
      output = "10 passed, 1 skipped, 2 failed in 1.23s"
      counts = TestInShadow.parse_python_output(output)
      assert counts.passed == 10
      assert counts.skipped == 1
      assert counts.failed == 2
      assert counts.total == 13
    end

    test "returns zero counts for unparseable output" do
      for output <- ["", "random text", "no test results here"] do
        counts = TestInShadow.parse_elixir_output(output)
        assert counts == %{total: 0, passed: 0, failed: 0, skipped: 0}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Summary construction
  # ---------------------------------------------------------------------------

  describe "summary construction" do
    test "summary includes test count info" do
      project = create_elixir_project!()

      result = TestInShadow.execute(%{}, context_for(project))

      assert result.success
      assert is_binary(result.output.summary)
      # Summary should mention test count or passed
      assert result.output.summary =~ ~r/\d+ test/
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp count_shadow_dirs do
    base = Path.join(System.tmp_dir!(), "muse_shadows")

    case File.ls(base) do
      {:ok, entries} -> length(entries)
      {:error, _} -> 0
    end
  end
end
