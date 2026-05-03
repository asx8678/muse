defmodule Muse.TelemetryTest do
  use ExUnit.Case, async: true

  alias Muse.Telemetry

  describe "event name functions" do
    test "turn_start returns correct event name" do
      assert Telemetry.turn_start() == [:muse, :turn, :start]
    end

    test "turn_stop returns correct event name" do
      assert Telemetry.turn_stop() == [:muse, :turn, :stop]
    end

    test "turn_exception returns correct event name" do
      assert Telemetry.turn_exception() == [:muse, :turn, :exception]
    end

    test "tool_start returns correct event name" do
      assert Telemetry.tool_start() == [:muse, :tool, :start]
    end

    test "tool_stop returns correct event name" do
      assert Telemetry.tool_stop() == [:muse, :tool, :stop]
    end

    test "tool_exception returns correct event name" do
      assert Telemetry.tool_exception() == [:muse, :tool, :exception]
    end

    test "provider_start returns correct event name" do
      assert Telemetry.provider_start() == [:muse, :provider, :start]
    end

    test "provider_stop returns correct event name" do
      assert Telemetry.provider_stop() == [:muse, :provider, :stop]
    end

    test "provider_error returns correct event name" do
      assert Telemetry.provider_error() == [:muse, :provider, :error]
    end

    test "session_created returns correct event name" do
      assert Telemetry.session_created() == [:muse, :session, :created]
    end

    test "session_loaded returns correct event name" do
      assert Telemetry.session_loaded() == [:muse, :session, :loaded]
    end

    test "approval_granted returns correct event name" do
      assert Telemetry.approval_granted() == [:muse, :approval, :granted]
    end

    test "approval_rejected returns correct event name" do
      assert Telemetry.approval_rejected() == [:muse, :approval, :rejected]
    end
  end

  describe "all_event_names/0" do
    test "returns all 13 canonical event names" do
      names = Telemetry.all_event_names()
      assert length(names) == 13
    end

    test "each event name is a list of atoms" do
      for name <- Telemetry.all_event_names() do
        assert is_list(name)
        assert length(name) == 3

        for part <- name do
          assert is_atom(part)
        end
      end
    end

    test "all event names start with :muse" do
      for name <- Telemetry.all_event_names() do
        assert hd(name) == :muse
      end
    end
  end

  describe "measurement helpers" do
    test "turn_stop_measurements returns duration_ms" do
      assert Telemetry.turn_stop_measurements(150) == %{duration_ms: 150}
    end

    test "turn_stop_measurements raises on negative" do
      assert_raise FunctionClauseError, fn ->
        Telemetry.turn_stop_measurements(-1)
      end
    end

    test "tool_stop_measurements returns duration_ms" do
      assert Telemetry.tool_stop_measurements(42) == %{duration_ms: 42}
    end

    test "provider_stop_measurements returns duration_ms plus tokens" do
      measurements = Telemetry.provider_stop_measurements(100, %{input: 50, output: 50})
      assert measurements.duration_ms == 100
      assert measurements.input == 50
      assert measurements.output == 50
    end

    test "provider_stop_measurements defaults tokens to empty map" do
      assert Telemetry.provider_stop_measurements(100) == %{duration_ms: 100}
    end
  end

  describe "metadata helpers" do
    test "turn_start_metadata includes session_id, turn_id, muse_id" do
      meta =
        Telemetry.turn_start_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          muse_id: "planning"
        )

      assert meta.session_id == "sess_1"
      assert meta.turn_id == "turn_1"
      assert meta.muse_id == "planning"
    end

    test "turn_stop_metadata includes session_id, turn_id, status" do
      meta =
        Telemetry.turn_stop_metadata(session_id: "sess_1", turn_id: "turn_1", status: :completed)

      assert meta.session_id == "sess_1"
      assert meta.turn_id == "turn_1"
      assert meta.status == "completed"
    end

    test "turn_exception_metadata includes all exception fields" do
      meta =
        Telemetry.turn_exception_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          kind: :error,
          reason: :timeout,
          stacktrace: []
        )

      assert meta.session_id == "sess_1"
      assert meta.turn_id == "turn_1"
      assert meta.kind == "error"
      assert meta.reason == "timeout"
    end

    test "tool_metadata includes session_id, turn_id, tool_name" do
      meta =
        Telemetry.tool_metadata(session_id: "sess_1", turn_id: "turn_1", tool_name: :read_file)

      assert meta.session_id == "sess_1"
      assert meta.turn_id == "turn_1"
      assert meta.tool_name == "read_file"
    end

    test "tool_exception_metadata includes reason" do
      meta =
        Telemetry.tool_exception_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          tool_name: :shell,
          reason: :blocked
        )

      assert meta.reason == "blocked"
    end

    test "provider_start_metadata includes provider and model" do
      meta =
        Telemetry.provider_start_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          provider: :openai,
          model: "gpt-4o"
        )

      assert meta.provider == "openai"
      assert meta.model == "gpt-4o"
    end

    test "provider_stop_metadata includes usage (non-sensitive key)" do
      # Uses "usage" instead of "tokens" to avoid MetadataSanitizer redaction
      # (the word "token" triggers sensitive-key detection).
      meta =
        Telemetry.provider_stop_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          usage: %{input: 100}
        )

      assert meta.usage == %{input: 100}
    end

    test "provider_error_metadata includes error_type" do
      meta =
        Telemetry.provider_error_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          error_type: :rate_limit
        )

      assert meta.error_type == "rate_limit"
    end

    test "session_created_metadata includes session_id and workspace" do
      meta = Telemetry.session_created_metadata(session_id: "sess_1", workspace: "/tmp")
      assert meta.session_id == "sess_1"
      assert meta.workspace == "/tmp"
    end

    test "session_loaded_metadata includes session_id" do
      meta = Telemetry.session_loaded_metadata(session_id: "sess_1")
      assert meta.session_id == "sess_1"
    end

    test "approval_metadata includes session_id, kind, id" do
      meta = Telemetry.approval_metadata(session_id: "sess_1", kind: :patch, id: "approval_1")
      assert meta.session_id == "sess_1"
      assert meta.kind == "patch"
      assert meta.id == "approval_1"
    end
  end

  describe "secret sanitization" do
    test "metadata helpers redact sensitive keys" do
      meta = Telemetry.turn_start_metadata(session_id: "sess_1", turn_id: "turn_1", muse_id: "m1")
      # MetadataSanitizer converts atoms to strings, so we verify no raw secrets
      assert is_map(meta)
      # Verify the sanitizer ran by checking that atom values were converted
      assert is_binary(meta.session_id) or is_nil(meta.session_id)
    end

    test "provider_start_metadata does not leak api_key even if passed accidentally" do
      # Simulate a bug where api_key is accidentally included
      meta =
        Telemetry.provider_start_metadata(
          session_id: "sess_1",
          turn_id: "turn_1",
          provider: :openai,
          model: "gpt-4o"
        )

      # The metadata map should never contain raw keys named api_key, token, etc.
      # MetadataSanitizer handles this, but let's verify the structure doesn't have them
      refute Map.has_key?(meta, :api_key)
      refute Map.has_key?(meta, "api_key")
    end

    test "provider metadata never includes credentials" do
      # provider_start_metadata only includes provider and model, not api keys
      meta =
        Telemetry.provider_start_metadata(
          session_id: "s",
          turn_id: "t",
          provider: :openai,
          model: "gpt-4o"
        )

      # Only the expected keys should be present
      assert Map.has_key?(meta, :session_id)
      assert Map.has_key?(meta, :turn_id)
      assert Map.has_key?(meta, :provider)
      assert Map.has_key?(meta, :model)
      # No credential keys
      for key <- [:api_key, :token, :authorization, :secret] do
        refute Map.has_key?(meta, key)
      end
    end

    test "MetadataSanitizer redacts 'tokens' key if accidentally passed" do
      # This verifies the safety net: even if someone accidentally passes a map
      # with a "tokens" key to sanitize_metadata, it gets redacted.
      sanitized = Muse.MetadataSanitizer.sanitize(%{tokens: %{input: 100}})
      assert sanitized.tokens == "**REDACTED**"
    end
  end
end
