defmodule Muse.SessionRouterTest do
  use ExUnit.Case, async: false

  alias Muse.State

  # -- Helpers ------------------------------------------------------------------

  defp ensure_infrastructure do
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

        # Wait for processes to fully exit and Registry entries to be cleaned
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

  # -- Setup --------------------------------------------------------------------

  setup do
    cleanup()
    ensure_infrastructure()

    on_exit(fn ->
      cleanup()
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  describe "find_or_start_session/1" do
    test "creates a new session for unknown id" do
      assert {:ok, pid} = Muse.SessionRouter.find_or_start_session("new-session")
      assert is_pid(pid)
    end

    test "returns same pid for same session id" do
      {:ok, pid1} = Muse.SessionRouter.find_or_start_session("same-id")
      {:ok, pid2} = Muse.SessionRouter.find_or_start_session("same-id")

      assert pid1 == pid2
    end

    test "returns different pids for different session ids" do
      {:ok, pid1} = Muse.SessionRouter.find_or_start_session("session-a")
      {:ok, pid2} = Muse.SessionRouter.find_or_start_session("session-b")

      assert pid1 != pid2
    end

    test "works with string session ids" do
      assert {:ok, _pid} = Muse.SessionRouter.find_or_start_session("string-id")
    end

    test "session process is registered in Registry" do
      {:ok, pid} = Muse.SessionRouter.find_or_start_session("reg-check")

      assert [{^pid, _}] = Registry.lookup(Muse.SessionRegistry, "reg-check")
    end
  end

  describe "runtime child smoke" do
    test "Muse.submit/2 does not raise when registry and supervisor are running" do
      assert {:ok, text} = Muse.submit(:cli, "smoke test")
      assert text == "Placeholder response: received \"smoke test\""

      events = State.events()
      # 5 events: user_message, turn_started, assistant_delta, assistant_message, turn_completed
      assert length(events) == 5
    end
  end

  describe "submit/2" do
    test "returns {:ok, text} with placeholder response" do
      assert {:ok, text} = Muse.SessionRouter.submit("test-session", :cli, "hello")
      assert text == "Placeholder response: received \"hello\""
    end

    test "appends events to State" do
      Muse.SessionRouter.submit("event-session", :cli, "test event")
      events = State.events()

      # 5 events: user_message, turn_started, assistant_delta, assistant_message, turn_completed
      assert length(events) == 5

      user_event = Enum.find(events, &(&1.type == :user_message))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))
      assert user_event.source == :cli
      assert user_event.type == :user_message

      assert assistant_event.source == :muse
      assert assistant_event.type == :assistant_message
    end

    test "uses default session id when not provided" do
      assert {:ok, _text} = Muse.SessionRouter.submit(:web, "default test")
    end

    test "creates session on first submit" do
      assert {:ok, _text} = Muse.SessionRouter.submit("first-submit", :cli, "first")

      assert [{_pid, _}] = Registry.lookup(Muse.SessionRegistry, "first-submit")
    end

    test "reuses session across submits" do
      {:ok, text1} = Muse.SessionRouter.submit("multi-submit", :cli, "first")
      {:ok, text2} = Muse.SessionRouter.submit("multi-submit", :cli, "second")

      assert text1 == "Placeholder response: received \"first\""
      assert text2 == "Placeholder response: received \"second\""

      # Only one session process
      assert length(
               Registry.select(Muse.SessionRegistry, [
                 {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
               ])
             ) == 1
    end
  end

  describe "status/1" do
    test "returns session status for active session" do
      {:ok, _pid} = Muse.SessionRouter.find_or_start_session("status-active")

      assert {:ok, status} = Muse.SessionRouter.status("status-active")

      assert status.session_id == "status-active"
      assert status.status == :idle
      assert is_integer(status.event_count)
    end

    test "returns {:error, :not_found} for unknown session" do
      assert {:error, :not_found} = Muse.SessionRouter.status("nonexistent")
    end
  end

  describe "concurrent start" do
    test "Task.async_stream callers for same session id all return {:ok, same_pid}" do
      caller_count = 20

      results =
        1..caller_count
        |> Task.async_stream(
          fn _ ->
            Muse.SessionRouter.find_or_start_session("concurrent-race")
          end,
          timeout: 5_000,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == caller_count

      # All returned {:ok, pid}
      assert Enum.all?(results, fn
               {:ok, _pid} -> true
               _ -> false
             end)

      # All pids are the same
      pids = Enum.map(results, fn {:ok, pid} -> pid end)
      assert Enum.all?(pids, &(&1 == hd(pids)))
      assert length(Enum.uniq(pids)) == 1
    end
  end

  describe "active_sessions/0" do
    test "returns all active sessions" do
      Muse.SessionRouter.find_or_start_session("active-1")
      Muse.SessionRouter.find_or_start_session("active-2")

      sessions = Muse.SessionRouter.active_sessions()
      assert length(sessions) == 2

      ids = Enum.map(sessions, fn {id, _pid} -> id end)
      assert "active-1" in ids
      assert "active-2" in ids
    end

    test "returns empty list when no sessions" do
      assert Muse.SessionRouter.active_sessions() == []
    end
  end
end
