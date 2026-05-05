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

    test "only includes chat and safe plan lifecycle events" do
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

    test "plan lifecycle events render as safe system status messages" do
      raw_plan_json =
        ~s({"objective":"Secret plan","tasks":[{"title":"Leak","description":"Nope"}]})

      events = [
        make_event(
          :plan_approved,
          %{plan_id: "plan_1", version: 2, task_count: 3, raw: raw_plan_json},
          id: 10,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )
      ]

      [message] = EventStream.chat_messages(events)

      assert message.role == :system
      assert message.text =~ "Plan approved: plan_1 (version 2)"
      assert message.text =~ "implementation still requires a later explicit gate"
      refute message.text =~ "Secret plan"
      refute message.text =~ ~s("tasks")
    end

    test "internal plan lifecycle events are not rendered into chat" do
      events = [
        make_event(:plan_approved, %{plan_id: "internal-plan"},
          id: 11,
          turn_id: nil,
          seq: nil,
          timestamp: now(),
          visibility: :internal
        )
      ]

      assert EventStream.chat_messages(events) == []
    end

    test "chat text suppresses raw plan JSON and redacts secrets" do
      events = [
        make_event(
          :assistant_message,
          %{text: "token=abc123 #{~s({"objective":"Hidden","tasks":[]})}"},
          id: 12,
          turn_id: "t-safe",
          seq: 1,
          timestamp: now()
        )
      ]

      [message] = EventStream.chat_messages(events)

      assert message.text =~ "structured plan JSON omitted"
      refute message.text =~ "abc123"
      refute message.text =~ "Hidden"
      refute message.text =~ ~s("tasks")
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
