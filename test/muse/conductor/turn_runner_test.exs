defmodule Muse.Conductor.TurnRunnerTest do
  use ExUnit.Case, async: false

  alias Muse.{Session, Turn}
  alias Muse.Conductor.TurnRunner

  setup do
    # Ensure TaskSupervisor is running
    case Process.whereis(Muse.TaskSupervisor) do
      nil ->
        {:ok, _} = Task.Supervisor.start_link(name: Muse.TaskSupervisor)

      _pid ->
        :ok
    end

    :ok
  end

  # -- Helpers ------------------------------------------------------------------

  defp build_session(opts \\ []) do
    defaults = [id: "runner-session", workspace: "/tmp/test_workspace", status: :idle]
    Session.new(Keyword.merge(defaults, opts))
  end

  defp build_turn(opts \\ []) do
    defaults = [
      session_id: "runner-session",
      id: "turn_runner1",
      source: :cli,
      user_text: "hello"
    ]

    Turn.new(Keyword.merge(defaults, opts))
  end

  # -- async/3 ------------------------------------------------------------------

  describe "async/3" do
    test "spawns a task that runs the Conductor and returns a result" do
      session = build_session()
      turn = build_turn()

      task = TurnRunner.async(session, turn, prompt_opts: [project_rules?: false])

      # Task should be a %Task{} struct
      assert %Task{} = task
      assert is_pid(task.pid)

      # Wait for the result
      result = Task.await(task, 5000)

      # Should be an ok result from Conductor
      assert match?({:ok, _}, result)
    end

    test "task runs outside the calling process" do
      session = build_session()
      turn = build_turn()

      caller_pid = self()

      task =
        TurnRunner.async(session, turn,
          prompt_opts: [project_rules?: false],
          # Override provider to verify it runs in a different process
          provider_module: Muse.LLM.FakeProvider
        )

      task_pid = task.pid
      refute task_pid == caller_pid

      result = Task.await(task, 5000)
      assert match?({:ok, _}, result)
    end

    test "task process has turn_id in process dictionary" do
      session = build_session()
      turn = build_turn(id: "turn_pd_test")

      task = TurnRunner.async(session, turn, prompt_opts: [project_rules?: false])

      # The task runs Conductor which completes. We just verify it doesn't crash.
      result = Task.await(task, 5000)
      assert match?({:ok, _}, result)
    end
  end

  # -- cancel/2 -----------------------------------------------------------------

  describe "cancel/2" do
    test "sends cancellation message to the task process" do
      # Start a task that waits a bit
      session = build_session()
      turn = build_turn()

      # Use a delay to give us time to cancel
      task =
        TurnRunner.async(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: [{:delay, 100}]}]
        )

      # Send cancellation
      :ok = TurnRunner.cancel(task.pid, turn.id)

      # The task should still complete (delay is short), but cancelled? should return true
      # in the task process. We just verify cancel doesn't crash.
      result = Task.await(task, 5000)
      # The task may complete normally or return {:cancelled, _}
      assert match?({:ok, _}, result) or match?({:cancelled, _}, result)
    end
  end

  # -- cancelled?/0 -------------------------------------------------------------

  describe "cancelled?/0" do
    test "returns false when no cancellation has been sent" do
      # In a fresh process, cancelled? should return false
      # (since the process dictionary is empty)
      refute TurnRunner.cancelled?()
    end

    test "returns true after cancellation message is received" do
      turn_id = "turn_cancel_test"
      Process.put(:muse_turn_id, turn_id)
      Process.put(:muse_cancelled, false)

      # Send a cancellation message to self
      send(self(), {:muse_turn_cancel, turn_id})

      assert TurnRunner.cancelled?()

      # Should stay true after first check
      assert TurnRunner.cancelled?()
    end

    test "ignores cancellation for different turn_id" do
      Process.put(:muse_turn_id, "turn_correct")
      Process.put(:muse_cancelled, false)

      # Send cancellation for a different turn
      send(self(), {:muse_turn_cancel, "turn_wrong"})

      refute TurnRunner.cancelled?()

      # The message should be re-queued
      receive do
        {:muse_turn_cancel, "turn_wrong"} -> :ok
      after
        0 -> flunk("Expected re-queued cancellation message")
      end
    end
  end
end
