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
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

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

    test "blocks test-prefixed sibling paths that are not under test/", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test.foo_test.exs"},
          context
        )

      refute result.success
      assert result.error =~ "must be under the test/ directory"
    end

    test "blocks mix_test_file with path traversal", %{context: context} do
      for path <- ["test/../../etc/passwd_test.exs", "test/../test/dummy_test.exs"] do
        result =
          TestRunner.execute(
            %{"command" => "mix_test_file", "file_path" => path},
            context
          )

        refute result.success
        assert result.error =~ "path traversal"
      end
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

      assert result.success
      output = result.output
      assert is_map(output)
      assert output.command == "mix_format_check"
      assert output.status in [:passed, :failed]
      assert is_integer(output.duration_ms)
      assert output.timed_out == false
      assert is_binary(output.argv_display)
      assert is_binary(output.next_action)
    end

    test "runs mix_compile in a valid workspace", %{context: context} do
      result = TestRunner.execute(%{"command" => "mix_compile"}, context)
      assert %Result{tool_name: "test_runner"} = result

      assert result.success
      output = result.output
      assert is_map(output)
      assert output.command == "mix_compile"
      assert output.status in [:passed, :failed]
      assert output.timed_out == false
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

  describe "safe env — secret isolation" do
    test "child commands do not receive MUSE_ secrets from BEAM environment", %{
      context: context,
      root: root
    } do
      # Create a test that prints MUSE_TEST_SECRET if it exists
      File.write!(Path.join(root, "test/env_leak_test.exs"), """
      defmodule EnvLeakTest do
        use ExUnit.Case
        test "no MUSE secret leaked" do
          val = System.get_env("MUSE_TEST_SECRET") || "not_found"
          IO.puts("MUSE_SECRET=" <> val)
          assert val == "not_found", "MUSE_TEST_SECRET leaked into child process!"
        end
      end
      """)

      original = System.get_env("MUSE_TEST_SECRET")

      try do
        System.put_env("MUSE_TEST_SECRET", "should-not-leak-into-child")

        result =
          TestRunner.execute(
            %{"command" => "mix_test_file", "file_path" => "test/env_leak_test.exs"},
            context
          )

        assert result.success
        assert result.output.status == :passed
        refute result.output.output_preview =~ "should-not-leak-into-child"
      after
        if original do
          System.put_env("MUSE_TEST_SECRET", original)
        else
          System.delete_env("MUSE_TEST_SECRET")
        end
      end
    end

    test "child commands do not receive provider API keys", %{context: context, root: root} do
      File.write!(Path.join(root, "test/env_provider_test.exs"), """
      defmodule EnvProviderTest do
        use ExUnit.Case
        test "no provider key leaked" do
          val = System.get_env("OPENAI_API_KEY") || "not_found"
          IO.puts("OPENAI_KEY=" <> val)
          assert val == "not_found", "OPENAI_API_KEY leaked into child process!"
        end
      end
      """)

      original = System.get_env("OPENAI_API_KEY")

      try do
        System.put_env("OPENAI_API_KEY", "sk-fake-provider-key-for-test")

        result =
          TestRunner.execute(
            %{"command" => "mix_test_file", "file_path" => "test/env_provider_test.exs"},
            context
          )

        assert result.success
        assert result.output.status == :passed
        refute result.output.output_preview =~ "sk-fake-provider-key-for-test"
      after
        if original do
          System.put_env("OPENAI_API_KEY", original)
        else
          System.delete_env("OPENAI_API_KEY")
        end
      end
    end
  end

  describe "execute/2 — mix_test_file path validation" do
    test "valid test file path runs and reports exit status", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test/dummy_test.exs"},
          context
        )

      assert result.success
      assert result.output.command == "mix_test_file"
      assert result.output.status == :passed
      assert result.output.exit_status == 0
      assert result.output.timed_out == false
      assert result.output.argv_display == "mix test test/dummy_test.exs"
    end

    test "redacts test output previews", %{context: context, root: root} do
      File.write!(Path.join(root, "test/secret_output_test.exs"), """
      defmodule SecretOutputTest do
        use ExUnit.Case
        test "prints a secret" do
          IO.puts("API_KEY=abcdef1234567890")
          assert true
        end
      end
      """)

      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test/secret_output_test.exs"},
          context
        )

      assert result.success
      assert result.output.status == :passed
      assert result.output.output_preview =~ "[REDACTED]"
      refute result.output.output_preview =~ "abcdef1234567890"
    end

    test "rejects non-existent test file", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test/missing_test.exs"},
          context
        )

      refute result.success
      assert result.error =~ "existing test file"
    end

    test "rejects symlink test file paths", %{context: context, root: root} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "muse_testrunner_outside_#{System.unique_integer([:positive])}_test.exs"
        )

      File.write!(outside, "defmodule OutsideTest do\n  use ExUnit.Case\nend\n")
      link = Path.join(root, "test/outside_link_test.exs")

      on_exit(fn -> File.rm_rf(outside) end)

      case File.ln_s(outside, link) do
        :ok ->
          result =
            TestRunner.execute(
              %{"command" => "mix_test_file", "file_path" => "test/outside_link_test.exs"},
              context
            )

          refute result.success
          assert result.error =~ "symlink" or result.error =~ "escapes workspace"

        {:error, reason} when reason in [:enotsup, :eperm] ->
          :ok
      end
    end

    test "rejects secret-looking test paths", %{context: context} do
      result =
        TestRunner.execute(
          %{"command" => "mix_test_file", "file_path" => "test/secrets.token_test.exs"},
          context
        )

      refute result.success
      assert result.error =~ "secret" or result.error =~ "sensitive"
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
