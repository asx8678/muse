defmodule Muse.ApprovalPersistenceTest do
  use ExUnit.Case, async: false

  alias Muse.{Approval, ApprovalGate, Plan, SessionServer, SessionStore}

  defp unique_id(prefix), do: "#{prefix}-#{:erlang.unique_integer([:positive])}"

  defp awaiting_plan(session_id, opts) do
    objective = Keyword.get(opts, :objective, "Test plan")
    plan = Plan.new(id: "plan-#{session_id}", session_id: session_id, objective: objective)
    {:ok, plan} = Plan.transition(plan, :awaiting_approval)
    plan
  end

  defp persist_plan_snapshot(session_id, plan, session_status \\ "awaiting_plan_approval") do
    :ok =
      SessionStore.save_session(session_id, %{
        "status" => session_status,
        "active_plan_id" => plan.id,
        "plan" => Plan.to_map(plan),
        "plans" => %{plan.id => Plan.to_map(plan)}
      })

    :ok
  end

  defp start_server(session_id) do
    {:ok, pid} = SessionServer.start_link(session_id: session_id)
    pid
  end

  defp cleanup_session(session_id) do
    dir = Path.join(".muse/sessions", session_id)
    if File.exists?(dir), do: File.rm_rf!(dir)
  end

  # -- Approval struct ---------------------------------------------------------

  describe "Muse.Approval struct" do
    test "new/1 creates an approval with required fields" do
      approval = Approval.new(plan_id: "p1", kind: :plan, status: :approved, source: :cli)
      assert approval.plan_id == "p1"
      assert approval.kind == :plan
      assert approval.status == :approved
      assert approval.source == :cli
      assert %DateTime{} = approval.created_at
      assert String.starts_with?(approval.id, "appr_")
    end

    test "new/1 auto-generates id and created_at" do
      a1 = Approval.new(plan_id: "p1", kind: :plan, status: :approved, source: :cli)
      a2 = Approval.new(plan_id: "p1", kind: :plan, status: :approved, source: :cli)
      assert a1.id != a2.id
    end

    test "new/1 normalizes string kind/status/source safely" do
      approval = Approval.new(plan_id: "p1", kind: "plan", status: "approved", source: "cli")
      assert approval.kind == :plan
      assert approval.status == :approved
      assert approval.source == :cli
    end

    test "new/1 defaults unknown kind to :plan" do
      assert Approval.new(plan_id: "p1", kind: "unknown", status: :approved, source: :cli).kind ==
               :plan
    end

    test "new/1 defaults unknown status to :approved" do
      assert Approval.new(plan_id: "p1", kind: :plan, status: "unknown", source: :cli).status ==
               :approved
    end

    test "new/1 defaults unknown source to :system" do
      assert Approval.new(plan_id: "p1", kind: :plan, status: :approved, source: "no_such_atom").source ==
               :system
    end

    test "valid_kind?/1 and valid_status?/1" do
      assert Approval.valid_kind?(:plan)
      assert Approval.valid_kind?(:shell)
      assert Approval.valid_kind?(:patch)
      refute Approval.valid_kind?(:unknown)
      assert Approval.valid_status?(:approved)
      assert Approval.valid_status?(:rejected)
      refute Approval.valid_status?(:pending)
    end
  end

  # -- JSON round-trip ---------------------------------------------------------

  describe "Muse.Approval JSON round-trip" do
    test "to_map/from_map preserves all fields" do
      now = ~U[2025-06-15 12:00:00Z]

      approval =
        Approval.new(
          id: "appr_test",
          plan_id: "plan_1",
          kind: :plan,
          status: :approved,
          source: :cli,
          reason: "Looks good",
          metadata: %{"fingerprint" => "abc123"},
          created_at: now
        )

      map = Approval.to_map(approval)
      assert map["id"] == "appr_test"
      assert map["kind"] == "plan"
      assert map["status"] == "approved"
      assert map["created_at"] == "2025-06-15T12:00:00Z"

      restored = Approval.from_map(map)
      assert restored.id == "appr_test"
      assert restored.kind == :plan
      assert restored.status == :approved
      assert restored.reason == "Looks good"
      assert restored.metadata == %{"fingerprint" => "abc123"}
      assert restored.created_at == now
    end

    test "to_map drops nil values for compact JSON" do
      map =
        Approval.to_map(
          Approval.new(id: "x", plan_id: "p1", kind: :plan, status: :approved, source: :system)
        )

      refute Map.has_key?(map, "reason")
      refute Map.has_key?(map, "metadata")
    end

    test "from_map parses ISO 8601 created_at to DateTime" do
      approval =
        Approval.from_map(%{
          "plan_id" => "p1",
          "kind" => "plan",
          "status" => "approved",
          "source" => "cli",
          "created_at" => "2025-06-15T12:00:00Z"
        })

      assert %DateTime{} = approval.created_at
      assert approval.created_at == ~U[2025-06-15 12:00:00Z]
    end

    test "from_map with invalid created_at falls back to current time" do
      approval =
        Approval.from_map(%{
          "plan_id" => "p1",
          "kind" => "plan",
          "status" => "approved",
          "source" => "cli",
          "created_at" => "not-a-date"
        })

      assert %DateTime{} = approval.created_at
      assert DateTime.diff(DateTime.utc_now(), approval.created_at, :second) < 5
    end
  end

  # -- No dynamic atoms -------------------------------------------------------

  describe "no dynamic atoms from persisted values" do
    test "from_map never creates atoms from arbitrary strings" do
      approval =
        Approval.from_map(%{
          "plan_id" => "p1",
          "kind" => "totally_malicious_kind",
          "status" => "super_invalid",
          "source" => "nonexistent_atom",
          "created_at" => "2025-06-15T12:00:00Z"
        })

      assert approval.kind == :plan
      assert approval.status == :approved
      assert approval.source == :system
    end

    test "from_map with kind=shell works (known atom)" do
      assert Approval.from_map(%{
               "plan_id" => "p1",
               "kind" => "shell",
               "status" => "rejected",
               "source" => "cli"
             }).kind == :shell
    end
  end

  # -- Redaction of sensitive metadata ----------------------------------------

  describe "redaction of approval reasons/metadata containing secrets" do
    test "to_map preserves reason and metadata as-is" do
      approval =
        Approval.new(
          plan_id: "p1",
          kind: :plan,
          status: :approved,
          source: :cli,
          reason: "Approved because sk-test-key-12345 is valid",
          metadata: %{"api_key" => "sk-proj-abc123def456"}
        )

      map = Approval.to_map(approval)
      assert map["reason"] == "Approved because sk-test-key-12345 is valid"
      assert map["metadata"]["api_key"] == "sk-proj-abc123def456"
    end

    test "SessionStore scrubs sensitive keys within nested approval data" do
      session_id = unique_id("redact-test")
      plan = awaiting_plan(session_id, objective: "Redaction test")

      approval =
        Approval.new(
          id: "appr_redact",
          plan_id: plan.id,
          kind: :plan,
          status: :approved,
          source: :cli,
          reason: "Contains sk-test-secret-key-12345 in reason",
          metadata: %{"token" => "sk-proj-abc123def456ghi789"}
        )

      data = %{
        "status" => "idle",
        "active_plan_id" => plan.id,
        "plan" => Plan.to_map(plan),
        "plans" => %{plan.id => Plan.to_map(plan)},
        "approvals" => [Approval.to_map(approval)],
        "approval_binding" => nil
      }

      :ok = SessionStore.save_session(session_id, data)
      {:ok, loaded} = SessionStore.load_session(session_id)
      loaded_json = Jason.encode!(loaded)
      # "token" key is sensitive → value redacted
      refute loaded_json =~ "sk-proj-abc123def456ghi789"
      # "reason" key is not sensitive → value preserved
      assert loaded_json =~ "sk-test-secret-key-12345"
      cleanup_session(session_id)
    end
  end

  # -- Save/load snapshots ----------------------------------------------------

  describe "save/load snapshots with approvals" do
    test "approvals survive save/load cycle" do
      session_id = unique_id("approval-snapshot")
      plan = awaiting_plan(session_id, objective: "Snapshot test")
      now = ~U[2025-06-15 12:00:00Z]

      approval =
        Approval.new(
          id: "appr_snap",
          plan_id: plan.id,
          kind: :plan,
          status: :approved,
          source: :cli,
          reason: "Looks good",
          created_at: now
        )

      data = %{
        "status" => "idle",
        "active_plan_id" => plan.id,
        "plan" => Plan.to_map(plan),
        "plans" => %{plan.id => Plan.to_map(plan)},
        "approvals" => [Approval.to_map(approval)]
      }

      :ok = SessionStore.save_session(session_id, data)
      {:ok, loaded} = SessionStore.load_session(session_id)
      [la] = loaded["approvals"]
      assert la["id"] == "appr_snap"
      assert la["plan_id"] == plan.id
      assert la["kind"] == "plan"
      assert la["status"] == "approved"
      cleanup_session(session_id)
    end

    test "approval_binding survives save/load cycle" do
      session_id = unique_id("binding-snapshot")
      plan = awaiting_plan(session_id, objective: "Binding test")
      bound_at = ~U[2025-06-15 12:00:00Z]

      binding =
        ApprovalGate.capture_binding(plan, session_id: session_id, workspace: nil, now: bound_at)

      data = %{
        "status" => "awaiting_plan_approval",
        "active_plan_id" => plan.id,
        "plan" => Plan.to_map(plan),
        "plans" => %{plan.id => Plan.to_map(plan)},
        "approval_binding" => %{
          "kind" => binding.kind,
          "session_id" => binding.session_id,
          "plan_id" => binding.plan_id,
          "plan_version" => binding.plan_version,
          "plan_hash" => binding.plan_hash,
          "workspace" => binding.workspace,
          "bound_at" => DateTime.to_iso8601(binding.bound_at)
        }
      }

      :ok = SessionStore.save_session(session_id, data)
      {:ok, loaded} = SessionStore.load_session(session_id)
      assert loaded["approval_binding"]["plan_hash"] == binding.plan_hash
      assert loaded["approval_binding"]["plan_id"] == plan.id
      cleanup_session(session_id)
    end
  end

  # -- Corrupt/legacy snapshots -----------------------------------------------

  describe "corrupt/legacy snapshots without approvals" do
    test "snapshot without approvals key restores to empty list" do
      session_id = unique_id("legacy-no-approvals")
      plan = awaiting_plan(session_id, objective: "Legacy test")

      :ok =
        SessionStore.save_session(session_id, %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => plan.id,
          "plan" => Plan.to_map(plan),
          "plans" => %{plan.id => Plan.to_map(plan)}
        })

      pid = start_server(session_id)
      status = SessionServer.status(pid)
      assert status.plan != nil
      assert status.approvals == []
      assert status.approval_binding != nil
      GenServer.stop(pid)
      cleanup_session(session_id)
    end

    test "snapshot with corrupt approval entry skips bad entry, keeps good ones" do
      session_id = unique_id("corrupt-approval")
      plan = awaiting_plan(session_id, objective: "Corrupt test")
      now = ~U[2025-06-15 12:00:00Z]

      good =
        Approval.new(
          id: "appr_good",
          plan_id: plan.id,
          kind: :plan,
          status: :approved,
          source: :cli,
          created_at: now
        )

      :ok =
        SessionStore.save_session(session_id, %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => plan.id,
          "plan" => Plan.to_map(plan),
          "plans" => %{plan.id => Plan.to_map(plan)},
          "approvals" => [Approval.to_map(good), %{"invalid" => "data"}]
        })

      pid = start_server(session_id)
      status = SessionServer.status(pid)
      assert length(status.approvals) >= 1
      assert Enum.any?(status.approvals, &(&1.id == "appr_good"))
      GenServer.stop(pid)
      cleanup_session(session_id)
    end

    test "snapshot with invalid approval_binding falls back to re-capture" do
      session_id = unique_id("invalid-binding")
      plan = awaiting_plan(session_id, objective: "Invalid binding test")

      :ok =
        SessionStore.save_session(session_id, %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => plan.id,
          "plan" => Plan.to_map(plan),
          "plans" => %{plan.id => Plan.to_map(plan)},
          "approval_binding" => "not_a_map"
        })

      pid = start_server(session_id)
      status = SessionServer.status(pid)
      assert status.approval_binding != nil
      assert status.approval_binding.plan_id == plan.id
      GenServer.stop(pid)
      cleanup_session(session_id)
    end

    test "empty snapshot (no plan) starts with nil approval_binding and empty approvals" do
      session_id = unique_id("empty-snapshot")
      pid = start_server(session_id)
      status = SessionServer.status(pid)
      assert status.approvals == []
      assert status.approval_binding == nil
      assert status.plan == nil
      GenServer.stop(pid)
      cleanup_session(session_id)
    end
  end

  # -- Restart restore --------------------------------------------------------

  describe "restart restore of approval state" do
    test "approved plan restart restores approval record" do
      session_id = unique_id("restart-approve")
      plan = awaiting_plan(session_id, objective: "Restart approve test")
      :ok = persist_plan_snapshot(session_id, plan)
      pid = start_server(session_id)
      assert {:ok, _} = SessionServer.approve_plan(pid, :cli)
      status = SessionServer.status(pid)
      assert status.status == :idle
      assert length(status.approvals) == 1
      assert hd(status.approvals).status == :approved
      assert hd(status.approvals).source == :cli
      GenServer.stop(pid)
      pid2 = start_server(session_id)
      restored = SessionServer.status(pid2)
      assert restored.status == :idle
      assert length(restored.approvals) == 1
      assert hd(restored.approvals).status == :approved
      GenServer.stop(pid2)
      cleanup_session(session_id)
    end

    test "rejected plan restart restores approval record" do
      session_id = unique_id("restart-reject")
      plan = awaiting_plan(session_id, objective: "Restart reject test")
      :ok = persist_plan_snapshot(session_id, plan)
      pid = start_server(session_id)
      assert {:ok, _} = SessionServer.reject_plan(pid, :web)
      GenServer.stop(pid)
      pid2 = start_server(session_id)
      restored = SessionServer.status(pid2)
      assert restored.status == :idle
      assert length(restored.approvals) == 1
      assert hd(restored.approvals).status == :rejected
      assert hd(restored.approvals).source == :web
      GenServer.stop(pid2)
      cleanup_session(session_id)
    end

    test "awaiting_approval plan restart restores binding" do
      session_id = unique_id("restart-awaiting")
      plan = awaiting_plan(session_id, objective: "Restart binding test")
      :ok = persist_plan_snapshot(session_id, plan)
      pid = start_server(session_id)
      status = SessionServer.status(pid)
      assert status.status == :awaiting_plan_approval
      assert status.approval_binding != nil
      assert status.approval_binding.plan_id == plan.id
      GenServer.stop(pid)
      pid2 = start_server(session_id)
      restored = SessionServer.status(pid2)
      assert restored.status == :awaiting_plan_approval
      assert restored.approval_binding != nil
      GenServer.stop(pid2)
      cleanup_session(session_id)
    end
  end

  # -- Plan approvals field ---------------------------------------------------

  describe "Plan approvals field" do
    test "Plan.to_map converts Approval structs to maps" do
      plan = Plan.new(id: "p1", session_id: "s1", objective: "Test")
      {:ok, plan} = Plan.transition(plan, :awaiting_approval)
      {:ok, plan} = Plan.transition(plan, :approved)
      approval = Approval.new(plan_id: plan.id, kind: :plan, status: :approved, source: :cli)
      plan = %{plan | approvals: [approval]}
      map = Plan.to_map(plan)
      assert is_list(map[:approvals])
      assert length(map[:approvals]) == 1
      assert hd(map[:approvals])["id"] == approval.id
      refute Map.has_key?(hd(map[:approvals]), "__struct__")
    end

    test "Plan.from_map restores approvals as Approval structs" do
      plan = Plan.new(id: "p1", session_id: "s1", objective: "Test")
      {:ok, plan} = Plan.transition(plan, :awaiting_approval)

      approval =
        Approval.new(
          id: "appr_restore",
          plan_id: plan.id,
          kind: :plan,
          status: :approved,
          source: :cli,
          created_at: ~U[2025-06-15 12:00:00Z]
        )

      plan = %{plan | approvals: [approval]}
      restored = Plan.from_map(Plan.to_map(plan))
      assert length(restored.approvals) == 1
      assert %Muse.Approval{} = hd(restored.approvals)
      assert hd(restored.approvals).id == "appr_restore"
    end

    test "Plan round-trip through JSON is safe" do
      plan = Plan.new(id: "p1", session_id: "s1", objective: "JSON Test")
      {:ok, plan} = Plan.transition(plan, :awaiting_approval)
      {:ok, plan} = Plan.transition(plan, :approved)

      approval =
        Approval.new(
          id: "appr_json",
          plan_id: plan.id,
          kind: :plan,
          status: :approved,
          source: :cli,
          reason: "JSON safe",
          created_at: ~U[2025-06-15 12:00:00Z]
        )

      plan = %{plan | approvals: [approval]}
      {:ok, json} = Jason.encode(Plan.to_map(plan))
      {:ok, decoded} = Jason.decode(json)
      restored = Plan.from_map(decoded)
      assert length(restored.approvals) == 1
      assert hd(restored.approvals).id == "appr_json"
      assert hd(restored.approvals).status == :approved
      assert hd(restored.approvals).reason == "JSON safe"
    end
  end
end
