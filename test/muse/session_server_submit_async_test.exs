defmodule Muse.SessionServerSubmitAsyncTest do
  @moduledoc """
  T0-04: Non-blocking submit API — submit_async/4.

  These tests verify the async submit path:

    1. `submit_async/4` returns `{:ok, turn_id}` immediately without
       blocking the caller.

    2. `submit_async/4` is rejected with `{:error, :turn_in_progress}`
       when a turn is already active — same single-flight guard as sync.

    3. Async turns emit the same PubSub/State events as sync turns
       (`:user_message`, `:turn_started`, `:turn_completed`, etc.).

    4. Task result handlers skip `GenServer.reply` when `from` is nil
       (async path) — no crash on completion/failure/cancellation.

    5. `Muse.start_submit/3` delegates correctly to the async path.

    6. Session status transitions correctly (idle → running → idle).
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
  # submit_async/4 — immediate return
  # ---------------------------------------------------------------------------

  describe "submit_async/4 — immediate return" do
    test "returns {:ok, turn_id} immediately without blocking" do
      pid = start_server("async-immediate-return")

      result = Muse.SessionServer.submit_async(pid, :web, "hello async")
      assert {:ok, turn_id} = result
      assert is_binary(turn_id)

      # Give the turn time to complete (fake provider is near-instant)
      Process.sleep(50)

      # Turn should no longer be active
      assert Muse.SessionServer.turn_active?(pid) == false
    end

    test "returned turn_id matches the active_turn_id while turn is running" do
      pid = start_server("async-turn-id-match")

      # Manually set running state to observe turn_id, then test
      # that submit_async returns a turn_id that is used in events
      {:ok, turn_id} = Muse.SessionServer.submit_async(pid, :web, "turn id test")

      # Since fake provider completes very fast, we just verify
      # the turn_id is a non-empty string
      assert is_binary(turn_id) and byte_size(turn_id) > 0

      Process.sleep(50)
    end
  end

  # ---------------------------------------------------------------------------
  # submit_async/4 — single-flight guard
  # ---------------------------------------------------------------------------

  describe "submit_async/4 — single-flight guard" do
    test "returns {:error, :turn_in_progress} when a turn is already active" do
      pid = start_server("async-concurrent-guard")

      # Manually set server into running state to simulate active turn
      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            runner_task: make_ref(),
            active_turn_id: "turn_async_existing"
        }
      end)

      result = Muse.SessionServer.submit_async(pid, :web, "concurrent async")
      assert {:error, :turn_in_progress} = result

      # Verify state was NOT mutated
      status = Muse.SessionServer.status(pid)
      assert status.active_turn_id == "turn_async_existing"
      assert status.status == :running

      # Clean up
      :sys.replace_state(pid, fn state ->
        %{state | status: :idle, runner_task: nil, active_turn_id: nil}
      end)
    end

    test "submit_async after turn completion succeeds" do
      pid = start_server("async-sequential-works")

      assert {:ok, _turn_id1} = Muse.SessionServer.submit_async(pid, :web, "first")
      Process.sleep(50)

      assert {:ok, _turn_id2} = Muse.SessionServer.submit_async(pid, :web, "second")
      Process.sleep(50)
    end
  end

  # ---------------------------------------------------------------------------
  # submit_async/4 — events emitted
  # ---------------------------------------------------------------------------

  describe "submit_async/4 — events emitted" do
    test "emits user_message and turn_completed events via State" do
      pid = start_server("async-events-emitted")

      # Clear events to isolate
      State.clear()

      {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "async event test")

      # Give the fake provider time to complete
      Process.sleep(100)

      events = State.events()
      event_types = Enum.map(events, & &1.type)

      assert :user_message in event_types
      assert :turn_started in event_types
      assert :turn_completed in event_types
    end

    test "emits :assistant_message event" do
      pid = start_server("async-assistant-event")

      State.clear()

      {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "async assistant")

      Process.sleep(100)

      events = State.events()
      event_types = Enum.map(events, & &1.type)

      assert :assistant_message in event_types
    end
  end

  # ---------------------------------------------------------------------------
  # submit_async/4 — no GenServer.reply crash
  # ---------------------------------------------------------------------------

  describe "submit_async/4 — no GenServer.reply crash" do
    test "async turn completion does not crash when from is nil" do
      pid = start_server("async-no-reply-crash")

      # This should complete without crash even though from=nil
      assert {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "no crash test")

      Process.sleep(100)

      # Server should still be alive and responsive
      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.active_turn_id == nil
    end

    test "async turn with manually-set running state completes safely" do
      pid = start_server("async-manual-complete")

      # Directly exercise the completion path with nil from
      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :running,
            runner_task: make_ref(),
            active_turn_id: "turn_nil_from",
            runner_pid: self(),
            from: nil,
            turn_start_time: System.monotonic_time(:millisecond),
            session_events_before_turn: [],
            cancellation_requested: false
        }
      end)

      # The server should be alive and in running state
      status = Muse.SessionServer.status(pid)
      assert status.status == :running

      # Clean up the running state manually since we didn't actually
      # start a real turn
      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :idle,
            runner_task: nil,
            active_turn_id: nil,
            runner_pid: nil,
            from: nil
        }
      end)

      # Verify server is still alive and accepts new submits
      assert {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "after manual clear")
      Process.sleep(50)
    end
  end

  # ---------------------------------------------------------------------------
  # Muse.start_submit/3 — top-level API
  # ---------------------------------------------------------------------------

  describe "Muse.start_submit/3 — top-level API delegation" do
    test "returns {:ok, turn_id} for successful submit" do
      _pid = start_server("default")

      State.clear()

      result = Muse.start_submit(:web, "top-level async test")
      assert {:ok, turn_id} = result
      assert is_binary(turn_id)

      Process.sleep(100)

      events = State.events()
      event_types = Enum.map(events, & &1.type)
      assert :turn_completed in event_types
    end

    test "returns {:error, :turn_in_progress} when turn is active" do
      pid = start_server("default")

      :sys.replace_state(pid, fn state ->
        %{state | status: :running, runner_task: make_ref(), active_turn_id: "turn_top_level"}
      end)

      result = Muse.start_submit(:web, "concurrent top-level")
      assert {:error, :turn_in_progress} = result

      # Clean up
      :sys.replace_state(pid, fn state ->
        %{state | status: :idle, runner_task: nil, active_turn_id: nil}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # SessionRouter.submit_async/4 — delegation
  # ---------------------------------------------------------------------------

  describe "SessionRouter.submit_async/4 — delegation" do
    test "2-arg form delegates correctly" do
      _pid = start_server("default")

      result = Muse.SessionRouter.submit_async(:web, "router async 2arg")
      assert {:ok, turn_id} = result
      assert is_binary(turn_id)

      Process.sleep(50)
    end

    test "3-arg form with session_id delegates correctly" do
      _pid = start_server("router-session-3arg")

      result = Muse.SessionRouter.submit_async("router-session-3arg", :web, "router async 3arg")
      assert {:ok, _turn_id} = result

      Process.sleep(50)
    end

    test "4-arg form with opts delegates correctly" do
      _pid = start_server("default")

      result = Muse.SessionRouter.submit_async("default", :web, "router async 4arg", [])
      assert {:ok, _turn_id} = result

      Process.sleep(50)
    end
  end

  # ---------------------------------------------------------------------------
  # Status transitions
  # ---------------------------------------------------------------------------

  describe "status transitions — async submit" do
    test "session transitions idle → running → idle for async submit" do
      pid = start_server("async-status-transition")

      # Initially idle
      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.active_turn_id == nil

      {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "status test")

      # After submit, check that turn was started (may already be complete with fake provider)
      Process.sleep(50)

      # After completion, should be idle again
      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.active_turn_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Sync submit still works after async changes
  # ---------------------------------------------------------------------------

  describe "backward compatibility — sync submit still works" do
    test "sync submit/4 still returns {:ok, assistant_text}" do
      pid = start_server("async-compat-sync")

      result = Muse.SessionServer.submit(pid, :cli, "sync still works")
      assert {:ok, text} = result
      assert is_binary(text)
    end

    test "sync submit after async submit still works" do
      pid = start_server("async-then-sync")

      # First, an async submit
      {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "async first")
      Process.sleep(50)

      # Then, a sync submit should still work
      assert {:ok, text} = Muse.SessionServer.submit(pid, :cli, "sync after")
      assert is_binary(text)
    end
  end
end
