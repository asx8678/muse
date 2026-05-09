defmodule Muse.EventStreamBaselineTest do
  @moduledoc """
  T0-00 Baseline / T1-15 Regression: EventStream.chat_messages/1 on large synthetic event lists.

  These tests exercise `chat_messages/1` at scale to:
    1. Confirm it completes without crashing on 1K, 5K, and 20K events.
    2. Establish tight timing baselines reflecting the O(n) single-pass grouping
       (T1-15 replaced the old O(n²) filter-per-turn algorithm).
    3. Detect O(n²) regressions by comparing timings across sizes.

  All events are generated deterministically via `Muse.Test.EventFixtures`
  — no network or live provider calls.
  """
  use ExUnit.Case, async: true

  alias Muse.EventStream
  alias Muse.Test.EventFixtures, as: EF

  # ---------------------------------------------------------------------------
  # chat_messages/1 — correctness at scale
  # ---------------------------------------------------------------------------

  describe "chat_messages/1 — large synthetic event lists" do
    test "handles 1,000 simple chat turn events" do
      events = EF.bulk_chat_turns(500, session_id: "sess_baseline")

      messages = EventStream.chat_messages(events)

      # 500 turns × 2 messages each = 1,000 messages
      assert length(messages) == 1_000

      # First and last messages should have correct roles
      assert hd(messages).role == :user
      assert List.last(messages).role == :assistant
    end

    test "handles 5,000 simple chat turn events" do
      events = EF.bulk_chat_turns(2_500, session_id: "sess_baseline")

      messages = EventStream.chat_messages(events)

      assert length(messages) == 5_000
      assert hd(messages).role == :user
    end

    test "handles 20,000 simple chat turn events" do
      events = EF.bulk_chat_turns(10_000, session_id: "sess_baseline")

      messages = EventStream.chat_messages(events)

      assert length(messages) == 20_000
    end

    test "handles 1,000 streaming turn events (3 deltas per turn)" do
      # 1,000 turns × (1 user + 3 deltas + 1 final) = 5,000 events
      events = EF.bulk_streaming_turns(1_000, 3, session_id: "sess_baseline")

      messages = EventStream.chat_messages(events)

      # Each streaming turn should produce 2 messages (1 user + 1 concatenated delta)
      # because the streamed final is suppressed
      assert length(messages) == 2_000
    end

    test "handles mixed structured and legacy events" do
      structured = EF.bulk_chat_turns(100, session_id: "sess_baseline")
      legacy = EF.bulk_legacy_events(200, session_id: "sess_baseline")

      # Interleave structured and legacy events
      events = Enum.zip_with(structured, legacy, fn s, l -> [s, l] end) |> List.flatten()
      # Add remaining legacy events if lists are uneven
      remaining_legacy = Enum.drop(legacy, length(structured))
      events = events ++ remaining_legacy

      messages = EventStream.chat_messages(events)

      # Should not crash; should produce messages for both structured and legacy events
      assert length(messages) > 0
    end

    test "returns empty list for empty input" do
      assert EventStream.chat_messages([]) == []
    end

    test "produces correct text content for each turn" do
      events = EF.bulk_chat_turns(10, session_id: "sess_baseline")

      messages = EventStream.chat_messages(events)

      # Verify every user message text starts with "user"
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 10

      Enum.each(user_msgs, fn msg ->
        assert String.starts_with?(msg.text, "user ")
      end)

      # Verify every assistant message text starts with "assistant"
      asst_msgs = Enum.filter(messages, &(&1.role == :assistant))
      assert length(asst_msgs) == 10

      Enum.each(asst_msgs, fn msg ->
        assert String.starts_with?(msg.text, "assistant ")
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # chat_messages/1 — rough timing baselines
  # ---------------------------------------------------------------------------

  # Tagged :timing_baseline — absolute timing thresholds flake on slow/loaded CI runners.
  # Run locally with: mix test --include timing_baseline
  describe "chat_messages/1 — rough timing baseline" do
    @describetag :timing_baseline
    test "1K events complete in under 500ms" do
      events = EF.bulk_chat_turns(500, session_id: "sess_baseline")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 1_000
      # Tightened from 2s — O(n) grouping makes this fast
      assert time_ms < 500,
             "chat_messages/1 took #{time_ms}ms for 1K events — possible O(n²) regression"
    end

    test "5K events complete in under 2 seconds" do
      events = EF.bulk_chat_turns(2_500, session_id: "sess_baseline")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 5_000

      assert time_ms < 2_000,
             "chat_messages/1 took #{time_ms}ms for 5K events — possible O(n²) regression"
    end

    test "20K events complete in under 15 seconds" do
      events = EF.bulk_chat_turns(10_000, session_id: "sess_baseline")

      {time_us, messages} =
        :timer.tc(fn -> EventStream.chat_messages(events) end)

      time_ms = div(time_us, 1_000)

      assert length(messages) == 20_000

      assert time_ms < 15_000,
             "chat_messages/1 took #{time_ms}ms for 20K events — possible O(n²) regression"
    end
  end

  # ---------------------------------------------------------------------------
  # chat_messages/1 — streaming deduplication at scale
  # ---------------------------------------------------------------------------

  describe "chat_messages/1 — streaming deduplication baseline" do
    test "streamed final is suppressed across 100 streaming turns" do
      events = EF.bulk_streaming_turns(100, 5, session_id: "sess_baseline")

      messages = EventStream.chat_messages(events)

      # Each turn: 1 user + (deltas concatenated as 1 assistant) = 2 messages per turn
      # The streamed final should be suppressed
      assert length(messages) == 200

      # No message should have streaming? == true (all are complete turns)
      refute Enum.any?(messages, &(&1.streaming? == true))
    end

    test "non-streamed final appears alongside deltas" do
      # Build a turn with deltas but a non-streamed final
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 "],
          base_id: 1,
          session_id: "sess_baseline"
        )
        |> Enum.map(fn event ->
          # Convert the streamed? final to non-streamed
          if event.type == :assistant_message do
            %{event | data: Map.put(event.data, :streamed?, false)}
          else
            event
          end
        end)

      messages = EventStream.chat_messages(events)

      # 1 user + 1 delta-concat + 1 non-streamed final = 3 messages
      assert length(messages) == 3

      asst_msgs = Enum.filter(messages, &(&1.role == :assistant))
      assert length(asst_msgs) == 2
    end
  end
end
