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
      assert plan.schema_version == Plan.default_schema_version()
      assert plan.tasks == []
      assert plan.assumptions == []
      assert plan.required_permissions == []
      assert plan.agent_assignments == []
      assert plan.phases == []
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

    test "accepts string status values, normalizing to atoms" do
      plan = Plan.new(objective: "Test", status: "awaiting_approval")
      assert plan.status == :awaiting_approval

      plan2 = Plan.new(objective: "Test", status: "draft")
      assert plan2.status == :draft

      plan3 = Plan.new(objective: "Test", status: "approved")
      assert plan3.status == :approved

      plan4 = Plan.new(objective: "Test", status: "rejected")
      assert plan4.status == :rejected

      plan5 = Plan.new(objective: "Test", status: "completed")
      assert plan5.status == :completed
    end

    test "falls back to :draft for unknown string status" do
      plan = Plan.new(objective: "Test", status: "nonexistent_status_value")
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

    test "unknown string keys from JSON are ignored without creating atoms" do
      before_atoms = :erlang.system_info(:atom_count)

      plan =
        Plan.new(%{
          "objective" => "Safe plan",
          "unknown_plan_key_99999" => "should be ignored",
          "another_bogus_key" => "also ignored"
        })

      after_atoms = :erlang.system_info(:atom_count)

      assert %Plan{} = plan
      assert plan.objective == "Safe plan"

      # Unknown keys should not increase the atom count significantly
      assert after_atoms - before_atoms < 3,
             "Unknown JSON keys should not create atoms: #{after_atoms - before_atoms} new atoms"
    end

    test "accepts versioned structured plan fields and filters metadata" do
      plan =
        Plan.new(%{
          "objective" => "Coordinate structured work",
          "schema_version" => "planning.v1",
          "assumptions" => ["Repository is clean"],
          "required_permissions" => ["read", "write"],
          "agent_assignments" => [
            %{"agent" => "coding", "task_ids" => ["task_1"], "api_token" => "secret"}
          ],
          "phases" => [%{"id" => "phase_1", "title" => "Implementation"}],
          "metadata" => %{"api_key" => "secret", :source => :planning}
        })

      assert plan.schema_version == "planning.v1"
      assert plan.assumptions == ["Repository is clean"]
      assert plan.required_permissions == ["read", "write"]
      assert [%{"api_token" => "**REDACTED**"}] = plan.agent_assignments
      assert [%{"id" => "phase_1", "title" => "Implementation"}] = plan.phases
      assert plan.metadata["api_key"] == "**REDACTED**"
      assert plan.metadata[:source] == "planning"
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
      assert plan.assumptions == []
      assert plan.required_permissions == []
      assert plan.agent_assignments == []
      assert plan.phases == []
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
      assert map[:schema_version] == Plan.default_schema_version()
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
      assert plan.schema_version == Plan.default_schema_version()
      assert plan.assumptions == []
      assert plan.required_permissions == []
      assert plan.agent_assignments == []
      assert plan.phases == []
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

    test "round-trips through JSON with structured plan fields" do
      original =
        Plan.new(
          id: "plan_structured_1",
          objective: "Structured objective",
          status: :awaiting_approval,
          created_at: nil,
          updated_at: nil,
          assumptions: ["Tests describe the public API"],
          required_permissions: ["read", "write"],
          agent_assignments: [%{"agent" => "coding", "task_ids" => ["task_1"]}],
          phases: [%{"id" => "phase_1", "title" => "Implementation"}],
          metadata: %{"api_key" => "secret", "safe" => true},
          tasks: [
            Task.new(
              id: "task_1",
              title: "T1",
              description: "D1",
              phase: "phase_1",
              required_permissions: ["write"]
            )
          ]
        )

      decoded =
        original
        |> Plan.to_map()
        |> Jason.encode!()
        |> Jason.decode!()

      restored = Plan.from_map(decoded)

      assert restored.id == "plan_structured_1"
      assert restored.schema_version == "planning.v1"
      assert restored.status == :awaiting_approval
      assert restored.assumptions == ["Tests describe the public API"]
      assert restored.required_permissions == ["read", "write"]
      assert restored.agent_assignments == [%{"agent" => "coding", "task_ids" => ["task_1"]}]
      assert restored.phases == [%{"id" => "phase_1", "title" => "Implementation"}]
      assert restored.metadata["api_key"] == "**REDACTED**"
      assert restored.metadata["safe"] == true
      assert [task] = restored.tasks
      assert task.phase == "phase_1"
      assert task.required_permissions == ["write"]
    end

    test "does not create atoms from unknown JSON keys or statuses" do
      before_atoms = :erlang.system_info(:atom_count)

      plan =
        Plan.from_map(%{
          "objective" => "Safe legacy payload",
          "status" => "unknown_status_value_12345",
          "unknown_plan_key_12345" => "ignored",
          "tasks" => [],
          "metadata" => %{"unknown_metadata_key_12345" => "kept as a string key"}
        })

      after_atoms = :erlang.system_info(:atom_count)

      assert plan.status == :draft
      assert plan.metadata["unknown_metadata_key_12345"] == "kept as a string key"

      assert after_atoms - before_atoms < 3,
             "Unknown JSON keys/statuses should not create atoms: #{after_atoms - before_atoms} new atoms"
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

    test "awaiting_approval footer shows approve/reject guidance" do
      plan = Plan.new(objective: "Test", status: :awaiting_approval)
      rendered = Plan.render(plan)

      assert rendered =~ "/approve plan"
      assert rendered =~ "/reject plan"
    end

    test "approved footer shows ready for implementation" do
      plan = Plan.new(objective: "Test", status: :approved)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      refute rendered =~ "/reject plan"
      assert rendered =~ "approved and is ready for implementation"
    end

    test "rejected footer shows rejection message" do
      plan = Plan.new(objective: "Test", status: :rejected)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      refute rendered =~ "/reject plan"
      assert rendered =~ "was rejected"
      assert rendered =~ "Ask Planning Muse for a revised plan"
    end

    test "completed footer shows completed message" do
      plan = Plan.new(objective: "Test", status: :completed)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      refute rendered =~ "/reject plan"
      assert rendered =~ "has been completed"
    end

    test "cancelled footer shows cancelled message" do
      plan = Plan.new(objective: "Test", status: :cancelled)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      assert rendered =~ "has been cancelled"
    end

    test "superseded footer shows superseded message" do
      plan = Plan.new(objective: "Test", status: :superseded)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      assert rendered =~ "has been superseded"
    end

    test "draft footer shows draft guidance without approval instructions" do
      plan = Plan.new(objective: "Test", status: :draft)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      refute rendered =~ "/reject plan"
      assert rendered =~ "draft"
    end

    test "needs_revision footer shows revision guidance without approval instructions" do
      plan = Plan.new(objective: "Test", status: :needs_revision)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      refute rendered =~ "/reject plan"
      assert rendered =~ "needs revision"
    end

    test "in_progress footer shows in-progress message" do
      plan = Plan.new(objective: "Test", status: :in_progress)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      assert rendered =~ "in progress"
    end

    test "executing footer shows executing message" do
      plan = Plan.new(objective: "Test", status: :executing)
      rendered = Plan.render(plan)

      refute rendered =~ "/approve plan"
      assert rendered =~ "being executed"
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

    test "renders assumptions and required permissions as bullet lists" do
      plan =
        Plan.new(
          objective: "Add structured fields",
          assumptions: ["Plan review happens before writes"],
          required_permissions: ["read", "write"]
        )

      rendered = Plan.render(plan)

      assert rendered =~ "Assumptions:"
      assert rendered =~ "- Plan review happens before writes"
      assert rendered =~ "Required permissions:"
      assert rendered =~ "- read"
      assert rendered =~ "- write"
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
