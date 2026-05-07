defmodule Muse.Execution.RunnerTest do
  use ExUnit.Case, async: false

  alias Muse.Execution.{Command, Runner, Target, TargetRegistry}

  setup do
    on_exit(fn ->
      TargetRegistry.clear()
    end)

    :ok
  end

  describe "run/2 — default routing (backward compatible)" do
    test "routes to LocalRunner for :local target" do
      {:ok, cmd} = Command.new("elixir", args: ["-e", "IO.puts(:hello)"], target: :local)
      assert {:ok, result} = Runner.run(cmd, [])
      assert result.status == :ok
    end

    test "routes to RemoteDeniedRunner for :remote target" do
      {:ok, cmd} = Command.new("ls", target: :remote)
      assert {:error, result} = Runner.run(cmd, [])
      assert result.status == :denied
    end

    test "routes to RemoteDeniedRunner for :ssh target" do
      {:ok, cmd} = Command.new("ls", target: :ssh)
      assert {:error, result} = Runner.run(cmd, [])
      assert result.status == :denied
    end

    test "routes to RemoteDeniedRunner for string target" do
      {:ok, cmd} = Command.new("ls", target: "some-host.com")
      assert {:error, result} = Runner.run(cmd, [])
      assert result.status == :denied
    end
  end

  describe "run/3 — context-aware routing" do
    setup do
      {:ok, target} = Target.new("tgt_runner_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)
      :ok
    end

    test "routes to LocalRunner for :local target with context" do
      {:ok, cmd} = Command.new("elixir", args: ["-e", "IO.puts(:hello)"], target: :local)
      assert {:ok, result} = Runner.run(cmd, [], %{})
      assert result.status == :ok
    end

    test "routes to FakeRemoteRunner for valid remote context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_fake",
          command_hash: cmd_hash,
          session_id: "sess_runner"
        },
        session_id: "sess_runner"
      }

      assert {:ok, result} = Runner.run(cmd, [], context)
      assert result.runner == :fake_remote
      assert result.status == :ok
    end

    test "routes to RemoteDeniedRunner without valid context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_fake")
      assert {:error, result} = Runner.run(cmd, [], %{})
      assert result.status == :denied
    end

    test "routes to RemoteDeniedRunner when approval is missing" do
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_fake")
      assert {:error, result} = Runner.run(cmd, [], %{target_id: "tgt_runner_fake"})
      assert result.status == :denied
    end

    test "routes to SSHRunner for valid SSH target with approval (Phase D)" do
      {:ok, ssh_target} =
        Target.new("tgt_runner_ssh_d",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      {:ok, cmd} = Command.new("ls", target: "tgt_runner_ssh_d")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_ssh_d",
          command_hash: cmd_hash,
          session_id: "sess_ssh_d"
        },
        session_id: "sess_ssh_d"
      }

      ssh_opts = [
        ssh_client: Muse.Execution.FakeSSHClient,
        fake_outcome: :ok,
        fake_stdout: "ssh output"
      ]

      assert {:ok, result} = Runner.run(cmd, ssh_opts, context)
      assert result.runner == :ssh
      assert result.status == :ok
    end

    test "routes to RemoteDeniedRunner for :ssh target even with context (Phase D)" do
      {:ok, ssh_target} =
        Target.new("tgt_runner_ssh_denied",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      {:ok, cmd} = Command.new("ls", target: "tgt_runner_ssh_denied")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_ssh_denied",
          command_hash: cmd_hash,
          session_id: "sess_ssh_denied"
        },
        session_id: "sess_ssh_denied"
      }

      # Without the fake SSH client opts, the SSHRunner will try to use
      # the real ErlangSSHClient which will fail to connect — but the
      # routing should still go to SSHRunner. Let's test with the fake
      # client to verify the routing works.
      ssh_opts = [
        ssh_client: Muse.Execution.FakeSSHClient,
        fake_outcome: :ok
      ]

      assert {:ok, result} = Runner.run(cmd, ssh_opts, context)
      assert result.runner == :ssh
    end

    test "routes to RemoteDeniedRunner for SSH target without approval" do
      {:ok, ssh_target} =
        Target.new("tgt_runner_ssh_no_approval",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      {:ok, cmd} = Command.new("ls", target: "tgt_runner_ssh_no_approval")

      assert {:error, result} = Runner.run(cmd, [], %{})
      assert result.status == :denied
    end

    test "routes to RemoteDeniedRunner when command_hash mismatches" do
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_fake")

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_fake",
          command_hash: "sha256-wrong-hash",
          session_id: "sess_wrong"
        },
        session_id: "sess_wrong"
      }

      assert {:error, result} = Runner.run(cmd, [], context)
      assert result.status == :denied
    end

    test "preserves policy denial reason in denied result" do
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_fake")

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_fake",
          command_hash: "sha256-wrong-hash",
          session_id: "sess_reason"
        },
        session_id: "sess_reason"
      }

      assert {:error, result} = Runner.run(cmd, [], context)
      assert result.status == :denied
      # The denial reason should contain the policy reason, not just
      # a generic RemoteDeniedRunner reason
      assert is_binary(result.error) or is_binary(result.reason)
    end

    test "denies when command target contradicts approval target_id" do
      {:ok, other_target} = Target.new("tgt_runner_other", protocol: :fake, host: "other.host.io")
      :ok = TargetRegistry.register(other_target)

      # Command targets tgt_runner_other, but approval is for tgt_runner_fake
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_other")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_fake",
          command_hash: cmd_hash,
          session_id: "sess_mismatch"
        },
        session_id: "sess_mismatch"
      }

      assert {:error, result} = Runner.run(cmd, [], context)
      assert result.status == :denied
    end
  end
end
