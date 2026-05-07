defmodule Muse.Execution.PolicyTest do
  use ExUnit.Case, async: false

  alias Muse.Execution.{Command, Policy, Target, TargetRegistry}

  # TargetRegistry is started by base_children/0 in the application supervisor.
  # We only need to interact with it for context-aware routing tests.

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

  describe "remote_execution_denied?/1 — default deny (no registry)" do
    test "always returns true for empty context" do
      assert Policy.remote_execution_denied?(%{}) == true
    end

    test "returns true for arbitrary approved-looking maps" do
      assert Policy.remote_execution_denied?(%{approval: :granted}) == true
      assert Policy.remote_execution_denied?(%{plan_status: :approved}) == true
      assert Policy.remote_execution_denied?(%{muse_id: :admin}) == true
    end

    test "returns true for approval with wrong kind" do
      assert Policy.remote_execution_denied?(%{approval: %{kind: :plan, status: :approved}}) ==
               true
    end

    test "returns true for approval with wrong status" do
      assert Policy.remote_execution_denied?(%{
               approval: %{kind: :remote_execution, status: :pending}
             }) == true
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
      targets = [
        "malicious_atom_creation",
        "user@host.com",
        "192.168.1.1",
        "server.example.com:22",
        "$(cat /etc/passwd)"
      ]

      for target <- targets do
        result = Policy.resolve_target(target)
        assert match?({:error, _}, result)
      end
    end
  end

  # -- Phase B regression: remote execution remains denied even with
  #     approved-looking context (arbitrary maps) -----------------------------

  describe "remote execution denied with approval context (Phase B regression)" do
    test "remote_execution_denied? returns true even with approved remote approval without target" do
      approved_context = %{
        approval: %{kind: :remote_execution, status: :approved},
        target_id: "tgt_staging_web_1",
        command_hash: "abc123"
      }

      # No registered target, so still denied
      assert Policy.remote_execution_denied?(approved_context) == true
    end

    test "remote_execution_denied? returns true for any context shape without valid routing" do
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

    test "resolve_target/1 still denies :remote and :ssh" do
      assert {:error, _} = Policy.resolve_target(:remote)
      assert {:error, _} = Policy.resolve_target(:ssh)
    end
  end

  # -- Phase C: Context-aware routing ------------------------------------------
  # These tests register targets in the TargetRegistry (which is started
  # by base_children/0) and clean up after themselves.

  describe "resolve_target/2 — context-aware routing" do
    setup do
      # Register targets for this describe block
      {:ok, target} = Target.new("tgt_ctx_fake_1", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      {:ok, ssh_target} =
        Target.new("tgt_ctx_ssh_1",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      on_exit(fn ->
        TargetRegistry.clear()
      end)

      :ok
    end

    test "routes to LocalRunner for :local target with context" do
      assert {:ok, Muse.Execution.LocalRunner} = Policy.resolve_target(:local, %{})
    end

    test "routes to FakeRemoteRunner for registered :fake target with valid approval" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_fake_1")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ctx_fake_1",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} =
               Policy.resolve_target("tgt_ctx_fake_1", context)
    end

    test "routes to FakeRemoteRunner using context target_id" do
      {:ok, cmd} = Command.new("ls", target: :remote)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ctx_fake_1",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        target_id: "tgt_ctx_fake_1",
        session_id: "sess_1",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target(:remote, context)
    end

    test "denies when approval kind is wrong" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_fake_1")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :plan,
          status: :approved,
          target_id: "tgt_ctx_fake_1",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:error, _} = Policy.resolve_target("tgt_ctx_fake_1", context)
    end

    test "denies when approval status is not :approved" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_fake_1")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :pending,
          target_id: "tgt_ctx_fake_1",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:error, _} = Policy.resolve_target("tgt_ctx_fake_1", context)
    end

    test "denies when target_id is not registered" do
      {:ok, cmd} = Command.new("ls", target: "nonexistent_target")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "nonexistent_target",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:error, _} = Policy.resolve_target("nonexistent_target", context)
    end

    test "denies when target protocol is :ssh without valid approval" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_ssh_1")

      # No approval — should be denied
      assert {:error, _} = Policy.resolve_target("tgt_ctx_ssh_1", %{})
    end

    test "routes to SSHRunner for registered :ssh target with valid approval" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_ssh_1")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ctx_ssh_1",
          command_hash: cmd_hash,
          session_id: "sess_ssh_1"
        },
        session_id: "sess_ssh_1",
        command: cmd
      }

      assert {:ok, Muse.Execution.SSHRunner} =
               Policy.resolve_target("tgt_ctx_ssh_1", context)
    end

    test "denies when command_hash mismatches" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_fake_1")
      wrong_hash = "sha256-deadbeef"

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ctx_fake_1",
          command_hash: wrong_hash,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:error, _} = Policy.resolve_target("tgt_ctx_fake_1", context)
    end

    test "denies when approval is expired" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_fake_1")
      cmd_hash = Command.command_hash(cmd)

      past = DateTime.add(DateTime.utc_now(), -600, :second)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ctx_fake_1",
          command_hash: cmd_hash,
          expires_at: past,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:error, _} = Policy.resolve_target("tgt_ctx_fake_1", context)
    end

    test "denies when no approval in context" do
      assert {:error, _} = Policy.resolve_target("tgt_ctx_fake_1", %{target_id: "tgt_ctx_fake_1"})
    end

    test "routes via remote_approval key in context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ctx_fake_1")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        remote_approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ctx_fake_1",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        session_id: "sess_1",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} =
               Policy.resolve_target("tgt_ctx_fake_1", context)
    end
  end

  describe "validate_command/2 — context-aware" do
    setup do
      {:ok, target} = Target.new("tgt_val_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "validates remote command with valid context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_val_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_val_fake",
          command_hash: cmd_hash,
          session_id: "sess_val"
        },
        session_id: "sess_val"
      }

      assert :ok = Policy.validate_command(cmd, context)
    end

    test "rejects remote command without valid context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_val_fake")
      assert {:error, _} = Policy.validate_command(cmd, %{})
    end
  end

  describe "get_runner/2 — context-aware" do
    setup do
      {:ok, target} = Target.new("tgt_runner_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "returns FakeRemoteRunner with valid context" do
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

      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.get_runner(cmd, context)
    end

    test "returns error without valid context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_runner_fake")
      assert {:error, _} = Policy.get_runner(cmd, %{})
    end
  end

  describe "remote_execution_denied?/1 — Phase C context-aware" do
    setup do
      {:ok, target} = Target.new("tgt_denied_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      {:ok, ssh_target} =
        Target.new("tgt_denied_ssh",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "returns false when all conditions met for fake target" do
      {:ok, cmd} = Command.new("ls", target: "tgt_denied_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_denied_fake",
          command_hash: cmd_hash,
          session_id: "sess_denied"
        },
        session_id: "sess_denied",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false
    end

    test "returns false for SSH target with valid approval (Phase D)" do
      # Need to register SSH target with required fields
      {:ok, ssh_target} =
        Target.new("tgt_denied_ssh",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      try do
        {:ok, cmd} = Command.new("ls", target: "tgt_denied_ssh")
        cmd_hash = Command.command_hash(cmd)

        context = %{
          approval: %{
            kind: :remote_execution,
            status: :approved,
            target_id: "tgt_denied_ssh",
            command_hash: cmd_hash,
            session_id: "sess_ssh"
          },
          session_id: "sess_ssh",
          command: cmd
        }

        assert Policy.remote_execution_denied?(context) == false
      after
        TargetRegistry.clear()
      end
    end

    test "returns true when approval is expired" do
      {:ok, cmd} = Command.new("ls", target: "tgt_denied_fake")
      cmd_hash = Command.command_hash(cmd)
      past = DateTime.add(DateTime.utc_now(), -600, :second)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_denied_fake",
          command_hash: cmd_hash,
          expires_at: past,
          session_id: "sess_exp"
        },
        session_id: "sess_exp",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "returns true when command_hash mismatches" do
      {:ok, cmd} = Command.new("ls", target: "tgt_denied_fake")

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_denied_fake",
          command_hash: "sha256-wrong",
          session_id: "sess_hash"
        },
        session_id: "sess_hash",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "returns true for arbitrary approved-looking maps (Phase B regression)" do
      # These should still return true — no registered target, no proper binding
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

    test "returns true for non-map input" do
      assert Policy.remote_execution_denied?(nil) == true
      assert Policy.remote_execution_denied?(:something) == true
    end
  end

  # -- Phase D: SSH protocol now routes to SSHRunner with valid approval -------

  describe "SSH protocol routing (Phase D)" do
    setup do
      {:ok, ssh_target} =
        Target.new("tgt_ssh_reg",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "resolve_target/1 still denies :ssh atom (no context)" do
      assert {:error, _} = Policy.resolve_target(:ssh)
    end

    test "resolve_target/2 routes to SSHRunner with valid approval" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_reg")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ssh_reg",
          command_hash: cmd_hash,
          session_id: "sess_ssh_reg"
        },
        session_id: "sess_ssh_reg",
        command: cmd
      }

      assert {:ok, Muse.Execution.SSHRunner} = Policy.resolve_target("tgt_ssh_reg", context)
    end

    test "resolve_target/2 denies :ssh atom with context (no registered target for :ssh atom)" do
      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ssh_reg",
          session_id: "sess_ssh_atom"
        },
        session_id: "sess_ssh_atom"
      }

      assert {:error, _} = Policy.resolve_target(:ssh, context)
    end

    test "remote_execution_denied? returns false for valid SSH approval" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_reg")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ssh_reg",
          command_hash: cmd_hash,
          session_id: "sess_ssh_denied"
        },
        session_id: "sess_ssh_denied",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false
    end

    test "remote_execution_denied? returns true for SSH target without approval" do
      context = %{target_id: "tgt_ssh_reg"}
      assert Policy.remote_execution_denied?(context) == true
    end
  end

  # -- Regression: no String.to_atom from target/protocol/user input -----------

  describe "no String.to_atom regression" do
    test "arbitrary target strings do not create atoms via resolve_target/1" do
      count_before = :erlang.system_info(:atom_count)

      for s <- ["malicious_atom_creation", "user@host.com", "192.168.1.1", "$(cat /etc/passwd)"] do
        assert {:error, _} = Policy.resolve_target(s)
      end

      count_after = :erlang.system_info(:atom_count)
      assert count_after - count_before < 5
    end

    test "arbitrary target strings do not create atoms via resolve_target/2" do
      count_before = :erlang.system_info(:atom_count)

      for s <- ["malicious_atom_creation", "user@host.com", "192.168.1.1", "$(cat /etc/passwd)"] do
        assert {:error, _} = Policy.resolve_target(s, %{})
      end

      count_after = :erlang.system_info(:atom_count)
      assert count_after - count_before < 5
    end
  end

  # -- Security: session_id binding ---------------------------------------------

  describe "session_id binding security" do
    setup do
      {:ok, target} = Target.new("tgt_sess_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "cross-session replay: approval from different session is denied" do
      {:ok, cmd} = Command.new("ls", target: "tgt_sess_fake")
      cmd_hash = Command.command_hash(cmd)

      # Approval was for sess_original, but context is for sess_attacker
      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_sess_fake",
          command_hash: cmd_hash,
          session_id: "sess_original"
        },
        session_id: "sess_attacker",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
      assert {:error, _} = Policy.resolve_target("tgt_sess_fake", context)
    end

    test "approval without session_id is denied (fail closed)" do
      {:ok, cmd} = Command.new("ls", target: "tgt_sess_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_sess_fake",
          command_hash: cmd_hash
          # no session_id!
        },
        session_id: "sess_1",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "context without session_id is denied (fail closed)" do
      {:ok, cmd} = Command.new("ls", target: "tgt_sess_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_sess_fake",
          command_hash: cmd_hash,
          session_id: "sess_1"
        },
        # no session_id in context!
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "valid approved fake route with matching session_id" do
      {:ok, cmd} = Command.new("ls", target: "tgt_sess_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_sess_fake",
          command_hash: cmd_hash,
          session_id: "sess_valid"
        },
        session_id: "sess_valid",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false

      assert {:ok, Muse.Execution.FakeRemoteRunner} =
               Policy.resolve_target("tgt_sess_fake", context)
    end
  end

  # -- Security: target_id context injection ------------------------------------

  describe "target_id context injection security" do
    setup do
      {:ok, fake_target} = Target.new("tgt_inject_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(fake_target)

      {:ok, ssh_target} =
        Target.new("tgt_inject_ssh",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      :ok = TargetRegistry.register(ssh_target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "context target_id that contradicts approval target_id is denied" do
      {:ok, cmd} = Command.new("ls", target: "tgt_inject_ssh")
      cmd_hash = Command.command_hash(cmd)

      # Approval says tgt_inject_fake, but context injects tgt_inject_ssh
      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_inject_fake",
          command_hash: cmd_hash,
          session_id: "sess_inject"
        },
        target_id: "tgt_inject_ssh",
        session_id: "sess_inject",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
      assert {:error, _} = Policy.resolve_target("tgt_inject_ssh", context)
    end

    test "approval without target_id is denied" do
      {:ok, cmd} = Command.new("ls", target: "tgt_inject_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          # no target_id!
          command_hash: cmd_hash,
          session_id: "sess_no_tid"
        },
        session_id: "sess_no_tid",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end
  end

  # -- Security: missing command_hash -------------------------------------------

  describe "missing command_hash security" do
    setup do
      {:ok, target} = Target.new("tgt_chash_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "approval without command_hash is denied (fail closed)" do
      {:ok, cmd} = Command.new("ls", target: "tgt_chash_fake")

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_chash_fake",
          session_id: "sess_chash"
          # no command_hash!
        },
        session_id: "sess_chash",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
      assert {:error, _} = Policy.resolve_target("tgt_chash_fake", context)
    end

    test "context without command is denied" do
      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_chash_fake",
          command_hash: "sha256-somehash",
          session_id: "sess_cmd"
        },
        session_id: "sess_cmd"
        # no command in context!
      }

      assert Policy.remote_execution_denied?(context) == true
    end
  end

  # -- Security: string kind/status support --------------------------------------

  describe "string kind/status support" do
    setup do
      {:ok, target} = Target.new("tgt_str_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "string 'remote_execution' kind is accepted" do
      {:ok, cmd} = Command.new("ls", target: "tgt_str_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          "kind" => "remote_execution",
          "status" => :approved,
          "target_id" => "tgt_str_fake",
          "command_hash" => cmd_hash,
          "session_id" => "sess_str"
        },
        session_id: "sess_str",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false
    end

    test "string 'approved' status is accepted" do
      {:ok, cmd} = Command.new("ls", target: "tgt_str_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: "approved",
          target_id: "tgt_str_fake",
          command_hash: cmd_hash,
          session_id: "sess_str_st"
        },
        session_id: "sess_str_st",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false
    end
  end

  # -- Security: ISO string expires_at support ----------------------------------

  describe "ISO string expires_at support" do
    setup do
      {:ok, target} = Target.new("tgt_iso_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "expired ISO string expires_at is treated as expired" do
      {:ok, cmd} = Command.new("ls", target: "tgt_iso_fake")
      cmd_hash = Command.command_hash(cmd)
      past = DateTime.add(DateTime.utc_now(), -600, :second) |> DateTime.to_iso8601()

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_iso_fake",
          command_hash: cmd_hash,
          expires_at: past,
          session_id: "sess_iso"
        },
        session_id: "sess_iso",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "unparseable expires_at is treated as expired (fail closed)" do
      {:ok, cmd} = Command.new("ls", target: "tgt_iso_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_iso_fake",
          command_hash: cmd_hash,
          expires_at: "not-a-date",
          session_id: "sess_bad_iso"
        },
        session_id: "sess_bad_iso",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end
  end

  # -- Security: command target vs approval target_id binding -------------------

  describe "command target vs approval target_id binding" do
    setup do
      {:ok, target_a} = Target.new("tgt_A", protocol: :fake, host: "fake-a.host.io")
      :ok = TargetRegistry.register(target_a)

      {:ok, target_b} = Target.new("tgt_B", protocol: :fake, host: "fake-b.host.io")
      :ok = TargetRegistry.register(target_b)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "command with target tgt_A must not route using approval for tgt_B" do
      # Build a command that targets tgt_A
      {:ok, cmd} = Command.new("ls", target: "tgt_A")
      cmd_hash = Command.command_hash(cmd)

      # Build an approval for tgt_B (wrong target)
      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_B",
          command_hash: cmd_hash,
          session_id: "sess_bind"
        },
        session_id: "sess_bind",
        command: cmd
      }

      # Must be denied — command target contradicts approval target_id
      assert {:error, _} = Policy.resolve_target("tgt_A", context)
    end

    test "remote_execution_denied? returns true when command target contradicts approval" do
      {:ok, cmd} = Command.new("ls", target: "tgt_A")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_B",
          command_hash: cmd_hash,
          session_id: "sess_bind_denied"
        },
        session_id: "sess_bind_denied",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "routing succeeds when command target matches approval target_id" do
      {:ok, cmd} = Command.new("ls", target: "tgt_A")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_A",
          command_hash: cmd_hash,
          session_id: "sess_bind_ok"
        },
        session_id: "sess_bind_ok",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target("tgt_A", context)
      assert Policy.remote_execution_denied?(context) == false
    end

    test ":remote atom command target does not conflict with approval target_id" do
      # :remote is a reserved atom — not a registered-target id
      {:ok, cmd} = Command.new("ls", target: :remote)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_A",
          command_hash: cmd_hash,
          session_id: "sess_remote_atom"
        },
        target_id: "tgt_A",
        session_id: "sess_remote_atom",
        command: cmd
      }

      # Should route to FakeRemoteRunner (approval's target_id is used)
      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target(:remote, context)
      assert Policy.remote_execution_denied?(context) == false
    end

    test "string 'remote' command target does not conflict with approval target_id" do
      # "remote" is a reserved string — not a registered-target id
      {:ok, cmd} = Command.new("ls", target: "remote")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_A",
          command_hash: cmd_hash,
          session_id: "sess_remote_str"
        },
        target_id: "tgt_A",
        session_id: "sess_remote_str",
        command: cmd
      }

      # Should route to FakeRemoteRunner (approval's target_id is used)
      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target("remote", context)
    end
  end

  # -- Security: target argument validation for resolve_target/2 --------------

  describe "resolve_target/2 — target argument validation" do
    setup do
      {:ok, target_a} = Target.new("tgt_arg_A", protocol: :fake, host: "fake-a.host.io")
      :ok = TargetRegistry.register(target_a)

      {:ok, target_b} = Target.new("tgt_arg_B", protocol: :fake, host: "fake-b.host.io")
      :ok = TargetRegistry.register(target_b)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "resolve_target(tgt_A, approval_for_tgt_B, cmd.target: :remote) must NOT route to FakeRemoteRunner" do
      {:ok, cmd} = Command.new("ls", target: :remote)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_B",
          command_hash: cmd_hash,
          session_id: "sess_arg"
        },
        session_id: "sess_arg",
        command: cmd
      }

      # Target argument "tgt_arg_A" does not match approval's target_id "tgt_arg_B"
      assert {:error, _} = Policy.resolve_target("tgt_arg_A", context)
    end

    test "resolve_target(:arbitrary_atom, valid_remote_context) must NOT route to FakeRemoteRunner" do
      {:ok, cmd} = Command.new("ls", target: "tgt_arg_A")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_A",
          command_hash: cmd_hash,
          session_id: "sess_arb"
        },
        session_id: "sess_arb",
        command: cmd
      }

      # Arbitrary atoms are not valid remote routing targets
      assert {:error, _} = Policy.resolve_target(:some_arbitrary_atom, context)
    end

    test "resolve_target(:ssh, valid_remote_context) must NOT route to FakeRemoteRunner" do
      {:ok, cmd} = Command.new("ls", target: "tgt_arg_A")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_A",
          command_hash: cmd_hash,
          session_id: "sess_ssh"
        },
        session_id: "sess_ssh",
        command: cmd
      }

      assert {:error, reason} = Policy.resolve_target(:ssh, context)
      assert reason =~ "SSH"
    end

    test "resolve_target(\"local\", valid_remote_context) routes as local, not remote" do
      {:ok, cmd} = Command.new("ls", target: "tgt_arg_A")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_A",
          command_hash: cmd_hash,
          session_id: "sess_local"
        },
        session_id: "sess_local",
        command: cmd
      }

      # "local" string normalizes to local — must NOT route to FakeRemoteRunner
      assert {:ok, Muse.Execution.LocalRunner} = Policy.resolve_target("local", context)
    end

    test "resolve_target(:remote, valid_remote_context) routes to FakeRemoteRunner" do
      {:ok, cmd} = Command.new("ls", target: :remote)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_A",
          command_hash: cmd_hash,
          session_id: "sess_remote"
        },
        target_id: "tgt_arg_A",
        session_id: "sess_remote",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target(:remote, context)
    end

    test "resolve_target(\"remote\", valid_remote_context) routes to FakeRemoteRunner" do
      {:ok, cmd} = Command.new("ls", target: "remote")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_A",
          command_hash: cmd_hash,
          session_id: "sess_remote_str"
        },
        target_id: "tgt_arg_A",
        session_id: "sess_remote_str",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target("remote", context)
    end

    test "resolve_target with matching target_id string routes to FakeRemoteRunner" do
      {:ok, cmd} = Command.new("ls", target: "tgt_arg_A")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_arg_A",
          command_hash: cmd_hash,
          session_id: "sess_match"
        },
        session_id: "sess_match",
        command: cmd
      }

      assert {:ok, Muse.Execution.FakeRemoteRunner} = Policy.resolve_target("tgt_arg_A", context)
    end
  end

  # -- Security: command target validation for remote routing -------------------

  describe "remote_execution_denied?/1 — command target must be valid remote form" do
    setup do
      {:ok, target} = Target.new("tgt_cmdval_fake", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      on_exit(fn -> TargetRegistry.clear() end)
      :ok
    end

    test "denied when command target is :local" do
      {:ok, cmd} = Command.new("ls", target: :local)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_local"
        },
        session_id: "sess_local",
        command: cmd
      }

      # :local command target is not a valid remote routing form
      assert Policy.remote_execution_denied?(context) == true
    end

    test "denied when command target is nil" do
      {:ok, cmd} = Command.new("ls", target: nil)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_nil"
        },
        session_id: "sess_nil",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "denied when command target is \"local\"" do
      {:ok, cmd} = Command.new("ls", target: "local")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_local_str"
        },
        session_id: "sess_local_str",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "denied when command target is an arbitrary atom" do
      {:ok, cmd} = Command.new("ls", target: :some_arbitrary_atom)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_arb"
        },
        session_id: "sess_arb",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "denied when command target is :ssh" do
      {:ok, cmd} = Command.new("ls", target: :ssh)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_ssh"
        },
        session_id: "sess_ssh",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end

    test "allowed when command target is :remote with valid approval" do
      {:ok, cmd} = Command.new("ls", target: :remote)
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_ok"
        },
        target_id: "tgt_cmdval_fake",
        session_id: "sess_ok",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false
    end

    test "allowed when command target matches approval target_id" do
      {:ok, cmd} = Command.new("ls", target: "tgt_cmdval_fake")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_ok2"
        },
        session_id: "sess_ok2",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == false
    end

    test "denied when command target is a string not matching approval target_id" do
      {:ok, cmd} = Command.new("ls", target: "other_target")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_cmdval_fake",
          command_hash: cmd_hash,
          session_id: "sess_mismatch"
        },
        session_id: "sess_mismatch",
        command: cmd
      }

      assert Policy.remote_execution_denied?(context) == true
    end
  end

  # -- Security: map_get/2 false-value bug fix ----------------------------------

  describe "map_get/2 false-value bug fix" do
    test "remote_execution_denied? correctly handles map with false values" do
      # If an approval map had a false value for a key, the old ||
      # would fall through to the string-key lookup. Now uses case.
      context = %{
        approval: %{kind: :remote_execution, status: :approved, target_id: nil}
      }

      # Should be denied because target_id is nil
      assert Policy.remote_execution_denied?(context) == true
    end
  end
end
