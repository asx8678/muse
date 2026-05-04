defmodule Muse.ApprovalGateTest do
  use ExUnit.Case, async: true

  alias Muse.{ApprovalGate, Plan, PlanBinding}

  # -- Helpers ------------------------------------------------------------------

  @fixed_time ~U[2025-06-01 12:00:00Z]

  defp make_plan(opts \\ []) do
    tasks =
      Keyword.get(opts, :tasks, [
        Muse.Task.new(id: "task_a", title: "Task A", description: "Do A"),
        Muse.Task.new(id: "task_b", title: "Task B", description: "Do B")
      ])

    Plan.new(
      id: Keyword.get(opts, :id, "plan_test"),
      session_id: Keyword.get(opts, :session_id, "session_test"),
      objective: Keyword.get(opts, :objective, "Test objective"),
      version: Keyword.get(opts, :version, 1),
      created_at: @fixed_time,
      updated_at: @fixed_time,
      tasks: tasks
    )
  end

  defp make_awaiting_plan(opts \\ []) do
    plan = make_plan(opts)
    {:ok, plan} = Plan.transition(plan, :awaiting_approval, updated_at: @fixed_time)
    plan
  end

  # Helper: validate with a fixed :now so tests don't fail on wall-clock drift
  defp validate_approval(plan, binding, opts) do
    ApprovalGate.validate_approval(plan, binding, Keyword.put_new(opts, :now, @fixed_time))
  end

  defp validate_rejection(plan, binding, opts) do
    ApprovalGate.validate_rejection(plan, binding, Keyword.put_new(opts, :now, @fixed_time))
  end

  # -- capture_binding ----------------------------------------------------------

  describe "capture_binding/2" do
    test "captures a binding with plan_hash, session_id, and bound_at" do
      plan = make_plan()
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert binding.kind == "plan_approval"
      assert binding.session_id == "session_test"
      assert binding.plan_id == "plan_test"
      assert binding.plan_version == 1
      assert binding.plan_hash == PlanBinding.content_hash(plan)
      assert binding.bound_at == @fixed_time
      assert binding.workspace == nil
    end

    test "captures workspace when provided" do
      plan = make_plan()
      binding = ApprovalGate.capture_binding(plan, workspace: "/tmp/project", now: @fixed_time)

      assert binding.workspace == "/tmp/project"
    end
  end

  # -- Case 1: version change --------------------------------------------------

  describe "stale prevention: version change" do
    test "approval fails when plan version has changed" do
      plan_v1 = make_awaiting_plan(version: 1)
      binding = ApprovalGate.capture_binding(plan_v1, now: @fixed_time)

      # Plan gets a new version
      plan_v2 = %{plan_v1 | version: 2}

      assert {:error, {:stale_content, _}} =
               validate_approval(plan_v2, binding, session_id: "session_test")
    end

    test "rejection fails when plan version has changed" do
      plan_v1 = make_awaiting_plan(version: 1)
      binding = ApprovalGate.capture_binding(plan_v1, now: @fixed_time)

      plan_v2 = %{plan_v1 | version: 2}

      assert {:error, {:stale_content, _}} =
               validate_rejection(plan_v2, binding, session_id: "session_test")
    end
  end

  # -- Case 2: content change with same id/version ------------------------------

  describe "stale prevention: content change with same id/version" do
    test "approval fails when objective changes under same id and version" do
      plan = make_awaiting_plan(id: "p1", version: 1, objective: "Original objective")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      # Content changed but id and version are the same
      modified = %{plan | objective: "Modified objective"}

      assert {:error, {:stale_content, details}} =
               validate_approval(modified, binding, session_id: "session_test")

      assert details.plan_id == "p1"
      assert details.expected != details.actual
    end

    test "approval fails when task title changes under same id and version" do
      plan = make_awaiting_plan(id: "p1", version: 1)
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      modified_task = %{hd(plan.tasks) | title: "Changed Task"}
      modified = %{plan | tasks: [modified_task | tl(plan.tasks)]}

      assert {:error, {:stale_content, _}} =
               validate_approval(modified, binding, session_id: "session_test")
    end

    test "approval succeeds when content is unchanged" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert :ok = validate_approval(plan, binding, session_id: "session_test")
    end
  end

  # -- Case 3: wrong session id -------------------------------------------------

  describe "stale prevention: wrong session id" do
    test "approval fails when session id does not match" do
      plan = make_awaiting_plan(session_id: "session_A")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert {:error, {:wrong_session, %{expected: "session_A", actual: "session_B"}}} =
               validate_approval(plan, binding, session_id: "session_B")
    end

    test "approval succeeds when session id matches" do
      plan = make_awaiting_plan(session_id: "session_A")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert :ok = validate_approval(plan, binding, session_id: "session_A")
    end

    test "approval succeeds when binding session is nil (no session constraint)" do
      plan = make_awaiting_plan(session_id: nil)
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert :ok = validate_approval(plan, binding, session_id: "any_session")
    end
  end

  # -- Case 4: wrong workspace -------------------------------------------------

  describe "stale prevention: wrong workspace" do
    test "approval fails when workspace does not match the binding" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, workspace: "/workspace/A", now: @fixed_time)

      assert {:error, {:wrong_workspace, %{expected: "/workspace/A", actual: "/workspace/B"}}} =
               validate_approval(plan, binding,
                 session_id: "session_test",
                 workspace: "/workspace/B"
               )
    end

    test "approval succeeds when workspace matches the binding" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, workspace: "/workspace/A", now: @fixed_time)

      assert :ok =
               validate_approval(plan, binding,
                 session_id: "session_test",
                 workspace: "/workspace/A"
               )
    end

    test "approval succeeds when binding workspace is nil (no workspace constraint)" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert :ok =
               validate_approval(plan, binding,
                 session_id: "session_test",
                 workspace: "/any/workspace"
               )
    end

    test "rejection does not check workspace" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, workspace: "/workspace/A", now: @fixed_time)

      # Rejection from a different workspace is allowed
      assert :ok =
               validate_rejection(plan, binding,
                 session_id: "session_test",
                 workspace: "/workspace/B"
               )
    end
  end

  # -- Case 5: expired binding --------------------------------------------------

  describe "stale prevention: expired binding" do
    test "approval fails when binding has expired" do
      plan = make_awaiting_plan()
      # Bound 2 days ago
      bound_at = ~U[2025-06-01 00:00:00Z]
      binding = ApprovalGate.capture_binding(plan, now: bound_at)

      # Current time is 2 days later (beyond default 24h expiry)
      now = ~U[2025-06-03 00:00:00Z]

      assert {:error, {:expired, details}} =
               ApprovalGate.validate_approval(plan, binding,
                 session_id: "session_test",
                 now: now,
                 expiry_seconds: 86_400
               )

      assert details.bound_at == bound_at
      assert details.now == now
      assert details.expiry_seconds == 86_400
    end

    test "approval succeeds when binding has not expired" do
      plan = make_awaiting_plan()
      bound_at = ~U[2025-06-01 00:00:00Z]
      binding = ApprovalGate.capture_binding(plan, now: bound_at)

      # Current time is 1 hour later (within 24h expiry)
      now = ~U[2025-06-01 01:00:00Z]

      assert :ok =
               ApprovalGate.validate_approval(plan, binding,
                 session_id: "session_test",
                 now: now,
                 expiry_seconds: 86_400
               )
    end

    test "custom expiry_seconds can be set to 0 for immediate expiry" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      # Even 1 second after binding with 0-second expiry
      now = DateTime.add(@fixed_time, 1, :second)

      assert {:error, {:expired, _}} =
               ApprovalGate.validate_approval(plan, binding,
                 session_id: "session_test",
                 now: now,
                 expiry_seconds: 0
               )
    end
  end

  # -- Case 6: no approval binding ----------------------------------------------

  describe "stale prevention: no approval binding" do
    test "approval fails with :no_approval_binding when no binding was captured" do
      plan = make_awaiting_plan()

      assert {:error, :no_approval_binding} =
               ApprovalGate.validate_approval(plan, nil, session_id: "session_test")
    end

    test "rejection fails with :no_approval_binding when no binding was captured" do
      plan = make_awaiting_plan()

      assert {:error, :no_approval_binding} =
               ApprovalGate.validate_rejection(plan, nil, session_id: "session_test")
    end
  end

  # -- Case 7: idempotent approval ----------------------------------------------

  describe "check_idempotent_approval/2" do
    test "returns {:ok, :idempotent} when plan content matches binding" do
      plan = make_awaiting_plan()
      {:ok, approved} = Plan.transition(plan, :approved, updated_at: @fixed_time)
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert {:ok, :idempotent} = ApprovalGate.check_idempotent_approval(approved, binding)
    end

    test "returns {:error, :stale_approval} when plan content differs from binding" do
      plan = make_awaiting_plan(objective: "Original")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      # Different plan was approved
      {:ok, other_plan} =
        Plan.transition(make_plan(objective: "Different"), :approved, updated_at: @fixed_time)

      assert {:error, :stale_approval} =
               ApprovalGate.check_idempotent_approval(other_plan, binding)
    end

    test "idempotent check is based on content hash, not just id or version" do
      plan = make_awaiting_plan(id: "p1", version: 1, objective: "Original")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      # Same id, same version, different content
      {:ok, modified} =
        Plan.transition(
          make_plan(id: "p1", version: 1, objective: "Changed"),
          :approved,
          updated_at: @fixed_time
        )

      assert {:error, :stale_approval} =
               ApprovalGate.check_idempotent_approval(modified, binding)
    end
  end

  # -- Rejected plan cannot later approve ----------------------------------------

  describe "rejected/expired approval cannot later approve" do
    test "modified rejected plan fails content check" do
      plan = make_awaiting_plan(objective: "V1 objective")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      # Plan content was modified after the original binding was captured
      {:ok, rejected} = Plan.transition(plan, :rejected, updated_at: @fixed_time)
      modified = %{rejected | objective: "V2 objective"}

      assert {:error, {:stale_content, _}} =
               validate_approval(modified, binding, session_id: "session_test")
    end

    test "expired binding prevents approval even on an otherwise-valid plan" do
      plan = make_awaiting_plan()
      binding = ApprovalGate.capture_binding(plan, now: ~U[2025-01-01 00:00:00Z])

      assert {:error, {:expired, _}} =
               ApprovalGate.validate_approval(plan, binding,
                 session_id: "session_test",
                 now: ~U[2025-02-01 00:00:00Z]
               )
    end
  end

  # -- Deterministic fingerprinting ---------------------------------------------

  describe "content fingerprint determinism" do
    test "identical plans produce identical content hashes" do
      plan_a = make_plan(id: "p1", session_id: "s1", objective: "Same")
      plan_b = make_plan(id: "p1", session_id: "s1", objective: "Same")

      assert PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end

    test "different objectives produce different content hashes" do
      plan_a = make_plan(id: "p1", session_id: "s1", objective: "Objective A")
      plan_b = make_plan(id: "p1", session_id: "s1", objective: "Objective B")

      refute PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end

    test "different tasks produce different content hashes" do
      plan_a = make_plan(tasks: [Muse.Task.new(id: "t1", title: "X", description: "D")])
      plan_b = make_plan(tasks: [Muse.Task.new(id: "t1", title: "Y", description: "D")])

      refute PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end

    test "volatile fields do not affect content hash" do
      plan_a = make_plan()
      {:ok, plan_b} = Plan.transition(plan_a, :awaiting_approval, updated_at: @fixed_time)

      # Status change should not affect the content hash
      assert PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end
  end

  # -- Multiple validation checks compose ---------------------------------------

  describe "combined validation checks" do
    test "stale content is checked before session/workspace" do
      plan = make_awaiting_plan(session_id: "A", objective: "Original")
      binding = ApprovalGate.capture_binding(plan, workspace: "/ws", now: @fixed_time)

      # Content is stale AND session is wrong
      modified = %{plan | objective: "Changed"}

      # Stale content should be the first error
      assert {:error, {:stale_content, _}} =
               validate_approval(modified, binding,
                 session_id: "B",
                 workspace: "/other"
               )
    end

    test "session check fires when content matches but session differs" do
      plan = make_awaiting_plan(session_id: "A")
      binding = ApprovalGate.capture_binding(plan, now: @fixed_time)

      assert {:error, {:wrong_session, _}} =
               validate_approval(plan, binding, session_id: "B")
    end
  end
end
