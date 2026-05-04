defmodule Muse.CLI.CommandDispatcherTest do
  use ExUnit.Case, async: false

  alias Muse.{CommandDispatcher, Commands, Plan, SessionServer, SessionStore, State}

  setup do
    cleanup!()
    ensure_state!()

    on_exit(fn -> cleanup!() end)

    :ok
  end

  describe "CLI plan lifecycle commands" do
    test "/plan and /approve plan bind to the active plan id/version without execution" do
      session_id = "cli-plan-approve-#{:erlang.unique_integer([:positive])}"
      plan = persist_awaiting_plan!(session_id, version: 4)
      pid = start_session!(session_id)
      context = %{session_id: session_id, source: :cli}

      event_count = State.events() |> length()

      assert {:ok, plan_output, []} = run_command("/plan", context)
      assert plan_output =~ "Muse Plan #{plan.id} (version 4)"
      assert plan_output =~ "Planning Muse prepared a plan."
      assert State.events() |> length() == event_count

      assert {:ok, approve_output, [{:refresh, :events}]} = run_command("/approve plan", context)

      assert approve_output ==
               "Plan approved.\n\nThe approved plan is ready for implementation.\nActive plan: #{plan.id} (version 4)."

      status = SessionServer.status(pid)
      assert status.status == :idle
      assert status.active_plan_id == plan.id
      assert status.plan.status == :approved
      assert status.plan.version == 4
      assert status.active_turn_id == nil
      assert status.runner_pid == nil

      new_events = State.events() |> Enum.drop(event_count)
      assert Enum.map(new_events, & &1.type) == [:plan_approved, :session_status_changed]
      assert hd(new_events).data.plan_id == plan.id
      assert hd(new_events).data.version == 4
      assert_no_execution_events(new_events)

      assert {:ok, stored} = SessionStore.load_session(session_id)
      assert stored["status"] == "idle"
      assert stored["active_plan_id"] == plan.id
      assert stored["plan"]["status"] == "approved"
      assert stored["plan"]["version"] == 4
      assert get_in(stored, ["plans", plan.id, "status"]) == "approved"
    end

    test "/reject plan binds to the active plan id/version without execution" do
      session_id = "cli-plan-reject-#{:erlang.unique_integer([:positive])}"
      plan = persist_awaiting_plan!(session_id, version: 5)
      pid = start_session!(session_id)
      context = %{session_id: session_id, source: :cli}
      event_count = State.events() |> length()

      assert {:ok, reject_output, [{:refresh, :events}]} = run_command("/reject plan", context)

      assert reject_output ==
               "Plan rejected.\n\nYou can ask Planning Muse for a revised plan.\nActive plan: #{plan.id} (version 5)."

      status = SessionServer.status(pid)
      assert status.status == :idle
      assert status.active_plan_id == plan.id
      assert status.plan.status == :rejected
      assert status.plan.version == 5
      assert status.active_turn_id == nil
      assert status.runner_pid == nil

      new_events = State.events() |> Enum.drop(event_count)
      assert Enum.map(new_events, & &1.type) == [:plan_rejected, :session_status_changed]
      assert hd(new_events).data.plan_id == plan.id
      assert hd(new_events).data.version == 5
      assert_no_execution_events(new_events)
    end
  end

  defp run_command(text, context) do
    case Commands.parse(text) do
      {:command, action} -> CommandDispatcher.dispatch(action, nil, context)
      {:command, action, args} -> CommandDispatcher.dispatch(action, args, context)
    end
  end

  defp persist_awaiting_plan!(session_id, opts) do
    plan =
      Plan.new(
        id: "#{session_id}-plan",
        session_id: session_id,
        version: Keyword.fetch!(opts, :version),
        objective: "Review CLI lifecycle binding",
        tasks: [Muse.Task.new(title: "Review", description: "Review the active plan")]
      )

    {:ok, plan} = Plan.transition(plan, :awaiting_approval)

    :ok =
      SessionStore.save_session(session_id, %{
        "status" => "awaiting_plan_approval",
        "active_plan_id" => plan.id,
        "plan" => Plan.to_map(plan),
        "plans" => %{plan.id => Plan.to_map(plan)}
      })

    plan
  end

  defp start_session!(session_id) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {SessionServer, session_id: session_id}
      )

    pid
  end

  defp ensure_state! do
    case Process.whereis(State) do
      nil -> {:ok, _pid} = State.start_link([])
      _pid -> :ok
    end
  end

  defp cleanup! do
    clean_sessions!()

    case Process.whereis(State) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    File.rm_rf!(".muse/sessions")
  end

  defp clean_sessions! do
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

  defp assert_no_execution_events(events) do
    refute Enum.any?(events, &(&1.type in [:turn_started, :turn_completed, :turn_failed]))
    refute Enum.any?(events, &(&1.type in [:muse_selected, :assistant_delta, :assistant_message]))
    refute Enum.any?(events, &String.starts_with?(Atom.to_string(&1.type), "tool_call_"))
  end
end
