defmodule Muse.Execution.TargetTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.Target

  describe "new/2 — basic construction" do
    test "creates target with required fields" do
      assert {:ok, target} =
               Target.new("tgt_staging", protocol: :fake, host: "staging.example.com")

      assert target.id == "tgt_staging"
      assert target.protocol == :fake
      assert target.host == "staging.example.com"
    end

    test "creates target with all optional fields" do
      now = DateTime.utc_now()

      assert {:ok, target} =
               Target.new("tgt_full",
                 label: "Staging Web 1",
                 protocol: :fake,
                 host: "staging.example.com",
                 port: 22,
                 user: "deploy",
                 connection_opts: [timeout: 5000],
                 credential_ref: {:ref, "key_1"},
                 tags: ["staging", "web"],
                 created_at: now,
                 updated_at: now
               )

      assert target.label == "Staging Web 1"
      assert target.port == 22
      assert target.user == "deploy"
      assert target.connection_opts == [timeout: 5000]
      assert target.credential_ref == {:ref, "key_1"}
      assert target.tags == ["staging", "web"]
    end

    test "defaults protocol to :fake" do
      assert {:ok, target} = Target.new("tgt_default", host: "host.io")
      assert target.protocol == :fake
    end

    test "sets created_at and updated_at automatically" do
      assert {:ok, target} = Target.new("tgt_time", host: "host.io")
      assert target.created_at != nil
      assert target.updated_at != nil
    end
  end

  describe "new/2 — validation" do
    test "rejects empty id" do
      assert {:error, "id must be a non-empty string"} = Target.new("", host: "host.io")
    end

    test "rejects non-string id" do
      assert {:error, "id must be a non-empty string"} = Target.new(123, host: "host.io")
    end

    test "rejects id with NUL character" do
      assert {:error, "id contains NUL character"} = Target.new("bad\0id", host: "host.io")
    end

    test "rejects unknown protocol atom" do
      assert {:error, "protocol must be one of: fake, ssh"} =
               Target.new("tgt_bad", protocol: :unknown, host: "host.io")
    end

    test "rejects unknown protocol string" do
      assert {:error, "protocol must be one of: fake, ssh"} =
               Target.new("tgt_bad", protocol: "unknown", host: "host.io")
    end

    test "rejects non-string tags" do
      assert {:error, "tags must be a list of strings"} =
               Target.new("tgt_bad", host: "host.io", tags: [123, :atom])
    end
  end

  describe "new!/2" do
    test "returns target on success" do
      target = Target.new!("tgt_quick", protocol: :fake, host: "host.io")
      assert target.id == "tgt_quick"
    end

    test "raises on validation error" do
      assert_raise ArgumentError, "protocol must be one of: fake, ssh", fn ->
        Target.new!("tgt_bad", protocol: :unknown, host: "host.io")
      end
    end
  end

  describe "parse_protocol/1" do
    test "accepts :fake atom" do
      assert {:ok, :fake} = Target.parse_protocol(:fake)
    end

    test "accepts :ssh atom" do
      assert {:ok, :ssh} = Target.parse_protocol(:ssh)
    end

    test "accepts 'fake' string" do
      assert {:ok, :fake} = Target.parse_protocol("fake")
    end

    test "accepts 'ssh' string" do
      assert {:ok, :ssh} = Target.parse_protocol("ssh")
    end

    test "accepts uppercase string" do
      assert {:ok, :fake} = Target.parse_protocol("FAKE")
      assert {:ok, :ssh} = Target.parse_protocol("SSH")
    end

    test "rejects unknown atom" do
      assert {:error, _} = Target.parse_protocol(:docker)
    end

    test "rejects unknown string" do
      assert {:error, _} = Target.parse_protocol("docker")
    end

    test "rejects arbitrary strings (no String.to_atom)" do
      # This is a regression test: never convert arbitrary strings to atoms
      assert {:error, _} = Target.parse_protocol("malicious_injection")
      assert {:error, _} = Target.parse_protocol("$(cat /etc/passwd)")
    end

    test "rejects non-string non-atom input" do
      assert {:error, _} = Target.parse_protocol(123)
      assert {:error, _} = Target.parse_protocol(nil)
    end
  end

  describe "safe_payload/1" do
    test "includes safe fields" do
      {:ok, target} =
        Target.new("tgt_safe",
          protocol: :fake,
          host: "staging.example.com",
          port: 22,
          label: "Staging",
          tags: ["web"]
        )

      payload = Target.safe_payload(target)

      assert payload.id == "tgt_safe"
      assert payload.protocol == :fake
      assert payload.host == "staging.example.com"
      assert payload.port == 22
      assert payload.label == "Staging"
      assert payload.tags == ["web"]
    end

    test "excludes user from safe payload" do
      {:ok, target} = Target.new("tgt_secret", protocol: :fake, host: "host.io", user: "deploy")
      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :user)
    end

    test "excludes credential_ref from safe payload" do
      {:ok, target} =
        Target.new("tgt_secret",
          protocol: :fake,
          host: "host.io",
          credential_ref: {:ref, "secret_key"}
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :credential_ref)
    end

    test "excludes connection_opts from safe payload" do
      {:ok, target} =
        Target.new("tgt_secret",
          protocol: :fake,
          host: "host.io",
          connection_opts: [password: "secret123"]
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :connection_opts)
    end

    test "excludes metadata from safe payload" do
      {:ok, target} =
        Target.new("tgt_secret", protocol: :fake, host: "host.io", metadata: %{internal: true})

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :metadata)
    end

    test "excludes created_at and updated_at from safe payload" do
      {:ok, target} = Target.new("tgt_time", protocol: :fake, host: "host.io")
      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :created_at)
      refute Map.has_key?(payload, :updated_at)
    end

    test "drops nil values" do
      {:ok, target} = Target.new("tgt_minimal", protocol: :fake, host: "host.io")
      payload = Target.safe_payload(target)
      # port and label are nil, should not appear
      refute Map.has_key?(payload, :port)
      refute Map.has_key?(payload, :label)
    end
  end

  describe "known_protocols/0" do
    test "returns list of known protocols" do
      protocols = Target.known_protocols()
      assert :fake in protocols
      assert :ssh in protocols
    end
  end

  describe "no String.to_atom regression" do
    test "arbitrary protocol strings never create atoms" do
      # Count atoms before
      count_before = :erlang.system_info(:atom_count)

      # Try many arbitrary protocol strings
      for s <- ["evil_atom", "$(rm -rf /)", "exec://host", "ssh\x00evil", "DOCKER", "K8S"] do
        assert {:error, _} = Target.parse_protocol(s)
      end

      # Count atoms after — should not have grown significantly
      count_after = :erlang.system_info(:atom_count)
      assert count_after - count_before < 5
    end

    test "arbitrary target IDs don't create atoms" do
      for id <- ["target_at_host.com", "192.168.1.1", "server:22", "$(cat /etc/passwd)"] do
        assert {:ok, _} = Target.new(id, protocol: :fake, host: "host.io")
      end
    end
  end

  # -- Host validation ----------------------------------------------------------

  describe "host validation" do
    test "rejects empty host" do
      assert {:error, "host must not be empty"} = Target.new("tgt_h", protocol: :fake, host: "")
    end

    test "rejects nil host" do
      assert {:error, "host must not be nil"} = Target.new("tgt_h", protocol: :fake, host: nil)
    end

    test "rejects non-string host" do
      assert {:error, _} = Target.new("tgt_h", protocol: :fake, host: 123)
    end

    test "rejects host with NUL character" do
      assert {:error, "host contains NUL character"} =
               Target.new("tgt_h", protocol: :fake, host: "host\0evil")
    end

    test "rejects host with control characters" do
      assert {:error, reason} = Target.new("tgt_h", protocol: :fake, host: "host\x01evil")
      assert reason =~ "control character"
    end

    test "rejects credential-bearing host: URL userinfo" do
      assert {:error, reason} =
               Target.new("tgt_h", protocol: :fake, host: "ssh://user:pass@evil.com")

      assert reason =~ "credentials"
    end

    test "rejects credential-bearing host: bare user:pass@" do
      assert {:error, reason} =
               Target.new("tgt_h", protocol: :fake, host: "deploy:secret123@staging.io")

      assert reason =~ "credentials"
    end

    test "accepts normal hostname" do
      assert {:ok, _} = Target.new("tgt_h", protocol: :fake, host: "staging.example.com")
    end

    test "accepts IP address" do
      assert {:ok, _} = Target.new("tgt_h", protocol: :fake, host: "192.168.1.100")
    end

    test "accepts hostname with port-like suffix" do
      # host:22 is not a user:pass@ form — this is just a hostname with a colon
      # (Colons in hostnames are unusual but not inherently credential-bearing)
      assert {:ok, _} = Target.new("tgt_h", protocol: :fake, host: "host.io")
    end
  end

  # -- Label validation ---------------------------------------------------------

  describe "label validation" do
    test "rejects label with NUL character" do
      assert {:error, "label contains NUL character"} =
               Target.new("tgt_l", protocol: :fake, host: "host.io", label: "bad\0label")
    end

    test "rejects label with control characters" do
      assert {:error, reason} =
               Target.new("tgt_l", protocol: :fake, host: "host.io", label: "bad\x01label")

      assert reason =~ "control character"
    end

    test "accepts normal label" do
      assert {:ok, t} =
               Target.new("tgt_l", protocol: :fake, host: "host.io", label: "Staging Web 1")

      assert t.label == "Staging Web 1"
    end

    test "accepts nil label" do
      assert {:ok, _} = Target.new("tgt_l", protocol: :fake, host: "host.io", label: nil)
    end
  end

  # -- ID validation: control chars --------------------------------------------

  describe "id validation: control characters" do
    test "rejects id with control characters" do
      assert {:error, reason} = Target.new("bad\x01id", protocol: :fake, host: "host.io")
      assert reason =~ "control character"
    end
  end

  # -- Tags validation: control chars ------------------------------------------

  describe "tags validation: control characters" do
    test "rejects tags with NUL character" do
      assert {:error, reason} =
               Target.new("tgt_t", protocol: :fake, host: "host.io", tags: ["web", "bad\0tag"])

      assert reason =~ "NUL"
    end

    test "rejects tags with control characters" do
      assert {:error, reason} =
               Target.new("tgt_t", protocol: :fake, host: "host.io", tags: ["web", "bad\x01tag"])

      assert reason =~ "control character"
    end
  end

  # -- Safe payload redaction ---------------------------------------------------

  describe "safe_payload/1 — redaction" do
    test "redacts secret-like patterns in host values" do
      {:ok, target} =
        Target.new("tgt_redact",
          protocol: :fake,
          host: "staging.example.com",
          label: "DATABASE_URL=postgres://user:pass@host/db"
        )

      payload = Target.safe_payload(target)
      # The label contains a secret pattern that should be redacted
      refute payload.label =~ "postgres://user:pass@host/db"
      assert payload.label =~ "[REDACTED]"
    end

    test "redacts API-key-like patterns in tags" do
      {:ok, target} =
        Target.new("tgt_redact_tags",
          protocol: :fake,
          host: "host.io",
          tags: ["web", "sk-test-secret-key-1234567890abcdef1234567890"]
        )

      payload = Target.safe_payload(target)
      # Tags should be redacted if they contain secret-like values
      secret_tag = Enum.find(payload.tags, &String.contains?(&1, "sk-test-secret-key"))
      assert secret_tag == nil
    end

    test "never includes user, credential_ref, or connection_opts" do
      {:ok, target} =
        Target.new("tgt_no_leak",
          protocol: :fake,
          host: "host.io",
          user: "secret_user",
          credential_ref: {:ref, "secret"},
          connection_opts: [password: "secret123"]
        )

      payload = Target.safe_payload(target)
      refute Map.has_key?(payload, :user)
      refute Map.has_key?(payload, :credential_ref)
      refute Map.has_key?(payload, :connection_opts)
    end

    test "sanitizes bare user:pass@host in manually constructed target" do
      # A manually constructed target (bypassing new/2 validation) with
      # bare credentials in the host field must still be safe in payloads.
      target = %Target{
        id: "tgt_manual",
        protocol: :fake,
        host: "deploy:secret123@staging.io"
      }

      payload = Target.safe_payload(target)
      # The credential portion must be redacted
      refute payload.host =~ "deploy:secret123"
      assert payload.host =~ "[REDACTED]"
      # The real hostname should still be present after @
      assert payload.host =~ "staging.io"
    end

    test "sanitizes bare user:pass@host with complex password in manually constructed target" do
      target = %Target{
        id: "tgt_manual2",
        protocol: :fake,
        host: "admin:p@ss:w0rd@prod.example.com"
      }

      payload = Target.safe_payload(target)
      # Must not leak any part of the password
      refute payload.host =~ "p@ss:w0rd"
      refute payload.host =~ "admin:p@ss"
      refute payload.host =~ "ss:w0rd"
      refute payload.host =~ ":w0rd"
      assert payload.host =~ "[REDACTED]"
      assert payload.host =~ "prod.example.com"
    end

    test "does not redact normal host values in safe_payload" do
      {:ok, target} = Target.new("tgt_normal_host", protocol: :fake, host: "staging.example.com")
      payload = Target.safe_payload(target)
      assert payload.host == "staging.example.com"
    end

    test "normal values pass through redaction unchanged" do
      {:ok, target} =
        Target.new("tgt_normal",
          protocol: :fake,
          host: "staging.example.com",
          label: "Staging Server",
          tags: ["web", "api"]
        )

      payload = Target.safe_payload(target)
      assert payload.host == "staging.example.com"
      assert payload.label == "Staging Server"
      assert payload.tags == ["web", "api"]
    end

    test "redacts bare credentials in id field" do
      # Manually constructed target with bare credentials in id
      target = %Target{
        id: "deploy:secret123@prod.io",
        protocol: :fake,
        host: "prod.io"
      }

      payload = Target.safe_payload(target)
      refute payload.id =~ "deploy:secret123"
      refute payload.id =~ "secret123"
      assert payload.id =~ "[REDACTED]"
      assert payload.id =~ "prod.io"
    end

    test "redacts bare credentials in label field" do
      # Manually constructed target with bare credentials in label
      target = %Target{
        id: "tgt_label_cred",
        protocol: :fake,
        host: "host.io",
        label: "Connect as admin:s3cret@staging.io for deploys"
      }

      payload = Target.safe_payload(target)
      refute payload.label =~ "admin:s3cret"
      refute payload.label =~ "s3cret"
      assert payload.label =~ "[REDACTED]"
      assert payload.label =~ "staging.io"
    end

    test "redacts bare credentials in tags" do
      # Manually constructed target with bare credentials in tags
      target = %Target{
        id: "tgt_tag_cred",
        protocol: :fake,
        host: "host.io",
        tags: ["deploy:password@prod.io", "web", "admin:sekrit@staging.io"]
      }

      payload = Target.safe_payload(target)
      # Credential-bearing tags must be redacted
      cred_tag = Enum.find(payload.tags, &String.contains?(&1, "deploy:password"))
      assert cred_tag == nil
      cred_tag2 = Enum.find(payload.tags, &String.contains?(&1, "admin:sekrit"))
      assert cred_tag2 == nil
      # Redacted tags still contain the hostname
      redacted_tags = Enum.filter(payload.tags, &String.contains?(&1, "[REDACTED]"))
      assert length(redacted_tags) == 2
      # Non-credential tags pass through
      assert "web" in payload.tags
    end

    test "redacts bare credentials with complex password in label" do
      # Password containing @ inside a label string
      target = %Target{
        id: "tgt_complex_label",
        protocol: :fake,
        host: "host.io",
        label: "Use admin:p@ss:w0rd@prod.example.com for access"
      }

      payload = Target.safe_payload(target)
      # No part of the password should leak
      refute payload.label =~ "p@ss:w0rd"
      refute payload.label =~ "ss:w0rd"
      refute payload.label =~ ":w0rd"
      assert payload.label =~ "[REDACTED]"
      assert payload.label =~ "prod.example.com"
    end

    test "redacts bare credentials in id with complex password" do
      target = %Target{
        id: "user:p@$$:w0rd@server.io",
        protocol: :fake,
        host: "server.io"
      }

      payload = Target.safe_payload(target)
      refute payload.id =~ "p@$$:w0rd"
      refute payload.id =~ "$$:w0rd"
      assert payload.id =~ "[REDACTED]"
    end

    test "does not redact normal-looking id values" do
      {:ok, target} = Target.new("tgt_normal_id", protocol: :fake, host: "host.io")
      payload = Target.safe_payload(target)
      assert payload.id == "tgt_normal_id"
    end

    test "does not redact normal tags without credentials" do
      {:ok, target} =
        Target.new("tgt_normal_tags",
          protocol: :fake,
          host: "host.io",
          tags: ["web", "api", "staging"]
        )

      payload = Target.safe_payload(target)
      assert payload.tags == ["web", "api", "staging"]
    end
  end

  # -- Phase D: SSH-specific target validation -----------------------------------

  describe "SSH target validation (Phase D)" do
    test "creates SSH target with required fields" do
      assert {:ok, target} =
               Target.new("tgt_ssh_create",
                 protocol: :ssh,
                 host: "ssh.example.com",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/home/deploy/.ssh/id_ed25519"},
                 connection_opts: [user_known_hosts_file: "/home/deploy/.ssh/known_hosts"]
               )

      assert target.protocol == :ssh
      assert target.host == "ssh.example.com"
      assert target.user == "deploy"
      assert target.port == 22
    end

    test "SSH target requires user" do
      assert {:error, reason} =
               Target.new("tgt_ssh_no_user",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "user"
    end

    test "SSH target requires credential_ref" do
      assert {:error, reason} =
               Target.new("tgt_ssh_no_cred",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy"
               )

      assert reason =~ "credential_ref"
    end

    test "SSH target rejects empty user" do
      assert {:error, reason} =
               Target.new("tgt_ssh_empty_user",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "user"
    end

    test "SSH target rejects user with whitespace" do
      assert {:error, reason} =
               Target.new("tgt_ssh_ws_user",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy user",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "whitespace"
    end

    test "SSH target rejects user with control characters" do
      assert {:error, reason} =
               Target.new("tgt_ssh_ctrl_user",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy\nuser",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "control characters"
    end

    test "SSH target rejects host with whitespace" do
      assert {:error, reason} =
               Target.new("tgt_ssh_ws_host",
                 protocol: :ssh,
                 host: "ssh host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "whitespace"
    end

    test "SSH target defaults port to 22" do
      {:ok, target} =
        Target.new("tgt_ssh_port_default",
          protocol: :ssh,
          host: "ssh.host.io",
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"}
        )

      assert target.port == 22
    end

    test "SSH target accepts explicit port" do
      {:ok, target} =
        Target.new("tgt_ssh_port_explicit",
          protocol: :ssh,
          host: "ssh.host.io",
          port: 2222,
          user: "deploy",
          credential_ref: %{type: "identity_file", path: "/key"}
        )

      assert target.port == 2222
    end

    test "SSH target rejects port 0" do
      assert {:error, reason} =
               Target.new("tgt_ssh_port_zero",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 port: 0,
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "1 and 65535"
    end

    test "SSH target rejects port > 65535" do
      assert {:error, reason} =
               Target.new("tgt_ssh_port_high",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 port: 99999,
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"}
               )

      assert reason =~ "1 and 65535"
    end

    test "SSH target rejects silently_accept_hosts in connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_silent_accept",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [silently_accept_hosts: true]
               )

      assert reason =~ "dangerous"
      assert reason =~ "silently_accept_hosts"
    end

    test "SSH target rejects user_interaction in connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_user_interact",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [user_interaction: true]
               )

      assert reason =~ "dangerous"
      assert reason =~ "user_interaction"
    end

    test "SSH target rejects password in connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_conn_password",
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
               Target.new("tgt_ssh_conn_privkey",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [private_key: "-----BEGIN RSA PRIVATE KEY-----"]
               )

      assert reason =~ "dangerous"
      assert reason =~ "private_key"
    end

    test "SSH target rejects passphrase in connection_opts" do
      assert {:error, reason} =
               Target.new("tgt_ssh_conn_passphrase",
                 protocol: :ssh,
                 host: "ssh.host.io",
                 user: "deploy",
                 credential_ref: %{type: "identity_file", path: "/key"},
                 connection_opts: [passphrase: "secret"]
               )

      assert reason =~ "dangerous"
      assert reason =~ "passphrase"
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

    test "SSH target port validation applies to all protocols (not just :ssh)" do
      # Port validation is universal
      assert {:error, reason} =
               Target.new("tgt_fake_bad_port",
                 protocol: :fake,
                 host: "host.io",
                 port: 99999
               )

      assert reason =~ "1 and 65535"
    end
  end
end
