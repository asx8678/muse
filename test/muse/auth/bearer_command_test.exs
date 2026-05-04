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
  end
end
