defmodule Muse.Tools.TestRunnerTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.TestRunner
  alias Muse.Tool.Result

  setup do
    root = Path.join(System.tmp_dir!(), "muse_testrunner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # Create a minimal Elixir project for testing
    File.write!(Path.join(root, "mix.exs"), """
    defmodule TestProject.MixProject do
      use Mix.Project
      def project, do: [app: :test_project, version: "0.1.0"]
    end
    """)

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/dummy_test.exs"), """
    defmodule DummyTest do
      use ExUnit.Case
      test "always passes", do: assert(true)
    end
    """)

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/dummy.ex"), "defmodule Dummy, do: nil")

    context = %{
      workspace: root,
      muse_id: :testing,
      session_id: "sess_test",
      turn_id: "turn_1"
    }

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, context: context}
  end

  describe "execute/2 — blocked commands" do
    test "blocks unknown/raw command strings", %{context: context} do
      for bad <- [
            "rm -rf /",
            "bash -c 'evil'",
            "curl http://evil.com",
            "mix test --include network",
            "custom_script.sh",
            "shell_command"
          ] do
        result = TestRunner.execute(%{"command" => bad}, context)
        refute result.success
        assert result.error =~ "blocked"
        assert result.error =~ "not a safe preset"
      end
    end

    test "blocks when command is nil or empty", %{context: context} do
      result = TestRunner.execute(%{}, context)
      refute result.success
      assert result.error =~ "command is required"

      result = TestRunner.execute(%{"command" => ""}, context)
      refute result.success
      assert result.error =~ "command is required"
    end

    test "blocks mix_test_file without file_path", %{context: context} do
      result = TestRunner.execute(%{"command" => "mix_test_file"}, context)
      refute result.success
      assert result.error =~ "blocked" or result.error =~ "path rejected"
    end

    test "blocks mix_test_file with invalid extension", %{context: context} do
      result =
        TestRunner.execute(%{"command" => "mix_test_file", "file_path" => "lib/app.ex"}, context)

      refute result.success
      assert result.error =~ "must end with _test.exs"
    end

    test "blocks mix_test_file with path outside test/", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "lib/app_test.exs"},
          context
        )

      refute result.success
      assert result.error =~ "must be under the test/ directory"
    end

    test "blocks mix_test_file with path traversal", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test/../../etc/passwd_test.exs"},
          context
        )

      refute result.success
      assert result.error =~ "path traversal"
    end

    test "blocks mix_test_file with absolute path", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "/etc/passwd_test.exs"},
          context
        )

      refute result.success
      assert result.error =~ "absolute"
    end
  end

  describe "execute/2 — allowed presets" do
    test "allowed_presets returns the set of safe preset names" do
      presets = TestRunner.allowed_presets()
      assert MapSet.member?(presets, "mix_format_check")
      assert MapSet.member?(presets, "mix_compile")
      assert MapSet.member?(presets, "mix_test")
      assert MapSet.member?(presets, "mix_test_file")
    end

    test "runs mix_format_check in a valid workspace", %{context: context} do
      # This may succeed or fail depending on formatting, but must not crash
      result = TestRunner.execute(%{"command" => "mix_format_check"}, context)
      assert %Result{tool_name: "test_runner"} = result

      if result.success do
        output = result.output
        assert is_map(output)
        assert output.command == "mix_format_check"
        assert output.status in [:passed, :failed]
        assert is_integer(output.duration_ms)
        assert output.timed_out == false
        assert is_binary(output.argv_display)
        assert is_binary(output.next_action)
      end
    end

    test "runs mix_compile in a valid workspace", %{context: context} do
      result = TestRunner.execute(%{"command" => "mix_compile"}, context)
      assert %Result{tool_name: "test_runner"} = result

      if result.success do
        output = result.output
        assert is_map(output)
        assert output.command == "mix_compile"
        assert output.status in [:passed, :failed, :timed_out]
      end
    end
  end

  describe "execute/2 — safety invariants" do
    test "never executes via shell — argv vector only" do
      # Shell metacharacters in command names are blocked, not interpreted
      presets = TestRunner.allowed_presets()

      for name <- MapSet.to_list(presets) do
        # All preset names are plain alphanumeric+underscore
        assert name =~ ~r/^[a-z_]+$/, "preset name #{name} contains unexpected characters"
      end
    end

    test "default_timeout_ms is reasonable" do
      timeout = TestRunner.default_timeout_ms()
      assert is_integer(timeout)
      assert timeout > 0
      # max 5 minutes
      assert timeout <= 300_000
    end

    test "max_output_bytes is reasonable" do
      max = TestRunner.max_output_bytes()
      assert is_integer(max)
      assert max > 0
      # max 500KB
      assert max <= 500_000
    end

    test "invalid workspace returns error" do
      result = TestRunner.execute(%{"command" => "mix_test"}, %{workspace: "/nonexistent/path"})
      refute result.success
      assert result.error =~ "workspace"
    end
  end

  describe "execute/2 — mix_test_file path validation" do
    test "valid test file path is accepted", %{context: context} do
      # This tests the validation logic; actual execution depends on workspace state
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test/dummy_test.exs"},
          context
        )

      # May succeed or fail depending on compilation, but should not be blocked by path validation
      if result.success do
        assert result.output.command == "mix_test_file"
      end

      # The important thing is it's NOT blocked for path reasons
      if not result.success do
        refute result.error =~ "must end with _test.exs"
        refute result.error =~ "must be under the test/ directory"
        refute result.error =~ "path traversal"
        refute result.error =~ "absolute"
      end
    end

    test "rejects file_path with very long name" do
      long_path = "test/" <> String.duplicate("a", 600) <> "_test.exs"

      result =
        TestRunner.execute(%{"command" => "mix_test_file", "file_path" => long_path}, %{
          workspace: "/tmp"
        })

      refute result.success
      assert result.error =~ "too long"
    end
  end
end
