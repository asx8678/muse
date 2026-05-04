defmodule Muse.PlanTest do
  use ExUnit.Case, async: true

  alias Muse.Plan
  alias Muse.Task

  describe "new/1" do
    test "creates a plan with required objective" do
      plan = Plan.new(objective: "Add a /version command.")

      assert %Plan{} = plan
      assert plan.objective == "Add a /version command."
      assert plan.status == :draft
      assert plan.version == 1
      assert plan.tasks == []
      assert plan.risks == []
      assert plan.metadata == %{}
    end

    test "accepts deterministic id and timestamps for testing" do
      ts = ~U[2025-01-01 00:00:00Z]

      plan =
        Plan.new(
          id: "plan_1",
          session_id: "sess_1",
          objective: "Test",
          created_at: ts,
          updated_at: ts
        )

      assert plan.id == "plan_1"
      assert plan.session_id == "sess_1"
      assert plan.created_at == ts
      assert plan.updated_at == ts
    end

    test "defaults timestamps to DateTime.utc_now when not overridden" do
      plan = Plan.new(objective: "Test")

      assert %DateTime{} = plan.created_at
      assert %DateTime{} = plan.updated_at
    end

    test "accepts custom initial status" do
      plan = Plan.new(objective: "Test", status: :awaiting_approval)
      assert plan.status == :awaiting_approval
    end

    test "falls back to :draft for invalid status" do
      plan = Plan.new(objective: "Test", status: :unknown)
      assert plan.status == :draft
    end

    test "accepts keyword list with all fields" do
      plan =
        Plan.new(
          id: "plan_1",
          session_id: "sess_1",
          version: 2,
          status: :approved,
          title: "Version command",
          objective: "Add /version",
          summary: "Implement command parsing",
          created_by: "planning",
          risks: ["Version source may differ in release"],
          alternatives: [%{approach: "Use git describe"}],
          validation: ["Run mix test"],
          inspected_files: ["lib/muse/commands.ex"],
          likely_changed_files: ["lib/muse/commands.ex"]
        )

      assert plan.version == 2
      assert plan.title == "Version command"
      assert plan.summary == "Implement command parsing"
      assert plan.risks == ["Version source may differ in release"]
      assert plan.alternatives == [%{approach: "Use git describe"}]
      assert plan.inspected_files == ["lib/muse/commands.ex"]
    end

    test "accepts string keys" do
      plan =
        Plan.new(%{
          "objective" => "Add /version",
          "summary" => "Short summary",
          "risks" => ["Risk 1"]
        })

      assert plan.objective == "Add /version"
      assert plan.summary == "Short summary"
      assert plan.risks == ["Risk 1"]
    end

    test "normalizes raw task maps to Muse.Task structs" do
      plan =
        Plan.new(
          objective: "Test",
          tasks: [
            %{"title" => "Task 1", "description" => "Desc 1"},
            %{title: "Task 2", description: "Desc 2"}
          ]
        )

      assert length(plan.tasks) == 2
      assert %Task{} = hd(plan.tasks)
      assert hd(plan.tasks).title == "Task 1"
    end

    test "preserves existing Muse.Task structs in tasks list" do
      task = Task.new(title: "Existing", description: "Already a struct")

      plan = Plan.new(objective: "Test", tasks: [task])

      assert length(plan.tasks) == 1
      assert hd(plan.tasks) == task
    end

    test "defaults all list fields to empty lists" do
      plan = Plan.new(objective: "Test")

      assert plan.tasks == []
      assert plan.steps == []
      assert plan.inspected_files == []
      assert plan.likely_changed_files == []
      assert plan.files_expected == []
      assert plan.commands_expected == []
      assert plan.risks == []
      assert plan.alternatives == []
      assert plan.validation == []
      assert plan.approvals == []
    end
  end

  describe "statuses/0" do
    test "returns the canonical list of plan statuses" do
      statuses = Plan.statuses()

      assert :draft in statuses
      assert :awaiting_approval in statuses
      assert :approved in statuses
      assert :rejected in statuses
      assert :superseded in statuses
      assert :in_progress in statuses
      assert :executing in statuses
      assert :completed in statuses
      assert :cancelled in statuses
      assert :needs_revision in statuses
    end

    test "all statuses are atoms" do
      for status <- Plan.statuses() do
        assert is_atom(status)
      end
    end

    test "has exactly 10 statuses" do
      assert length(Plan.statuses()) == 10
    end
  end

  describe "valid_status?/1" do
    test "returns true for canonical statuses" do
      for status <- Plan.statuses() do
        assert Plan.valid_status?(status)
      end
    end

    test "returns false for non-canonical values" do
      refute Plan.valid_status?(:unknown)
      refute Plan.valid_status?(nil)
      refute Plan.valid_status?("draft")
    end
  end

  describe "transition/3" do
    test "transitions to a valid status" do
      ts = ~U[2025-01-01 00:00:00Z]
      plan = Plan.new(id: "plan_1", objective: "Test", created_at: ts, updated_at: ts)

      assert {:ok, updated} = Plan.transition(plan, :awaiting_approval)
      assert updated.status == :awaiting_approval
    end

    test "updates updated_at on transition" do
      ts = ~U[2025-01-01 00:00:00Z]
      plan = Plan.new(id: "plan_1", objective: "Test", created_at: ts, updated_at: ts)

      {:ok, updated} = Plan.transition(plan, :approved, updated_at: ts)
      assert updated.updated_at == ts
    end

    test "sets approved_at when transitioning to :approved" do
      ts = ~U[2025-01-01 00:00:00Z]
      plan = Plan.new(id: "plan_1", objective: "Test", created_at: ts, updated_at: ts)

      {:ok, updated} = Plan.transition(plan, :approved, approved_at: ts)
      assert updated.approved_at == ts
    end

    test "sets rejected_at when transitioning to :rejected" do
      ts = ~U[2025-01-01 00:00:00Z]
      plan = Plan.new(id: "plan_1", objective: "Test", created_at: ts, updated_at: ts)

      {:ok, updated} = Plan.transition(plan, :rejected, rejected_at: ts)
      assert updated.rejected_at == ts
    end

    test "sets completed_at when transitioning to :completed" do
      ts = ~U[2025-01-01 00:00:00Z]
      plan = Plan.new(id: "plan_1", objective: "Test", created_at: ts, updated_at: ts)

      {:ok, updated} = Plan.transition(plan, :completed, completed_at: ts)
      assert updated.completed_at == ts
    end

    test "rejects invalid status" do
      plan = Plan.new(objective: "Test")

      assert {:error, {:invalid_status, :unknown}} = Plan.transition(plan, :unknown)
    end

    test "preserves other fields through transition" do
      plan =
        Plan.new(
          id: "plan_1",
          session_id: "sess_1",
          objective: "Add feature",
          risks: ["Risk 1"]
        )

      {:ok, updated} = Plan.transition(plan, :awaiting_approval)

      assert updated.id == "plan_1"
      assert updated.session_id == "sess_1"
      assert updated.objective == "Add feature"
      assert updated.risks == ["Risk 1"]
    end
  end

  describe "put_task/2" do
    test "appends a Muse.Task struct" do
      plan = Plan.new(objective: "Add feature")
      task = Task.new(title: "Implement", description: "Write code")

      updated = Plan.put_task(plan, task)

      assert length(updated.tasks) == 1
      assert hd(updated.tasks) == task
    end

    test "appends a raw map, converting to Muse.Task" do
      plan = Plan.new(objective: "Add feature")

      updated =
        Plan.put_task(plan, %{
          "title" => "Implement",
          "description" => "Write code"
        })

      assert length(updated.tasks) == 1
      assert %Task{} = hd(updated.tasks)
      assert hd(updated.tasks).title == "Implement"
    end

    test "appends multiple tasks preserving order" do
      plan = Plan.new(objective: "Add feature")
      task1 = Task.new(title: "First", description: "D1")
      task2 = Task.new(title: "Second", description: "D2")

      plan = Plan.put_task(plan, task1)
      plan = Plan.put_task(plan, task2)

      assert Enum.map(plan.tasks, & &1.title) == ["First", "Second"]
    end

    test "updates updated_at" do
      plan = Plan.new(objective: "Test")

      updated = Plan.put_task(plan, Task.new(title: "T", description: "D"))
      assert %DateTime{} = updated.updated_at
    end
  end

  describe "to_map/1" do
    test "converts struct to plain map" do
      plan =
        Plan.new(
          id: "plan_1",
          objective: "Add /version",
          tasks: [Task.new(title: "T1", description: "D1")]
        )

      map = Plan.to_map(plan)

      assert is_map(map)
      assert map[:objective] == "Add /version"
    end

    test "serializes tasks via Task.to_map/1" do
      plan =
        Plan.new(
          id: "plan_1",
          objective: "Test",
          tasks: [Task.new(title: "T1", description: "D1", requires_write?: true)]
        )

      map = Plan.to_map(plan)

      [task_map] = map[:tasks]
      assert task_map[:requires_write] == true
      refute Map.has_key?(task_map, :requires_write?)
    end

    test "drops nil values" do
      plan = Plan.new(id: "plan_1", objective: "Test")
      map = Plan.to_map(plan)

      assert map[:id] == "plan_1"
      assert map[:objective] == "Test"
      refute Map.has_key?(map, :title)
      refute Map.has_key?(map, :session_id)
    end
  end

  describe "from_map/1" do
    test "creates plan from plain map" do
      plan =
        Plan.from_map(%{
          "objective" => "Add /version",
          "tasks" => [%{"title" => "T1", "description" => "D1"}]
        })

      assert %Plan{} = plan
      assert plan.objective == "Add /version"
      assert length(plan.tasks) == 1
      assert %Task{} = hd(plan.tasks)
    end

    test "round-trips through to_map and from_map" do
      original =
        Plan.new(
          id: "plan_1",
          objective: "Test objective",
          summary: "Test summary",
          risks: ["Risk 1"],
          tasks: [Task.new(title: "T1", description: "D1", requires_write?: true)]
        )

      map = Plan.to_map(original)
      restored = Plan.from_map(map)

      assert restored.objective == original.objective
      assert restored.summary == original.summary
      assert restored.risks == original.risks
      assert length(restored.tasks) == 1
      assert hd(restored.tasks).title == "T1"
      assert hd(restored.tasks).requires_write? == true
    end
  end

  describe "render/1" do
    test "renders awaiting_approval plan with Planning Muse header" do
      plan =
        Plan.new(
          objective: "Add a /version command.",
          status: :awaiting_approval,
          tasks: [
            Task.new(title: "Add command definition", description: "Update commands.ex"),
            Task.new(title: "Add dispatch handler", description: "Update dispatcher"),
            Task.new(title: "Verify shared interface", description: "Run tests")
          ]
        )

      rendered = Plan.render(plan)

      assert rendered =~ "Planning Muse prepared a plan."
      assert rendered =~ "Objective:\nAdd a /version command."
      assert rendered =~ "Tasks:\n1. Add command definition"
      assert rendered =~ "2. Add dispatch handler"
      assert rendered =~ "3. Verify shared interface"
      assert rendered =~ "/approve plan"
      assert rendered =~ "/reject plan"
    end

    test "renders plan status in header when not awaiting_approval" do
      plan = Plan.new(objective: "Test", status: :approved)
      rendered = Plan.render(plan)

      assert rendered =~ "Muse Plan (approved)"
    end

    test "omits tasks section when tasks list is empty" do
      plan = Plan.new(objective: "Test")
      rendered = Plan.render(plan)

      refute rendered =~ "Tasks:"
    end

    test "omits risks section when risks list is empty" do
      plan = Plan.new(objective: "Test")
      rendered = Plan.render(plan)

      refute rendered =~ "Risks:"
    end

    test "renders risks as bullet list" do
      plan =
        Plan.new(
          objective: "Add /version",
          risks: [
            "Version source should work in dev and release.",
            "Command behavior should be consistent across interfaces."
          ]
        )

      rendered = Plan.render(plan)

      assert rendered =~ "Risks:"
      assert rendered =~ "- Version source should work in dev and release."
      assert rendered =~ "- Command behavior should be consistent across interfaces."
    end

    test "renders full plan matching docs testing example" do
      plan =
        Plan.new(
          objective: "Add a /version command to Muse.",
          status: :awaiting_approval,
          tasks: [
            Task.new(title: "Add command definition", description: "Add /version to Commands"),
            Task.new(title: "Add dispatch handler", description: "Add :version handling"),
            Task.new(
              title: "Verify shared interface behavior",
              description: "Ensure consistent behavior"
            )
          ],
          risks: [
            "Version source should work both in Mix/dev and release/escript contexts.",
            "Command behavior should remain consistent across CLI, TUI, and LiveView."
          ]
        )

      rendered = Plan.render(plan)

      # Match the expected output from docs/testing.md section 8.5
      assert rendered =~ "Planning Muse prepared a plan."
      assert rendered =~ "Objective:\nAdd a /version command to Muse."
      assert rendered =~ "1. Add command definition"
      assert rendered =~ "2. Add dispatch handler"
      assert rendered =~ "3. Verify shared interface behavior"
      assert rendered =~ "Approve this plan with: /approve plan"
      assert rendered =~ "Reject this plan with: /reject plan"
    end
  end
end
