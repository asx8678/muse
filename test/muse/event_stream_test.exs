defmodule Muse.EventStreamTest do
  use ExUnit.Case, async: false

  alias Muse.Event
  alias Muse.EventStream
  alias Muse.State

  # -- Setup --------------------------------------------------------------------

  setup do
    case Process.whereis(Muse.State) do
      nil ->
        {:ok, pid} = State.start_link([])
        Process.unlink(pid)

      _pid ->
        # Reset for test isolation — prior sync tests may have left events
        Muse.State.clear()
    end

    on_exit(fn ->
      case Process.whereis(Muse.State) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end)

    :ok
  end

  # -- Helpers ------------------------------------------------------------------

  defp make_event(type, data, opts) do
    Event.new(:test, type, data, opts)
  end

  defp now, do: DateTime.utc_now()

  # -- replay/2 ----------------------------------------------------------------

  describe "replay/2" do
    test "returns all events when no filters given" do
      filtered = EventStream.replay([])
      assert filtered == []
    end

    test "replay with session_id filter" do
      event = Event.new(:test, :user_message, %{text: "hi"}, session_id: "s1", visibility: :user)
      State.append(event)

      filtered = EventStream.replay(session_id: "s1")
      assert length(filtered) == 1

      filtered_other = EventStream.replay(session_id: "other")
      assert filtered_other == []
    end

    test "replay with visibility filter" do
      event = Event.new(:test, :user_message, %{text: "hi"}, session_id: "s1", visibility: :user)
      State.append(event)

      filtered = EventStream.replay(visibility: :user)
      assert length(filtered) == 1

      filtered_debug = EventStream.replay(visibility: :debug)
      assert filtered_debug == []
    end
  end

  # -- chat_messages/1 ----------------------------------------------------------

  describe "chat_messages/1 — basic user/assistant" do
    test "converts user_message and assistant_message to chat messages" do
      events = [
        make_event(:user_message, %{text: "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "hi there"},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2

      [user_msg, asst_msg] = messages
      assert user_msg.role == :user
      assert user_msg.text == "hello"
      assert asst_msg.role == :assistant
      assert asst_msg.text == "hi there"
      assert asst_msg.streaming? == false
    end

    test "only includes user_message, assistant_delta, and assistant_message events" do
      events = [
        make_event(:user_message, %{text: "hi"}, id: 1, turn_id: "t1", seq: 1, timestamp: now()),
        make_event(:turn_started, %{}, id: 2, turn_id: "t1", seq: 2, timestamp: now()),
        make_event(:assistant_delta, %{text: "chunk"},
          id: 3,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "chunk", streamed?: true},
          id: 4,
          turn_id: "t1",
          seq: 4,
          timestamp: now()
        ),
        make_event(:turn_completed, %{}, id: 5, turn_id: "t1", seq: 5, timestamp: now())
      ]

      messages = EventStream.chat_messages(events)
      # turn_started and turn_completed are filtered out
      assert length(messages) == 2
    end
  end

  describe "chat_messages/1 — streaming delta deduplication" do
    test "when streamed? is true, deltas are concatenated and final message is suppressed" do
      events = [
        make_event(:user_message, %{text: "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{text: "Hello", index: 0},
          id: 2,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{text: " world", index: 1},
          id: 3,
          turn_id: "t1",
          seq: 4,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "Hello world", streamed?: true},
          id: 4,
          turn_id: "t1",
          seq: 5,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2

      [user_msg, asst_msg] = messages
      assert user_msg.role == :user
      assert asst_msg.role == :assistant
      # Deltas are concatenated
      assert asst_msg.text == "Hello world"
      assert asst_msg.streaming? == false
    end

    test "when streamed? is false, deltas and final message are both shown" do
      events = [
        make_event(:user_message, %{text: "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{text: "Hello", index: 0},
          id: 2,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "Hello world", streamed?: false},
          id: 3,
          turn_id: "t1",
          seq: 5,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      # Both delta concat and final message
      assert length(messages) == 3

      [_user_msg, delta_msg, final_msg] = messages
      assert delta_msg.text == "Hello"
      assert final_msg.text == "Hello world"
    end

    test "incomplete stream (deltas, no final) shows as streaming" do
      events = [
        make_event(:user_message, %{text: "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{text: "Hello", index: 0},
          id: 2,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{text: " wor", index: 1},
          id: 3,
          turn_id: "t1",
          seq: 4,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2

      [_user_msg, asst_msg] = messages
      assert asst_msg.text == "Hello wor"
      assert asst_msg.streaming? == true
    end
  end

  describe "chat_messages/1 — string-keyed delta text (JSON replay)" do
    test "delta with string key \"text\" renders correctly" do
      events = [
        make_event(:user_message, %{"text" => "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{"text" => "chunk1", "index" => 0},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        ),
        make_event(:assistant_message, %{"text" => "chunk1", "streamed?" => true},
          id: 3,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2

      [user_msg, asst_msg] = messages
      assert user_msg.text == "hello"
      assert asst_msg.text == "chunk1"
      assert asst_msg.streaming? == false
    end

    test "streamed? with string key \"streamed?\" is detected" do
      events = [
        make_event(:assistant_delta, %{"text" => "hi"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_message, %{"text" => "hi", "streamed?" => true},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      # Final should be suppressed (streamed)
      assert length(messages) == 1
      assert hd(messages).text == "hi"
    end
  end

  describe "chat_messages/1 — multiple turns" do
    test "events from different turns produce separate messages" do
      events = [
        make_event(:user_message, %{text: "hi"}, id: 1, turn_id: "t1", seq: 1, timestamp: now()),
        make_event(:assistant_message, %{text: "hello"},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        ),
        make_event(:user_message, %{text: "bye"}, id: 3, turn_id: "t2", seq: 3, timestamp: now()),
        make_event(:assistant_message, %{text: "see ya"},
          id: 4,
          turn_id: "t2",
          seq: 4,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 4

      texts = Enum.map(messages, & &1.text)
      assert texts == ["hi", "hello", "bye", "see ya"]
    end
  end

  describe "chat_messages/1 — nil turn_id (legacy events)" do
    test "two legacy assistant messages with nil turn_id render individually" do
      events = [
        make_event(:assistant_message, %{text: "first legacy"},
          id: 1,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "second legacy"},
          id: 2,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2

      [first, second] = messages
      assert first.text == "first legacy"
      assert second.text == "second legacy"
    end

    test "mixed legacy user/assistant with nil turn_id render individually" do
      events = [
        make_event(:user_message, %{text: "q1"}, id: 1, turn_id: nil, seq: nil, timestamp: now()),
        make_event(:assistant_message, %{text: "a1"},
          id: 2,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:user_message, %{text: "q2"}, id: 3, turn_id: nil, seq: nil, timestamp: now()),
        make_event(:assistant_message, %{text: "a2"},
          id: 4,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 4

      texts = Enum.map(messages, & &1.text)
      assert texts == ["q1", "a1", "q2", "a2"]
    end

    test "legacy events with nil turn_id don't crash when mixed with structured events" do
      events = [
        make_event(:user_message, %{text: "legacy"},
          id: 1,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "old reply"},
          id: 2,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:user_message, %{text: "new"}, id: 3, turn_id: "t1", seq: 1, timestamp: now()),
        make_event(:assistant_message, %{text: "new reply"},
          id: 4,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      # Legacy: 2 messages, structured turn: 2 messages = 4 total
      assert length(messages) == 4
    end
  end

  describe "chat_messages/1 — multiple finals in a turn" do
    test "handles two assistant_message events in same turn gracefully" do
      events = [
        make_event(:assistant_delta, %{text: "partial"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "final1", streamed?: true},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "final2"},
          id: 3,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        )
      ]

      # Should not crash — first final wins for dedup
      messages = EventStream.chat_messages(events)
      assert length(messages) == 1
      # Delta text is concatenated
      assert hd(messages).text == "partial"
    end

    test "no deltas with two finals renders first final only" do
      events = [
        make_event(:assistant_message, %{text: "first"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "second"},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 1
      assert hd(messages).text == "first"
    end
  end

  describe "chat_messages/1 — nil seq values" do
    test "events with nil seq sort before numbered seq" do
      events = [
        make_event(:assistant_delta, %{text: "second"},
          id: 1,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        ),
        make_event(:assistant_delta, %{text: "first"},
          id: 2,
          turn_id: "t1",
          seq: nil,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      # nil seq treated as 0 in sort, so "first" comes before "second"
      assert hd(messages).text == "firstsecond"
    end
  end

  describe "chat_messages/1 — edge cases" do
    test "empty events list returns empty messages" do
      assert EventStream.chat_messages([]) == []
    end

    test "events with only internal types return empty messages" do
      events = [
        make_event(:turn_started, %{}, id: 1, turn_id: "t1", seq: 1, timestamp: now()),
        make_event(:turn_completed, %{}, id: 2, turn_id: "t1", seq: 2, timestamp: now())
      ]

      assert EventStream.chat_messages(events) == []
    end
  end

  # -- external replay/envelopes ------------------------------------------------

  describe "external_replay/1 and external_replay/2" do
    test "returns JSON-safe envelopes for a session" do
      events = [
        make_event(:user_message, %{text: "first"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:01Z],
          session_id: "s1",
          visibility: :user
        ),
        make_event(:assistant_delta, %{text: "second"},
          id: 2,
          timestamp: ~U[2025-01-01 00:00:02Z],
          session_id: "s1",
          visibility: :user
        )
      ]

      envelopes = EventStream.external_replay(events, session_id: "s1", replay_limit: 10)

      assert length(envelopes) == 2
      assert hd(envelopes)["type"] == "user_message"
      assert hd(envelopes)["session_id"] == "s1"
      assert Map.has_key?(hd(envelopes), "payload")
    end

    test "requires a session_id and isolates events by session" do
      events = [
        make_event(:user_message, %{text: "s1"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:01Z],
          session_id: "s1",
          visibility: :user
        ),
        make_event(:user_message, %{text: "s2"},
          id: 2,
          timestamp: ~U[2025-01-01 00:00:02Z],
          session_id: "s2",
          visibility: :user
        )
      ]

      assert EventStream.external_replay(events, session_id: "s1", replay_limit: 10)
             |> Enum.map(& &1["id"]) == [1]

      # Missing session_id returns []
      assert EventStream.external_replay(events, replay_limit: 10) == []
    end

    test "returns [] for invalid/missing session_id without calling Muse.State" do
      # Stop Muse.State so it would crash if called
      case Process.whereis(Muse.State) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end

      # Invalid session_id — should not touch State at all
      assert EventStream.external_replay(session_id: nil) == []
      assert EventStream.external_replay(session_id: "") == []
      assert EventStream.external_replay(session_id: "../escape") == []

      # Missing session_id — also short-circuits
      assert EventStream.external_replay([]) == []
      assert EventStream.external_replay(%{}) == []
    end

    test "returns empty list when session_id is nil" do
      events = [
        make_event(:user_message, %{text: "hi"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:01Z],
          session_id: "s1",
          visibility: :user
        )
      ]

      # Explicitly nil
      assert EventStream.external_replay(events, session_id: nil, replay_limit: 10) == []
    end

    test "returns empty list for blank or invalid session_id" do
      events = [
        make_event(:user_message, %{text: "hi"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:01Z],
          session_id: "s1",
          visibility: :user
        )
      ]

      # Empty string
      assert EventStream.external_replay(events, session_id: "", replay_limit: 10) == []

      # Path traversal
      assert EventStream.external_replay(events, session_id: "../escape", replay_limit: 10) == []

      # Too long
      too_long = String.duplicate("a", 257)
      assert EventStream.external_replay(events, session_id: too_long, replay_limit: 10) == []
    end

    test "does not replay nil-session events even with a valid session_id" do
      events = [
        make_event(:user_message, %{text: "global"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:01Z],
          session_id: nil,
          visibility: :user
        ),
        make_event(:user_message, %{text: "scoped"},
          id: 2,
          timestamp: ~U[2025-01-01 00:00:02Z],
          session_id: "s1",
          visibility: :user
        )
      ]

      result = EventStream.external_replay(events, session_id: "s1", replay_limit: 10)
      assert length(result) == 1
      assert hd(result)["session_id"] == "s1"
    end

    test "filters to externally safe visibility only" do
      events = [
        make_event(:user_message, %{text: "visible"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:01Z],
          session_id: "s1",
          visibility: :user
        ),
        make_event(:user_message, %{text: "debug"},
          id: 2,
          timestamp: ~U[2025-01-01 00:00:02Z],
          session_id: "s1",
          visibility: :debug
        ),
        make_event(:user_message, %{text: "internal"},
          id: 3,
          timestamp: ~U[2025-01-01 00:00:03Z],
          session_id: "s1",
          visibility: :internal
        ),
        make_event(:user_message, %{text: "sensitive"},
          id: 4,
          timestamp: ~U[2025-01-01 00:00:04Z],
          session_id: "s1",
          visibility: :sensitive
        )
      ]

      assert EventStream.external_replay(events, session_id: "s1", replay_limit: 10)
             |> Enum.map(& &1["id"]) == [1]
    end

    test "applies replay limit" do
      events =
        for i <- 1..5 do
          make_event(:user_message, %{text: "msg#{i}"},
            id: i,
            timestamp: ~U[2025-01-01 00:00:00Z],
            session_id: "s1",
            visibility: :user
          )
        end

      result = EventStream.external_replay(events, session_id: "s1", replay_limit: 2)
      assert length(result) == 2
    end

    test "returns JSON-encodable envelopes" do
      event =
        make_event(:user_message, %{text: "hello"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z],
          session_id: "s1",
          visibility: :user
        )

      [envelope] = EventStream.external_replay([event], session_id: "s1", replay_limit: 10)
      assert {:ok, _json} = Jason.encode(envelope)
    end
  end

  describe "external_envelope/2" do
    test "returns envelope for allowed event" do
      event =
        make_event(:user_message, %{text: "hello"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z],
          session_id: "s1",
          visibility: :user
        )

      assert %{"type" => "user_message", "session_id" => "s1"} =
               EventStream.external_envelope(event, session_id: "s1")
    end

    test "returns nil for denied event" do
      event =
        make_event(:user_message, %{text: "hidden"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z],
          session_id: "s1",
          visibility: :internal
        )

      assert EventStream.external_envelope(event, session_id: "s1") == nil
    end

    test "returns nil for session mismatch" do
      event =
        make_event(:user_message, %{text: "other"},
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z],
          session_id: "s2",
          visibility: :user
        )

      assert EventStream.external_envelope(event, session_id: "s1") == nil
    end
  end
end
