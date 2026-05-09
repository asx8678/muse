defmodule Muse.Auth.BearerCommandTest do
  use ExUnit.Case, async: true

  alias Muse.Auth.BearerCommand

  # ---------------------------------------------------------------------------
  # Basic resolve/1 tests
  # ---------------------------------------------------------------------------

  describe "resolve/1 basic" do
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
  end

  # ---------------------------------------------------------------------------
  # Runner injection
  # ---------------------------------------------------------------------------

  describe "resolve/1 runner injection" do
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
  end

  # ---------------------------------------------------------------------------
  # Argv list command
  # ---------------------------------------------------------------------------

  describe "resolve/1 argv list" do
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
  end

  # ---------------------------------------------------------------------------
  # Timeout (runner-based)
  # ---------------------------------------------------------------------------

  describe "resolve/1 timeout via runner" do
    test "timeout returns safe error via injected runner that sleeps" do
      runner = fn _cmd ->
        :timer.sleep(100)
        {"too-late", 0}
      end

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
  end

  # ---------------------------------------------------------------------------
  # Invalid/non-positive timeout_ms safely defaults
  # ---------------------------------------------------------------------------

  describe "resolve/1 invalid timeout defaults" do
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
  end

  # ---------------------------------------------------------------------------
  # Multi-line output parsing
  # ---------------------------------------------------------------------------

  describe "resolve/1 multi-line output" do
    test "multi-line output uses last non-empty line (bearer token is typically last)" do
      runner = fn _cmd -> {"header-line\n\nsecond-line\ntok-third", 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "multi-line",
                 allow_exec?: true,
                 runner: runner
               )

      # Bearer tokens are on the last line; earlier lines may be diagnostics
      assert cred.value == "tok-third"
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
  end

  # ---------------------------------------------------------------------------
  # Runner edge cases
  # ---------------------------------------------------------------------------

  describe "resolve/1 runner edge cases" do
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

  # ---------------------------------------------------------------------------
  # T1-09: Bounded stdout — output_too_large
  # ---------------------------------------------------------------------------

  describe "resolve/1 output_too_large (T1-09)" do
    test "runner output exceeding max_stdout_bytes returns output_too_large" do
      # 100-byte limit, runner returns 200 bytes
      huge_output = String.duplicate("a", 200)

      runner = fn _cmd -> {huge_output, 0} end

      assert {:error, {:output_too_large, "bearer_command"}} =
               BearerCommand.resolve(
                 command: "huge",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: 100
               )
    end

    test "output_too_large includes custom source_label" do
      huge_output = String.duplicate("x", 500)

      runner = fn _cmd -> {huge_output, 0} end

      assert {:error, {:output_too_large, "my-label"}} =
               BearerCommand.resolve(
                 command: "huge",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: 100,
                 source_label: "my-label"
               )
    end

    test "output exactly at max_stdout_bytes succeeds" do
      # 100-byte limit, runner returns exactly 100 bytes of valid token
      token = "tok-" <> String.duplicate("a", 96)

      runner = fn _cmd -> {token, 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "exact",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: 100
               )

      assert cred.value == token
    end

    test "output one byte over max_stdout_bytes fails" do
      # 100-byte limit, runner returns 101 bytes
      output = String.duplicate("a", 101)

      runner = fn _cmd -> {output, 0} end

      assert {:error, {:output_too_large, "bearer_command"}} =
               BearerCommand.resolve(
                 command: "over",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: 100
               )
    end

    test "real command producing huge stdout returns output_too_large" do
      # Use a real command (printf) to generate output exceeding the limit.
      # This tests the port-based bounded execution path.
      assert {:error, {:output_too_large, "bearer_command"}} =
               BearerCommand.resolve(
                 command: "printf '#{String.duplicate("a", 200)}'",
                 allow_exec?: true,
                 max_stdout_bytes: 100
               )
    end

    test "default max_stdout_bytes is 4096" do
      assert BearerCommand.default_max_stdout_bytes() == 4_096
    end

    test "invalid max_stdout_bytes defaults to 4096" do
      token = "tok-valid"

      runner = fn _cmd -> {token, 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "test",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: nil
               )

      assert cred.value == token
    end

    test "zero max_stdout_bytes defaults to 4096" do
      token = "tok-valid"

      runner = fn _cmd -> {token, 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "test",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: 0
               )

      assert cred.value == token
    end

    test "negative max_stdout_bytes defaults to 4096" do
      token = "tok-valid"

      runner = fn _cmd -> {token, 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "test",
                 allow_exec?: true,
                 runner: runner,
                 max_stdout_bytes: -1
               )

      assert cred.value == token
    end
  end

  # ---------------------------------------------------------------------------
  # T1-09: Timeout with real command (port-based execution)
  # ---------------------------------------------------------------------------

  describe "resolve/1 timeout with real command (T1-09)" do
    test "real command that sleeps times out with explicit error" do
      assert {:error, {:timeout, "bearer_command"}} =
               BearerCommand.resolve(
                 command: "sleep 10",
                 allow_exec?: true,
                 timeout_ms: 100
               )
    end

    test "timeout with real command includes custom source_label" do
      assert {:error, {:timeout, "my-timeout-label"}} =
               BearerCommand.resolve(
                 command: "sleep 10",
                 allow_exec?: true,
                 timeout_ms: 100,
                 source_label: "my-timeout-label"
               )
    end
  end

  # ---------------------------------------------------------------------------
  # T1-09: Secret safety in error messages
  # ---------------------------------------------------------------------------

  describe "resolve/1 secret safety in errors (T1-09)" do
    test "output_too_large error never contains the token value" do
      secret = "sk-super-secret-key-12345"
      huge_output = secret <> String.duplicate("x", 500)

      runner = fn _cmd -> {huge_output, 0} end

      result =
        BearerCommand.resolve(
          command: "secret-cmd",
          allow_exec?: true,
          runner: runner,
          max_stdout_bytes: 100
        )

      case result do
        {:error, {:output_too_large, _label}} ->
          error_str = inspect(result)
          refute error_str =~ secret

        other ->
          flunk("Expected output_too_large error, got: #{inspect(other)}")
      end
    end

    test "exec_failed error for nonzero exit never contains stdout" do
      secret = "sk-leaked-in-stderr-or-stdout"
      runner = fn _cmd -> {secret, 1} end

      result =
        BearerCommand.resolve(
          command: "leaky",
          allow_exec?: true,
          runner: runner
        )

      case result do
        {:error, {:exec_failed, _msg}} ->
          error_str = inspect(result)
          refute error_str =~ secret

        other ->
          flunk("Expected exec_failed error, got: #{inspect(other)}")
      end
    end

    test "timeout error never contains partial output" do
      runner = fn _cmd ->
        :timer.sleep(100)
        {"secret-partial-token", 0}
      end

      result =
        BearerCommand.resolve(
          command: "slow-leak",
          allow_exec?: true,
          runner: runner,
          timeout_ms: 10
        )

      case result do
        {:error, {:timeout, _label}} ->
          error_str = inspect(result)
          refute error_str =~ "secret-partial-token"

        other ->
          flunk("Expected timeout error, got: #{inspect(other)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # T1-09: Valid small token output succeeds
  # ---------------------------------------------------------------------------

  describe "resolve/1 valid small token (T1-09)" do
    test "real echo command produces valid credential" do
      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "echo valid-small-token",
                 allow_exec?: true
               )

      assert cred.type == :bearer
      assert cred.source == :command
      assert cred.value == "valid-small-token"
      assert cred.redacted =~ "REDACTED"
      refute cred.redacted =~ "valid-small-token"
    end

    test "argv list command with real echo produces valid credential" do
      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: ["echo", "argv-token"],
                 allow_exec?: true
               )

      assert cred.value == "argv-token"
    end

    test "JWT-shaped token succeeds" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.sig123"

      runner = fn _cmd -> {jwt, 0} end

      assert {:ok, cred} =
               BearerCommand.resolve(
                 command: "jwt-cmd",
                 allow_exec?: true,
                 runner: runner
               )

      assert cred.value == jwt
    end

    test "non-printable output fails with exec_failed" do
      runner = fn _cmd -> {"tok\x00bad", 0} end

      assert {:error, {:exec_failed, msg}} =
               BearerCommand.resolve(
                 command: "nonprint",
                 allow_exec?: true,
                 runner: runner
               )

      assert msg =~ "non-printable"
    end
  end

  # ---------------------------------------------------------------------------
  # T1-09: Port execution safety
  # ---------------------------------------------------------------------------

  describe "resolve/1 port execution safety (T1-09)" do
    test "stderr is captured and bounded — no leak to BEAM console" do
      # Write a canary to stderr; it should NOT appear in the return value
      # and should be counted toward max_stdout_bytes.
      # With :stderr_to_stdout, both streams are captured and bounded.
      # Use argv list to preserve shell script as single -c argument.
      result =
        BearerCommand.resolve(
          command: ["sh", "-c", "echo STDERR_CANARY_BC >&2; echo tok-stderr-test"],
          allow_exec?: true
        )

      # The credential should still resolve (stderr is captured, token on stdout)
      assert {:ok, cred} = result
      assert cred.value == "tok-stderr-test"

      # The canary must NOT leak into error messages or inspect output
      refute inspect(result) =~ "STDERR_CANARY_BC"
    end

    test "stderr canary does not appear in error output when command fails" do
      result =
        BearerCommand.resolve(
          command: ["sh", "-c", "echo STDERR_CANARY_FAIL >&2; exit 1"],
          allow_exec?: true
        )

      assert {:error, {:exec_failed, _msg}} = result
      refute inspect(result) =~ "STDERR_CANARY_FAIL"
    end

    test "argv list with non-string args returns exec_failed" do
      # Non-binary args should be rejected safely, not crash Port.open
      assert {:error, {:exec_failed, msg}} =
               BearerCommand.resolve(
                 command: ["echo", 123],
                 allow_exec?: true
               )

      assert msg =~ "string"
    end

    test "Port.open failure returns safe exec_failed error" do
      # An absolute path to a non-executable file should fail gracefully
      tmp_path = System.tmp_dir!()
      non_exec = Path.join(tmp_path, "bearer_test_not_exec_#{:erlang.unique_integer()}")
      File.write!(non_exec, "not executable")

      try do
        assert {:error, {:exec_failed, _msg}} =
                 BearerCommand.resolve(
                   command: non_exec,
                   allow_exec?: true
                 )
      after
        File.rm(non_exec)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # T1-09: Configuration accessors
  # ---------------------------------------------------------------------------

  describe "configuration defaults (T1-09)" do
    test "default_timeout_ms returns 5000" do
      assert BearerCommand.default_timeout_ms() == 5_000
    end

    test "default_max_stdout_bytes returns 4096" do
      assert BearerCommand.default_max_stdout_bytes() == 4_096
    end
  end
end
