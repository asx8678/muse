defmodule Muse.ApprovalGateTest do
  use ExUnit.Case, async: true

  alias Muse.{ApprovalGate, Plan, Session}

  describe "request_plan_approval/3 + approve_plan/4 + allowed?/2" do
    test "happy path binds and allows plan scope" do
      plan = plan_fixture()
      session = session_fixture(plan)
      now = base_time()

      assert {:ok, pending, session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan,
                 now: now,
                 requested_by: :planning_muse
               )

      assert pending.status == :pending
      assert pending.scope == :plan
      assert pending.session_id == session.id
      assert pending.plan_id == plan.id

      assert {:ok, approved} =
               ApprovalGate.approve_plan(session_with_pending, plan, :user,
                 now: DateTime.add(now, 5, :second)
               )

      session_with_approved = %{session_with_pending | approvals: [approved]}

      assert :ok = ApprovalGate.allowed?(session_with_approved, :plan)
      refute ApprovalGate.stale_plan_approval?(approved, plan)
    end

    test "wrong session is rejected" do
      plan = plan_fixture(session_id: "sess-a")
      session_a = session_fixture(plan, id: "sess-a")
      session_b = session_fixture(plan, id: "sess-b")

      assert {:ok, pending, _session_with_pending} =
               ApprovalGate.request_plan_approval(session_a, plan, now: base_time())

      assert {:error, :session_mismatch} =
               ApprovalGate.approve_plan(session_b, plan, :user,
                 approval: pending,
                 now: base_time()
               )
    end

    test "wrong plan id is rejected" do
      plan = plan_fixture()

      session =
        Session.new(
          id: plan.session_id,
          workspace: plan.metadata["workspace"],
          active_plan_id: nil,
          created_at: base_time(),
          updated_at: base_time()
        )

      assert {:ok, pending, _session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan, now: base_time())

      wrong_plan = %{plan | id: "plan-other"}

      assert {:error, :plan_id_mismatch} =
               ApprovalGate.approve_plan(session, wrong_plan, :user,
                 approval: pending,
                 now: base_time()
               )
    end

    test "version mismatch is rejected" do
      plan = plan_fixture()
      session = session_fixture(plan)

      assert {:ok, pending, _session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan, now: base_time())

      newer_plan = %{plan | version: plan.version + 1}

      assert {:error, :plan_version_mismatch} =
               ApprovalGate.approve_plan(session, newer_plan, :user,
                 approval: pending,
                 now: base_time()
               )
    end

    test "hash mismatch is rejected" do
      plan = plan_fixture()
      session = session_fixture(plan)

      assert {:ok, pending, _session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan, now: base_time())

      changed_content = %{plan | objective: "Changed objective without re-approval"}

      assert {:error, :plan_hash_mismatch} =
               ApprovalGate.approve_plan(session, changed_content, :user,
                 approval: pending,
                 now: base_time()
               )
    end

    test "expired approvals are rejected" do
      plan = plan_fixture()
      session = session_fixture(plan)

      created_at = DateTime.add(base_time(), -120, :second)
      expired_at = DateTime.add(base_time(), -60, :second)

      assert {:ok, pending, _session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan,
                 now: created_at,
                 expires_at: expired_at
               )

      assert {:error, :approval_expired} =
               ApprovalGate.approve_plan(session, plan, :user,
                 approval: pending,
                 now: base_time()
               )

      assert ApprovalGate.stale_plan_approval?(pending, plan)
    end

    test "rejected approvals are stale and not allowed" do
      plan = plan_fixture()
      session = session_fixture(plan)

      assert {:ok, _pending, session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan, now: base_time())

      assert {:ok, rejected} =
               ApprovalGate.reject_plan(session_with_pending, plan, :user,
                 now: DateTime.add(base_time(), 1, :second),
                 reason: "Need revisions"
               )

      assert rejected.status == :rejected
      assert {:error, :approval_rejected} = ApprovalGate.allowed?(session, rejected)
      assert ApprovalGate.stale_plan_approval?(rejected, plan)
    end

    test "missing approval is denied" do
      plan = plan_fixture()
      session = session_fixture(plan)

      assert {:error, :missing_plan_approval} = ApprovalGate.approve_plan(session, plan, :user)
      assert {:error, :missing_plan_approval} = ApprovalGate.allowed?(session, :plan)
    end

    test "future patch/shell/network scopes are denied by default" do
      plan = plan_fixture()
      session = session_fixture(plan)

      assert {:ok, _pending, session_with_pending} =
               ApprovalGate.request_plan_approval(session, plan, now: base_time())

      assert {:ok, approved} =
               ApprovalGate.approve_plan(session_with_pending, plan, :user,
                 now: DateTime.add(base_time(), 1, :second)
               )

      session_with_approved = %{session_with_pending | approvals: [approved]}

      assert {:error, {:scope_denied, :patch}} =
               ApprovalGate.allowed?(session_with_approved, :patch)

      assert {:error, {:scope_denied, :shell}} =
               ApprovalGate.allowed?(session_with_approved, :shell)

      assert {:error, {:scope_denied, :network}} =
               ApprovalGate.allowed?(session_with_approved, :network)
    end
  end

  defp base_time, do: ~U[2026-01-01 00:00:00Z]

  defp plan_fixture(attrs \\ []) do
    attrs = Enum.into(attrs, %{})

    Plan.new(%{
      id: Map.get(attrs, :id, "plan-1"),
      session_id: Map.get(attrs, :session_id, "sess-1"),
      version: Map.get(attrs, :version, 1),
      objective: Map.get(attrs, :objective, "Implement lane04 approval gate"),
      schema_version: "planning.v1",
      metadata: %{"workspace" => "/tmp/muse-lane04"},
      tasks: [%{title: "Task 1", description: "Implement the module"}],
      created_at: base_time(),
      updated_at: base_time()
    })
  end

  defp session_fixture(plan, attrs \\ []) do
    attrs = Enum.into(attrs, %{})

    session =
      Session.new(
        id: Map.get(attrs, :id, plan.session_id),
        workspace: Map.get(attrs, :workspace, plan.metadata["workspace"]),
        active_plan_id: Map.get(attrs, :active_plan_id, plan.id),
        created_at: base_time(),
        updated_at: base_time()
      )

    %{session | plans: %{plan.id => plan}}
  end
end
