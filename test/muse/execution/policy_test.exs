defmodule Muse.Execution.PolicyTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.{Command, Policy}

  describe "resolve_target/1" do
    test "allows :local target" do
      assert {:ok, Muse.Execution.LocalRunner} = Policy.resolve_target(:local)
    end

    test "allows nil target" do
      assert {:ok, Muse.Execution.LocalRunner} = Policy.resolve_target(nil)
    end

    test "denies :remote target" do
      assert {:error, reason} = Policy.resolve_target(:remote)
      assert reason =~ "remote execution is denied"
    end

    test "denies :ssh target" do
      assert {:error, reason} = Policy.resolve_target(:ssh)
      assert reason =~ "SSH execution is denied"
    end

    test "denies string target (hostname)" do
      assert {:error, reason} = Policy.resolve_target("example.com")
      assert reason =~ "not recognized" or reason =~ "denied"
    end

    test "denies string 'remote'" do
      assert {:error, reason} = Policy.resolve_target("remote")
      assert reason =~ "remote execution is denied"
    end

    test "denies string 'ssh'" do
      assert {:error, reason} = Policy.resolve_target("ssh")
      assert reason =~ "SSH execution is denied"
    end

    test "allows string 'local'" do
      assert {:ok, Muse.Execution.LocalRunner} = Policy.resolve_target("local")
    end
  end

  describe "target_allowed?/1" do
    test "returns true for :local" do
      assert Policy.target_allowed?(:local)
    end

    test "returns true for nil" do
      assert Policy.target_allowed?(nil)
    end

    test "returns false for :remote" do
      refute Policy.target_allowed?(:remote)
    end

    test "returns false for :ssh" do
      refute Policy.target_allowed?(:ssh)
    end

    test "returns false for string targets" do
      refute Policy.target_allowed?("example.com")
      refute Policy.target_allowed?("192.168.1.1")
    end
  end

  describe "target_denied?/1" do
    test "returns false for :local" do
      refute Policy.target_denied?(:local)
    end

    test "returns false for nil" do
      refute Policy.target_denied?(nil)
    end

    test "returns true for :remote" do
      assert Policy.target_denied?(:remote)
    end

    test "returns true for :ssh" do
      assert Policy.target_denied?(:ssh)
    end

    test "returns true for string targets" do
      assert Policy.target_denied?("example.com")
    end
  end

  describe "validate_command/1" do
    test "validates local command" do
      {:ok, cmd} = Command.new("elixir", target: :local)
      assert :ok = Policy.validate_command(cmd)
    end

    test "rejects remote command" do
      {:ok, cmd} = Command.new("elixir", target: :remote)
      assert {:error, reason} = Policy.validate_command(cmd)
      assert reason =~ "remote execution is denied"
    end

    test "rejects ssh command" do
      {:ok, cmd} = Command.new("elixir", target: :ssh)
      assert {:error, reason} = Policy.validate_command(cmd)
      assert reason =~ "SSH execution is denied"
    end
  end

  describe "get_runner/1" do
    test "returns LocalRunner for local target" do
      {:ok, cmd} = Command.new("elixir", target: :local)
      assert {:ok, Muse.Execution.LocalRunner} = Policy.get_runner(cmd)
    end

    test "returns error for remote target" do
      {:ok, cmd} = Command.new("elixir", target: :remote)
      assert {:error, _} = Policy.get_runner(cmd)
    end
  end

  describe "remote_execution_denied?/1" do
    test "always returns true regardless of context" do
      assert Policy.remote_execution_denied?(%{})
      assert Policy.remote_execution_denied?(%{approval: :granted})
      assert Policy.remote_execution_denied?(%{plan_status: :approved})
      assert Policy.remote_execution_denied?(%{muse_id: :admin})
    end
  end

  describe "remote_tool_blocked?/1" do
    test "blocks remote_execution tool name" do
      assert Policy.remote_tool_blocked?("remote_execution")
    end

    test "blocks ssh_exec tool name" do
      assert Policy.remote_tool_blocked?("ssh_exec")
    end

    test "blocks ssh_run tool name" do
      assert Policy.remote_tool_blocked?("ssh_run")
    end

    test "blocks remote_run tool name" do
      assert Policy.remote_tool_blocked?("remote_run")
    end

    test "does not block other tool names" do
      refute Policy.remote_tool_blocked?("read_file")
      refute Policy.remote_tool_blocked?("list_files")
      refute Policy.remote_tool_blocked?("test_runner")
    end
  end

  describe "allowed_targets/0" do
    test "returns list with :local and nil" do
      allowed = Policy.allowed_targets()
      assert :local in allowed
      assert nil in allowed
    end
  end

  describe "denied_targets/0" do
    test "returns list with :remote and :ssh" do
      denied = Policy.denied_targets()
      assert :remote in denied
      assert :ssh in denied
    end
  end

  describe "no String.to_atom/1 on user input" do
    test "handles string targets without atom conversion" do
      # These should not create atoms from arbitrary strings
      targets = [
        "malicious_atom_creation",
        "user@host.com",
        "192.168.1.1",
        "server.example.com:22",
        "$(cat /etc/passwd)"
      ]

      for target <- targets do
        # Should not raise or create atoms
        result = Policy.resolve_target(target)
        assert match?({:error, _}, result)
      end
    end
  end

  # Phase B regression: remote execution remains denied even with approved
  # remote_execution approval context
  describe "remote execution denied with approval context (Phase B regression)" do
    test "remote_execution_denied? returns true even with approved remote approval" do
      # Simulate an approved remote_execution approval in context
      approved_context = %{
        approval: %{kind: :remote_execution, status: :approved},
        target_id: "tgt_staging_web_1",
        command_hash: "abc123"
      }

      assert Policy.remote_execution_denied?(approved_context) == true
    end

    test "remote_execution_denied? returns true for any context shape" do
      contexts = [
        %{approval: :granted},
        %{approval: %{kind: :remote_execution, status: :approved, scope: :single_command}},
        %{plan_status: :approved, muse_id: :admin, remote_approval: %{}},
        %{}
      ]

      for ctx <- contexts do
        assert Policy.remote_execution_denied?(ctx) == true
      end
    end

    test "remote_tool_blocked? still blocks remote tool names" do
      assert Policy.remote_tool_blocked?("remote_execution")
      assert Policy.remote_tool_blocked?("ssh_exec")
      assert Policy.remote_tool_blocked?("ssh_run")
      assert Policy.remote_tool_blocked?("remote_run")
    end

    test "resolve_target still denies :remote and :ssh" do
      assert {:error, _} = Policy.resolve_target(:remote)
      assert {:error, _} = Policy.resolve_target(:ssh)
    end
  end
end
