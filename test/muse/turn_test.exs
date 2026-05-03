defmodule Muse.TurnTest do
  use ExUnit.Case, async: true

  alias Muse.Turn

  describe "new/1" do
    test "creates a turn with required session_id" do
      turn = Turn.new(session_id: "sess_1")

      assert %Turn{} = turn
      assert turn.session_id == "sess_1"
      assert turn.status == :queued
      assert turn.source == :user
    end

    test "raises on missing session_id" do
      assert_raise KeyError, fn ->
        Turn.new([])
      end
    end

    test "generates a unique id" do
      turn1 = Turn.new(session_id: "sess_1")
      turn2 = Turn.new(session_id: "sess_1")

      assert is_binary(turn1.id)
      assert is_binary(turn2.id)
      assert turn1.id != turn2.id
      assert String.starts_with?(turn1.id, "turn_")
    end

    test "accepts deterministic id for testing" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")
      assert turn.id == "turn_1"
    end

    test "accepts user_text option" do
      turn = Turn.new(session_id: "sess_1", user_text: "add a /version command")
      assert turn.user_text == "add a /version command"
    end

    test "accepts selected_muse option" do
      turn = Turn.new(session_id: "sess_1", selected_muse: "planning_muse")
      assert turn.selected_muse == "planning_muse"
    end

    test "accepts source option" do
      turn = Turn.new(session_id: "sess_1", source: :conductor)
      assert turn.source == :conductor
    end

    test "accepts deterministic started_at for testing" do
      ts = ~U[2025-01-01 00:00:00Z]
      turn = Turn.new(session_id: "sess_1", id: "turn_1", started_at: ts)
      assert turn.started_at == ts
    end

    test "defaults timestamps to DateTime.utc_now when not overridden" do
      turn = Turn.new(session_id: "sess_1")
      assert %DateTime{} = turn.started_at
      assert turn.completed_at == nil
    end

    test "defaults collection fields to empty" do
      turn = Turn.new(session_id: "sess_1")

      assert turn.tool_calls == []
      assert turn.assistant_buffer == ""
      assert turn.result == nil
      assert turn.streamed? == false
    end
  end

  describe "statuses/0" do
    test "returns the canonical list of turn statuses" do
      statuses = Turn.statuses()

      assert :queued in statuses
      assert :running in statuses
      assert :awaiting_approval in statuses
      assert :completed in statuses
      assert :failed in statuses
      assert :cancelled in statuses
    end

    test "all statuses are atoms" do
      for status <- Turn.statuses() do
        assert is_atom(status)
      end
    end
  end

  describe "valid_status?/1" do
    test "returns true for canonical statuses" do
      for status <- Turn.statuses() do
        assert Turn.valid_status?(status)
      end
    end

    test "returns false for non-canonical values" do
      refute Turn.valid_status?(:unknown)
      refute Turn.valid_status?(nil)
      refute Turn.valid_status?("queued")
    end
  end

  describe "transition/3" do
    test "transitions to a valid status" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")

      assert {:ok, updated} = Turn.transition(turn, :running)
      assert updated.status == :running
    end

    test "sets completed_at when transitioning to completed" do
      ts = ~U[2025-01-01 00:00:00Z]
      turn = Turn.new(session_id: "sess_1", id: "turn_1", started_at: ts)

      {:ok, completed} = Turn.transition(turn, :completed, completed_at: ts)
      assert completed.completed_at == ts
    end

    test "sets completed_at when transitioning to failed" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")

      {:ok, failed} = Turn.transition(turn, :failed)
      assert %DateTime{} = failed.completed_at
    end

    test "sets completed_at when transitioning to cancelled" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")

      {:ok, cancelled} = Turn.transition(turn, :cancelled)
      assert %DateTime{} = cancelled.completed_at
    end

    test "does not set completed_at for non-terminal status" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")

      {:ok, running} = Turn.transition(turn, :running)
      assert running.completed_at == nil
    end

    test "rejects invalid status" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")

      assert {:error, {:invalid_status, :unknown}} = Turn.transition(turn, :unknown)
    end

    test "preserves other fields through transition" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1", user_text: "hello")

      {:ok, running} = Turn.transition(turn, :running)
      assert running.id == "turn_1"
      assert running.session_id == "sess_1"
      assert running.user_text == "hello"
    end
  end

  describe "mark_streamed/1" do
    test "sets streamed? to true" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")
      refute turn.streamed?

      streamed = Turn.mark_streamed(turn)
      assert streamed.streamed? == true
    end

    test "returns the same struct type" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1")
      streamed = Turn.mark_streamed(turn)
      assert %Turn{} = streamed
    end

    test "preserves other fields" do
      turn = Turn.new(session_id: "sess_1", id: "turn_1", user_text: "hello")
      streamed = Turn.mark_streamed(turn)

      assert streamed.id == "turn_1"
      assert streamed.session_id == "sess_1"
      assert streamed.user_text == "hello"
    end
  end
end
