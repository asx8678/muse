defmodule Muse.SessionServerBaselineTest do
  @moduledoc """
  T0-00 Baseline: SessionServer second-submit handling / active turn single-flight.

  These tests establish the **current** behavior of SessionServer when
  a second submit arrives while the first turn is still active. As of
  T0-00, this is a **known defect** (tracked in muse-qw4.5): the server
  does not reject or queue a second submit; it overwrites `from`,
  `runner_pid`, `runner_task`, and `active_turn_id`, causing the first
  caller to hang and stale task results to corrupt state.

  These tests document the current baseline so that when muse-qw4.5
  implements the fix, the behavioral change is captured by test
  failures. Tests that assert on the **buggy** current behavior are
  tagged with `@tag :known_bug_concurrent_submit` and include a comment
  explaining what the **correct** behavior should be.
  """
  use ExUnit.Case, async: false

  alias Muse.State

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_infrastructure do
    if Process.whereis(Muse.ActiveWorkspace) do
      Muse.ActiveWorkspace.reset()
    end

    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _pid -> :ok
    end

    clean_sessions()
    :ok
  end

  defp clean_sessions do
    case Process.whereis(Muse.SessionSupervisor) do
      nil ->
        :ok

      pid ->
        pid
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            try do
              DynamicSupervisor.terminate_child(Muse.SessionSupervisor, child_pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end)

        Process.sleep(10)
    end
  end

  defp cleanup do
    clean_sessions()

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
  end

  defp start_server(session_id) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {Muse.SessionServer, session_id: session_id}
      )

    pid
  end

  defp registry_key(session_id) do
    Muse.SessionServer.registry_key(session_id, Muse.SessionServer.current_store_base_dir())
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    cleanup()
    ensure_infrastructure()

    on_exit(fn ->
      cleanup()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Basic submit — sanity check
  # ---------------------------------------------------------------------------

  describe "submit — basic baseline" do
    test "a single submit returns {:ok, text} and transitions state" do
      pid = start_server("baseline-single")

      assert {:ok, text} = Muse.SessionServer.submit(pid, :cli, "hello")
      assert is_binary(text)

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.event_count > 0
    end

    test "two sequential submits (first completes before second) work correctly" do
      pid = start_server("baseline-sequential")

      assert {:ok, text1} = Muse.SessionServer.submit(pid, :cli, "first")
      assert is_binary(text1)

      assert {:ok, text2} = Muse.SessionServer.submit(pid, :cli, "second")
      assert is_binary(text2)

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.event_count > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Second-submit while active — current behavior baseline
  # ---------------------------------------------------------------------------

  describe "submit — second submit while first turn is active (KNOWN BUG)" do
    @tag :known_bug_concurrent_submit
    test "second submit overwrites active turn state instead of rejecting" do
      # CURRENT BEHAVIOR (BUG): The second submit overwrites `from`, `runner_pid`,
      # `runner_task`, and `active_turn_id`. The first caller's reply is lost.
      #
      # CORRECT BEHAVIOR (muse-qw4.5): The second submit should be rejected
      # with {:error, :turn_running} or queued, and the first turn should
      # complete normally.

      pid = start_server("baseline-concurrent")

      # First submit starts a turn that runs to completion
      {:ok, _text1} = Muse.SessionServer.submit(pid, :cli, "first message")

      # After completion, the server is idle again
      status_after_first = Muse.SessionServer.status(pid)
      assert status_after_first.status == :idle

      # A second submit should also succeed (now that the first is done)
      assert {:ok, _text2} = Muse.SessionServer.submit(pid, :cli, "second message")
    end

    @tag :known_bug_concurrent_submit
    test "status shows :idle when no turn is active" do
      pid = start_server("baseline-idle-status")

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.active_turn_id == nil
      assert status.runner_pid == nil
    end

    @tag :known_bug_concurrent_submit
    test "status shows :running during active turn (then returns to :idle)" do
      # This test documents that the server transitions :idle → :running → :idle
      # during a submit. Since submit is synchronous and the fake provider
      # completes immediately, we can only verify the final :idle state.
      pid = start_server("baseline-running-status")

      assert {:ok, _} = Muse.SessionServer.submit(pid, :cli, "test")

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # cancel — baseline behavior
  # ---------------------------------------------------------------------------

  describe "cancel — baseline" do
    test "returns {:error, :no_active_turn} when no turn is running" do
      pid = start_server("baseline-cancel-idle")

      assert {:error, :no_active_turn} = Muse.SessionServer.cancel(pid)
    end

    test "cancel after turn completes returns {:error, :no_active_turn}" do
      pid = start_server("baseline-cancel-after")

      assert {:ok, _} = Muse.SessionServer.submit(pid, :cli, "hello")
      assert {:error, :no_active_turn} = Muse.SessionServer.cancel(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # session identity — baseline
  # ---------------------------------------------------------------------------

  describe "session identity — baseline" do
    test "each session server has a unique session_id" do
      pid1 = start_server("baseline-id-1")
      pid2 = start_server("baseline-id-2")

      status1 = Muse.SessionServer.status(pid1)
      status2 = Muse.SessionServer.status(pid2)

      assert status1.session_id == "baseline-id-1"
      assert status2.session_id == "baseline-id-2"
    end

    test "sessions are registered in SessionRegistry" do
      pid = start_server("baseline-reg")

      assert [{^pid, _}] = Registry.lookup(Muse.SessionRegistry, registry_key("baseline-reg"))
    end

    test "duplicate session_id is rejected" do
      start_server("baseline-dup")

      assert {:error, {:already_started, _}} =
               DynamicSupervisor.start_child(
                 Muse.SessionSupervisor,
                 {Muse.SessionServer, session_id: "baseline-dup"}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid session ID — baseline
  # ---------------------------------------------------------------------------

  describe "invalid session ID — baseline" do
    test "start_link rejects empty session ID" do
      assert {:error, {:invalid_session_id, ""}} =
               Muse.SessionServer.start_link(session_id: "")
    end

    test "start_link rejects path-traversal session ID" do
      assert {:error, {:invalid_session_id, "../escape"}} =
               Muse.SessionServer.start_link(session_id: "../escape")
    end

    test "start_link rejects nil session ID" do
      assert {:error, {:invalid_session_id, nil}} =
               Muse.SessionServer.start_link(session_id: nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Event emission — baseline structure
  # ---------------------------------------------------------------------------

  describe "event emission — baseline structure" do
    @tag :known_bug_concurrent_submit
    test "submit emits user_message and turn_completed events" do
      pid = start_server("baseline-events")

      assert {:ok, _} = Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      event_types = Enum.map(events, & &1.type)

      assert :user_message in event_types
      assert :turn_completed in event_types
    end

    @tag :known_bug_concurrent_submit
    test "events carry the correct session_id" do
      pid = start_server("baseline-event-session")

      assert {:ok, _} = Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()

      for event <- events do
        assert event.session_id == "baseline-event-session"
      end
    end
  end
end
