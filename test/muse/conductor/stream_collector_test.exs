defmodule Muse.Conductor.StreamCollectorTest do
  @moduledoc """
  Unit tests for StreamCollector — the Agent-based replacement for
  process-dictionary streaming collectors.
  """
  use ExUnit.Case, async: true

  alias Muse.Conductor.StreamCollector
  alias Muse.LLM.Event

  describe "start/0" do
    test "starts an Agent process" do
      {:ok, pid} = StreamCollector.start()
      assert is_pid(pid)
      assert Process.alive?(pid)
      StreamCollector.collect(pid)
    end
  end

  describe "record/2 — assistant_delta" do
    test "returns delta info with correct index" do
      {:ok, pid} = StreamCollector.start()

      assert {:delta, "hello", 0} =
               StreamCollector.record(pid, Event.assistant_delta("hello"))

      assert {:delta, " world", 1} =
               StreamCollector.record(pid, Event.assistant_delta(" world"))

      StreamCollector.collect(pid)
    end

    test "monotonically increments index across multiple deltas" do
      {:ok, pid} = StreamCollector.start()

      for i <- 0..9 do
        assert {:delta, _, ^i} =
                 StreamCollector.record(pid, Event.assistant_delta("chunk#{i}"))
      end

      StreamCollector.collect(pid)
    end
  end

  describe "record/2 — non-delta events" do
    test "returns :ok for response_started" do
      {:ok, pid} = StreamCollector.start()
      assert :ok = StreamCollector.record(pid, Event.response_started())
      StreamCollector.collect(pid)
    end

    test "returns :ok for response_completed" do
      {:ok, pid} = StreamCollector.start()

      assert :ok =
               StreamCollector.record(
                 pid,
                 Event.response_completed(%{prompt_tokens: 1, completion_tokens: 2})
               )

      StreamCollector.collect(pid)
    end

    test "returns :ok for assistant_completed" do
      {:ok, pid} = StreamCollector.start()
      assert :ok = StreamCollector.record(pid, Event.assistant_completed("done"))
      StreamCollector.collect(pid)
    end
  end

  describe "mark_live_emitted/1" do
    test "increments live_emitted_count" do
      {:ok, pid} = StreamCollector.start()

      StreamCollector.record(pid, Event.assistant_delta("a"))
      StreamCollector.mark_live_emitted(pid)

      StreamCollector.record(pid, Event.assistant_delta("b"))
      StreamCollector.mark_live_emitted(pid)

      {_events, live_emitted_count} = StreamCollector.collect(pid)
      assert live_emitted_count == 2
    end

    test "live_emitted_count is 0 when mark_live_emitted is never called" do
      {:ok, pid} = StreamCollector.start()
      StreamCollector.record(pid, Event.assistant_delta("a"))
      StreamCollector.record(pid, Event.assistant_delta("b"))

      {_events, live_emitted_count} = StreamCollector.collect(pid)
      assert live_emitted_count == 0
    end
  end

  describe "collect/1" do
    test "returns events in emission order and correct live_emitted count" do
      {:ok, pid} = StreamCollector.start()

      StreamCollector.record(pid, Event.response_started())
      StreamCollector.record(pid, Event.assistant_delta("chunk1"))
      StreamCollector.mark_live_emitted(pid)
      StreamCollector.record(pid, Event.assistant_delta("chunk2"))
      StreamCollector.mark_live_emitted(pid)
      StreamCollector.record(pid, Event.assistant_completed("chunk1chunk2"))
      StreamCollector.record(pid, Event.response_completed(%{prompt_tokens: 10}))

      {events, live_emitted_count} = StreamCollector.collect(pid)

      assert length(events) == 5
      assert live_emitted_count == 2

      types = Enum.map(events, & &1.type)

      assert types == [
               :response_started,
               :assistant_delta,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]
    end

    test "stops the Agent process" do
      {:ok, pid} = StreamCollector.start()
      StreamCollector.collect(pid)
      refute Process.alive?(pid)
    end

    test "returns empty list and zero count when no events recorded" do
      {:ok, pid} = StreamCollector.start()
      {events, live_emitted_count} = StreamCollector.collect(pid)
      assert events == []
      assert live_emitted_count == 0
    end
  end

  describe "cross-process safety" do
    test "events from spawned processes are collected correctly" do
      {:ok, pid} = StreamCollector.start()

      # Spawn 5 processes that each record an event concurrently
      tasks =
        for i <- 0..4 do
          Task.async(fn ->
            StreamCollector.record(pid, Event.assistant_delta("from_proc_#{i}"))
            StreamCollector.mark_live_emitted(pid)
          end)
        end

      # Wait for all tasks to finish recording
      Task.await_many(tasks, 5000)

      # Also record from the calling process
      StreamCollector.record(pid, Event.assistant_delta("from_parent"))
      StreamCollector.mark_live_emitted(pid)

      {events, live_emitted_count} = StreamCollector.collect(pid)

      # All 6 events should be present
      assert length(events) == 6
      assert live_emitted_count == 6

      texts = Enum.map(events, & &1.text) |> Enum.sort()

      expected =
        Enum.sort([
          "from_proc_0",
          "from_proc_1",
          "from_proc_2",
          "from_proc_3",
          "from_proc_4",
          "from_parent"
        ])

      assert texts == expected
    end

    test "delta index is atomic — no gaps or duplicates" do
      {:ok, pid} = StreamCollector.start()

      tasks =
        for _i <- 0..19 do
          Task.async(fn ->
            result = StreamCollector.record(pid, Event.assistant_delta("x"))
            result
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All indices should be unique
      indices =
        Enum.map(results, fn
          {:delta, _, idx} -> idx
          :ok -> nil
        end)
        |> Enum.reject(&is_nil/1)

      assert length(Enum.uniq(indices)) == length(indices),
             "Expected unique indices, got duplicates: #{inspect(indices)}"

      {events, live_emitted_count} = StreamCollector.collect(pid)
      assert length(events) == 20
      # No mark_live_emitted calls, so count should be 0
      assert live_emitted_count == 0
    end

    test "mark_live_emitted from another process is counted" do
      {:ok, pid} = StreamCollector.start()

      StreamCollector.record(pid, Event.assistant_delta("delta"))

      Task.async(fn ->
        StreamCollector.mark_live_emitted(pid)
      end)
      |> Task.await(5000)

      {_events, live_emitted_count} = StreamCollector.collect(pid)
      assert live_emitted_count == 1
    end
  end
end
