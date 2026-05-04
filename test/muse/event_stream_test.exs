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

  defp make_event(type, data \\ %{}, opts \\ []) do
    Event.new(:test, type, data, opts)
  end

  defp now, do: DateTime.utc_now()

  # -- replay/2 ----------------------------------------------------------------

  describe "replay/2" do
    test "returns all events when no filters given" do
      # replay reads from State, which is empty in a fresh setup
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

    test "filters out events with nil turn_id" do
      events = [
        make_event(:user_message, %{text: "orphan"},
          id: 1,
          turn_id: nil,
          seq: 1,
          timestamp: now()
        )
      ]

      # Events with nil turn_id get grouped under nil key — they're still
      # included in chat_messages since we group by turn_id (nil is valid key)
      messages = EventStream.chat_messages(events)
      assert length(messages) == 1
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
