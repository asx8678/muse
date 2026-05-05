defmodule Muse.PlanBindingTest do
  use ExUnit.Case, async: true

  alias Muse.Plan
  alias Muse.PlanBinding
  alias Muse.Task

  # -- Helper: create a well-populated plan for hash tests -----------------------

  defp sample_plan(overrides \\ []) do
    defaults = [
      id: "plan_001",
      session_id: "sess_abc",
      version: 3,
      schema_version: "planning.v1",
      objective: "Add a /version command to the Muse CLI.",
      title: "Version command",
      assumptions: ["Repository is clean", "Tests pass on main"],
      required_permissions: ["read", "write"],
      files_expected: ["lib/muse/commands.ex"],
      commands_expected: ["mix test"],
      risks: ["Version source may differ in release"],
      validation: ["Run mix test"],
      inspected_files: ["lib/muse/commands.ex"],
      likely_changed_files: ["lib/muse/commands.ex"],
      tasks: [
        Task.new(id: "t1", title: "Add command definition", description: "Update commands.ex"),
        Task.new(id: "t2", title: "Add dispatch handler", description: "Update dispatcher")
      ],
      created_at: ~U[2025-01-01 00:00:00Z],
      updated_at: ~U[2025-01-01 00:00:00Z]
    ]

    Plan.new(Keyword.merge(defaults, overrides))
  end

  # -- content_hash/1 -----------------------------------------------------------

  describe "content_hash/1" do
    test "returns a 64-character lowercase hex string" do
      plan = sample_plan()
      hash = PlanBinding.content_hash(plan)

      assert is_binary(hash)
      assert byte_size(hash) == 64
      assert hash == String.downcase(hash)
    end

    test "is deterministic: same plan content produces same hash" do
      plan1 = sample_plan()
      plan2 = sample_plan()

      assert PlanBinding.content_hash(plan1) == PlanBinding.content_hash(plan2)
    end

    test "is deterministic across atom and string key construction" do
      # Build a plan with atom keys
      plan_atoms =
        Plan.new(
          id: "plan_atom",
          session_id: "sess_1",
          objective: "Atom key plan",
          tasks: [Task.new(id: "t1", title: "T1", description: "D1")]
        )

      # Build the same plan via JSON decode (string keys)
      json =
        plan_atoms
        |> Plan.to_map()
        |> Jason.encode!()

      {:ok, decoded} = Jason.decode(json)
      plan_strings = Plan.from_map(decoded)

      assert PlanBinding.content_hash(plan_atoms) == PlanBinding.content_hash(plan_strings),
             "Hash must be identical regardless of atom vs string key origin"
    end

    test "hash changes when objective changes" do
      plan_a = sample_plan(objective: "Objective A")
      plan_b = sample_plan(objective: "Objective B")

      refute PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end

    test "hash changes when version changes" do
      plan_v1 = sample_plan(version: 1)
      plan_v2 = sample_plan(version: 2)

      refute PlanBinding.content_hash(plan_v1) == PlanBinding.content_hash(plan_v2)
    end

    test "hash changes when tasks change" do
      plan_few = sample_plan(tasks: [Task.new(id: "t1", title: "Only task", description: "D1")])

      plan_more =
        sample_plan(
          tasks: [
            Task.new(id: "t1", title: "Task A", description: "DA"),
            Task.new(id: "t2", title: "Task B", description: "DB")
          ]
        )

      refute PlanBinding.content_hash(plan_few) == PlanBinding.content_hash(plan_more)
    end

    test "hash changes when risks change" do
      plan_no_risks = sample_plan(risks: [])
      plan_with_risk = sample_plan(risks: ["Data loss possible"])

      refute PlanBinding.content_hash(plan_no_risks) == PlanBinding.content_hash(plan_with_risk)
    end

    test "hash changes when assumptions change" do
      plan_a = sample_plan(assumptions: ["Assumption A"])
      plan_b = sample_plan(assumptions: ["Assumption B"])

      refute PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end

    test "hash changes when required_permissions change" do
      plan_read = sample_plan(required_permissions: ["read"])
      plan_write = sample_plan(required_permissions: ["write"])

      refute PlanBinding.content_hash(plan_read) == PlanBinding.content_hash(plan_write)
    end

    test "hash changes when schema_version changes" do
      plan_v1 = sample_plan(schema_version: "planning.v1")
      plan_v2 = sample_plan(schema_version: "planning.v2")

      refute PlanBinding.content_hash(plan_v1) == PlanBinding.content_hash(plan_v2)
    end

    test "hash changes when title changes" do
      plan_a = sample_plan(title: "Title A")
      plan_b = sample_plan(title: "Title B")

      refute PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b)
    end

    test "hash is stable across atom/string map round-trip through JSON" do
      plan =
        sample_plan(phases: [%{"id" => "ph1", "title" => "Implementation"}])

      original_hash = PlanBinding.content_hash(plan)

      # Round-trip through JSON decode
      round_tripped =
        plan
        |> Plan.to_map()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Plan.from_map()

      assert PlanBinding.content_hash(round_tripped) == original_hash,
             "Hash must survive JSON round-trip"
    end
  end

  # -- Volatile fields excluded from hash ---------------------------------------

  describe "content_hash/1 — volatile fields excluded" do
    test "timestamps do not change the hash" do
      ts_early = ~U[2025-01-01 00:00:00Z]
      ts_late = ~U[2099-12-31 23:59:59Z]

      plan_early = sample_plan(created_at: ts_early, updated_at: ts_early)
      plan_late = sample_plan(created_at: ts_late, updated_at: ts_late)

      assert PlanBinding.content_hash(plan_early) == PlanBinding.content_hash(plan_late),
             "created_at and updated_at must not affect hash"
    end

    test "approved_at does not change the hash" do
      plan_no_approval = sample_plan()

      {:ok, plan_approved} =
        Plan.transition(sample_plan(), :approved, approved_at: ~U[2025-06-01 12:00:00Z])

      assert PlanBinding.content_hash(plan_no_approval) ==
               PlanBinding.content_hash(plan_approved),
             "approved_at must not affect hash"
    end

    test "rejected_at does not change the hash" do
      plan_no_rejection = sample_plan()

      {:ok, plan_rejected} =
        Plan.transition(sample_plan(), :rejected, rejected_at: ~U[2025-06-01 12:00:00Z])

      assert PlanBinding.content_hash(plan_no_rejection) ==
               PlanBinding.content_hash(plan_rejected),
             "rejected_at must not affect hash"
    end

    test "completed_at does not change the hash" do
      plan_no_completion = sample_plan()

      {:ok, plan_completed} =
        Plan.transition(sample_plan(), :completed, completed_at: ~U[2025-12-01 00:00:00Z])

      assert PlanBinding.content_hash(plan_no_completion) ==
               PlanBinding.content_hash(plan_completed),
             "completed_at must not affect hash"
    end

    test "status does not change the hash" do
      plan_draft = sample_plan(status: :draft)
      plan_awaiting = sample_plan(status: :awaiting_approval)
      plan_approved = sample_plan(status: :approved)
      plan_rejected = sample_plan(status: :rejected)

      hash = PlanBinding.content_hash(plan_draft)

      assert PlanBinding.content_hash(plan_awaiting) == hash
      assert PlanBinding.content_hash(plan_approved) == hash
      assert PlanBinding.content_hash(plan_rejected) == hash
    end

    test "approvals list does not change the hash" do
      plan_no_approvals = sample_plan()

      plan_with_approvals =
        sample_plan(approvals: [%{"approver" => "user_1", "at" => "2025-06-01T00:00:00Z"}])

      assert PlanBinding.content_hash(plan_no_approvals) ==
               PlanBinding.content_hash(plan_with_approvals),
             "approvals must not affect hash"
    end

    test "metadata does not change the hash" do
      plan_no_meta = sample_plan()
      plan_with_meta = sample_plan(metadata: %{"extra" => "info", "count" => 42})

      assert PlanBinding.content_hash(plan_no_meta) ==
               PlanBinding.content_hash(plan_with_meta),
             "metadata must not affect hash"
    end

    test "created_by does not change the hash" do
      plan_a = sample_plan(created_by: "planning_muse")
      plan_b = sample_plan(created_by: "user_42")

      assert PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b),
             "created_by must not affect hash"
    end

    test "summary does not change the hash" do
      plan_a = sample_plan(summary: "Short summary A")
      plan_b = sample_plan(summary: "Completely different summary B")

      assert PlanBinding.content_hash(plan_a) == PlanBinding.content_hash(plan_b),
             "summary must not affect hash"
    end
  end

  # -- Secret safety ------------------------------------------------------------

  describe "content_hash/1 — secret safety" do
    test "metadata secrets do not leak into hash" do
      # Two plans with different secret metadata must have the same hash
      # because metadata is excluded from the hash entirely.
      plan_secret_a = sample_plan(metadata: %{"api_key" => "sk-secret-key-AAA"})
      plan_secret_b = sample_plan(metadata: %{"api_key" => "sk-secret-key-BBB"})

      assert PlanBinding.content_hash(plan_secret_a) ==
               PlanBinding.content_hash(plan_secret_b)
    end

    test "metadata secrets do not leak into debug output of approval_binding" do
      plan = sample_plan(metadata: %{"api_key" => "sk-super-secret-key-12345"})

      binding = PlanBinding.approval_binding(plan, workspace: "/tmp/project")

      # The binding map should not contain any metadata
      refute Map.has_key?(binding, :metadata)

      # The inspect output should not contain the secret
      inspected = inspect(binding)
      refute String.contains?(inspected, "sk-super-secret-key-12345")
    end

    test "agent_assignments with secrets do not affect hash" do
      # agent_assignments is excluded from the hash, so secrets in
      # agent_assignments should not change the hash.
      plan_clean = sample_plan()

      plan_with_secret_agent =
        sample_plan(
          agent_assignments: [
            %{"agent" => "coding", "api_token" => "sk-secret-token-XYZ"}
          ]
        )

      assert PlanBinding.content_hash(plan_clean) ==
               PlanBinding.content_hash(plan_with_secret_agent)
    end
  end

  # -- approval_binding/2 -------------------------------------------------------

  describe "approval_binding/2" do
    test "returns all required binding fields" do
      plan = sample_plan()
      binding = PlanBinding.approval_binding(plan, workspace: "/tmp/project")

      assert binding.kind == "plan_approval"
      assert binding.session_id == "sess_abc"
      assert binding.plan_id == "plan_001"
      assert binding.plan_version == 3
      assert binding.plan_hash == PlanBinding.content_hash(plan)
      assert binding.workspace == "/tmp/project"
    end

    test "workspace defaults to nil" do
      plan = sample_plan()
      binding = PlanBinding.approval_binding(plan)

      assert binding.workspace == nil
    end

    test "kind is always plan_approval" do
      plan = sample_plan()
      binding = PlanBinding.approval_binding(plan)

      assert binding.kind == "plan_approval"
      assert binding.kind == PlanBinding.binding_kind()
    end

    test "plan_hash in binding matches content_hash" do
      plan = sample_plan()
      binding = PlanBinding.approval_binding(plan)

      assert binding.plan_hash == PlanBinding.content_hash(plan)
      assert is_binary(binding.plan_hash)
      assert byte_size(binding.plan_hash) == 64
    end

    test "reflects session_id from plan" do
      plan = sample_plan(session_id: "sess_xyz")
      binding = PlanBinding.approval_binding(plan)

      assert binding.session_id == "sess_xyz"
    end

    test "reflects plan_id from plan" do
      plan = sample_plan(id: "plan_42")
      binding = PlanBinding.approval_binding(plan)

      assert binding.plan_id == "plan_42"
    end

    test "reflects plan_version from plan" do
      plan = sample_plan(version: 7)
      binding = PlanBinding.approval_binding(plan)

      assert binding.plan_version == 7
    end

    test "binding fields are all atom-keyed" do
      plan = sample_plan()
      binding = PlanBinding.approval_binding(plan)

      for key <- Map.keys(binding) do
        assert is_atom(key), "Binding key #{inspect(key)} should be an atom"
      end
    end

    test "binding contains exactly the expected keys" do
      plan = sample_plan()
      binding = PlanBinding.approval_binding(plan)

      expected_keys =
        MapSet.new([
          :kind,
          :session_id,
          :plan_id,
          :plan_version,
          :plan_hash,
          :content_hash,
          :workspace
        ])

      actual_keys = MapSet.new(Map.keys(binding))

      assert actual_keys == expected_keys
    end
  end

  # -- stable_fields/0 -----------------------------------------------------------

  describe "stable_fields/0" do
    test "returns a list of atoms" do
      for field <- PlanBinding.stable_fields() do
        assert is_atom(field)
      end
    end

    test "includes all expected content fields" do
      fields = PlanBinding.stable_fields()

      assert :id in fields
      assert :session_id in fields
      assert :version in fields
      assert :schema_version in fields
      assert :objective in fields
      assert :tasks in fields
      assert :assumptions in fields
      assert :required_permissions in fields
      assert :risks in fields
      assert :validation in fields
      assert :files_expected in fields
      assert :commands_expected in fields
    end

    test "excludes volatile fields" do
      fields = PlanBinding.stable_fields()

      refute :created_at in fields
      refute :updated_at in fields
      refute :approved_at in fields
      refute :rejected_at in fields
      refute :completed_at in fields
      refute :status in fields
      refute :approvals in fields
      refute :metadata in fields
      refute :created_by in fields
      refute :summary in fields
    end
  end

  # -- Delegates from Muse.Plan -------------------------------------------------

  describe "Muse.Plan.content_hash/1 (delegate)" do
    test "delegates to PlanBinding.content_hash/1" do
      plan = sample_plan()

      assert Plan.content_hash(plan) == PlanBinding.content_hash(plan)
    end
  end

  describe "Muse.Plan.approval_binding/2 (delegate)" do
    test "delegates to PlanBinding.approval_binding/2" do
      plan = sample_plan()

      assert Plan.approval_binding(plan, workspace: "/tmp") ==
               PlanBinding.approval_binding(plan, workspace: "/tmp")
    end
  end

  # -- Edge cases ---------------------------------------------------------------

  describe "content_hash/1 — edge cases" do
    test "minimal plan with only required fields produces valid hash" do
      plan = Plan.new(objective: "Minimal plan")

      hash = PlanBinding.content_hash(plan)

      assert is_binary(hash)
      assert byte_size(hash) == 64
    end

    test "plan with nil id still produces valid hash" do
      plan = Plan.new(objective: "No ID plan")
      # id is nil, so it's excluded from the canonical term (nil values dropped)

      hash = PlanBinding.content_hash(plan)

      assert is_binary(hash)
      assert byte_size(hash) == 64
    end

    test "plan with empty list fields produces valid hash" do
      plan =
        Plan.new(
          objective: "Empty lists",
          risks: [],
          assumptions: [],
          required_permissions: [],
          files_expected: [],
          commands_expected: [],
          validation: []
        )

      hash = PlanBinding.content_hash(plan)

      assert is_binary(hash)
      assert byte_size(hash) == 64
    end

    test "task with requires_write and requires_shell is canonicalized consistently" do
      plan_write =
        Plan.new(
          id: "p1",
          objective: "Test",
          tasks: [Task.new(id: "t1", title: "T1", description: "D1", requires_write?: true)]
        )

      # Round-trip through JSON to test string-key normalization
      json =
        plan_write
        |> Plan.to_map()
        |> Jason.encode!()

      {:ok, decoded} = Jason.decode(json)
      plan_round_tripped = Plan.from_map(decoded)

      assert PlanBinding.content_hash(plan_write) ==
               PlanBinding.content_hash(plan_round_tripped),
             "Task requires_write must canonicalize consistently across round-trip"
    end

    test "alternatives with atom vs string keys hash identically" do
      plan_atoms =
        Plan.new(
          id: "p1",
          objective: "Test",
          alternatives: [%{approach: "A"}]
        )

      plan_strings =
        Plan.new(
          id: "p1",
          objective: "Test",
          alternatives: [%{"approach" => "A"}]
        )

      assert PlanBinding.content_hash(plan_atoms) == PlanBinding.content_hash(plan_strings),
             "Alternative maps with atom vs string keys must hash identically"
    end

    test "phases with atom vs string keys hash identically" do
      plan_atoms =
        Plan.new(
          id: "p1",
          objective: "Test",
          phases: [%{id: "ph1", title: "Phase 1"}]
        )

      plan_strings =
        Plan.new(
          id: "p1",
          objective: "Test",
          phases: [%{"id" => "ph1", "title" => "Phase 1"}]
        )

      assert PlanBinding.content_hash(plan_atoms) == PlanBinding.content_hash(plan_strings),
             "Phase maps with atom vs string keys must hash identically"
    end

    test "no dynamic atoms are created from arbitrary string keys" do
      # Create a plan with arbitrary string keys in nested maps
      plan =
        Plan.new(
          id: "p1",
          objective: "Test",
          alternatives: [
            %{
              "totally_unknown_alternative_key_99999" => "no atom",
              "another_bogus_key_xyzzy" => "also no atom"
            }
          ]
        )

      # Verify the alternatives maps still have string keys (not converted to atoms)
      [alt] = plan.alternatives

      assert Map.has_key?(alt, "totally_unknown_alternative_key_99999"),
             "String keys should survive through Plan.new"

      refute Map.has_key?(alt, :totally_unknown_alternative_key_99999),
             "Unknown string keys should NOT be converted to atoms"

      # Compute the hash — this should not crash and should produce a valid result
      hash = PlanBinding.content_hash(plan)

      assert is_binary(hash),
             "content_hash should produce a valid hash with arbitrary string keys"

      assert String.length(hash) == 64,
             "content_hash should produce a SHA-256 hex string (64 chars)"
    end
  end

  # -- Hash determinism stress test ---------------------------------------------

  describe "content_hash/1 — determinism stress" do
    test "hash is stable over 100 calls on the same plan" do
      plan = sample_plan()
      hash = PlanBinding.content_hash(plan)

      for _ <- 1..100 do
        assert PlanBinding.content_hash(plan) == hash
      end
    end

    test "hash is identical for plans constructed with identical content" do
      plans =
        for _ <- 1..10 do
          Plan.new(
            id: "plan_001",
            session_id: "sess_abc",
            version: 3,
            objective: "Stress test objective",
            tasks: [Task.new(id: "t1", title: "T1", description: "D1")]
          )
        end

      hashes = Enum.map(plans, &PlanBinding.content_hash/1)

      assert Enum.uniq(hashes) |> length() == 1,
             "All identical plans must produce the same hash"
    end
  end
end
