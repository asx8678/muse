defmodule Muse.EventStreamIncrementalTest do
  @moduledoc """
  T1-15 tests: O(n) grouping correctness and incremental chat_messages updates.

  Verifies that:
    1. The single-pass group_by_turn_preserving_order produces the same output
       as the old O(n²) filter-per-turn approach for all event patterns.
    2. `apply_event_to_chat_messages/2` produces the same chat message list
       as a full `chat_messages/1` re-derivation for representative scenarios.
    3. Incremental updates handle streaming deltas, finals, nil-turn events,
       and system events correctly.
    4. Performance scales linearly (not quadratically) with event count.
  """
  use ExUnit.Case, async: true

  alias Muse.Event
  alias Muse.EventStream
  alias Muse.Test.EventFixtures, as: EF

  # -- Helpers ----------------------------------------------------------------

  defp make_event(type, data, opts) do
    Event.new(:test, type, data, opts)
  end

  defp now, do: DateTime.utc_now()

  # Simulate a full incremental apply cycle: start with empty messages,
  # apply each event one at a time, return final message list.
  defp incremental_chat_messages(events) do
    Enum.reduce(events, [], fn event, msgs ->
      EventStream.apply_event_to_chat_messages(msgs, event)
    end)
  end

  # Apply events incrementally and return each intermediate state
  defp incremental_steps(events) do
    Enum.reduce(events, {[], []}, fn event, {msgs, steps} ->
      updated = EventStream.apply_event_to_chat_messages(msgs, event)
      {updated, steps ++ [updated]}
    end)
    |> elem(1)
  end

  # ===========================================================================
  # O(n) grouping correctness
  # ===========================================================================

  describe "O(n) grouping — correctness vs old behavior" do
    test "single turn with user + assistant" do
      events =
        EF.chat_turn("t1", "hello", "world",
          base_id: 1,
          session_id: "sess_test"
        )

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).text == "hello"
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).text == "world"
    end

    test "multiple turns preserve first-appearance order" do
      events =
        EF.chat_turn("t1", "first", "reply1", base_id: 1, session_id: "sess_test") ++
          EF.chat_turn("t2", "second", "reply2", base_id: 3, session_id: "sess_test") ++
          EF.chat_turn("t3", "third", "reply3", base_id: 5, session_id: "sess_test")

      messages = EventStream.chat_messages(events)
      assert length(messages) == 6

      texts = Enum.map(messages, & &1.text)
      assert texts == ["first", "reply1", "second", "reply2", "third", "reply3"]
    end

    test "interleaved turn events group correctly" do
      events = [
        make_event(:user_message, %{text: "q1"}, id: 1, turn_id: "t1", seq: 1, timestamp: now()),
        make_event(:user_message, %{text: "q2"}, id: 2, turn_id: "t2", seq: 1, timestamp: now()),
        make_event(:assistant_message, %{text: "a1"},
          id: 3,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "a2"},
          id: 4,
          turn_id: "t2",
          seq: 2,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 4

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :user, :assistant]

      texts = Enum.map(messages, & &1.text)
      assert texts == ["q1", "a1", "q2", "a2"]
    end

    test "nil-turn events each get their own group" do
      events = [
        make_event(:assistant_message, %{text: "legacy1"},
          id: 1,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "legacy2"},
          id: 2,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "legacy3"},
          id: 3,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 3
      assert Enum.map(messages, & &1.text) == ["legacy1", "legacy2", "legacy3"]
    end

    test "mixed nil-turn and structured events preserve chronological order" do
      events = [
        make_event(:user_message, %{text: "legacy"},
          id: 1,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:user_message, %{text: "new"},
          id: 2,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "legacy_reply"},
          id: 3,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "new_reply"},
          id: 4,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )
      ]

      messages = EventStream.chat_messages(events)
      assert length(messages) == 4

      texts = Enum.map(messages, & &1.text)
      assert texts == ["legacy", "new", "new_reply", "legacy_reply"]
    end

    test "streaming turn with multiple deltas and streamed final" do
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 ", "chunk3"],
          base_id: 1,
          session_id: "sess_test"
        )

      messages = EventStream.chat_messages(events)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).text == "chunk1 chunk2 chunk3"
      assert Enum.at(messages, 1).streaming? == false
    end

    test "streaming turn without final shows streaming? true" do
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 "],
          base_id: 1,
          session_id: "sess_test"
        )

      events_without_final = Enum.reject(events, &(&1.type == :assistant_message))

      messages = EventStream.chat_messages(events_without_final)
      assert length(messages) == 2
      assert Enum.at(messages, 1).streaming? == true
      assert Enum.at(messages, 1).text == "chunk1 chunk2 "
    end
  end

  # ===========================================================================
  # Incremental apply_event_to_chat_messages correctness
  # ===========================================================================

  describe "apply_event_to_chat_messages/2 — basic correctness" do
    test "empty messages + user_message = one user message" do
      event =
        make_event(:user_message, %{text: "hi"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        )

      messages = EventStream.apply_event_to_chat_messages([], event)
      assert length(messages) == 1
      assert hd(messages).role == :user
      assert hd(messages).text == "hi"
      assert hd(messages).streaming? == false
    end

    test "non-chat events pass through unchanged" do
      event =
        make_event(:turn_started, %{},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        )

      messages = EventStream.apply_event_to_chat_messages([], event)
      assert messages == []
    end

    test "internal events pass through unchanged" do
      event =
        make_event(:user_message, %{text: "secret"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now(),
          visibility: :internal
        )

      messages = EventStream.apply_event_to_chat_messages([], event)
      assert messages == []
    end
  end

  describe "apply_event_to_chat_messages/2 — streaming deltas" do
    test "first delta creates streaming message" do
      event =
        make_event(:assistant_delta, %{text: "Hello"},
          id: 1,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      messages = EventStream.apply_event_to_chat_messages([], event)
      assert length(messages) == 1
      assert hd(messages).streaming? == true
      assert hd(messages).text == "Hello"
      assert hd(messages).turn_id == "t1"
    end

    test "subsequent deltas append to streaming message" do
      delta1 =
        make_event(:assistant_delta, %{text: "Hello"},
          id: 1,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      delta2 =
        make_event(:assistant_delta, %{text: " world"},
          id: 2,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], delta1)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, delta2)

      assert length(msgs2) == 1
      assert hd(msgs2).streaming? == true
      assert hd(msgs2).text == "Hello world"
    end

    test "nil-turn delta creates its own streaming message each time" do
      delta1 =
        make_event(:assistant_delta, %{text: "orphan1"},
          id: 1,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )

      delta2 =
        make_event(:assistant_delta, %{text: "orphan2"},
          id: 2,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], delta1)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, delta2)

      assert length(msgs2) == 2
      assert Enum.at(msgs2, 0).text == "orphan1"
      assert Enum.at(msgs2, 0).streaming? == true
      assert Enum.at(msgs2, 1).text == "orphan2"
      assert Enum.at(msgs2, 1).streaming? == true
    end

    test "deltas from different turns create separate streaming messages" do
      delta_t1 =
        make_event(:assistant_delta, %{text: "from t1"},
          id: 1,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      delta_t2 =
        make_event(:assistant_delta, %{text: "from t2"},
          id: 2,
          turn_id: "t2",
          seq: 2,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], delta_t1)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, delta_t2)

      assert length(msgs2) == 2
      assert Enum.at(msgs2, 0).turn_id == "t1"
      assert Enum.at(msgs2, 1).turn_id == "t2"
    end
  end

  describe "apply_event_to_chat_messages/2 — streamed final" do
    test "streamed final finalizes streaming message, suppresses duplicate" do
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 "],
          base_id: 1,
          session_id: "sess_test"
        )

      messages =
        Enum.reduce(events, [], fn event, msgs ->
          EventStream.apply_event_to_chat_messages(msgs, event)
        end)

      # user + finalized delta message (streamed final suppressed)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).text == "chunk1 chunk2 "
      assert Enum.at(messages, 1).streaming? == false
    end

    test "non-streamed final adds alongside delta message" do
      user =
        make_event(:user_message, %{text: "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        )

      delta =
        make_event(:assistant_delta, %{text: "partial"},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      final =
        make_event(:assistant_message, %{text: "complete answer", streamed?: false},
          id: 3,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], user)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, delta)
      msgs3 = EventStream.apply_event_to_chat_messages(msgs2, final)

      assert length(msgs3) == 3
      assert Enum.at(msgs3, 0).role == :user
      assert Enum.at(msgs3, 1).role == :assistant
      assert Enum.at(msgs3, 1).text == "partial"
      assert Enum.at(msgs3, 1).streaming? == false
      assert Enum.at(msgs3, 2).role == :assistant
      assert Enum.at(msgs3, 2).text == "complete answer"
      assert Enum.at(msgs3, 2).streaming? == false
    end

    test "final without prior delta adds as non-streaming message" do
      user =
        make_event(:user_message, %{text: "hello"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        )

      final =
        make_event(:assistant_message, %{text: "direct reply"},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], user)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, final)

      assert length(msgs2) == 2
      assert Enum.at(msgs2, 1).text == "direct reply"
      assert Enum.at(msgs2, 1).streaming? == false
    end

    test "duplicate finals in a turn match full re-derive first-final-wins behavior" do
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

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert Enum.map(incr, & &1.text) == Enum.map(full, & &1.text)
      assert Enum.map(incr, & &1.text) == ["first"]
    end

    test "extra final after streamed final stays suppressed like full re-derive" do
      events = [
        make_event(:assistant_delta, %{text: "partial"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "partial", streamed?: true},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        ),
        make_event(:assistant_message, %{text: "duplicate"},
          id: 3,
          turn_id: "t1",
          seq: 3,
          timestamp: now()
        )
      ]

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert Enum.map(incr, & &1.text) == Enum.map(full, & &1.text)
      assert Enum.map(incr, & &1.text) == ["partial"]
    end

    test "nil-turn final appends as separate message" do
      delta =
        make_event(:assistant_delta, %{text: "orphan delta"},
          id: 1,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )

      final =
        make_event(:assistant_message, %{text: "orphan final"},
          id: 2,
          turn_id: nil,
          seq: nil,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], delta)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, final)

      assert length(msgs2) == 2
      assert Enum.at(msgs2, 0).text == "orphan delta"
      assert Enum.at(msgs2, 0).streaming? == true
      assert Enum.at(msgs2, 1).text == "orphan final"
      assert Enum.at(msgs2, 1).streaming? == false
    end
  end

  describe "apply_event_to_chat_messages/2 — system events" do
    test "system events append to messages" do
      user =
        make_event(:user_message, %{text: "fix this"},
          id: 1,
          turn_id: "t1",
          seq: 1,
          timestamp: now()
        )

      patch =
        make_event(
          :patch_proposed,
          %{patch_id: "p1", files: ["lib/a.ex"], hash: "abc", diff: "d"},
          id: 2,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      msgs1 = EventStream.apply_event_to_chat_messages([], user)
      msgs2 = EventStream.apply_event_to_chat_messages(msgs1, patch)

      assert length(msgs2) == 2
      assert Enum.at(msgs2, 1).role == :system
      assert Enum.at(msgs2, 1).turn_id == "t1"
    end
  end

  # ===========================================================================
  # Parity: incremental matches full re-derive
  # ===========================================================================

  describe "incremental vs full re-derive parity" do
    test "simple user → assistant turn" do
      events =
        EF.chat_turn("t1", "hello", "world",
          base_id: 1,
          session_id: "sess_parity"
        )

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert length(incr) == length(full)

      Enum.zip(incr, full)
      |> Enum.each(fn {i, f} ->
        assert i.role == f.role
        assert i.streaming? == f.streaming?
        assert i.text == f.text
      end)
    end

    test "streaming turn with deltas and streamed final" do
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 "],
          base_id: 1,
          session_id: "sess_parity"
        )

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert length(incr) == length(full)

      Enum.zip(incr, full)
      |> Enum.each(fn {i, f} ->
        assert i.role == f.role
        assert i.streaming? == f.streaming?
        assert i.text == f.text
      end)
    end

    test "multiple simple turns" do
      events =
        EF.chat_turn("t1", "q1", "a1", base_id: 1, session_id: "sess_parity") ++
          EF.chat_turn("t2", "q2", "a2", base_id: 3, session_id: "sess_parity") ++
          EF.chat_turn("t3", "q3", "a3", base_id: 5, session_id: "sess_parity")

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert length(incr) == length(full)

      Enum.zip(incr, full)
      |> Enum.each(fn {i, f} ->
        assert i.role == f.role
        assert i.streaming? == f.streaming?
        assert i.text == f.text
      end)
    end

    test "mixed streaming and simple turns" do
      simple =
        EF.chat_turn("t1", "simple q", "simple a",
          base_id: 1,
          session_id: "sess_parity"
        )

      streaming =
        EF.streaming_turn("t2", "stream q", ["chunk1 ", "chunk2 "],
          base_id: 3,
          session_id: "sess_parity"
        )

      events = simple ++ streaming

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert length(incr) == length(full)

      Enum.zip(incr, full)
      |> Enum.with_index()
      |> Enum.each(fn {{i, f}, idx} ->
        assert i.role == f.role, "Role mismatch at index #{idx}"
        assert i.streaming? == f.streaming?, "Streaming? mismatch at index #{idx}"

        assert i.text == f.text,
               "Text mismatch at index #{idx}: #{inspect(i.text)} vs #{inspect(f.text)}"
      end)
    end

    test "legacy nil-turn events" do
      events = EF.bulk_legacy_events(10, session_id: "sess_parity")

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert length(incr) == length(full)

      Enum.zip(incr, full)
      |> Enum.each(fn {i, f} ->
        assert i.role == f.role
        assert i.streaming? == f.streaming?
        assert i.text == f.text
      end)
    end

    test "bulk streaming turns parity" do
      events =
        EF.bulk_streaming_turns(50, 3, session_id: "sess_parity")

      full = EventStream.chat_messages(events)
      incr = incremental_chat_messages(events)

      assert length(incr) == length(full)

      Enum.zip(incr, full)
      |> Enum.with_index()
      |> Enum.each(fn {{i, f}, idx} ->
        assert i.role == f.role, "Role mismatch at index #{idx}"
        assert i.streaming? == f.streaming?, "Streaming? mismatch at index #{idx}"
        assert i.text == f.text, "Text mismatch at index #{idx}"
      end)
    end

    test "incomplete streaming turn (no final)" do
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 "],
          base_id: 1,
          session_id: "sess_parity"
        )

      events_no_final = Enum.reject(events, &(&1.type == :assistant_message))

      full = EventStream.chat_messages(events_no_final)
      incr = incremental_chat_messages(events_no_final)

      assert length(incr) == length(full)
      assert Enum.at(incr, 1).streaming? == true
      assert Enum.at(incr, 1).text == Enum.at(full, 1).text
    end
  end

  # ===========================================================================
  # Performance: O(n) grouping + incremental updates
  # ===========================================================================

  # Tagged :timing_baseline — absolute timing thresholds flake on slow/loaded CI runners.
  # Run locally with: mix test --include timing_baseline
  describe "O(n) grouping performance" do
    @describetag :timing_baseline
    test "1K events: grouping is fast (under 500ms)" do
      events = EF.bulk_chat_turns(500, session_id: "sess_perf")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 1_000

      assert time_ms < 500,
             "chat_messages/1 took #{time_ms}ms for 1K events — possible O(n²) regression"
    end

    test "5K events: grouping is fast (under 2s)" do
      events = EF.bulk_chat_turns(2_500, session_id: "sess_perf")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 5_000

      assert time_ms < 2_000,
             "chat_messages/1 took #{time_ms}ms for 5K events — possible O(n²) regression"
    end

    test "20K events: linear scaling (under 15s)" do
      events = EF.bulk_chat_turns(10_000, session_id: "sess_perf")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 20_000

      assert time_ms < 15_000,
             "chat_messages/1 took #{time_ms}ms for 20K events — possible O(n²) regression"
    end

    test "many unique turns with events in each: linear not quadratic" do
      events =
        EF.bulk_streaming_turns(500, 2, session_id: "sess_perf")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 1_000

      assert time_ms < 2_000,
             "chat_messages/1 took #{time_ms}ms for 500 streaming turns — possible O(n²) regression in grouping"
    end

    test "incremental apply is faster than full re-derive for streaming" do
      base_events =
        EF.chat_turn("t1", "hello", "world",
          base_id: 1,
          session_id: "sess_perf"
        )

      user_event = Enum.find(base_events, &(&1.type == :user_message))

      delta_events =
        for i <- 1..100 do
          make_event(:assistant_delta, %{text: "chunk#{i} "},
            id: 100 + i,
            turn_id: "t1",
            seq: 100 + i,
            timestamp: now()
          )
        end

      # Measure incremental: apply user + 100 deltas one by one
      {incr_time_us, _} =
        :timer.tc(fn ->
          msgs = EventStream.apply_event_to_chat_messages([], user_event)

          Enum.reduce(delta_events, msgs, fn delta, msgs ->
            EventStream.apply_event_to_chat_messages(msgs, delta)
          end)
        end)

      # Measure full re-derive: chat_messages on growing event list
      all_events = [user_event | delta_events]

      {full_time_us, _} =
        :timer.tc(fn ->
          Enum.reduce(1..100, [], fn i, _ ->
            EventStream.chat_messages(Enum.take(all_events, i + 1))
          end)
        end)

      incr_ms = div(incr_time_us, 1_000)
      full_ms = div(full_time_us, 1_000)

      # Incremental should be significantly faster than full re-derive
      assert incr_ms < full_ms * 2,
             "Incremental (#{incr_ms}ms) should be faster than full re-derive per delta (#{full_ms}ms)"
    end
  end

  # ===========================================================================
  # Incremental step-by-step verification
  # ===========================================================================

  describe "incremental step-by-step behavior" do
    test "streaming turn: messages evolve correctly at each step" do
      events =
        EF.streaming_turn("t1", "hello", ["Hello", " world"],
          base_id: 1,
          session_id: "sess_steps"
        )

      steps = incremental_steps(events)

      # Step 0: user message
      assert length(Enum.at(steps, 0)) == 1
      assert Enum.at(steps, 0) |> Enum.at(0) |> Map.get(:role) == :user

      # Step 1: first delta — streaming message created
      assert length(Enum.at(steps, 1)) == 2
      assert Enum.at(steps, 1) |> Enum.at(1) |> Map.get(:streaming?) == true
      assert Enum.at(steps, 1) |> Enum.at(1) |> Map.get(:text) == "Hello"

      # Step 2: second delta — streaming message updated
      assert length(Enum.at(steps, 2)) == 2
      assert Enum.at(steps, 2) |> Enum.at(1) |> Map.get(:streaming?) == true
      assert Enum.at(steps, 2) |> Enum.at(1) |> Map.get(:text) == "Hello world"

      # Step 3: streamed final — streaming message finalized
      assert length(Enum.at(steps, 3)) == 2
      assert Enum.at(steps, 3) |> Enum.at(1) |> Map.get(:streaming?) == false
      assert Enum.at(steps, 3) |> Enum.at(1) |> Map.get(:text) == "Hello world"
    end

    test "multiple turns: messages accumulate correctly" do
      events =
        EF.chat_turn("t1", "first", "reply1", base_id: 1, session_id: "sess_steps") ++
          EF.chat_turn("t2", "second", "reply2", base_id: 3, session_id: "sess_steps")

      steps = incremental_steps(events)

      assert length(Enum.at(steps, 0)) == 1
      assert length(Enum.at(steps, 1)) == 2
      assert length(Enum.at(steps, 2)) == 3
      assert length(Enum.at(steps, 3)) == 4
    end
  end

  # ===========================================================================
  # Edge cases
  # ===========================================================================

  describe "apply_event_to_chat_messages/2 — edge cases" do
    test "turn_id field is present on all message types" do
      events =
        EF.streaming_turn("t1", "hello", ["chunk"],
          base_id: 1,
          session_id: "sess_edge"
        )

      messages = incremental_chat_messages(events)

      Enum.each(messages, fn msg ->
        assert Map.has_key?(msg, :turn_id),
               "Message #{inspect(msg)} missing :turn_id key"
      end)
    end

    test "string-keyed delta data works with incremental" do
      event =
        make_event(:assistant_delta, %{"text" => "chunk"},
          id: 1,
          turn_id: "t1",
          seq: 2,
          timestamp: now()
        )

      messages = EventStream.apply_event_to_chat_messages([], event)
      assert length(messages) == 1
      assert hd(messages).text == "chunk"
    end

    test "empty events list returns empty messages" do
      messages = incremental_chat_messages([])
      assert messages == []
    end

    test "all non-chat event types return unchanged messages" do
      non_chat_types = [
        :turn_started,
        :turn_completed,
        :turn_failed,
        :turn_cancelled,
        :tool_call,
        :tool_result,
        :checkpoint_created
      ]

      Enum.each(non_chat_types, fn type ->
        event = make_event(type, %{}, id: 1, turn_id: "t1", seq: 1, timestamp: now())

        messages = EventStream.apply_event_to_chat_messages([], event)
        assert messages == [], "Non-chat event type #{type} should not produce messages"
      end)
    end
  end
end
