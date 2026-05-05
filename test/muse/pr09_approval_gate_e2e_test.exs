defmodule Muse.PR09ApprovalGateE2ETest do
  use ExUnit.Case, async: false

  alias Muse.{CommandDispatcher, Commands, Plan, PlanParser, SessionServer, SessionStore, State}
  import Muse.PR09ApprovalGateWorkspaceHelpers

  @fixtures_dir Path.expand("../fixtures/fake_provider", __DIR__)
  @fixture_file "pr09_approval_gate_flow_batches.json"
  @fixture_plan_id "pr09-approval-gate-plan"
  @read_only_tools ~w(list_files read_file git_status repo_search git_diff_readonly)
  @forbidden_tools ~w(write_file replace_in_file delete_file patch_apply patch_propose apply_patch shell_command network_call remote_execution)
  @forbidden_execution_event_types [
    :patch_approval_requested,
    :patch_approved,
    :patch_applied,
    :workspace_write,
    :coding_handoff,
    :implementation_started
  ]

  setup do
    cleanup_infrastructure()
    ensure_infrastructure()

    workspace = tmp_dir!()
    seed_workspace(workspace)

    on_exit(fn ->
      cleanup_infrastructure()
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  describe "PR09 fake-provider approval gate E2E" do
    @tag :pr09_approval_gate
    test "planning flow uses read-only tools and parks a valid structured plan for approval",
         %{workspace: workspace} do
      session_id = session_id("plan")
      pid = start_server(session_id)
      batches = fixture_batches()
      fixture_plan = assert_fixture_plan_is_valid!(batches, @fixture_plan_id)
      {paths_before, hashes_before} = workspace_snapshot(workspace)

      {:ok, assistant_text} = submit_plan_request(pid, workspace, batches)

      status = assert_awaiting_plan!(pid, @fixture_plan_id)
      assert status.plan.objective == fixture_plan.objective
      assert status.plan.version == 1
      assert status.plan.created_by == "planning"
      assert status.plan.session_id == session_id

      refute assistant_text =~ ~r/^\s*\{/
      refute assistant_text =~ ~s("objective")
      assert assistant_text =~ "Planning Muse prepared a plan."
      assert assistant_text =~ "Objective:"
      assert assistant_text =~ "Tasks:"
      assert assistant_text =~ "/approve plan"
      assert assistant_text =~ "/reject plan"

      stored =
        assert_stored_plan_status(
          session_id,
          @fixture_plan_id,
          "awaiting_plan_approval",
          "awaiting_approval"
        )

      assert_pending_approval_binding_if_present(status, stored, status.plan)

      events = State.events()
      assert_fake_provider_request!(events)
      assert_read_only_tool_flow!(events, @read_only_tools)
      assert_no_forbidden_execution_or_handoff(events)

      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end

    @tag :pr09_approval_gate
    test "/approve plan approves the exact active plan and remains lifecycle-only",
         %{workspace: workspace} do
      session_id = session_id("approve")
      pid = start_server(session_id)
      {paths_before, hashes_before} = workspace_snapshot(workspace)

      {:ok, _assistant_text} = submit_plan_request(pid, workspace, fixture_batches())
      awaiting_status = assert_awaiting_plan!(pid, @fixture_plan_id)
      plan_id = awaiting_status.active_plan_id
      context = command_context(session_id, :cli)

      events_before_approve = State.events()
      {:ok, approve_output, approve_effects} = run_slash_command("/approve plan", context)

      assert approve_output ==
               "Plan approved.\n\nThe approved plan is ready for implementation.\nActive plan: #{plan_id} (version 1)."

      assert approve_effects == [{:refresh, :events}]

      approved_status = SessionServer.status(pid)
      assert approved_status.status == :idle
      assert approved_status.active_plan_id == plan_id
      assert approved_status.plan.id == plan_id
      assert approved_status.plan.status == :approved
      assert approved_status.plan.approved_at != nil
      assert approved_status.plan.rejected_at == nil
      assert approved_status.active_turn_id == nil
      assert approved_status.runner_pid == nil

      new_approve_events = new_events_since(events_before_approve)
      assert Enum.map(new_approve_events, & &1.type) == [:plan_approved, :session_status_changed]
      assert_no_turn_execution_events(new_approve_events)
      assert_no_forbidden_execution_or_handoff(new_approve_events)
      assert_no_coding_handoff(new_approve_events)
      assert_stored_plan_status(session_id, plan_id, "idle", "approved")

      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before

      events_before_duplicate = State.events()
      {:error, duplicate_output, []} = run_slash_command("/approve plan", context)
      assert duplicate_output == "Error: active Muse Plan is approved, not awaiting approval."
      assert new_events_since(events_before_duplicate) == []

      duplicate_status = SessionServer.status(pid)
      assert duplicate_status.status == :idle
      assert duplicate_status.plan.status == :approved
      assert duplicate_status.active_plan_id == plan_id
    end

    @tag :pr09_approval_gate
    test "/reject plan rejects the exact active plan and remains lifecycle-only",
         %{workspace: workspace} do
      session_id = session_id("reject")
      pid = start_server(session_id)
      {paths_before, hashes_before} = workspace_snapshot(workspace)

      {:ok, _assistant_text} = submit_plan_request(pid, workspace, fixture_batches())
      awaiting_status = assert_awaiting_plan!(pid, @fixture_plan_id)
      plan_id = awaiting_status.active_plan_id
      context = command_context(session_id, :web)

      events_before_reject = State.events()
      {:ok, reject_output, reject_effects} = run_slash_command("/reject plan", context)

      assert reject_output ==
               "Plan rejected.\n\nYou can ask Planning Muse for a revised plan.\nActive plan: #{plan_id} (version 1)."

      assert reject_effects == [{:refresh, :events}]

      rejected_status = SessionServer.status(pid)
      assert rejected_status.status == :idle
      assert rejected_status.active_plan_id == plan_id
      assert rejected_status.plan.id == plan_id
      assert rejected_status.plan.status == :rejected
      assert rejected_status.plan.rejected_at != nil
      assert rejected_status.plan.approved_at == nil
      assert rejected_status.active_turn_id == nil
      assert rejected_status.runner_pid == nil

      new_reject_events = new_events_since(events_before_reject)
      assert Enum.map(new_reject_events, & &1.type) == [:plan_rejected, :session_status_changed]
      assert_no_turn_execution_events(new_reject_events)
      assert_no_forbidden_execution_or_handoff(new_reject_events)
      assert_no_coding_handoff(new_reject_events)
      assert_stored_plan_status(session_id, plan_id, "idle", "rejected")

      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end

    @tag :pr09_approval_gate
    test "stale explicit plan approval attempt fails safely after a newer active plan exists",
         %{workspace: workspace} do
      session_id = session_id("stale")
      pid = start_server(session_id)
      {paths_before, hashes_before} = workspace_snapshot(workspace)

      old_plan_id = "pr09-stale-plan"
      current_plan_id = "pr09-current-plan"

      {:ok, _old_text} =
        submit_plan_request(
          pid,
          workspace,
          fixture_batches(plan_id: old_plan_id, objective: "Prepare the first /version plan.")
        )

      old_status = assert_awaiting_plan!(pid, old_plan_id)
      assert old_status.plan.version == 1

      {:ok, _current_text} =
        submit_plan_request(
          pid,
          workspace,
          fixture_batches(
            plan_id: current_plan_id,
            objective: "Prepare the revised active /version plan."
          )
        )

      current_status = assert_awaiting_plan!(pid, current_plan_id)
      assert current_status.plan.version == 2
      assert current_status.active_plan_id == current_plan_id
      assert Map.fetch!(current_status.plans, old_plan_id).status == :awaiting_approval

      context = command_context(session_id, :cli)
      events_before_stale_attempt = State.events()

      {:error, stale_output, []} = run_slash_command("/approve plan #{old_plan_id}", context)
      assert stale_output == "Error: usage: /approve plan"
      assert new_events_since(events_before_stale_attempt) == []

      status_after_stale_attempt = SessionServer.status(pid)
      assert status_after_stale_attempt.status == :awaiting_plan_approval
      assert status_after_stale_attempt.active_plan_id == current_plan_id
      assert status_after_stale_attempt.plan.status == :awaiting_approval

      assert Map.fetch!(status_after_stale_attempt.plans, old_plan_id).status ==
               :awaiting_approval

      {:ok, approve_output, _effects} = run_slash_command("/approve plan", context)
      assert approve_output =~ "Active plan: #{current_plan_id} (version 2)."

      approved_status = SessionServer.status(pid)
      assert approved_status.status == :idle
      assert approved_status.active_plan_id == current_plan_id
      assert approved_status.plan.status == :approved
      assert Map.fetch!(approved_status.plans, old_plan_id).status == :awaiting_approval

      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end

    @tag :pr09_full_approval_gate_contract
    @tag skip:
           "Full content-bound ApprovalGate session/version/hash binding is tracked by muse-rc8; main currently exposes lifecycle-only /approve plan and /reject plan."
    test "full ApprovalGate rejects stale approval bindings by session, version, and hash mismatch" do
      # Contract placeholder for the follow-up full ApprovalGate integration:
      # a pending plan approval should be bound to the active session id, plan id,
      # plan version, and content hash, and any mismatch must fail closed without
      # executing Coding Muse, shell commands, patch application, or workspace writes.
    end
  end

  # -- Fixture helpers ---------------------------------------------------------

  defp fixture_batches(overrides \\ []) do
    @fixture_file
    |> load_fixture!()
    |> Map.fetch!("batches")
    |> maybe_override_fixture_plan(overrides)
  end

  defp load_fixture!(filename) do
    path = Path.join(@fixtures_dir, filename)
    assert File.exists?(path), "Fixture file not found: #{path}"

    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp maybe_override_fixture_plan(batches, []), do: batches

  defp maybe_override_fixture_plan(batches, overrides) do
    plan =
      batches
      |> fixture_plan_text!()
      |> Jason.decode!()
      |> apply_plan_overrides(overrides)

    plan_json = Jason.encode!(plan)

    Enum.map(batches, fn batch ->
      Enum.map(batch, fn entry ->
        if plan_json_entry?(entry) do
          Map.put(entry, "text", plan_json)
        else
          entry
        end
      end)
    end)
  end

  defp apply_plan_overrides(plan, overrides) do
    Enum.reduce(overrides, plan, fn
      {:plan_id, plan_id}, acc -> Map.put(acc, "id", plan_id)
      {:objective, objective}, acc -> Map.put(acc, "objective", objective)
      {:summary, summary}, acc -> Map.put(acc, "summary", summary)
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
    end)
  end

  defp fixture_plan_text!(batches) do
    batches
    |> List.last()
    |> Enum.find_value(fn entry ->
      if (entry["event"] || entry["type"]) == "assistant_completed" do
        entry["text"]
      end
    end)
  end

  defp plan_json_entry?(entry) do
    event = entry["event"] || entry["type"]
    text = entry["text"]

    event in ["assistant_delta", "assistant_completed"] and is_binary(text) and
      match?({:ok, %{"objective" => _}}, Jason.decode(text))
  end

  defp assert_fixture_plan_is_valid!(batches, expected_plan_id) do
    plan_text = fixture_plan_text!(batches)
    assert {:ok, %Plan{} = plan} = PlanParser.parse(plan_text)
    assert plan.id == expected_plan_id
    assert plan.objective =~ "/version command"
    assert length(plan.tasks) == 3
    plan
  end

  # -- Session/command helpers -------------------------------------------------

  defp submit_plan_request(pid, workspace, fake_event_batches) do
    SessionServer.submit(pid, :cli, "plan the version command",
      workspace: workspace,
      prompt_opts: [project_rules?: false],
      request_options: [options: %{fake_event_batches: fake_event_batches}]
    )
  end

  defp assert_awaiting_plan!(pid, expected_plan_id) do
    status = SessionServer.status(pid)

    assert status.status == :awaiting_plan_approval
    assert status.active_plan_id == expected_plan_id
    assert %Plan{} = status.plan
    assert status.plan.id == expected_plan_id
    assert status.plan.status == :awaiting_approval
    assert Map.fetch!(status.plans, expected_plan_id).status == :awaiting_approval
    assert status.active_turn_id == nil
    assert status.runner_pid == nil

    status
  end

  defp command_context(session_id, source) do
    %{session_id: session_id, source: source}
  end

  defp run_slash_command(command, context) do
    case Commands.parse(command) do
      {:command, action} -> CommandDispatcher.dispatch(action, nil, context)
      {:command, action, args} -> CommandDispatcher.dispatch(action, args, context)
    end
  end

  defp assert_stored_plan_status(session_id, plan_id, session_status, plan_status) do
    assert {:ok, stored} = SessionStore.load_session(session_id)
    assert stored["status"] == session_status
    assert stored["active_plan_id"] == plan_id
    assert get_in(stored, ["plan", "status"]) == plan_status
    assert get_in(stored, ["plans", plan_id, "status"]) == plan_status
    stored
  end

  defp assert_pending_approval_binding_if_present(status, stored, plan) do
    approval_records = approval_records(status) ++ approval_records(stored)

    case approval_records do
      [] ->
        :ok

      records ->
        assert Enum.any?(records, &pending_approval_for_plan?(&1, status.session_id, plan)),
               "Expected at least one pending approval binding for #{plan.id}, got: #{inspect(records)}"
    end
  end

  defp approval_records(source) when is_map(source) do
    source
    |> map_get_any([
      :pending_approval,
      "pending_approval",
      :approval,
      "approval",
      :approvals,
      "approvals"
    ])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp pending_approval_for_plan?(record, session_id, plan) do
    record_status = map_get_any(record, [:status, "status"])
    record_session_id = map_get_any(record, [:session_id, "session_id"])
    record_plan_id = map_get_any(record, [:plan_id, "plan_id", :active_plan_id, "active_plan_id"])
    record_version = map_get_any(record, [:plan_version, "plan_version", :version, "version"])

    record_status in [:pending, "pending", :awaiting_approval, "awaiting_approval"] and
      record_session_id in [nil, session_id] and
      record_plan_id == plan.id and
      record_version in [nil, plan.version, Integer.to_string(plan.version)]
  end

  defp new_events_since(events_before) do
    State.events()
    |> Enum.drop(length(events_before))
  end

  # -- Event assertions --------------------------------------------------------

  defp assert_fake_provider_request!(events) do
    provider_events = events_of_type(events, :provider_request_started)

    assert Enum.any?(provider_events, fn event ->
             map_get_any(event.data, [:provider, "provider"]) in [:fake, "fake"]
           end)
  end

  defp assert_read_only_tool_flow!(events, expected_tools) do
    completed_tools =
      events
      |> events_of_type(:tool_call_completed)
      |> Enum.map(&tool_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    for tool <- expected_tools do
      assert tool in completed_tools,
             "Expected read-only tool #{tool}, got completed tools: #{inspect(completed_tools)}"
    end

    blocked_or_failed =
      Enum.filter(events, &(&1.type in [:tool_call_blocked, :tool_call_failed, :tool_call_error]))

    assert blocked_or_failed == []
  end

  defp assert_no_turn_execution_events(events) do
    refute Enum.any?(events, &(&1.type in [:turn_started, :turn_completed, :turn_failed]))
    refute Enum.any?(events, &(&1.type in [:muse_selected, :assistant_delta, :assistant_message]))
    refute Enum.any?(events, &String.starts_with?(Atom.to_string(&1.type), "tool_call_"))
  end

  defp assert_no_forbidden_execution_or_handoff(events) do
    forbidden_tool_events =
      Enum.filter(events, fn event ->
        tool_name = tool_name(event)

        event.type in [:tool_call_started, :tool_call_requested, :tool_call_completed] and
          tool_name in @forbidden_tools
      end)

    assert forbidden_tool_events == []

    refute Enum.any?(events, &(&1.type in @forbidden_execution_event_types))
    assert_no_coding_handoff(events)
  end

  defp assert_no_coding_handoff(events) do
    refute Enum.any?(events, fn
             %{type: :muse_selected, data: %{muse_id: :coding}} -> true
             %{type: :muse_selected, data: %{"muse_id" => "coding"}} -> true
             %{type: :muse_selected, muse_id: "coding"} -> true
             %{muse_id: "coding"} -> true
             _ -> false
           end)
  end

  defp events_of_type(events, type) do
    Enum.filter(events, &(&1.type == type))
  end

  defp tool_name(%{data: data}) when is_map(data) do
    map_get_any(data, [:tool_name, "tool_name"])
  end

  defp tool_name(_event), do: nil

  # -- Infrastructure helpers --------------------------------------------------

  defp ensure_infrastructure do
    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _pid -> State.clear()
    end

    clean_sessions()
    File.rm_rf!(".muse/sessions")
    :ok
  end

  defp cleanup_infrastructure do
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

    File.rm_rf!(".muse/sessions")
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

  defp start_server(session_id) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {SessionServer, session_id: session_id}
      )

    pid
  end

  defp map_get_any(map, keys, default \\ nil)

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default
end
