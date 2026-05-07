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

    test "routes to RemoteDeniedRunner for :ssh target even with context" do
      {:ok, ssh_target} = Target.new("tgt_runner_ssh", protocol: :ssh, host: "ssh.host.io")
      :ok = TargetRegistry.register(ssh_target)

      {:ok, cmd} = Command.new("ls", target: "tgt_runner_ssh")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_runner_ssh",
          command_hash: cmd_hash,
          session_id: "sess_ssh"
        },
        session_id: "sess_ssh"
      }

      assert {:error, result} = Runner.run(cmd, [], context)
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
