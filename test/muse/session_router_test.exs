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

  defp persist_awaiting_plan(session_id) do
    plan =
      Muse.Plan.new(
        id: "#{session_id}-plan",
        session_id: session_id,
        objective: "Router approval plan",
        tasks: [Muse.Task.new(title: "Review", description: "Review plan")]
      )

    {:ok, plan} = Muse.Plan.transition(plan, :awaiting_approval)

    :ok =
      Muse.SessionStore.save_session(session_id, %{
        "status" => "awaiting_plan_approval",
        "active_plan_id" => plan.id,
        "plan" => Muse.Plan.to_map(plan),
        "plans" => %{plan.id => Muse.Plan.to_map(plan)}
      })

    plan
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
      assert text =~ "Placeholder response"

      events = State.events()
      # 12 events after Conductor integration:
      # user_message, turn_started, muse_selected, session_status_changed,
      # prompt_prepared, provider_request_started, provider_response_started,
      # assistant_delta, provider_response_completed, assistant_message,
      # session_status_changed, turn_completed
      assert length(events) == 12
    end
  end

  describe "submit/2" do
    test "returns {:ok, text} with placeholder response" do
      assert {:ok, text} = Muse.SessionRouter.submit("test-session", :cli, "hello")
      assert text =~ "Placeholder response"
    end

    test "appends events to State" do
      Muse.SessionRouter.submit("event-session", :cli, "test event")
      events = State.events()

      # 12 events after Conductor integration
      assert length(events) == 12

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

      assert text1 =~ "Placeholder response"
      assert text2 =~ "Placeholder response"

      # Only one session process
      assert length(
               Registry.select(Muse.SessionRegistry, [
                 {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
               ])
             ) == 1
    end
  end

  describe "approve_plan/2 and reject_plan/2" do
    test "returns {:error, :not_found} without starting missing sessions" do
      session_id = "router-missing-#{:erlang.unique_integer([:positive])}"

      assert {:error, :not_found} = Muse.SessionRouter.approve_plan(session_id)
      assert {:error, :not_found} = Muse.SessionRouter.reject_plan(session_id)
      assert Registry.lookup(Muse.SessionRegistry, session_id) == []
    end

    test "routes approval to an existing session" do
      session_id = "router-approve-#{:erlang.unique_integer([:positive])}"
      plan = persist_awaiting_plan(session_id)
      {:ok, pid} = Muse.SessionRouter.find_or_start_session(session_id)

      assert {:ok, approved_plan} = Muse.SessionRouter.approve_plan(session_id, :cli)
      assert approved_plan.status == :approved

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.plan.status == :approved
      assert status.active_plan_id == plan.id
    end

    test "routes rejection to an existing session" do
      session_id = "router-reject-#{:erlang.unique_integer([:positive])}"
      plan = persist_awaiting_plan(session_id)
      {:ok, pid} = Muse.SessionRouter.find_or_start_session(session_id)

      assert {:ok, rejected_plan} = Muse.SessionRouter.reject_plan(session_id, :web)
      assert rejected_plan.status == :rejected

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.plan.status == :rejected
      assert status.active_plan_id == plan.id
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
