defmodule Muse.ApprovalPersistenceTest do
  use ExUnit.Case, async: false

  alias Muse.{Approval, ApprovalGate, Plan, SessionServer, SessionStore}

  defp unique_id(prefix), do: "#{prefix}-#{:erlang.unique_integer([:positive])}"

  defp awaiting_plan(session_id, opts \\ []) do
    plan =
      Plan.new(
        id: Keyword.get(opts, :id, "plan-#{session_id}"),
        session_id: session_id,
        objective: Keyword.get(opts, :objective, "Approval persistence test"),
        version: Keyword.get(opts, :version, 1),
        tasks: [
          Muse.Task.new(id: "task-a", title: "A", description: "Do A"),
          Muse.Task.new(id: "task-b", title: "B", description: "Do B")
        ]
      )

    {:ok, plan} = Plan.transition(plan, :awaiting_approval)
    plan
  end

  defp persist_plan_snapshot(session_id, plan, extra \\ %{}) do
    data =
      Map.merge(
        %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => plan.id,
          "plan" => Plan.to_map(plan),
          "plans" => %{plan.id => Plan.to_map(plan)}
        },
        extra
      )

    SessionStore.save_session(session_id, data)
  end

  defp start_server(session_id) do
    {:ok, pid} = SessionServer.start_link(session_id: session_id)
    pid
  end

  defp cleanup_session(session_id) do
    session_id
    |> then(&Path.join(".muse/sessions", &1))
    |> File.rm_rf!()
  end

  setup do
    on_exit(fn ->
      case Process.whereis(Muse.State) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
      end
    end)

    :ok
  end

  describe "snapshot persistence" do
    test "pending approvals and approval bindings survive save/load" do
      session_id = unique_id("approval-snapshot")
      plan = awaiting_plan(session_id)
      binding = ApprovalGate.capture_binding(plan, now: ~U[2025-06-15 12:00:00Z])

      approval =
        Approval.new(
          id: "approval_snapshot",
          session_id: session_id,
          kind: :plan,
          status: :pending,
          plan_id: plan.id,
          plan_version: plan.version,
          plan_hash: binding.plan_hash,
          content_hash: binding.content_hash,
          created_at: ~U[2025-06-15 12:00:00Z]
        )

      assert :ok =
               persist_plan_snapshot(
                 session_id,
                 ApprovalGate.put_plan_approval(plan, approval),
                 %{
                   "approvals" => [Approval.to_map(approval)],
                   "approval_binding" => binding
                 }
               )

      assert {:ok, loaded} = SessionStore.load_session(session_id)
      assert [stored_approval] = loaded["approvals"]
      assert stored_approval["id"] == "approval_snapshot"
      assert stored_approval["status"] == "pending"
      assert stored_approval["plan_hash"] == binding.plan_hash
      assert loaded["approval_binding"]["plan_hash"] == binding.plan_hash

      cleanup_session(session_id)
    end

    test "legacy awaiting snapshots without approvals restore and can approve safely" do
      session_id = unique_id("legacy-approval")
      plan = awaiting_plan(session_id)
      assert :ok = persist_plan_snapshot(session_id, plan)

      pid = start_server(session_id)
      restored = SessionServer.status(pid)

      assert restored.status == :awaiting_plan_approval
      assert restored.plan.id == plan.id
      assert restored.approvals != []
      assert restored.active_approval.status == :pending
      assert restored.approval_binding.plan_id == plan.id
      assert restored.approval_binding.plan_hash == restored.active_approval.plan_hash

      assert {:ok, approved_plan} = SessionServer.approve_plan(pid, :cli)
      assert approved_plan.status == :approved

      approved = SessionServer.status(pid)
      assert approved.status == :idle
      assert [approval] = approved.approvals
      assert approval.status == :approved
      assert approval.plan_hash == Plan.content_hash(plan)

      GenServer.stop(pid)
      cleanup_session(session_id)
    end

    test "approval persistence recursively redacts secrets in reasons and metadata" do
      session_id = unique_id("approval-redaction")
      plan = awaiting_plan(session_id)

      approval =
        Approval.new(
          id: "approval_redaction",
          session_id: session_id,
          kind: :plan,
          status: :approved,
          plan_id: plan.id,
          plan_version: plan.version,
          plan_hash: Plan.content_hash(plan),
          reason: "human typed Bearer sk-test-approval-secret and api_key=sk-test-query-secret",
          metadata: %{
            safe: "ok",
            nested: %{token: "sk-test-nested-secret", comment: "Bearer sk-test-comment-secret"}
          }
        )

      assert :ok =
               persist_plan_snapshot(
                 session_id,
                 ApprovalGate.put_plan_approval(plan, approval),
                 %{
                   "status" => "idle",
                   "approvals" => [Approval.to_map(approval)]
                 }
               )

      assert {:ok, loaded} = SessionStore.load_session(session_id)
      encoded = Jason.encode!(loaded)

      refute encoded =~ "sk-test-approval-secret"
      refute encoded =~ "sk-test-query-secret"
      refute encoded =~ "sk-test-nested-secret"
      refute encoded =~ "sk-test-comment-secret"
      assert encoded =~ "[REDACTED]"

      cleanup_session(session_id)
    end
  end
end
