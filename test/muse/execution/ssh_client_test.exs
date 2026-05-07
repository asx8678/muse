defmodule Muse.Execution.SSHClientTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.{ErlangSSHClient, FakeSSHClient, SSHCredentialResolver, SSHKeyCallback}

  describe "FakeSSHClient" do
    test "connect returns a fake connection ref" do
      assert {:ok, {Muse.Execution.FakeSSHClient, _ref, _target_id}} =
               FakeSSHClient.connect(%{})
    end

    test "connect with target_id option" do
      assert {:ok, {Muse.Execution.FakeSSHClient, _ref, "my_target"}} =
               FakeSSHClient.connect(%{}, target_id: "my_target")
    end

    test "exec returns ok outcome by default" do
      {:ok, conn} = FakeSSHClient.connect(%{})

      assert {:ok, result} = FakeSSHClient.exec(conn, "echo hello")
      assert result.stdout == "fake ssh stdout"
      assert result.stderr == ""
      assert result.exit_status == 0
      assert result.timed_out == false
    end

    test "exec returns error outcome" do
      {:ok, conn} = FakeSSHClient.connect(%{})

      assert {:ok, result} =
               FakeSSHClient.exec(conn, "echo hello", fake_outcome: :error)

      assert result.exit_status == 1
      assert result.stderr == "command failed"
    end

    test "exec returns timed_out outcome" do
      {:ok, conn} = FakeSSHClient.connect(%{})

      assert {:ok, result} =
               FakeSSHClient.exec(conn, "echo hello", fake_outcome: :timed_out)

      assert result.timed_out == true
      assert result.exit_status == nil
    end

    test "exec returns denied outcome" do
      {:ok, conn} = FakeSSHClient.connect(%{})

      assert {:error, reason} =
               FakeSSHClient.exec(conn, "echo hello", fake_outcome: :denied)

      assert reason =~ "denied"
    end

    test "exec with custom stdout" do
      {:ok, conn} = FakeSSHClient.connect(%{})

      assert {:ok, result} =
               FakeSSHClient.exec(conn, "echo hello", fake_stdout: "custom output")

      assert result.stdout == "custom output"
    end

    test "exec with custom exit status" do
      {:ok, conn} = FakeSSHClient.connect(%{})

      assert {:ok, result} =
               FakeSSHClient.exec(conn, "echo hello", fake_exit_status: 42)

      assert result.exit_status == 42
    end

    test "exec with invalid connection ref returns error" do
      assert {:error, _} = FakeSSHClient.exec({:invalid, :ref}, "echo hello")
    end

    test "disconnect always returns :ok" do
      {:ok, conn} = FakeSSHClient.connect(%{})
      assert :ok = FakeSSHClient.disconnect(conn)
    end

    test "disconnect with invalid ref returns :ok" do
      assert :ok = FakeSSHClient.disconnect({:invalid, :ref})
    end
  end

  describe "SSHCredentialResolver" do
    test "resolves identity_file map credential" do
      assert {:ok, opts} =
               SSHCredentialResolver.resolve(%{
                 type: "identity_file",
                 path: "/home/user/.ssh/id_ed25519"
               })

      assert {:key_cb, {SSHKeyCallback, key_cb_opts}} = List.keyfind(opts, :key_cb, 0)
      assert is_list(key_cb_opts)
      assert Keyword.get(key_cb_opts, :identity_file) == ~c"/home/user/.ssh/id_ed25519"
    end

    test "resolves identity_file tuple credential" do
      assert {:ok, opts} =
               SSHCredentialResolver.resolve({:identity_file, "/home/user/.ssh/id_ed25519"})

      assert {:key_cb, {SSHKeyCallback, key_cb_opts}} = List.keyfind(opts, :key_cb, 0)
      assert is_list(key_cb_opts)
    end

    test "rejects password credential type" do
      assert {:error, reason} = SSHCredentialResolver.resolve(%{type: "password"})
      assert reason =~ "unsupported credential type: password"
    end

    test "rejects private_key credential type" do
      assert {:error, reason} = SSHCredentialResolver.resolve(%{type: "private_key"})
      assert reason =~ "unsupported credential type: private_key"
    end

    test "rejects passphrase credential type" do
      assert {:error, reason} = SSHCredentialResolver.resolve(%{type: "passphrase"})
      assert reason =~ "unsupported credential type: passphrase"
    end

    test "rejects unknown credential type without echoing arbitrary input" do
      assert {:error, reason} = SSHCredentialResolver.resolve(%{type: "unknown-secret-token"})
      assert reason == "unsupported credential type"
      refute reason =~ "unknown-secret-token"
    end

    test "rejects nil credential ref" do
      assert {:error, reason} = SSHCredentialResolver.resolve(nil)
      assert reason =~ "required"
    end

    test "rejects arbitrary term credential ref" do
      assert {:error, _} = SSHCredentialResolver.resolve(:some_atom)
      assert {:error, _} = SSHCredentialResolver.resolve(12345)
    end

    test "rejects empty identity file path" do
      assert {:error, reason} = SSHCredentialResolver.resolve(%{type: "identity_file", path: ""})
      assert reason =~ "must not be empty"
    end

    test "rejects identity file path with control characters" do
      assert {:error, reason} =
               SSHCredentialResolver.resolve(%{type: "identity_file", path: "/tmp/\nkey"})

      assert reason =~ "control characters"
    end

    test "rejects identity file path with path traversal" do
      assert {:error, reason} =
               SSHCredentialResolver.resolve(%{type: "identity_file", path: "/tmp/../etc/keys"})

      assert reason =~ "path traversal"
    end
  end

  describe "ErlangSSHClient offline safety checks" do
    test "rejects missing host key verification before any network connection" do
      target = %{
        host: "ssh.example.invalid",
        port: 22,
        user: "deploy",
        credential_ref: %{type: "identity_file", path: "/tmp/id_ed25519"},
        connection_opts: []
      }

      assert {:error, reason} = ErlangSSHClient.connect(target, timeout_ms: 1)
      assert reason =~ "host key verification is required"
    end

    test "rejects invalid ports before any network connection" do
      target = %{
        host: "ssh.example.invalid",
        port: "22",
        user: "deploy",
        credential_ref: %{type: "identity_file", path: "/tmp/id_ed25519"},
        connection_opts: []
      }

      assert {:error, reason} = ErlangSSHClient.connect(target, timeout_ms: 1)
      assert reason =~ "valid port"
    end

    test "rejects host key accept callbacks instead of allowing silent accept" do
      target = %{
        host: "ssh.example.invalid",
        port: 22,
        user: "deploy",
        credential_ref: %{type: "identity_file", path: "/tmp/id_ed25519"},
        connection_opts: [host_key_accept: fn _host, _fingerprint -> true end]
      }

      assert {:error, reason} = ErlangSSHClient.connect(target, timeout_ms: 1)
      assert reason =~ "callbacks are not supported"
    end
  end

  describe "SSHKeyCallback" do
    test "user_key reads identity_file from nested key_cb_private options without raising" do
      opts = [key_cb_private: [identity_file: ~c"/path/that/does/not/exist"]]

      assert {:error, ~c"identity key unavailable"} =
               SSHKeyCallback.user_key(:"ssh-ed25519", opts)
    end

    test "is_host_key fails closed when known_hosts file is missing" do
      opts = [key_cb_private: [known_hosts_file: ~c"/path/that/does/not/exist"]]

      refute SSHKeyCallback.is_host_key(
               :not_a_real_key,
               ~c"example.invalid",
               22,
               :"ssh-ed25519",
               opts
             )
    end
  end
end
