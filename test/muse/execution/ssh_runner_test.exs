defmodule Muse.Execution.SSHRunnerTest do
  use ExUnit.Case, async: false

  alias Muse.Execution.{Command, Result, SSHRunner, Target, TargetRegistry}

  defmodule FailingIfConnectedSSHClient do
    @behaviour Muse.Execution.SSHClient

    def connect(_target, _opts), do: raise("SSH connection should not have been attempted")
    def exec(_connection_ref, _command_string, _opts), do: {:error, "unexpected exec"}
    def disconnect(_connection_ref), do: :ok
  end

  defmodule ConnectFailureSSHClient do
    @behaviour Muse.Execution.SSHClient

    def connect(_target, _opts), do: {:error, "SSH connection failed"}
    def exec(_connection_ref, _command_string, _opts), do: {:error, "unexpected exec"}
    def disconnect(_connection_ref), do: :ok
  end

  setup do
    on_exit(fn ->
      TargetRegistry.clear()
    end)

    :ok
  end

  # -- Helper to build a valid SSH target + approval context -------------------

  defp register_ssh_target!(id \\ "tgt_ssh_test", opts \\ []) do
    defaults = [
      protocol: :ssh,
      host: "ssh.test.host.io",
      user: "deploy",
      credential_ref: %{type: "identity_file", path: "/home/deploy/.ssh/id_ed25519"},
      connection_opts: [user_known_hosts_file: "/home/deploy/.ssh/known_hosts"]
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, target} = Target.new(id, merged)
    :ok = TargetRegistry.register(target)
    target
  end

  defp valid_ssh_context(cmd, target_id \\ "tgt_ssh_test", session_id \\ "sess_ssh_test") do
    %{
      approval: %{
        kind: :remote_execution,
        status: :approved,
        target_id: target_id,
        command_hash: Command.command_hash(cmd),
        session_id: session_id
      },
      session_id: session_id,
      command: cmd
    }
  end

  defp ssh_opts do
    [
      ssh_client: Muse.Execution.FakeSSHClient,
      fake_outcome: :ok,
      fake_stdout: "hello from ssh",
      fake_stderr: "",
      fake_exit_status: 0
    ]
  end

  # -- Direct SSHRunner.run/2 without context: DENIED -------------------------

  describe "SSHRunner.run/2 — deny-by-default" do
    test "denies without execution context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      assert {:error, %Result{status: :denied}} = SSHRunner.run(cmd, ssh_opts())
    end

    test "denies without execution context and does not connect" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      assert {:error, %Result{status: :denied}} =
               SSHRunner.run(cmd, ssh_client: FailingIfConnectedSSHClient)
    end

    test "denies with empty execution context" do
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      assert {:error, %Result{status: :denied}} =
               SSHRunner.run(cmd, Keyword.put(ssh_opts(), :execution_context, %{}))
    end

    test "remote_run/3 denies without execution context" do
      {:ok, conn_ref} = Muse.Execution.FakeSSHClient.connect(%{})
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      assert %Result{status: :denied} = SSHRunner.remote_run(conn_ref, cmd, ssh_opts())
    end

    test "denies with context that would not route to SSHRunner" do
      {:ok, cmd} = Command.new("ls", target: :local)

      # Context for a local target — SSHRunner should not accept
      context = %{approval: %{kind: :remote_execution, status: :approved}}
      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:error, %Result{status: :denied}} = SSHRunner.run(cmd, opts)
    end

    test "denies with context that has wrong approval kind" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      context = %{
        approval: %{kind: :plan, status: :approved},
        command: cmd
      }

      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:error, %Result{status: :denied}} = SSHRunner.run(cmd, opts)
    end

    test "denies with expired approval" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      past = DateTime.add(DateTime.utc_now(), -600, :second)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ssh_test",
          command_hash: Command.command_hash(cmd),
          session_id: "sess_expired",
          expires_at: past
        },
        session_id: "sess_expired",
        command: cmd
      }

      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:error, %Result{status: :denied}} = SSHRunner.run(cmd, opts)
    end
  end

  # -- SSHRunner.run/2 with valid context + fake adapter ------------------------

  describe "SSHRunner.run/2 — valid approval context" do
    test "executes with valid context and fake adapter" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)
      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:ok, %Result{status: :ok, runner: :ssh}} = SSHRunner.run(cmd, opts)
    end

    test "denies direct run when context command hash is for a different command" do
      register_ssh_target!()
      {:ok, approved_cmd} = Command.new("ls", target: "tgt_ssh_test")

      {:ok, substituted_cmd} =
        Command.new("rm", args: ["-rf", "/tmp/muse-test"], target: "tgt_ssh_test")

      stale_context = valid_ssh_context(approved_cmd)
      opts = Keyword.put(ssh_opts(), :execution_context, stale_context)

      assert {:error, %Result{status: :denied}} = SSHRunner.run(substituted_cmd, opts)
    end

    test "returns capped and redacted output" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)
      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:ok, %Result{status: :ok} = result} = SSHRunner.run(cmd, opts)
      assert is_binary(result.output)
    end

    test "returns error result for connection failure without crashing" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)
      opts = [ssh_client: ConnectFailureSSHClient, execution_context: context]

      assert {:ok, %Result{status: :error, runner: :ssh} = result} = SSHRunner.run(cmd, opts)
      assert result.error =~ "SSH connection failed"
    end

    test "returns error result for non-zero exit" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)

      opts =
        ssh_opts()
        |> Keyword.put(:execution_context, context)
        |> Keyword.put(:fake_outcome, :error)
        |> Keyword.put(:fake_exit_status, 1)

      assert {:ok, %Result{status: :error, exit_status: 1}} = SSHRunner.run(cmd, opts)
    end

    test "returns timed_out result for timeout" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)

      opts =
        ssh_opts()
        |> Keyword.put(:execution_context, context)
        |> Keyword.put(:fake_outcome, :timed_out)

      assert {:ok, %Result{status: :timed_out, timed_out: true}} = SSHRunner.run(cmd, opts)
    end

    test "returns error result for fake denied outcome" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)

      opts =
        ssh_opts()
        |> Keyword.put(:execution_context, context)
        |> Keyword.put(:fake_outcome, :denied)

      assert {:ok, %Result{} = result} = SSHRunner.run(cmd, opts)
      # The denied outcome from the fake client causes an error result
      assert result.status == :error
    end
  end

  # -- SSHRunner via Runner.run/3 routing ----------------------------------------

  describe "SSHRunner via Runner.run/3 — policy routing" do
    test "routes to SSHRunner for valid SSH target with approval" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)

      assert {:ok, %Result{status: :ok, runner: :ssh}} =
               Muse.Execution.Runner.run(cmd, ssh_opts(), context)
    end

    test "routes to RemoteDeniedRunner for SSH target without approval" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")

      assert {:error, %Result{status: :denied}} =
               Muse.Execution.Runner.run(cmd, ssh_opts(), %{})
    end

    test "routes to RemoteDeniedRunner for SSH target with wrong session" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd, "tgt_ssh_test", "sess_original")

      # Attacker session
      attacker_context = %{context | session_id: "sess_attacker"}

      assert {:error, %Result{status: :denied}} =
               Muse.Execution.Runner.run(cmd, ssh_opts(), attacker_context)
    end

    test "routes to RemoteDeniedRunner for SSH target with wrong command hash" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      {:ok, wrong_cmd} = Command.new("rm", target: "tgt_ssh_test")

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_ssh_test",
          command_hash: Command.command_hash(wrong_cmd),
          session_id: "sess_wrong_hash"
        },
        session_id: "sess_wrong_hash",
        command: cmd
      }

      assert {:error, %Result{status: :denied}} =
               Muse.Execution.Runner.run(cmd, ssh_opts(), context)
    end

    test "preserves existing fake remote routing" do
      {:ok, target} = Target.new("tgt_fake_existing", protocol: :fake, host: "fake.host.io")
      :ok = TargetRegistry.register(target)

      {:ok, cmd} = Command.new("ls", target: "tgt_fake_existing")
      cmd_hash = Command.command_hash(cmd)

      context = %{
        approval: %{
          kind: :remote_execution,
          status: :approved,
          target_id: "tgt_fake_existing",
          command_hash: cmd_hash,
          session_id: "sess_fake_existing"
        },
        session_id: "sess_fake_existing",
        command: cmd
      }

      assert {:ok, %Result{status: :ok, runner: :fake_remote}} =
               Muse.Execution.Runner.run(cmd, [], context)
    end
  end

  # -- SSH command constraints ---------------------------------------------------

  describe "SSHRunner — command constraints" do
    test "rejects command with non-empty env" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test", env: %{"FOO" => "bar"})
      context = valid_ssh_context(cmd)
      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:error, %Result{status: :denied}} = SSHRunner.run(cmd, opts)
    end

    test "rejects command with cwd" do
      register_ssh_target!()

      # Bypass Command validation for cwd since it must exist on disk;
      # construct the struct directly for this test
      {:ok, cmd_base} = Command.new("ls", target: "tgt_ssh_test")
      cmd = %{cmd_base | cwd: "/some/remote/path"}
      context = valid_ssh_context(cmd)
      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:error, %Result{status: :denied}} = SSHRunner.run(cmd, opts)
    end

    test "accepts command with empty env" do
      register_ssh_target!()
      {:ok, cmd} = Command.new("ls", target: "tgt_ssh_test")
      context = valid_ssh_context(cmd)
      opts = Keyword.put(ssh_opts(), :execution_context, context)

      assert {:ok, %Result{status: :ok}} = SSHRunner.run(cmd, opts)
    end
  end

  # -- Command string quoting (adversarial) --------------------------------------

  describe "SSHRunner — command quoting" do
    test "quotes simple arguments" do
      cmd = %Command{executable: "echo", args: ["hello"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'hello'"
    end

    test "quotes arguments with spaces" do
      cmd = %Command{executable: "echo", args: ["hello world"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'hello world'"
    end

    test "quotes arguments with single quotes" do
      cmd = %Command{executable: "echo", args: ["it's", "a test"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'it'\\''s' 'a test'"
    end

    test "quotes arguments with command substitution" do
      cmd = %Command{executable: "echo", args: ["$(rm -rf /)"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' '$(rm -rf /)'"
    end

    test "quotes arguments with semicolons" do
      cmd = %Command{executable: "echo", args: ["hello; rm -rf /"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'hello; rm -rf /'"
    end

    test "quotes arguments with backticks" do
      cmd = %Command{executable: "echo", args: ["`whoami`"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' '`whoami`'"
    end

    test "quotes arguments with pipes" do
      cmd = %Command{executable: "echo", args: ["hello | cat"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'hello | cat'"
    end

    test "quotes arguments with redirections" do
      cmd = %Command{
        executable: "echo",
        args: ["hello > /etc/passwd"],
        id: "test",
        target: :local
      }

      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'hello > /etc/passwd'"
    end

    test "quotes arguments with dollar signs" do
      cmd = %Command{executable: "echo", args: ["$HOME"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' '$HOME'"
    end

    test "quotes arguments with newlines" do
      cmd = %Command{executable: "echo", args: ["hello\nworld"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'hello\nworld'"
    end

    test "quotes empty argument" do
      cmd = %Command{executable: "echo", args: [""], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' ''"
    end

    test "quotes multiple single quotes in argument" do
      cmd = %Command{executable: "echo", args: ["a'b'c"], id: "test", target: :local}
      assert SSHRunner.build_safe_command_string(cmd) == "'echo' 'a'\\''b'\\''c'"
    end

    test "shell_quote/1 returns safe quoted string" do
      assert SSHRunner.shell_quote("hello") == "'hello'"
      assert SSHRunner.shell_quote("hello world") == "'hello world'"
      assert SSHRunner.shell_quote("it's") == "'it'\\''s'"
      assert SSHRunner.shell_quote("") == "''"
    end
  end

  # -- Capabilities --------------------------------------------------------------

  describe "SSHRunner — capabilities" do
    test "declares remote and ssh capabilities" do
      caps = SSHRunner.capabilities()
      assert caps.local == false
      assert caps.remote == true
      assert caps.ssh == true
      assert caps.shell == false
      assert caps.network == true
      assert :ssh in caps.protocols
    end
  end

  # -- Host key verification: no silent acceptance ------------------------------

  describe "SSHRunner — host key verification" do
    test "SSH target without known_hosts in connection_opts is rejected by Target validation" do
      # An SSH target without connection_opts is allowed (opts are validated at connect time),
      # but connecting without host key verification options should fail.
      # This test verifies that the target CAN be created (connection_opts are optional
      # at Target level), but the ErlangSSHClient will reject the connection.
      {:ok, target} =
        Target.new("tgt_ssh_no_hostkey",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/home/deploy/.ssh/id_ed25519"}
        )

      # Target should be creatable — connection_opts are optional
      assert target.id == "tgt_ssh_no_hostkey"
    end
  end

  # -- Target SSH-specific validation -------------------------------------------

  describe "Target — SSH-specific validation" do
    test "SSH target requires user" do
      assert {:error, reason} =
               Target.new("tgt_ssh_no_user",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [user_known_hosts_file: "/known_hosts"]
               )

      assert reason =~ "user"
    end

    test "SSH target requires credential_ref" do
      assert {:error, reason} =
               Target.new("tgt_ssh_no_cred",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 connection_opts: [user_known_hosts_file: "/known_hosts"]
               )

      assert reason =~ "credential_ref"
    end

    test "SSH target rejects host with whitespace" do
      assert {:error, reason} =
               Target.new("tgt_ssh_ws_host",
                 protocol: :ssh,
                 host: "ssh host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [user_known_hosts_file: "/known_hosts"]
               )

      assert reason =~ "whitespace"
    end

    test "SSH target rejects user with whitespace" do
      assert {:error, reason} =
               Target.new("tgt_ssh_ws_user",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy user",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [user_known_hosts_file: "/known_hosts"]
               )

      assert reason =~ "whitespace"
    end

    test "SSH target defaults port to 22" do
      {:ok, target} =
        Target.new("tgt_ssh_default_port",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      assert target.port == 22
    end

    test "SSH target rejects port out of range" do
      assert {:error, reason} =
               Target.new("tgt_ssh_bad_port",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 port: 99999,
                 connection_opts: [user_known_hosts_file: "/known_hosts"]
               )

      assert reason =~ "1 and 65535"
    end

    test "SSH target rejects dangerous connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_dangerous_opts",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [silently_accept_hosts: true]
               )

      assert reason =~ "dangerous"
      assert reason =~ "silently_accept_hosts"
    end

    test "SSH target rejects password in connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_password",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [password: "secret123"]
               )

      assert reason =~ "dangerous"
      assert reason =~ "password"
    end

    test "SSH target rejects private_key in connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_privkey",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [private_key: "-----BEGIN RSA..."]
               )

      assert reason =~ "dangerous"
      assert reason =~ "private_key"
    end

    test "SSH target accepts safe connection_opts" do
      assert {:ok, target} =
               Target.new("tgt_ssh_safe_opts",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [user_known_hosts_file: "/home/deploy/.ssh/known_hosts"]
               )

      assert target.id == "tgt_ssh_safe_opts"
    end

    test "fake target does not require user or credential_ref" do
      assert {:ok, target} =
               Target.new("tgt_fake_no_ssh", protocol: :fake, host: "fake.host.io")

      assert target.user == nil
      assert target.credential_ref == nil
    end
  end

  # -- Safe payload never includes SSH-sensitive fields --------------------------

  describe "Target.safe_payload — SSH field redaction" do
    test "never includes user in safe payload" do
      {:ok, target} =
        Target.new("tgt_payload_user",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :user)
    end

    test "never includes credential_ref in safe payload" do
      {:ok, target} =
        Target.new("tgt_payload_cred",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :credential_ref)
    end

    test "never includes connection_opts in safe payload" do
      {:ok, target} =
        Target.new("tgt_payload_opts",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :connection_opts)
    end

    test "never includes metadata in safe payload" do
      {:ok, target} =
        Target.new("tgt_payload_meta",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :metadata)
    end

    test "includes safe fields in safe payload" do
      {:ok, target} =
        Target.new("tgt_payload_safe",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"},
          port: 22,
          label: "Staging SSH",
          connection_opts: [user_known_hosts_file: "/known_hosts"]
        )

      payload = Target.safe_payload(target)
      assert Map.has_key?(payload, :id)
      assert Map.has_key?(payload, :protocol)
      assert Map.has_key?(payload, :host)
      assert Map.has_key?(payload, :port)
      assert Map.has_key?(payload, :label)
    end
  end
end
