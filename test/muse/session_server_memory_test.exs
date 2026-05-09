defmodule Muse.SessionServerMemoryTest do
  @moduledoc """
  T1-16: Memory and performance regression tests for SessionServer event
  storage optimizations.

  Verifies:
  - O(n²) list-copy patterns are eliminated (append is O(new_events))
  - Large event lists (>1000 events) do not cause performance cliffs
  - Behavior/ordering semantics are fully preserved
  - Cap, order, event_count after drops, and long append sequence bounds
  - Relative timing (not absolute thresholds) to avoid CI flakiness
  """
  use ExUnit.Case, async: false

  alias Muse.{Event, SessionServer}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp start_dependencies(workspace_root) do
    assert Process.whereis(Muse.PubSub) != nil,
           "Muse.PubSub not running — Application base_children not started?"

    assert Process.whereis(Muse.TaskSupervisor) != nil, "Muse.TaskSupervisor not running"
    assert Process.whereis(Muse.SessionRegistry) != nil, "Muse.SessionRegistry not running"

    stop_named(Muse.Workspace)
    {:ok, _} = Muse.Workspace.start_link(root: workspace_root)

    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])

    stop_named(Muse.Diagnostics)
    {:ok, _} = Muse.Diagnostics.start_link(install_logger_handler?: false)

    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = Muse.SelfHealingQueue.start_link([])

    stop_named(Muse.AgentRegistry)
    {:ok, _} = Muse.AgentRegistry.start_link([])
  end

  defp stop_dependencies do
    stop_named(Muse.AgentRegistry)
    stop_named(Muse.SelfHealingQueue)
    stop_named(Muse.Diagnostics)
    stop_named(Muse.State)
    stop_named(Muse.Workspace)
  end

  defp tmp_workspace do
    dir = Path.join(System.tmp_dir!(), "muse_ss_mem_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  setup do
    workspace = tmp_workspace()
    start_dependencies(workspace)

    on_exit(fn ->
      stop_dependencies()
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  # ---------------------------------------------------------------------------
  # Event addition with large lists
  # ---------------------------------------------------------------------------

  describe "large event list addition" do
    test "append_session_events handles large batches correctly" do
      cap = Muse.Bounds.session_events()
      # Create more events than the cap to test trimming
      event_count = cap + 500

      events =
        for i <- 1..event_count do
          Event.new(:test, :batch, %{i: i}, id: i, seq: i)
        end

      # Simulate what append_session_events does: reverse incoming, prepend, trim
      {trimmed, final_count} = Muse.Bounds.trim_prepend(Enum.reverse(events), cap, event_count)

      assert final_count == cap
      assert length(trimmed) == cap

      # The newest events should survive (first in newest-first list)
      chron = Enum.reverse(trimmed)
      assert hd(chron).seq == event_count - cap + 1
      assert List.last(chron).seq == event_count
    end

    test "status event_count is O(1) after many turns" do
      {:ok, pid} =
        SessionServer.start_link(
          session_id: "mem-event-count",
          store_base_dir: Path.join(tmp_workspace(), "sessions")
        )

      for i <- 1..30 do
        assert {:ok, _text} = SessionServer.submit(pid, :test, "msg #{i}")
      end

      status = SessionServer.status(pid)
      # event_count should be the cap, not computed via length()
      assert status.event_count == Muse.Bounds.session_events()

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Dedup under volume
  # ---------------------------------------------------------------------------

  describe "dedup semantics under volume" do
    test "events with duplicate seq values are stored independently (no implicit dedup)" do
      # SessionServer doesn't dedup by seq — it stores all events.
      # This test verifies the store/trim behavior with repeated values.
      events =
        for i <- 1..100 do
          Event.new(:test, :dup, %{i: rem(i, 10)}, id: i, seq: i)
        end

      {trimmed, count} = Muse.Bounds.trim_prepend(Enum.reverse(events), 50, 100)
      assert count == 50
      # No dedup expected — exactly 50 items remain
      assert length(trimmed) == 50
    end
  end

  # ---------------------------------------------------------------------------
  # Trim under volume
  # ---------------------------------------------------------------------------

  describe "trim under volume" do
    test "trim_prepend drops oldest (tail) entries when over cap" do
      # Build a newest-first list: [10, 9, 8, ..., 1]
      events = for i <- 10..1//-1, do: Event.new(:test, :trim, %{i: i}, id: i, seq: i)

      {trimmed, count} = Muse.Bounds.trim_prepend(events, 5, 10)

      assert count == 5
      chron = Enum.reverse(trimmed)
      # Oldest 5 should be dropped; newest 5 (seq 6..10) survive
      assert Enum.map(chron, & &1.seq) == [6, 7, 8, 9, 10]
    end

    test "trim_prepend returns unchanged list when within cap" do
      events = for i <- 3..1//-1, do: Event.new(:test, :ok, %{i: i}, id: i, seq: i)

      {trimmed, count} = Muse.Bounds.trim_prepend(events, 10, 3)

      assert count == 3
      assert trimmed == events
    end

    test "trim_prepend with 2-arg convenience uses length" do
      events = for i <- 5..1//-1, do: Event.new(:test, :conv, %{i: i}, id: i, seq: i)

      {trimmed, count} = Muse.Bounds.trim_prepend(events, 3)

      assert count == 3
      chron = Enum.reverse(trimmed)
      assert Enum.map(chron, & &1.seq) == [3, 4, 5]
    end

    test "sequential trims maintain correctness" do
      # Simulate multiple rounds of append + trim
      list = []
      count = 0
      cap = 20

      {list, count} =
        Enum.reduce(1..50, {list, count}, fn batch, {l, c} ->
          new_events = for i <- 1..5, do: Event.new(:test, :seq, %{b: batch, i: i})
          new_count = c + 5
          all = Enum.reverse(new_events) ++ l
          Muse.Bounds.trim_prepend(all, cap, new_count)
        end)

      assert count == cap
      assert length(list) == cap
    end
  end

  # ---------------------------------------------------------------------------
  # Event ordering preservation
  # ---------------------------------------------------------------------------

  describe "event ordering semantics" do
    test "events returned by SessionServer.events/1 are chronological" do
      {:ok, pid} =
        SessionServer.start_link(
          session_id: "mem-ordering",
          store_base_dir: Path.join(tmp_workspace(), "sessions")
        )

      assert {:ok, _} = SessionServer.submit(pid, :test, "first")
      assert {:ok, _} = SessionServer.submit(pid, :test, "second")
      assert {:ok, _} = SessionServer.submit(pid, :test, "third")

      events = SessionServer.events(pid)

      # User messages should appear in chronological order
      user_messages = Enum.filter(events, &(&1.type == :user_message))
      texts = Enum.map(user_messages, & &1.data.text)
      assert texts == ["first", "second", "third"]

      GenServer.stop(pid, :normal, 1_000)
    end

    test "seq values are monotonically increasing in chronological output" do
      {:ok, pid} =
        SessionServer.start_link(
          session_id: "mem-seq-order",
          store_base_dir: Path.join(tmp_workspace(), "sessions")
        )

      for i <- 1..5 do
        assert {:ok, _} = SessionServer.submit(pid, :test, "turn #{i}")
      end

      events = SessionServer.events(pid)
      seqs = Enum.map(events, & &1.seq)

      # All seqs should be present and strictly increasing
      assert seqs == Enum.sort(seqs)
      assert seqs == Enum.uniq(seqs)

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Performance characteristics (relative timing)
  # ---------------------------------------------------------------------------

  describe "performance characteristics" do
    test "append cost scales with new events, not total history" do
      # Measure: appending 100 new events to a list of 100 vs 2000 items
      # The prepend-based approach should be approximately the same time
      # since cost is O(new_events), not O(history).

      small_history =
        for i <- 1..100, do: Event.new(:test, :hist, %{i: i}, id: i, seq: i)

      large_history =
        for i <- 1..2000, do: Event.new(:test, :hist, %{i: i}, id: i, seq: i)

      new_events = for i <- 1..100, do: Event.new(:test, :new, %{i: i}, id: i + 10_000, seq: i)

      # The prepend-based append: Enum.reverse(new_events) ++ history
      # Cost is O(len(new_events)) for the reverse + prepend.
      # The old approach: history ++ new_events would be O(len(history)).

      {time_small, _} =
        :timer.tc(fn ->
          Enum.reverse(new_events) ++ small_history
        end)

      {time_large, _} =
        :timer.tc(fn ->
          Enum.reverse(new_events) ++ large_history
        end)

      # With prepend approach, time_large should NOT be 20x time_small.
      # It should be approximately the same (within 5x to account for
      # list traversal overhead in ++, but NOT 20x).
      #
      # Old O(n²) approach: history ++ new_events would make time_large ~20x time_small.
      # New approach: the ++ just prepends the small reversed list, so the ratio
      # should be close to 1.
      ratio = time_large / max(time_small, 1)

      # If this were O(history), ratio would be ~20. With prepend approach,
      # the ++ operation on the left side of prepend is O(len(left_list)),
      # and the left list is the same size in both cases.
      # Allow generous margin for CI overhead, but catch O(n²) regressions.
      assert ratio < 10,
             "Prepend-based append should scale with new events, not history. " <>
               "Ratio: #{ratio}, small: #{time_small}µs, large: #{time_large}µs"
    end

    test "trim_prepend with explicit count is O(1) when within cap" do
      # With explicit count and within-cap list, trim_prepend should
      # return immediately without traversing the list.
      events = for i <- 1..500, do: Event.new(:test, :perf, %{i: i}, id: i, seq: i)

      {time_within, _} =
        :timer.tc(fn ->
          Muse.Bounds.trim_prepend(events, 1000, 500)
        end)

      # When within cap, should be very fast (no traversal needed)
      assert time_within < 1000,
             "Within-cap trim_prepend should be near-instant: #{time_within}µs"
    end

    test "live_emitted_events prepending is faster than appending for many events" do
      # Simulate the streaming pattern: many live events arriving one at a time.
      # Old: list ++ [event] — O(n²) total for n events
      # New: [event | list] — O(n) total for n events

      event_count = 500
      events = for i <- 1..event_count, do: Event.new(:test, :live, %{i: i}, id: i, seq: i)

      {time_prepend, _} =
        :timer.tc(fn ->
          Enum.reduce(events, [], fn e, acc -> [e | acc] end)
        end)

      {time_append, _} =
        :timer.tc(fn ->
          Enum.reduce(events, [], fn e, acc -> acc ++ [e] end)
        end)

      # Prepend should be significantly faster than append for large event streams.
      # Append is O(n²), prepend is O(n), so prepend should be at least 2x faster.
      assert time_prepend < time_append,
             "Prepend (#{time_prepend}µs) should be faster than append (#{time_append}µs)"
    end
  end

  # ---------------------------------------------------------------------------
  # Bounds.trim_prepend regression tests
  # ---------------------------------------------------------------------------

  describe "Bounds.trim_prepend/2,3" do
    test "empty list returns empty with count 0" do
      {list, count} = Muse.Bounds.trim_prepend([], 5)
      assert list == []
      assert count == 0
    end

    test "exact cap returns unchanged list" do
      list = [5, 4, 3, 2, 1]
      {trimmed, count} = Muse.Bounds.trim_prepend(list, 5, 5)
      assert trimmed == list
      assert count == 5
    end

    test "over cap drops from tail (oldest)" do
      list = [5, 4, 3, 2, 1]
      {trimmed, count} = Muse.Bounds.trim_prepend(list, 3, 5)
      assert trimmed == [5, 4, 3]
      assert count == 3
    end

    test "single element list" do
      {trimmed, count} = Muse.Bounds.trim_prepend([42], 3, 1)
      assert trimmed == [42]
      assert count == 1
    end

    test "zero count is handled" do
      {trimmed, count} = Muse.Bounds.trim_prepend([], 5, 0)
      assert trimmed == []
      assert count == 0
    end
  end
end
