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
        :ok
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

  defp timestamp(second) do
    DateTime.new!(~D[2025-01-01], Time.new!(0, 0, second), "Etc/UTC")
  end

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

  # -- external replay/envelopes ------------------------------------------------

  describe "external_replay/1 and external_replay/2" do
    test "returns the newest limited replay for a session in oldest-first order" do
      events = [
        make_event(:user_message, %{text: "first"},
          id: 1,
          timestamp: timestamp(1),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:assistant_delta, %{text: "second"},
          id: 2,
          timestamp: timestamp(2),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:assistant_message, %{text: "third"},
          id: 3,
          timestamp: timestamp(3),
          session_id: "s1",
          visibility: :user
        )
      ]

      envelopes = EventStream.external_replay(events, session_id: "s1", replay_limit: 2)

      assert Enum.map(envelopes, & &1["id"]) == [2, 3]
      assert Enum.map(envelopes, &get_in(&1, ["data", "text"])) == ["second", "third"]

      assert EventStream.external_replay(session_id: "s1", events: events, replay_limit: 3)
             |> Enum.map(& &1["id"]) == [1, 2, 3]
    end

    test "requires a session id and isolates events by session" do
      events = [
        make_event(:user_message, %{text: "s1"},
          id: 1,
          timestamp: timestamp(1),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:user_message, %{text: "s2"},
          id: 2,
          timestamp: timestamp(2),
          session_id: "s2",
          visibility: :user
        )
      ]

      assert EventStream.external_replay(events, session_id: "s1", replay_limit: 10)
             |> Enum.map(& &1["id"]) == [1]

      assert EventStream.external_replay(events, replay_limit: 10) == []
    end

    test "filters to externally safe visibility only" do
      events = [
        make_event(:user_message, %{text: "visible"},
          id: 1,
          timestamp: timestamp(1),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:user_message, %{text: "debug"},
          id: 2,
          timestamp: timestamp(2),
          session_id: "s1",
          visibility: :debug
        ),
        make_event(:user_message, %{text: "internal"},
          id: 3,
          timestamp: timestamp(3),
          session_id: "s1",
          visibility: :internal
        ),
        make_event(:user_message, %{text: "sensitive"},
          id: 4,
          timestamp: timestamp(4),
          session_id: "s1",
          visibility: :sensitive
        ),
        make_event(:user_message, %{text: "legacy"},
          id: 5,
          timestamp: timestamp(5),
          session_id: "s1",
          visibility: nil
        )
      ]

      assert EventStream.external_replay(events, session_id: "s1", replay_limit: 10)
             |> Enum.map(& &1["id"]) == [1]

      assert EventStream.external_replay(events,
               session_id: "s1",
               replay_limit: 10,
               visibility: :debug
             ) == []
    end

    test "keeps only allowlisted event types and supports safe narrowing by string type" do
      events = [
        make_event(:user_message, %{text: "question"},
          id: 1,
          timestamp: timestamp(1),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:assistant_delta, %{text: "answer"},
          id: 2,
          timestamp: timestamp(2),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:provider_response_started, %{},
          id: 3,
          timestamp: timestamp(3),
          session_id: "s1",
          visibility: :user
        )
      ]

      assert EventStream.external_replay(events, session_id: "s1", replay_limit: 10)
             |> Enum.map(& &1["type"]) == ["user_message", "assistant_delta"]

      assert EventStream.external_replay(events,
               session_id: "s1",
               replay_limit: 10,
               event_types: ["assistant_delta", "provider_response_started"]
             )
             |> Enum.map(& &1["id"]) == [2]
    end

    test "uses configured replay limit when opts omit a limit" do
      previous = Application.get_env(:muse, :external_event_stream, :__unset__)

      on_exit(fn ->
        case previous do
          :__unset__ -> Application.delete_env(:muse, :external_event_stream)
          value -> Application.put_env(:muse, :external_event_stream, value)
        end
      end)

      Application.put_env(:muse, :external_event_stream, replay_limit: 1)

      events = [
        make_event(:user_message, %{text: "one"},
          id: 1,
          timestamp: timestamp(1),
          session_id: "s1",
          visibility: :user
        ),
        make_event(:user_message, %{text: "two"},
          id: 2,
          timestamp: timestamp(2),
          session_id: "s1",
          visibility: :user
        )
      ]

      assert EventStream.external_replay(events, session_id: "s1")
             |> Enum.map(& &1["id"]) == [2]
    end

    test "returns JSON-safe redacted envelopes" do
      event =
        make_event(
          :assistant_message,
          %{
            text: "API_KEY=abcdefghijklmnopqrstuvwxyz0123456789",
            at: timestamp(1),
            tuple: {:ok, :done},
            pid: self(),
            nested: %{atom_key: :atom_value}
          },
          id: 42,
          timestamp: timestamp(2),
          session_id: "s1",
          turn_id: "turn-1",
          seq: 7,
          visibility: :user,
          muse_id: "planning_muse"
        )

      [envelope] = EventStream.external_replay([event], session_id: "s1", replay_limit: 10)

      assert envelope["source"] == "test"
      assert envelope["type"] == "assistant_message"
      assert envelope["visibility"] == "user"
      assert envelope["turn_id"] == "turn-1"
      assert envelope["seq"] == 7
      assert envelope["muse_id"] == "planning_muse"
      assert envelope["data"]["text"] == "[REDACTED]"
      assert envelope["data"]["at"] == DateTime.to_iso8601(timestamp(1))
      assert envelope["data"]["tuple"] == ["ok", "done"]
      assert envelope["data"]["nested"] == %{"atom_key" => "atom_value"}
      assert is_binary(envelope["data"]["pid"])
      assert Jason.encode!(envelope)
    end

    test "external_envelope/2 applies the same live-event filter" do
      visible =
        make_event(:assistant_delta, %{text: "chunk"},
          id: 1,
          timestamp: timestamp(1),
          session_id: "s1",
          visibility: :user
        )

      other_session =
        make_event(:assistant_delta, %{text: "other"},
          id: 2,
          timestamp: timestamp(2),
          session_id: "s2",
          visibility: :user
        )

      debug =
        make_event(:assistant_delta, %{text: "debug"},
          id: 3,
          timestamp: timestamp(3),
          session_id: "s1",
          visibility: :debug
        )

      assert %{"id" => 1, "data" => %{"text" => "chunk"}} =
               EventStream.external_envelope(visible, session_id: "s1")

      assert EventStream.external_envelope(other_session, session_id: "s1") == nil
      assert EventStream.external_envelope(debug, session_id: "s1") == nil
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
end
