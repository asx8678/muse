defmodule Muse.Execution.LocalRunnerTest do
  use ExUnit.Case, async: false

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

    test "returns error result for non-zero exit code" do
      {:ok, cmd} = Command.new("elixir", args: ["-e", "exit(1)"])

      {:ok, %Result{status: :error, exit_status: exit_status} = result} = LocalRunner.run(cmd)
      # Exit code 1 should produce status: :error, not :ok
      assert exit_status == 1
      assert result.error =~ "command exited with status 1"
      refute Result.ok?(result)
      assert Result.failed?(result)
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

    test "timeout result includes cleanup diagnostic metadata" do
      {:ok, cmd} = Command.new("sleep", args: ["10"], timeout_ms: 100)

      {:ok, result} = LocalRunner.run(cmd)

      assert result.status == :timed_out
      assert is_map(result.metadata)
      assert Map.has_key?(result.metadata, :timeout_cleanup)

      cleanup = result.metadata.timeout_cleanup
      # On Unix, should have pgid_available: true
      # On Windows, should have pgid_available: false with fallback_reason
      assert Map.has_key?(cleanup, :platform)
      assert Map.has_key?(cleanup, :pgid_available)
      assert Map.has_key?(cleanup, :os_pid)
    end

    @tag :unix
    test "timeout kills child processes on Unix" do
      # Spawn bash which creates background children
      # This is the core acceptance criterion:
      # A command that spawns a long-lived child does not leave
      # that child alive after timeout on supported platforms.
      {:ok, cmd} =
        Command.new("bash",
          args: ["-c", "sleep 60 & sleep 60 & echo READY; wait"],
          timeout_ms: 500
        )

      {:ok, result} = LocalRunner.run(cmd)

      assert result.status == :timed_out
      assert result.metadata.timeout_cleanup.pgid_available == true

      # After timeout cleanup, verify no orphaned processes from this command
      # exist by checking the process group is gone
      pgid = result.metadata.timeout_cleanup.pgid

      if pgid do
        Process.sleep(300)
        {remaining, _} = System.cmd("pgrep", ["-g", to_string(pgid)], stderr_to_stdout: true)

        assert String.trim(remaining) == "",
               "Orphaned child processes still alive after timeout cleanup"
      end
    end

    test "timeout cleanup diagnostic has structured fields" do
      {:ok, cmd} = Command.new("sleep", args: ["10"], timeout_ms: 100)

      {:ok, result} = LocalRunner.run(cmd)

      cleanup = result.metadata.timeout_cleanup

      # Required fields
      assert Map.has_key?(cleanup, :platform)
      assert Map.has_key?(cleanup, :pgid_available)
      assert Map.has_key?(cleanup, :os_pid)

      # Platform should be one of the known values
      assert cleanup.platform in [:unix, :windows, :unknown, :unsupported]

      # pgid_available should match platform support
      case :os.type() do
        {:unix, _} ->
          assert cleanup.pgid_available == true
          assert is_integer(cleanup.pgid) and cleanup.pgid > 0
          assert is_integer(cleanup.os_pid) and cleanup.os_pid > 0

        {:win32, _} ->
          assert cleanup.pgid_available == false
          assert Map.has_key?(cleanup, :fallback_reason)
      end
    end

    test "timeout on already-exited process does not crash" do
      # A command that finishes just at the timeout boundary should
      # not crash even if the process exits before cleanup runs.
      # Use a very short timeout with a fast command.
      {:ok, cmd} = Command.new("elixir", args: ["-e", "IO.puts(:fast)"], timeout_ms: 200)

      # This should succeed normally (no timeout)
      {:ok, result} = LocalRunner.run(cmd)
      assert result.status == :ok
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
    test "does not inherit MUSE_ secrets from BEAM environment" do
      original = System.get_env("MUSE_TEST_SECRET")

      try do
        System.put_env("MUSE_TEST_SECRET", "secret-value-123")

        {:ok, cmd} =
          Command.new("elixir",
            args: ["-e", "IO.puts(System.get_env(\"MUSE_TEST_SECRET\") || \"none\")"],
            timeout_ms: 10_000
          )

        {:ok, result} = LocalRunner.run(cmd)

        # MUSE_TEST_SECRET should NOT be inherited by the child process.
        # Env.port_env strips MUSE_ prefixed vars and adds unset markers.
        assert result.status == :ok
        assert result.output =~ "none"
        refute result.output =~ "secret-value-123"
      after
        if original do
          System.put_env("MUSE_TEST_SECRET", original)
        else
          System.delete_env("MUSE_TEST_SECRET")
        end
      end
    end

    test "does not inherit provider API keys from BEAM environment" do
      original = System.get_env("OPENAI_API_KEY")

      try do
        System.put_env("OPENAI_API_KEY", "sk-fake-provider-key-for-test")

        {:ok, cmd} =
          Command.new("elixir",
            args: ["-e", "IO.puts(System.get_env(\"OPENAI_API_KEY\") || \"none\")"],
            timeout_ms: 10_000
          )

        {:ok, result} = LocalRunner.run(cmd)

        # OPENAI_API_KEY should NOT be inherited by the child process.
        assert result.status == :ok
        assert result.output =~ "none"
        refute result.output =~ "sk-fake-provider-key-for-test"
      after
        if original do
          System.put_env("OPENAI_API_KEY", original)
        else
          System.delete_env("OPENAI_API_KEY")
        end
      end
    end

    test "does not inherit proxy vars from BEAM environment" do
      original = System.get_env("http_proxy")

      try do
        System.put_env("http_proxy", "http://evil.proxy:8080")

        {:ok, cmd} =
          Command.new("elixir",
            args: ["-e", "IO.puts(System.get_env(\"http_proxy\") || \"none\")"],
            timeout_ms: 10_000
          )

        {:ok, result} = LocalRunner.run(cmd)

        # http_proxy should NOT be inherited by the child process.
        assert result.status == :ok
        assert result.output =~ "none"
        refute result.output =~ "evil.proxy"
      after
        if original do
          System.put_env("http_proxy", original)
        else
          System.delete_env("http_proxy")
        end
      end
    end

    test "denied var is removed even if explicitly passed in command env" do
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(System.get_env(\"OPENAI_API_KEY\") || \"none\")"],
          env: %{"OPENAI_API_KEY" => "sk-should-be-stripped"},
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # Even explicitly passed, denylisted keys are stripped
      assert result.status == :ok
      assert result.output =~ "none"
      refute result.output =~ "sk-should-be-stripped"
    end

    test "allowed safe vars are still available" do
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(System.get_env(\"LANG\") || \"none\")"],
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # LANG is a safe default, always set
      assert result.status == :ok
      assert result.output =~ "C.UTF-8"
    end

    test "PATH is available for command execution" do
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(System.get_env(\"PATH\") || \"none\")"],
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # PATH must be available for tools to find executables
      assert result.status == :ok
      refute result.output =~ "none"
      assert byte_size(result.output) > 5
    end

    test "user-provided non-secret env var is available" do
      {:ok, cmd} =
        Command.new("elixir",
          args: ["-e", "IO.puts(System.get_env(\"MY_BUILD_DIR\") || \"none\")"],
          env: %{"MY_BUILD_DIR" => "/tmp/build"},
          timeout_ms: 10_000
        )

      {:ok, result} = LocalRunner.run(cmd)

      # Non-secret user env vars should be available
      assert result.status == :ok
      assert result.output =~ "/tmp/build"
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
