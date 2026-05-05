defmodule Muse.PatchSessionServerTest do
  use ExUnit.Case, async: false

  alias Muse.{SessionServer, Plan, Patch, SessionStore}

  # -- Helpers ------------------------------------------------------------------

  defp ensure_infrastructure do
    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = Muse.State.start_link([])
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

  defp approved_plan(session_id, opts \\ []) do
    plan =
      Plan.new(
        id: Keyword.get(opts, :id, "#{session_id}-plan"),
        session_id: session_id,
        objective: Keyword.get(opts, :objective, "Test patch plan"),
        status: :approved,
        tasks: Keyword.get(opts, :tasks, [])
      )

    plan
  end

  defp persist_approved_plan_snapshot(session_id, plan, extra \\ %{}) do
    approval =
      Muse.Approval.new(%{
        kind: :plan,
        status: :approved,
        session_id: session_id,
        plan_id: plan.id,
        plan_version: plan.version,
        plan_hash: Muse.PlanBinding.content_hash(plan),
        approved_by: "test",
        approved_at: ~U[2025-01-01 00:00:00Z]
      })

    data =
      Map.merge(
        %{
          "status" => "idle",
          "active_plan_id" => plan.id,
          "plan" => Plan.to_map(plan),
          "plans" => %{plan.id => Plan.to_map(plan)},
          "approvals" => [Muse.Approval.to_map(approval)]
        },
        extra
      )

    :ok = SessionStore.save_session(session_id, data)
    :ok
  end

  defp persist_awaiting_approval_snapshot(session_id, plan) do
    data = %{
      "status" => "awaiting_plan_approval",
      "active_plan_id" => plan.id,
      "plan" => Plan.to_map(plan),
      "plans" => %{plan.id => Plan.to_map(plan)}
    }

    :ok = SessionStore.save_session(session_id, data)
    :ok
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

  describe "propose_patch/2" do
    test "creates a pending patch proposal when plan is approved" do
      session_id = "patch-propose-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, %Patch{} = patch} =
               SessionServer.propose_patch(pid,
                 summary: "Add /version command",
                 affected_files: ["lib/muse/commands.ex"]
               )

      assert patch.status == :awaiting_approval
      assert patch.plan_id == plan.id
      assert patch.session_id == session_id
      assert patch.summary == "Add /version command"
    end

    test "session transitions to awaiting_patch_approval after proposal" do
      session_id = "patch-transition-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      status_before = SessionServer.status(pid)
      assert status_before.status == :idle

      assert {:ok, _patch} = SessionServer.propose_patch(pid, summary: "Test")

      status_after = SessionServer.status(pid)
      assert status_after.status == :awaiting_patch_approval
    end

    test "pending_patch is set in status after proposal" do
      session_id = "patch-status-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, patch} = SessionServer.propose_patch(pid, summary: "Test")

      status = SessionServer.status(pid)
      assert status.pending_patch != nil
      assert status.pending_patch.id == patch.id
    end

    test "creates a patch approval record" do
      session_id = "patch-approval-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, _patch} = SessionServer.propose_patch(pid, summary: "Test")

      status = SessionServer.status(pid)
      assert status.approvals != nil

      patch_approvals =
        Enum.filter(status.approvals, fn a ->
          a.kind == :patch and a.status == :pending
        end)

      assert length(patch_approvals) >= 1
    end

    test "persists patch to patches.jsonl" do
      session_id = "patch-persist-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, patch} = SessionServer.propose_patch(pid, summary: "Persist test")

      {:ok, patches, _} = SessionStore.load_patches(session_id)
      assert length(patches) >= 1

      stored = Enum.find(patches, &(&1["id"] == patch.id))
      assert stored != nil
      assert stored["summary"] == "Persist test"
    end
  end

  describe "propose_patch/2 validation" do
    test "fails when no active plan" do
      session_id = "patch-no-plan-#{System.unique_integer([:positive])}"

      # Start server with empty snapshot (no plan)
      :ok = SessionStore.save_session(session_id, %{"status" => "idle"})

      pid = start_server(session_id)

      assert {:error, :no_active_plan} = SessionServer.propose_patch(pid, summary: "No plan")
    end

    test "fails when plan is not approved" do
      session_id = "patch-unapproved-#{System.unique_integer([:positive])}"

      plan =
        Plan.new(
          id: "unapproved-plan",
          session_id: session_id,
          objective: "Test",
          status: :awaiting_approval
        )

      persist_awaiting_approval_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:error, :plan_not_approved} =
               SessionServer.propose_patch(pid, summary: "Test unapproved")
    end
  end

  describe "approve_patch/2" do
    test "approves a pending patch proposal" do
      session_id = "patch-approve-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, %Patch{} = patch} =
               SessionServer.propose_patch(pid, summary: "Approve me")

      assert {:ok, %Patch{} = approved} = SessionServer.approve_patch(pid, :test_user)
      assert approved.status == :approved
      assert approved.id == patch.id
    end

    test "session returns to idle after approval" do
      session_id = "patch-approve-idle-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, _} = SessionServer.propose_patch(pid, summary: "Approve")
      assert {:ok, _} = SessionServer.approve_patch(pid, :test_user)

      status = SessionServer.status(pid)
      assert status.status == :idle
    end

    test "cannot approve when no pending patch" do
      session_id = "patch-no-pending-approve-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:error, :no_pending_patch} = SessionServer.approve_patch(pid, :test_user)
    end

    test "cannot approve a patch that is not awaiting approval" do
      session_id = "patch-already-approved-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, _} = SessionServer.propose_patch(pid, summary: "Already")
      assert {:ok, _} = SessionServer.approve_patch(pid, :test_user)

      # Try to approve again
      assert {:error, {:patch_not_awaiting_approval, :approved}} =
               SessionServer.approve_patch(pid, :test_user)
    end
  end

  describe "reject_patch/2" do
    test "rejects a pending patch proposal" do
      session_id = "patch-reject-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, %Patch{} = patch} =
               SessionServer.propose_patch(pid, summary: "Reject me")

      assert {:ok, %Patch{} = rejected} = SessionServer.reject_patch(pid, :test_user)
      assert rejected.status == :rejected
      assert rejected.id == patch.id
    end

    test "session returns to idle after rejection" do
      session_id = "patch-reject-idle-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, _} = SessionServer.propose_patch(pid, summary: "Reject")
      assert {:ok, _} = SessionServer.reject_patch(pid, :test_user)

      status = SessionServer.status(pid)
      assert status.status == :idle
    end

    test "cannot reject when no pending patch" do
      session_id = "patch-no-pending-reject-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:error, :no_pending_patch} = SessionServer.reject_patch(pid, :test_user)
    end
  end

  describe "reload preserves patch proposal metadata" do
    test "pending_patch survives snapshot reload" do
      session_id = "patch-reload-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      # Propose a patch
      assert {:ok, patch} =
               SessionServer.propose_patch(pid,
                 summary: "Reload test patch",
                 affected_files: ["lib/muse/foo.ex"]
               )

      # Verify the patch was persisted
      {:ok, patches, _} = SessionStore.load_patches(session_id)
      assert length(patches) >= 1

      # The snapshot should include the pending patch
      {:ok, snapshot_data} = SessionStore.load_session(session_id)
      assert snapshot_data["pending_patch"] != nil
      assert snapshot_data["pending_patch"]["id"] == patch.id
      assert snapshot_data["pending_patch"]["summary"] == "Reload test patch"

      # Stop the server
      GenServer.stop(pid)
      Process.sleep(50)

      # Restart the server
      pid2 = start_server(session_id)
      Process.sleep(50)

      # The restored server should have the pending patch
      status = SessionServer.status(pid2)
      assert status.pending_patch != nil
      assert status.pending_patch.id == patch.id
      assert status.pending_patch.status == :awaiting_approval
      assert status.pending_patch.summary == "Reload test patch"
      assert status.status == :awaiting_patch_approval
    end
  end

  describe "workspace safety" do
    test "no workspace files are modified by proposal storage" do
      session_id = "patch-safety-#{System.unique_integer([:positive])}"
      plan = approved_plan(session_id)
      persist_approved_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      # Track the session dir contents before
      session_dir = SessionStore.session_dir(session_id)
      files_before = if File.dir?(session_dir), do: File.ls!(session_dir), else: []

      assert {:ok, _patch} =
               SessionServer.propose_patch(pid,
                 summary: "Safe patch",
                 affected_files: ["/tmp/should_not_exist/foo.ex"]
               )

      # The affected_files path should NOT cause any files to be created
      refute File.exists?("/tmp/should_not_exist/foo.ex")

      # Only session storage files should be modified
      files_after = File.ls!(session_dir)

      # The new files should be only session storage files
      new_files = files_after -- files_before

      assert Enum.all?(new_files, fn f ->
               String.ends_with?(f, ".json") or String.ends_with?(f, ".jsonl")
             end)
    end
  end
end
