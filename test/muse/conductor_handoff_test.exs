defmodule Muse.ConductorHandoffTest do
  use ExUnit.Case, async: true

  alias Muse.{Conductor, MuseRegistry, Session}

  describe "can_handoff_to?/3" do
    test "Planning Muse can handoff to Coding Muse" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(planning, :coding, session) == true
    end

    test "Coding Muse can handoff to Planning and Testing" do
      coding = MuseRegistry.get(:coding)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(coding, :planning, session) == true
      assert Conductor.can_handoff_to?(coding, :testing, session) == true
    end

    test "Memory Muse cannot handoff to anyone" do
      memory = MuseRegistry.get(:memory)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(memory, :planning, session) == false
      assert Conductor.can_handoff_to?(memory, :coding, session) == false
    end

    test "Restoration Muse can handoff to Planning" do
      restoration = MuseRegistry.get(:restoration)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(restoration, :planning, session) == true
    end

    test "cannot handoff to unknown Muse" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(planning, :unknown_muse, session) == false
    end

    test "cannot handoff to unlisted target" do
      # Planning can handoff to coding, but not to restoration
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(planning, :coding, session) == true
      assert Conductor.can_handoff_to?(planning, :restoration, session) == false
    end
  end

  describe "request_handoff/4" do
    test "returns handoff event spec for valid handoff" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} = Conductor.request_handoff(planning, :coding, session, reason: "Plan approved")

      assert {:conductor, :muse_handoff_requested, data, opts} = spec
      assert data.source_muse_id == :planning
      assert data.target_muse_id == :coding
      assert data.reason == "Plan approved"
      assert opts[:visibility] == :user
    end

    test "sanitizes context in handoff" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{secret_key: "sk-123", normal_data: "safe"}
        )

      assert {:conductor, :muse_handoff_requested, data, _opts} = spec
      # Context should be sanitized (no raw secret values)
      assert is_map(data.context)
    end

    test "returns error for invalid handoff" do
      memory = MuseRegistry.get(:memory)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      assert {:error, {:handoff_not_allowed, :memory, :planning}} =
               Conductor.request_handoff(memory, :planning, session)
    end

    test "returns error for unknown target" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      assert {:error, {:handoff_not_allowed, :planning, :unknown}} =
               Conductor.request_handoff(planning, :unknown, session)
    end
  end

  # -- Security regression tests (muse-mlp) --------------------------------------

  describe "request_handoff/4 — security: reason redaction" do
    test "reason with Bearer token does not leak in returned spec" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "auth failed: Bearer raw-token-abc123"
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      # Reason should be redacted
      refute data.reason =~ "raw-token-abc123"
      assert data.reason =~ "[REDACTED]"

      # inspect(spec) must not contain raw secret
      refute inspect(spec) =~ "raw-token-abc123"
    end

    test "reason with sk- prefixed API key does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "API key sk-proj-abcdefghij123456 was invalid"
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "sk-proj-abcdefghij123456"
      assert data.reason =~ "[REDACTED]"
      refute inspect(spec) =~ "sk-proj-abcdefghij123456"
    end

    test "reason with password assignment does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "login failed: password=hunter2 for user admin"
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "hunter2"
      assert data.reason =~ "[REDACTED]"
      refute inspect(spec) =~ "hunter2"
    end

    test "reason with private key block does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      private_key =
        "-----BEGIN RSA PRIVATE KEY-----MIIEpQIBAAKCAQEA0Z3JS6tq" <>
          String.duplicate("X", 100) <> "-----END RSA PRIVATE KEY-----"

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session, reason: "Found key: #{private_key}")

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "BEGIN RSA PRIVATE KEY"
      refute inspect(spec) =~ "BEGIN RSA PRIVATE KEY"
    end

    test "reason with Authorization header does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "Request header: Authorization: Bearer secret-token-xyz"
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "secret-token-xyz"
      assert data.reason =~ "[REDACTED]"
      refute inspect(spec) =~ "secret-token-xyz"
    end
  end

  describe "request_handoff/4 — security: context redaction" do
    test "context with sensitive atom key does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{api_key: "plain-secret-value", safe_field: "visible"}
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      # Sensitive key value should be redacted
      assert data.context.api_key == "[REDACTED]"
      assert data.context.safe_field == "visible"
      refute inspect(spec) =~ "plain-secret-value"
    end

    test "context with sensitive string key does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{"api_key" => "plain-secret-value", "normal" => "ok"}
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      assert data.context["api_key"] == "[REDACTED]"
      assert data.context["normal"] == "ok"
      refute inspect(spec) =~ "plain-secret-value"
    end

    test "context with nested sensitive data does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{nested: %{password: "hunter2", safe: "ok"}}
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      assert data.context.nested.password == "[REDACTED]"
      assert data.context.nested.safe == "ok"
      refute inspect(spec) =~ "hunter2"
    end

    test "context with token pattern values does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{note: "key is sk-test-abc123", safe_note: "no secrets"}
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.context.note =~ "sk-test-abc123"
      assert data.context.note =~ "[REDACTED]"
      assert data.context.safe_note == "no secrets"
      refute inspect(spec) =~ "sk-test-abc123"
    end

    test "context with deep nesting is redacted" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      deep_context = %{
        level1: %{
          level2: %{
            level3: %{
              level4: %{
                secret: "deep-secret-value"
              }
            }
          }
        }
      }

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session, context: deep_context)

      {:conductor, :muse_handoff_requested, _data, _opts} = spec

      # Even deeply nested secrets should be redacted or truncated
      refute inspect(spec) =~ "deep-secret-value"
    end

    test "context with tuple containing secrets does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{notes: {:password, "hunter2"}}
        )

      {:conductor, :muse_handoff_requested, _data, _opts} = spec

      # Tuple is converted to list and redacted
      refute inspect(spec) =~ "hunter2"
    end

    test "context with keyword list containing secrets does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{notes: [{:password, "hunter2"}, {:safe, "ok"}]}
        )

      {:conductor, :muse_handoff_requested, _data, _opts} = spec

      refute inspect(spec) =~ "hunter2"
    end

    test "context with string tuple pair does not leak" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{notes: [{"api_key", "plain-secret-value"}]}
        )

      {:conductor, :muse_handoff_requested, _data, _opts} = spec

      refute inspect(spec) =~ "plain-secret-value"
    end
  end

  describe "request_handoff/4 — security: non-binary reason redaction (muse-7lo)" do
    test "tuple reason {:password, \"tuple-sentinel\"} does not raise and excludes sentinel" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: {:password, "tuple-sentinel"}
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "tuple-sentinel"
      assert is_binary(data.reason)
      refute inspect(spec) =~ "tuple-sentinel"
    end

    test "keyword list reason [password: \"kw-sentinel\"] excludes sentinel" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session, reason: [password: "kw-sentinel"])

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "kw-sentinel"
      assert is_binary(data.reason)
      refute inspect(spec) =~ "kw-sentinel"
    end

    test "map reason %{nested: %{api_key: \"map-sentinel\"}} excludes sentinel" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: %{nested: %{api_key: "map-sentinel"}}
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "map-sentinel"
      assert is_binary(data.reason)
      refute inspect(spec) =~ "map-sentinel"
    end

    test "deep non-binary reason excludes sentinel" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      deep_reason = %{
        level1: [
          {:password, "deep-sentinel"},
          {:safe, "ok"},
          %{token: "sk-proj-deep123456abc"}
        ]
      }

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session, reason: deep_reason)

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "deep-sentinel"
      refute data.reason =~ "sk-proj-deep123456abc"
      assert is_binary(data.reason)
      refute inspect(spec) =~ "deep-sentinel"
      refute inspect(spec) =~ "sk-proj-deep123456abc"
    end

    test "safe binary reason remains useful" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "Plan approved, ready for implementation"
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      assert data.reason == "Plan approved, ready for implementation"
    end
  end

  describe "request_handoff/4 — security: safe fields preserved" do
    test "safe context fields survive redaction" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{
            user: "alice",
            action: "plan_approved",
            timestamp: "2024-01-01T00:00:00Z",
            count: 42,
            metadata: %{plan_id: "plan-123", status: "approved"}
          }
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      assert data.context.user == "alice"
      assert data.context.action == "plan_approved"
      assert data.context.timestamp == "2024-01-01T00:00:00Z"
      assert data.context.count == 42
      assert data.context.metadata.plan_id == "plan-123"
      assert data.context.metadata.status == "approved"
    end

    test "safe reason text is preserved" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "Plan approved, ready for implementation"
        )

      {:conductor, :muse_handoff_requested, data, _opts} = spec

      assert data.reason == "Plan approved, ready for implementation"
    end
  end

  describe "request_handoff/4 — security: defense in depth" do
    test "entire spec data is redacted wholesale" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      # Inject secret in multiple places
      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          reason: "Bearer token-here-12345",
          context: %{note: "sk-test-secret-key"}
        )

      # Both should be redacted
      {:conductor, :muse_handoff_requested, data, _opts} = spec

      refute data.reason =~ "token-here-12345"
      refute data.context.note =~ "sk-test-secret-key"
      refute inspect(spec) =~ "token-here-12345"
      refute inspect(spec) =~ "sk-test-secret-key"
    end
  end

  describe "complete_handoff/2" do
    test "updates session active_muse" do
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, updated_session} = Conductor.complete_handoff(session, :coding)

      assert updated_session.active_muse == "coding"
    end

    test "returns error for invalid Muse" do
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      assert {:error, {:invalid_target_muse, :unknown}} =
               Conductor.complete_handoff(session, :unknown)
    end
  end

  describe "handoff targets validation" do
    test "all registered handoff targets exist in registry" do
      for profile <- MuseRegistry.all() do
        for target <- profile.handoff_targets || [] do
          assert MuseRegistry.get(target) != nil,
                 "#{profile.display_name} handoff target #{target} not found in registry"
        end
      end
    end

    test "handoff targets form a valid graph (no orphan targets)" do
      registry_ids = MuseRegistry.ids() |> MapSet.new()

      for profile <- MuseRegistry.all() do
        for target <- profile.handoff_targets || [] do
          assert MapSet.member?(registry_ids, target),
                 "#{profile.display_name} references non-existent handoff target: #{target}"
        end
      end
    end
  end
end
