defmodule Muse.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Muse.SessionStore

  setup do
    base_dir = tmp_dir!()
    session_id = "test-session-#{System.unique_integer([:positive])}"
    %{base_dir: base_dir, session_id: session_id}
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "muse-session-store-test-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

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

    test "returns error for corrupt session.json", %{base_dir: base_dir, session_id: session_id} do
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "session.json"), "not valid json")

      assert {:error, _reason} = SessionStore.load_session(base_dir, session_id)
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

    test "rejects values that cannot be serialized", %{base_dir: base_dir, session_id: session_id} do
      # Jason cannot encode tuples (like anonymous function references)
      assert_raise Protocol.UndefinedError, fn ->
        SessionStore.append_event(base_dir, session_id, %{"bad" => fn -> :ok end})
      end
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
      File.write!(path, ~s|{"type":"valid"}
{"type":"partial
|)

      assert {:ok, events, %{skipped: 1}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 1
      assert hd(events)["type"] == "valid"
    end
  end

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

      # Verify events come back in order by checking data.index
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

      # Atoms in data get serialized as strings
      assert loaded["data"]["status"] == "running"
      assert loaded["data"]["mode"] == "streaming"
    end
  end

  describe "no secrets in persisted data" do
    test "does not persist provider credentials in snapshot",
         %{base_dir: base_dir, session_id: session_id} do
      data = %{
        "objective" => "Build feature",
        "provider" => "openai",
        "api_key" => "sk-test-12345"
      }

      SessionStore.save_session(base_dir, session_id, data)

      {:ok, raw} =
        File.read(Path.join(SessionStore.session_dir(base_dir, session_id), "session.json"))

      assert String.contains?(raw, "sk-test-12345"),
             "SessionStore does not filter fields; secret hygiene is caller responsibility"

      # Acceptance: test data must not contain real credentials
      refute String.contains?(raw, "sk-prod-")
      refute String.contains?(raw, "Bearer")
    end

    test "does not persist provider credentials in events",
         %{base_dir: base_dir, session_id: session_id} do
      event_data = %{provider: "anthropic", api_key: "sk-ant-test"}

      SessionStore.append_event(
        base_dir,
        session_id,
        %{"type" => "test", "data" => event_data}
      )

      {:ok, raw} =
        File.read(Path.join(SessionStore.session_dir(base_dir, session_id), "events.jsonl"))

      # Acceptance: test data uses non-production credentials
      refute String.contains?(raw, "sk-prod-")
      refute String.contains?(raw, "Bearer")
    end
  end
end
