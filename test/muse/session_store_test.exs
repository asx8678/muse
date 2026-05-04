defmodule Muse.SessionStoreTest do
  use ExUnit.Case, async: false

  alias Muse.SessionStore

  setup do
    base_dir = tmp_dir!()
    session_id = "test-session-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    %{base_dir: base_dir, session_id: session_id}
  end

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "muse-session-store-test-#{suffix}"
      )

    # Defensive: clean any stale dir from a previous crashed run
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  # ── session_dir/2 ──────────────────────────────────────────────────────

  describe "session_dir/2" do
    test "returns a deterministic path" do
      assert SessionStore.session_dir("/tmp/sessions", "abc-123") ==
               "/tmp/sessions/abc-123"
    end

    test "uses default base dir" do
      assert String.ends_with?(SessionStore.session_dir("abc-123"), "/abc-123")
      assert String.starts_with?(SessionStore.session_dir("abc-123"), ".muse/sessions")
    end

    test "accepts custom base dir" do
      assert SessionStore.session_dir("/custom/path", "xyz") ==
               "/custom/path/xyz"
    end
  end

  # ── Session ID validation ──────────────────────────────────────────────

  describe "session ID validation" do
    test "rejects empty session id", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, ""}} =
               SessionStore.save_session(base_dir, "", %{"a" => 1})

      assert {:error, {:invalid_session_id, ""}} =
               SessionStore.load_session(base_dir, "")

      assert {:error, {:invalid_session_id, ""}} =
               SessionStore.append_event(base_dir, "", %{})
    end

    test "rejects dot-only session ids", %{base_dir: base_dir} do
      for id <- [".", ".."] do
        assert {:error, {:invalid_session_id, ^id}} =
                 SessionStore.save_session(base_dir, id, %{"a" => 1})
      end
    end

    test "rejects session id with forward slash", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.save_session(base_dir, "../escape", %{"a" => 1})
    end

    test "rejects session id with backslash", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "foo\\bar"}} =
               SessionStore.save_session(base_dir, "foo\\bar", %{"a" => 1})
    end

    test "rejects session id with NUL byte", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "foo\0bar"}} =
               SessionStore.save_session(base_dir, "foo\0bar", %{"a" => 1})
    end

    test "path traversal does not write outside base dir", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.save_session(base_dir, "../escape", %{"data" => "should not persist"})

      assert {:error, {:invalid_session_id, "sub/../escape"}} =
               SessionStore.save_session(base_dir, "sub/../escape", %{
                 "data" => "should not persist"
               })

      # No session file or directory was created inside base_dir for these invalid ids
      session_path = Path.join(SessionStore.session_dir(base_dir, "../escape"), "session.json")

      refute File.exists?(session_path),
             "no session.json should exist for invalid session id"

      sub_path = Path.join(SessionStore.session_dir(base_dir, "sub/../escape"), "session.json")

      refute File.exists?(sub_path),
             "no session.json should exist for path-traversal id"
    end

    test "accepts normal alphanumeric session ids", %{base_dir: base_dir, session_id: session_id} do
      assert :ok = SessionStore.save_session(base_dir, session_id, %{"a" => 1})
      assert {:ok, _} = SessionStore.load_session(base_dir, session_id)
    end

    test "accepts session id with hyphens and underscores", %{base_dir: base_dir} do
      assert :ok = SessionStore.save_session(base_dir, "my-session_id_123", %{"a" => 1})
      assert {:ok, _} = SessionStore.load_session(base_dir, "my-session_id_123")
    end

    test "rejects non-binary session id", %{base_dir: base_dir} do
      # session_dir/2 has a guard, but save_session validates
      assert {:error, {:invalid_session_id, :atom_id}} =
               SessionStore.save_session(base_dir, :atom_id, %{"a" => 1})
    end

    test "load_events rejects invalid session id", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.load_events(base_dir, "../escape")
    end

    test "load_messages rejects invalid session id", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.load_messages(base_dir, "../escape")
    end
  end

  # ── save_session/3 and load_session/2 ──────────────────────────────────

  describe "save_session/3 and load_session/2" do
    test "happy path round-trip", %{base_dir: base_dir, session_id: session_id} do
      data = %{"objective" => "Build something", "status" => "created"}

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["objective"] == "Build something"
      assert loaded["status"] == "created"
      refute Map.has_key?(loaded, "schema_version")
    end

    test "saves atom keys as strings", %{base_dir: base_dir, session_id: session_id} do
      data = %{objective: "Test", status: :active, count: 42}

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["objective"] == "Test"
      assert loaded["status"] == "active"
      assert loaded["count"] == 42
    end

    test "creates session directory automatically", %{base_dir: base_dir, session_id: session_id} do
      data = %{"msg" => "hello"}
      assert :ok = SessionStore.save_session(base_dir, session_id, data)

      dir = SessionStore.session_dir(base_dir, session_id)
      assert File.dir?(dir)
      assert File.exists?(Path.join(dir, "session.json"))
    end

    test "overwrites existing session.json", %{base_dir: base_dir, session_id: session_id} do
      SessionStore.save_session(base_dir, session_id, %{"v" => 1})
      SessionStore.save_session(base_dir, session_id, %{"v" => 2})

      assert {:ok, %{"v" => 2}} = SessionStore.load_session(base_dir, session_id)
    end

    test "returns error for non-existent session", %{base_dir: base_dir} do
      assert {:error, _reason} = SessionStore.load_session(base_dir, "no-such-session")
    end

    test "returns error for corrupt session.json with {:corrupt_json, reason}",
         %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "session.json"), "not valid json")

      assert {:error, {:corrupt_json, _reason}} =
               SessionStore.load_session(base_dir, session_id)
    end

    test "returns error for unresolvable path", %{base_dir: base_dir} do
      # A path that is guaranteed to fail File.read
      assert {:error, _reason} =
               SessionStore.load_session(base_dir, "nonexistent-session")
    end

    test "round-trips active plan lifecycle snapshot", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      plan =
        Muse.Plan.new(
          id: "plan-store-roundtrip",
          session_id: session_id,
          objective: "Persist active plan lifecycle state",
          version: 3,
          status: :awaiting_approval,
          tasks: [Muse.Task.new(title: "Persist", description: "Persist active plan")]
        )

      data = %{
        "status" => "awaiting_plan_approval",
        "active_plan_id" => plan.id,
        "plan" => Muse.Plan.to_map(plan),
        "plans" => %{plan.id => Muse.Plan.to_map(plan)}
      }

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["status"] == "awaiting_plan_approval"
      assert loaded["active_plan_id"] == plan.id
      assert loaded["plan"]["id"] == plan.id
      assert loaded["plan"]["session_id"] == session_id
      assert loaded["plan"]["version"] == 3
      assert loaded["plan"]["status"] == "awaiting_approval"
      assert get_in(loaded, ["plans", plan.id, "version"]) == 3
    end

    test "atomic write cleans up .tmp files", %{base_dir: base_dir, session_id: session_id} do
      SessionStore.save_session(base_dir, session_id, %{"data" => "atomic"})

      dir = SessionStore.session_dir(base_dir, session_id)

      assert [] ==
               dir
               |> File.ls!()
               |> Enum.filter(&String.ends_with?(&1, ".tmp"))
    end
  end

  # ── append_event/3 and load_events/2 ───────────────────────────────────

  describe "append_event/3 and load_events/2" do
    test "append and replay in order", %{base_dir: base_dir, session_id: session_id} do
      e1 = %{"type" => "user_message", "text" => "hello"}
      e2 = %{"type" => "assistant_delta", "text" => "hi"}
      e3 = %{"type" => "user_message", "text" => "how are you?"}

      assert :ok = SessionStore.append_event(base_dir, session_id, e1)
      assert :ok = SessionStore.append_event(base_dir, session_id, e2)
      assert :ok = SessionStore.append_event(base_dir, session_id, e3)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 3

      [first, second, third] = events
      assert first["text"] == "hello"
      assert second["text"] == "hi"
      assert third["text"] == "how are you?"
    end

    test "empty file returns empty list", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "events.jsonl"), "")

      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
    end

    test "missing file returns empty list", %{base_dir: base_dir, session_id: session_id} do
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
    end

    test "returns error for values that cannot be serialized",
         %{base_dir: base_dir, session_id: session_id} do
      # Jason cannot encode anonymous functions
      assert {:error, {:encode_failed, _reason}} =
               SessionStore.append_event(base_dir, session_id, %{"bad" => fn -> :ok end})
    end

    test "separate namespaces from messages", %{base_dir: base_dir, session_id: session_id} do
      SessionStore.append_event(base_dir, session_id, %{"from" => "event"})
      SessionStore.append_message(base_dir, session_id, %{"from" => "message"})

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert {:ok, messages, %{skipped: 0}} = SessionStore.load_messages(base_dir, session_id)

      assert length(events) == 1
      assert length(messages) == 1
      assert hd(events)["from"] == "event"
      assert hd(messages)["from"] == "message"
    end

    test "appends survive partial file truncation", %{base_dir: base_dir, session_id: session_id} do
      # Simulate a crash that leaves a partial line at the end
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "events.jsonl")

      # Write one valid line and one partial (incomplete JSON)
      File.write!(path, ~s|{"type":"valid"}\n{"type":"partial\n|)

      assert {:ok, events, %{skipped: 1}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 1
      assert hd(events)["type"] == "valid"
    end
  end

  # ── append_message/3 and load_messages/2 ───────────────────────────────

  describe "append_message/3 and load_messages/2" do
    test "append and replay", %{base_dir: base_dir, session_id: session_id} do
      m1 = %{"role" => "user", "content" => "Hi"}
      m2 = %{"role" => "assistant", "content" => "Hello"}

      assert :ok = SessionStore.append_message(base_dir, session_id, m1)
      assert :ok = SessionStore.append_message(base_dir, session_id, m2)

      assert {:ok, messages, %{skipped: 0}} = SessionStore.load_messages(base_dir, session_id)
      assert length(messages) == 2

      [first, second] = messages
      assert first["role"] == "user"
      assert second["role"] == "assistant"
    end
  end

  # ── Corrupt-line handling ──────────────────────────────────────────────

  describe "corrupt-line handling" do
    test "skips corrupt lines mid-file", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "events.jsonl")

      File.write!(path, ~s|{"seq":1}\nNOT_JSON\n{"seq":2}\n{"seq":3}\n|)

      assert {:ok, events, %{skipped: 1}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 3

      [e1, e2, e3] = events
      assert e1["seq"] == 1
      assert e2["seq"] == 2
      assert e3["seq"] == 3
    end

    test "skips multiple corrupt lines", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "events.jsonl")

      File.write!(path, ~s|BAD\n{"ok":1}\nBROKEN\n{"ok":2}\nGARBAGE\n|)

      assert {:ok, events, %{skipped: 3}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 2
    end

    test "all corrupt lines returns empty list", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "events.jsonl")

      File.write!(path, "garbage\nbad\ncorrupt\n")

      assert {:ok, [], %{skipped: 3}} = SessionStore.load_events(base_dir, session_id)
    end

    test "does not crash on binary garbage", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "events.jsonl")

      File.write!(path, <<0, 0, 0, 0, 255, 254, 253>>)

      assert {:ok, [], %{skipped: 1}} = SessionStore.load_events(base_dir, session_id)
    end

    test "empty lines do not count as corrupt", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      path = Path.join(dir, "events.jsonl")

      File.write!(path, ~s|{"a":1}\n\n\n{"a":2}\n|)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 2
    end
  end

  # ── Muse.Event round-trip ──────────────────────────────────────────────

  describe "Muse.Event round-trip" do
    test "serializes and deserializes a Muse.Event struct as map",
         %{base_dir: base_dir, session_id: session_id} do
      event = Muse.Event.new(:test, :ping, %{payload: "hello"})

      assert :ok = SessionStore.append_event(base_dir, session_id, event)

      assert {:ok, [loaded], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)

      assert loaded["source"] == "test"
      assert loaded["type"] == "ping"
      assert loaded["data"]["payload"] == "hello"
      assert is_integer(loaded["id"])
      assert is_binary(loaded["timestamp"])
    end

    test "multiple event round-trip preserves order",
         %{base_dir: base_dir, session_id: session_id} do
      events =
        for i <- 1..5 do
          Muse.Event.new(:test, :sequence, %{index: i})
        end

      for event <- events do
        SessionStore.append_event(base_dir, session_id, event)
      end

      assert {:ok, loaded, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert length(loaded) == 5

      for {decoded, idx} <- Enum.zip(loaded, 1..5) do
        assert decoded["data"]["index"] == idx
      end
    end

    test "event data with nested maps",
         %{base_dir: base_dir, session_id: session_id} do
      event =
        Muse.Event.new(:planning, :analysis, %{
          files: ["a.ex", "b.ex"],
          scores: %{complexity: 5, cohesion: 0.8}
        })

      assert :ok = SessionStore.append_event(base_dir, session_id, event)
      assert {:ok, [loaded], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)

      assert loaded["data"]["files"] == ["a.ex", "b.ex"]
      assert loaded["data"]["scores"]["complexity"] == 5
      assert loaded["data"]["scores"]["cohesion"] == 0.8
    end

    test "event with atom values in data",
         %{base_dir: base_dir, session_id: session_id} do
      event = Muse.Event.new(:session, :status, %{status: :running, mode: :streaming})

      assert :ok = SessionStore.append_event(base_dir, session_id, event)
      assert {:ok, [loaded], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)

      assert loaded["data"]["status"] == "running"
      assert loaded["data"]["mode"] == "streaming"
    end

    test "Event.new/4 metadata round-trip persists session_id, turn_id, seq, visibility",
         %{base_dir: base_dir, session_id: session_id} do
      event =
        Muse.Event.new(:planning_muse, :assistant_delta, %{text: "..."},
          session_id: "sess_42",
          turn_id: "turn_abc",
          seq: 7,
          visibility: :user,
          muse_id: "planning_muse"
        )

      assert :ok = SessionStore.append_event(base_dir, session_id, event)
      assert {:ok, [loaded], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)

      assert loaded["session_id"] == "sess_42"
      assert loaded["turn_id"] == "turn_abc"
      assert loaded["seq"] == 7
      assert loaded["visibility"] == "user"
      assert loaded["muse_id"] == "planning_muse"
    end
  end

  # ── Sensitive key redaction ────────────────────────────────────────────

  describe "sensitive key redaction" do
    test "redacts sensitive keys from session snapshot",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{
        "objective" => "Build feature",
        "api_key" => "sk-test-12345",
        "config" => %{"token" => "secret-value", "name" => "safe"}
      }

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["objective"] == "Build feature"
      assert loaded["api_key"] == "**REDACTED**"
      assert loaded["config"]["token"] == "**REDACTED**"
      assert loaded["config"]["name"] == "safe"
    end

    test "redacts sensitive keys from events",
         %{base_dir: base_dir, session_id: session_id} do
      event_data = %{provider: "anthropic", api_key: "sk-ant-test", messages: [%{role: "user"}]}

      assert :ok =
               SessionStore.append_event(base_dir, session_id, %{
                 "type" => "test",
                 "data" => event_data
               })

      assert {:ok, [loaded], %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert loaded["data"]["api_key"] == "**REDACTED**"
      assert loaded["data"]["provider"] == "anthropic"
      assert loaded["data"]["messages"] == [%{"role" => "user"}]
    end

    test "redacts sensitive atom keys",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{api_key: "sk-test-value", safe_field: "keep-me"}

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["api_key"] == "**REDACTED**"
      assert loaded["safe_field"] == "keep-me"
    end

    test "redacted values are not the original secret in raw file",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{"api_key" => "sk-test-12345", "password" => "hunter2"}

      assert :ok = SessionStore.save_session(base_dir, session_id, data)

      {:ok, raw} =
        File.read(Path.join(SessionStore.session_dir(base_dir, session_id), "session.json"))

      # The raw file must NOT contain the original secrets
      refute String.contains?(raw, "sk-test-12345"),
             "raw session.json must not contain original secret value"

      refute String.contains?(raw, "hunter2"),
             "raw session.json must not contain original password value"

      # But it MUST contain the redaction marker
      assert String.contains?(raw, "**REDACTED**"),
             "raw session.json must contain redaction marker"
    end

    test "redacted secrets do not appear in raw events file",
         %{base_dir: base_dir, session_id: session_id} do
      event_data = %{provider: "anthropic", api_key: "sk-ant-real-test"}

      SessionStore.append_event(
        base_dir,
        session_id,
        %{"type" => "test", "data" => event_data}
      )

      {:ok, raw} =
        File.read(Path.join(SessionStore.session_dir(base_dir, session_id), "events.jsonl"))

      refute String.contains?(raw, "sk-ant-real-test"),
             "raw events.jsonl must not contain original secret"

      assert String.contains?(raw, "**REDACTED**"),
             "raw events.jsonl must contain redaction marker"
    end

    test "non-sensitive keys are preserved",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{
        "source" => "cli",
        "objective" => "build feature",
        "config" => %{"model" => "gpt-4", "temperature" => 0.7}
      }

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded} = SessionStore.load_session(base_dir, session_id)

      assert loaded["source"] == "cli"
      assert loaded["objective"] == "build feature"
      assert loaded["config"]["model"] == "gpt-4"
      assert loaded["config"]["temperature"] == 0.7
    end
  end

  # ── No real secrets in persisted data ──────────────────────────────────

  describe "no secrets in persisted data" do
    test "test data uses non-production credential patterns",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{
        "objective" => "Build feature",
        "provider" => "openai",
        "api_key" => "sk-test-12345"
      }

      SessionStore.save_session(base_dir, session_id, data)

      {:ok, raw} =
        File.read(Path.join(SessionStore.session_dir(base_dir, session_id), "session.json"))

      # SessionStore redacts, but this test is a safety net for test-data hygiene
      refute String.contains?(raw, "sk-prod-")
      refute String.contains?(raw, "Bearer")
    end

    test "test data uses non-production credential patterns in events",
         %{base_dir: base_dir, session_id: session_id} do
      event_data = %{provider: "anthropic", api_key: "sk-ant-test"}

      SessionStore.append_event(
        base_dir,
        session_id,
        %{"type" => "test", "data" => event_data}
      )

      {:ok, raw} =
        File.read(Path.join(SessionStore.session_dir(base_dir, session_id), "events.jsonl"))

      refute String.contains?(raw, "sk-prod-")
      refute String.contains?(raw, "Bearer")
    end
  end

  # ── Temp-dir isolation ─────────────────────────────────────────────────

  describe "temp-dir isolation" do
    test "each run uses a fresh base_dir", %{base_dir: base_dir, session_id: session_id} do
      assert :ok = SessionStore.save_session(base_dir, session_id, %{"run" => 1})
      assert {:ok, %{"run" => 1}} = SessionStore.load_session(base_dir, session_id)

      # Session dir and session.json exist during the test
      session_dir = SessionStore.session_dir(base_dir, session_id)
      assert File.dir?(session_dir)
      assert File.exists?(Path.join(session_dir, "session.json"))
    end

    test "subsequent run with fresh dir is independent",
         %{base_dir: base_dir, session_id: session_id} do
      # Fresh base_dir and session_id from setup
      assert :ok = SessionStore.save_session(base_dir, session_id, %{"run" => 2})
      assert {:ok, %{"run" => 2}} = SessionStore.load_session(base_dir, session_id)

      # on_exit will clean up base_dir after the test completes
    end
  end

  # ── Repeated deterministic runs ────────────────────────────────────────

  describe "repeated deterministic runs" do
    test "two saves and loads with same data produce same result",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{"objective" => "test", "count" => 42}

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded1} = SessionStore.load_session(base_dir, session_id)

      assert :ok = SessionStore.save_session(base_dir, session_id, data)
      assert {:ok, loaded2} = SessionStore.load_session(base_dir, session_id)

      assert loaded1 == loaded2
    end

    test "append and replay produces same events across multiple load calls",
         %{base_dir: base_dir, session_id: session_id} do
      SessionStore.append_event(base_dir, session_id, %{"seq" => 1})
      SessionStore.append_event(base_dir, session_id, %{"seq" => 2})

      assert {:ok, e1, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert {:ok, e2, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)

      assert e1 == e2
    end
  end
end
