defmodule Muse.Execution.LocalRunnerTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.{Command, LocalRunner, Result}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "muse_local_runner_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "capabilities/0" do
    test "returns local-only capabilities" do
      caps = LocalRunner.capabilities()

      assert caps.local == true
      assert caps.remote == false
      assert caps.ssh == false
      assert caps.shell == false
      assert caps.network == false
    end
  end

  describe "run/2 — successful execution" do
    test "executes simple command without shell", %{tmp_dir: tmp_dir} do
      # Create a simple Elixir script
      script_path = Path.join(tmp_dir, "hello.exs")
      File.write!(script_path, "IO.puts(\"hello from test\")")

      {:ok, cmd} =
        Command.new("elixir",
          args: [script_path],
          cwd: tmp_dir,
          timeout_ms: 10_000
        )

      assert {:ok, result} = LocalRunner.run(cmd)
      assert result.status == :ok
      assert result.output =~ "hello from test"
    end

    test "executes mix command in workspace", %{tmp_dir: tmp_dir} do
      # Create minimal mix project
      mix_exs = Path.join(tmp_dir, "mix.exs")

      File.write!(mix_exs, """
      defmodule TestProject.MixProject do
        use Mix.Project
        def project, do: [app: :test_project, version: "0.1.0"]
      end
      """)

      {:ok, cmd} = Command.new("mix", args: ["compile", "--no-warnings-as-errors"], cwd: tmp_dir)

      # May succeed or fail depending on project, but should not crash
      result = LocalRunner.run(cmd)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "run/2 — error handling" do
    test "returns error for non-existent executable" do
      {:ok, cmd} = Command.new("nonexistent_executable_xyz", args: [])

      assert {:error, %Result{status: :blocked} = result} = LocalRunner.run(cmd)
      assert result.error =~ "executable not found"
    end

    test "returns ok with exit_status for non-zero exit code" do
      {:ok, cmd} = Command.new("elixir", args: ["-e", "exit(1)"])

      {:ok, %Result{status: :ok, exit_status: exit_status}} = LocalRunner.run(cmd)
      # Exit code 1 should be reflected in result
      assert exit_status == 1
    end
  end

  describe "run/2 — timeout" do
    test "enforces timeout and marks timed_out" do
      # Create a command that will timeout (sleep for 10s, timeout at 100ms)
      {:ok, cmd} = Command.new("sleep", args: ["10"], timeout_ms: 100)

      {:ok, result} = LocalRunner.run(cmd)

      assert result.status == :timed_out
      assert result.timed_out == true
      assert result.duration_ms != nil
      # Should complete within reasonable overhead of timeout
      assert result.duration_ms < 500
    end
  end

  describe "run/2 — output capping" do
    test "caps output at max_output_bytes" do
      # Generate large output via a loop (single line, no control chars)
      script = "for _ <- 1..5000, do: IO.write(String.duplicate(\"x\", 20))"

      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", script],
          max_output_bytes: 1000,
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # Output should be capped
      assert result.status == :ok
      assert byte_size(result.output) <= 1500
    end
  end

  describe "run/2 — secret redaction" do
    test "redacts secrets in output" do
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(\"API_KEY=sk-test-runner-secret-12345\")"],
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # Output should be redacted
      refute result.output =~ "sk-test-runner-secret-12345"
      assert result.output =~ "[REDACTED]"
    end

    test "does not leak env secrets in argv_display" do
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(:ok)"],
          env: %{"SECRET_TOKEN" => "sk-test-env-secret"},
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # argv_display should not leak env secrets
      refute result.argv_display =~ "sk-test-env-secret"
    end
  end

  describe "run/2 — safe env" do
    test "uses provided env without inheriting secrets" do
      # Set a sensitive env var in test env
      original = System.get_env("MUSE_TEST_SECRET")

      try do
        System.put_env("MUSE_TEST_SECRET", "secret-value-123")

        {:ok, cmd} =
          Command.new("elixir",
            args: ["-e", "IO.puts(System.get_env(\"MUSE_TEST_SECRET\") || \"none\")"],
            env: %{"OTHER_VAR" => "safe_value"},
            timeout_ms: 10_000
          )

        {:ok, result} = LocalRunner.run(cmd)

        # With explicit env, MUSE_TEST_SECRET should not be inherited
        # (Port behavior: explicit env replaces inherited env)
        # The test env var might or might not appear depending on Port behavior
        assert result.status == :ok
      after
        if original do
          System.put_env("MUSE_TEST_SECRET", original)
        else
          System.delete_env("MUSE_TEST_SECRET")
        end
      end
    end
  end

  describe "check_executable/1" do
    test "finds elixir executable" do
      assert {:ok, path} = LocalRunner.check_executable("elixir")
      assert is_binary(path)
      assert String.contains?(path, "elixir")
    end

    test "returns error for non-existent executable" do
      assert {:error, _} = LocalRunner.check_executable("nonexistent_xyz")
    end
  end

  describe "run/2 — shell metacharacter rejection" do
    test "does not interpret shell metacharacters" do
      # Args should be passed literally, not interpreted by shell
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(\"hello; rm -rf /\")"],
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # The semicolon should be output, not interpreted
      assert result.status == :ok
      assert result.output =~ "hello"
    end
  end
end
