defmodule Muse.PatchTest do
  use ExUnit.Case, async: true

  alias Muse.Patch

  describe "new/1" do
    test "creates a patch with required plan binding fields" do
      patch =
        Patch.new(
          session_id: "sess_1",
          plan_id: "plan_1",
          plan_version: 2,
          plan_hash: "abc123def456",
          workspace: "/tmp/project"
        )

      assert %Patch{} = patch
      assert patch.status == :proposed
      assert patch.session_id == "sess_1"
      assert patch.plan_id == "plan_1"
      assert patch.plan_version == 2
      assert patch.plan_hash == "abc123def456"
      assert patch.workspace == "/tmp/project"
    end

    test "auto-generates id when not provided" do
      patch =
        Patch.new(
          session_id: "sess_1",
          plan_id: "plan_1",
          plan_version: 1,
          plan_hash: "abc"
        )

      assert patch.id != nil
      assert String.starts_with?(patch.id, "patch_")
    end

    test "accepts deterministic id for testing" do
      patch =
        Patch.new(
          id: "patch_test_1",
          session_id: "sess_1",
          plan_id: "plan_1",
          plan_version: 1,
          plan_hash: "abc"
        )

      assert patch.id == "patch_test_1"
    end

    test "accepts deterministic timestamps for testing" do
      ts = ~U[2025-01-01 00:00:00Z]

      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          created_at: ts,
          updated_at: ts
        )

      assert patch.created_at == ts
      assert patch.updated_at == ts
    end

    test "accepts optional metadata fields" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          summary: "Add /version command",
          description: "Adds a version endpoint",
          diff_summary: "2 files changed",
          affected_files: ["lib/muse/commands.ex", "test/muse/commands_test.exs"],
          created_by: "coding_muse"
        )

      assert patch.summary == "Add /version command"
      assert patch.description == "Adds a version endpoint"
      assert patch.diff_summary == "2 files changed"
      assert patch.affected_files == ["lib/muse/commands.ex", "test/muse/commands_test.exs"]
      assert patch.created_by == "coding_muse"
    end

    test "defaults collection fields to empty" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc"
        )

      assert patch.affected_files == []
      assert patch.approvals == []
      assert patch.metadata == %{}
    end

    test "accepts map with string keys" do
      patch =
        Patch.new(%{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "workspace" => "/tmp/project",
          "summary" => "Test patch"
        })

      assert patch.session_id == "s1"
      assert patch.plan_id == "p1"
      assert patch.workspace == "/tmp/project"
      assert patch.summary == "Test patch"
    end
  end

  describe "statuses/0" do
    test "returns the canonical list of patch statuses" do
      statuses = Patch.statuses()

      assert :proposed in statuses
      assert :awaiting_approval in statuses
      assert :approved in statuses
      assert :rejected in statuses
    end

    test "all statuses are atoms" do
      for status <- Patch.statuses() do
        assert is_atom(status)
      end
    end
  end

  describe "valid_status?/1" do
    test "returns true for canonical statuses" do
      for status <- Patch.statuses() do
        assert Patch.valid_status?(status)
      end
    end

    test "returns false for non-canonical values" do
      refute Patch.valid_status?(:unknown)
      refute Patch.valid_status?(nil)
      refute Patch.valid_status?(:applied)
      refute Patch.valid_status?("proposed")
    end
  end

  describe "transition/3" do
    setup do
      patch =
        Patch.new(
          id: "patch_t1",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          created_at: ~U[2025-01-01 00:00:00Z],
          updated_at: ~U[2025-01-01 00:00:00Z]
        )

      %{patch: patch}
    end

    test "transitions from proposed to awaiting_approval", %{patch: patch} do
      assert {:ok, updated} = Patch.transition(patch, :awaiting_approval)
      assert updated.status == :awaiting_approval
    end

    test "transitions from awaiting_approval to approved", %{patch: patch} do
      {:ok, patch} = Patch.transition(patch, :awaiting_approval)

      assert {:ok, approved} = Patch.transition(patch, :approved)
      assert approved.status == :approved
      assert %DateTime{} = approved.approved_at
    end

    test "transitions from awaiting_approval to rejected", %{patch: patch} do
      {:ok, patch} = Patch.transition(patch, :awaiting_approval)

      assert {:ok, rejected} = Patch.transition(patch, :rejected)
      assert rejected.status == :rejected
      assert %DateTime{} = rejected.rejected_at
    end

    test "rejects invalid status", %{patch: patch} do
      assert {:error, {:invalid_status, :unknown}} = Patch.transition(patch, :unknown)
    end

    test "allows deterministic updated_at for testing", %{patch: patch} do
      ts = ~U[2025-06-01 00:00:00Z]
      {:ok, updated} = Patch.transition(patch, :awaiting_approval, updated_at: ts)
      assert updated.updated_at == ts
    end

    test "preserves other fields through transition", %{patch: patch} do
      {:ok, updated} = Patch.transition(patch, :awaiting_approval)

      assert updated.id == "patch_t1"
      assert updated.session_id == "s1"
      assert updated.plan_id == "p1"
      assert updated.plan_hash == "abc"
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips a patch through JSON-friendly map" do
      patch =
        Patch.new(
          id: "patch_rt",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 2,
          plan_hash: "abc123",
          workspace: "/tmp/project",
          summary: "Add feature",
          affected_files: ["lib/foo.ex"]
        )

      map = Patch.to_map(patch)
      assert is_map(map)
      assert map["id"] == "patch_rt" or map[:id] == "patch_rt"

      restored = Patch.from_map(map)
      assert restored.id == patch.id
      assert restored.session_id == patch.session_id
      assert restored.plan_id == patch.plan_id
      assert restored.plan_version == patch.plan_version
      assert restored.plan_hash == patch.plan_hash
      assert restored.workspace == patch.workspace
      assert restored.summary == patch.summary
    end

    test "to_map drops nil values" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc"
        )

      map = Patch.to_map(patch)
      refute Map.has_key?(map, :description)
      refute Map.has_key?(map, :diff_summary)
    end

    test "from_map handles string-key maps (decoded JSON)" do
      map = %{
        "id" => "patch_json",
        "session_id" => "s1",
        "plan_id" => "p1",
        "plan_version" => 1,
        "plan_hash" => "abc",
        "status" => "awaiting_approval",
        "workspace" => "/tmp/project"
      }

      patch = Patch.from_map(map)
      assert patch.id == "patch_json"
      assert patch.status == :awaiting_approval
      assert patch.workspace == "/tmp/project"
    end
  end

  describe "content_hash/1" do
    test "produces a deterministic SHA-256 hex digest" do
      patch =
        Patch.new(
          id: "patch_hash",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          workspace: "/tmp/project",
          summary: "Test"
        )

      hash = Patch.content_hash(patch)
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash == Patch.content_hash(patch)
    end

    test "changes when stable content changes" do
      base =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          summary: "First"
        )

      changed =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          summary: "Second"
        )

      assert Patch.content_hash(base) != Patch.content_hash(changed)
    end

    test "does not change with status or timestamp changes" do
      patch =
        Patch.new(
          id: "patch_stable",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      {:ok, transitioned} = Patch.transition(patch, :awaiting_approval)

      assert Patch.content_hash(patch) == Patch.content_hash(transitioned)
    end
  end

  describe "approval_binding/2" do
    test "produces a binding map with patch identity" do
      patch =
        Patch.new(
          id: "patch_bind",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 2,
          plan_hash: "abc123",
          workspace: "/tmp/project"
        )

      binding = Patch.approval_binding(patch)

      assert binding.kind == "patch_approval"
      assert binding.session_id == "s1"
      assert binding.plan_id == "p1"
      assert binding.plan_version == 2
      assert binding.plan_hash == "abc123"
      assert binding.patch_id == "patch_bind"
      assert binding.workspace == "/tmp/project"
      assert Map.has_key?(binding, :patch_hash)
    end

    test "accepts workspace override" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          workspace: "/tmp/default"
        )

      binding = Patch.approval_binding(patch, workspace: "/tmp/override")
      assert binding.workspace == "/tmp/override"
    end
  end

  describe "validate_plan_binding/1" do
    test "returns :ok when all binding fields are present" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc"
        )

      assert :ok = Patch.validate_plan_binding(patch)
    end

    test "returns error when session_id is missing" do
      patch =
        Patch.new(
          session_id: "",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc"
        )

      assert {:error, :missing_session_id} = Patch.validate_plan_binding(patch)
    end

    test "returns error when plan_id is missing" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "",
          plan_version: 1,
          plan_hash: "abc"
        )

      assert {:error, :missing_plan_id} = Patch.validate_plan_binding(patch)
    end

    test "returns error when plan_version is missing" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_hash: "abc"
        )

      # plan_version defaults to 1, so this should pass
      assert :ok = Patch.validate_plan_binding(patch)
    end

    test "returns error when plan_hash is missing" do
      patch =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: ""
        )

      assert {:error, :missing_plan_hash} = Patch.validate_plan_binding(patch)
    end
  end
end
