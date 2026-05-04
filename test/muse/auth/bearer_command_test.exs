defmodule Muse.Auth.BearerCommandTest do
  use ExUnit.Case, async: true

  alias Muse.Auth.BearerCommand

  describe "resolve/1" do
    test "returns not_allowed error when allow_exec? is false (default)" do
      assert {:error, {:not_allowed, "bearer_command"}} =
               BearerCommand.resolve(command: "echo tok-secret")
    end

    test "returns no_command error when command is nil" do
      assert {:error, {:no_command, "bearer_command"}} =
               BearerCommand.resolve()
    end

    test "returns no_command error when command is empty" do
      assert {:error, {:no_command, "bearer_command"}} =
               BearerCommand.resolve(command: "")
    end

    test "returns exec_failed for nonexistent command" do
      assert {:error, {:exec_failed, _reason}} =
               BearerCommand.resolve(
                 command: "./nonexistent_command_12345",
                 allow_exec?: true
               )
    end

    test "returns empty_output for command that produces only whitespace" do
      assert {:error, :empty_output} =
               BearerCommand.resolve(
                 command: "echo",
                 allow_exec?: true
               )
    end

    test "returns ok credential for command that outputs a token" do
      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "echo tok-test-value",
                 allow_exec?: true
               )

      assert cred.type == :bearer
      assert cred.source == :command
      assert cred.value == "tok-test-value"
    end

    test "redacted field never includes raw token" do
      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "echo sk-secret-key-12345",
                 allow_exec?: true
               )

      assert cred.redacted =~ "REDACTED"
      refute cred.redacted =~ "sk-secret-key-12345"
    end

    test "inspect never includes raw token" do
      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "echo sensitive-value",
                 allow_exec?: true
               )

      inspected = inspect(cred)
      assert inspected =~ "REDACTED"
      refute inspected =~ "sensitive-value"
    end

    test "uses custom source_label in error messages" do
      assert {:error, {:not_allowed, "my-custom-label"}} =
               BearerCommand.resolve(
                 command: "echo tok",
                 source_label: "my-custom-label"
               )

      assert {:error, {:no_command, "my-custom-label"}} =
               BearerCommand.resolve(
                 command: nil,
                 source_label: "my-custom-label"
               )
    end

    # -----------------------------------------------------------------------
    # Runner injection
    # -----------------------------------------------------------------------

    test "runner with {output, 0} returns ok credential" do
      runner = fn _cmd -> {"tok-from-runner", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner
               )

      assert cred.type == :bearer
      assert cred.source == :command
      assert cred.value == "tok-from-runner"
    end

    test "runner with {:ok, output} returns ok credential" do
      runner = fn _cmd -> {:ok, "tok-with-envelope"} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner
               )

      assert cred.value == "tok-with-envelope"
    end

    test "runner with {:error, reason} returns exec_failed safely" do
      runner = fn _cmd -> {:error, :some_failure} end

      assert {:error, {:exec_failed, _msg}} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner
               )
    end

    test "runner that raises returns exec_failed safely" do
      runner = fn _cmd -> raise "oh no" end

      assert {:error, {:exec_failed, _msg}} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner
               )
    end

    test "runner is not invoked when allow_exec? is false" do
      runner = fn _cmd -> raise "should not be called" end

      assert {:error, {:not_allowed, "bearer_command"}} =
               BearerCommand.resolve(
                 command: "echo tok",
                 allow_exec?: false,
                 runner: runner
               )
    end

    test ":cmd_fn alias works like :runner" do
      cmd_fn = fn _cmd -> {"tok-from-cmd-fn", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 cmd_fn: cmd_fn
               )

      assert cred.value == "tok-from-cmd-fn"
    end

    # -----------------------------------------------------------------------
    # Argv list command
    # -----------------------------------------------------------------------

    test "argv list with runner works correctly" do
      runner = fn ["echo", "hello", "world"] -> {"hello-world-token", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: ["echo", "hello", "world"],
                 allow_exec?: true,
                 runner: runner
               )

      assert cred.value == "hello-world-token"
    end

    test "empty argv list returns no_command error" do
      assert {:error, {:no_command, "bearer_command"}} =
               BearerCommand.resolve(
                 command: [],
                 allow_exec?: true
               )
    end

    test "argv list with non-binary first element returns no_command error" do
      assert {:error, {:no_command, "bearer_command"}} =
               BearerCommand.resolve(
                 command: [42],
                 allow_exec?: true
               )
    end

    # -----------------------------------------------------------------------
    # Timeout
    # -----------------------------------------------------------------------

    test "timeout returns safe error via injected runner that sleeps" do
      runner = fn _cmd ->
        :timer.sleep(100)
        {"too-late", 0}
      end

      # Use tiny timeout_ms so the runner's sleep triggers timeout
      assert {:error, {:timeout, _label}} =
               BearerCommand.resolve(
                 command: "sleepy",
                 allow_exec?: true,
                 runner: runner,
                 timeout_ms: 10
               )
    end

    test "timeout returns source_label in error tuple" do
      runner = fn _cmd ->
        :timer.sleep(100)
        {"too-late", 0}
      end

      assert {:error, {:timeout, "my-sleepy-label"}} =
               BearerCommand.resolve(
                 command: "sleepy",
                 allow_exec?: true,
                 runner: runner,
                 timeout_ms: 10,
                 source_label: "my-sleepy-label"
               )
    end

    # -----------------------------------------------------------------------
    # Invalid/non-positive timeout_ms safely defaults
    # -----------------------------------------------------------------------

    test "nil timeout_ms defaults to 5000" do
      runner = fn _cmd -> {"tok-from-nil-timeout", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner,
                 timeout_ms: nil
               )

      assert cred.value == "tok-from-nil-timeout"
    end

    test "zero timeout_ms defaults to 5000" do
      runner = fn _cmd -> {"tok-from-zero-timeout", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner,
                 timeout_ms: 0
               )

      assert cred.value == "tok-from-zero-timeout"
    end

    test "negative timeout_ms defaults to 5000" do
      runner = fn _cmd -> {"tok-from-negative-timeout", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "ignored",
                 allow_exec?: true,
                 runner: runner,
                 timeout_ms: -100
               )

      assert cred.value == "tok-from-negative-timeout"
    end

    # -----------------------------------------------------------------------
    # Multi-line output parsing
    # -----------------------------------------------------------------------

    test "multi-line output uses first non-empty line" do
      runner = fn _cmd -> {"header-line\n\nsecond-line\nthird", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "multi-line",
                 allow_exec?: true,
                 runner: runner
               )

      assert cred.value == "header-line"
    end

    test "leading whitespace in output is trimmed" do
      runner = fn _cmd -> {"  \n  tok-padded  \n", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "padded",
                 allow_exec?: true,
                 runner: runner
               )

      assert cred.value == "tok-padded"
    end

    # -----------------------------------------------------------------------
    # Runner edge cases — nonzero exit, empty output
    # -----------------------------------------------------------------------

    test "runner returning {output, nonzero} treated as exec_failed" do
      runner = fn _cmd -> {"some-output", 1} end

      assert {:error, {:exec_failed, _msg}} =
               BearerCommand.resolve(
                 command: "failing",
                 allow_exec?: true,
                 runner: runner
               )
    end

    test "runner returning unexpected data structure is safe" do
      runner = fn _cmd -> :not_a_tuple end

      assert {:error, {:exec_failed, _msg}} =
               BearerCommand.resolve(
                 command: "weird",
                 allow_exec?: true,
                 runner: runner
               )
    end
  end
end
