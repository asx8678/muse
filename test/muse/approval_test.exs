defmodule Muse.ApprovalTest do
  use ExUnit.Case, async: true

  alias Muse.Approval

  @ts ~U[2025-01-01 00:00:00Z]
  @later ~U[2025-01-02 00:00:00Z]

  describe "new/1" do
    test "creates a pending plan approval by default" do
      approval = Approval.new([])

      assert %Approval{} = approval
      assert is_binary(approval.id)
      assert String.starts_with?(approval.id, "approval_")
      assert approval.kind == :plan
      assert approval.type == :plan
      assert approval.status == :pending
      assert %DateTime{} = approval.created_at
      assert approval.metadata == %{}
    end

    test "accepts deterministic identifiers and timestamps" do
      approval =
        Approval.new(
          id: "approval_1",
          session_id: "sess_1",
          kind: :patch,
          status: :pending,
          plan_id: "plan_1",
          plan_version: 3,
          plan_hash: "hash_1",
          workspace: "/tmp/muse",
          requested_by: "user_1",
          created_at: @ts,
          expires_at: @later
        )

      assert approval.id == "approval_1"
      assert approval.session_id == "sess_1"
      assert approval.kind == :patch
      assert approval.type == :patch
      assert approval.plan_id == "plan_1"
      assert approval.plan_version == 3
      assert approval.plan_hash == "hash_1"
      assert approval.workspace == "/tmp/muse"
      assert approval.requested_by == "user_1"
      assert approval.created_at == @ts
      assert approval.expires_at == @later
    end

    test "supports all PR09 approval kinds" do
      assert Approval.kinds() == Approval.types()

      for kind <- [
            :plan,
            :patch,
            :shell_command,
            :network,
            :delete,
            :restore,
            :restore_checkpoint,
            :remote_execution
          ] do
        assert kind in Approval.kinds()
        assert Approval.valid_kind?(kind)
        assert Approval.valid_type?(kind)
        assert Approval.new(kind: kind).kind == kind
      end
    end

    test "supports all PR09 approval statuses" do
      for status <- [:pending, :approved, :rejected, :expired, :stale, :superseded] do
        assert status in Approval.statuses()
        assert Approval.valid_status?(status)
        assert Approval.new(status: status).status == status
      end
    end

    test "validation predicates require canonical atom values" do
      refute Approval.valid_kind?("plan")
      refute Approval.valid_type?("patch")
      refute Approval.valid_status?("pending")
      refute Approval.valid_kind?(:unknown)
      refute Approval.valid_status?(:unknown)
    end
  end

  describe "transition/3" do
    test "transitions to approved with actor and timestamp" do
      approval = Approval.new(id: "approval_1", created_at: @ts)

      assert {:ok, approved} =
               Approval.transition(approval, :approved,
                 approved_by: "user_1",
                 approved_at: @later
               )

      assert approved.status == :approved
      assert approved.approved_by == "user_1"
      assert approved.approved_at == @later
      assert approved.kind == approved.type
    end

    test "transitions with known string statuses without creating atoms" do
      approval = Approval.new(id: "approval_1", created_at: @ts)

      assert {:ok, stale} = Approval.transition(approval, "stale", reason: "plan changed")
      assert stale.status == :stale
      assert stale.reason == "plan changed"
    end

    test "rejects invalid transition statuses" do
      approval = Approval.new(id: "approval_1", created_at: @ts)

      assert {:error, {:invalid_status, "not_a_status"}} =
               Approval.transition(approval, "not_a_status")
    end
  end

  describe "approve/2 and reject/2" do
    test "approves pending approvals" do
      approval = Approval.new(id: "approval_1", created_at: @ts)

      assert {:ok, approved} =
               Approval.approve(approval, approved_by: "user_1", approved_at: @later)

      assert approved.status == :approved
      assert approved.approved_by == "user_1"
      assert approved.approved_at == @later
    end

    test "rejects pending approvals with reason and actor" do
      approval = Approval.new(id: "approval_1", created_at: @ts)

      assert {:ok, rejected} =
               Approval.reject(approval,
                 rejected_by: "user_1",
                 reason: "Unsafe scope",
                 rejected_at: @later
               )

      assert rejected.status == :rejected
      assert rejected.rejected_by == "user_1"
      assert rejected.reason == "Unsafe scope"
      assert rejected.rejected_at == @later
    end

    test "does not approve or reject non-pending approvals" do
      approved = Approval.new(id: "approval_1", status: :approved, created_at: @ts)
      rejected = Approval.new(id: "approval_2", status: :rejected, created_at: @ts)

      assert {:error, {:invalid_transition, :approved, :approved}} =
               Approval.approve(approved, "user_1")

      assert {:error, {:invalid_transition, :rejected, :rejected}} =
               Approval.reject(rejected, "already rejected")
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips through JSON" do
      original =
        Approval.new(
          id: "approval_1",
          session_id: "sess_1",
          kind: :shell_command,
          status: :pending,
          scope: %{"command" => "mix test"},
          plan_id: "plan_1",
          plan_version: 2,
          plan_hash: "hash_1",
          workspace: "/tmp/muse",
          requested_by: "cli",
          created_at: @ts,
          expires_at: @later,
          metadata: %{"api_key" => "secret", "safe" => true}
        )

      decoded =
        original
        |> Approval.to_map()
        |> Jason.encode!()
        |> Jason.decode!()

      restored = Approval.from_map(decoded)

      assert restored.id == original.id
      assert restored.session_id == original.session_id
      assert restored.kind == :shell_command
      assert restored.type == :shell_command
      assert restored.status == :pending
      assert restored.scope == %{"command" => "mix test"}
      assert restored.plan_id == "plan_1"
      assert restored.plan_version == 2
      assert restored.plan_hash == "hash_1"
      assert restored.workspace == "/tmp/muse"
      assert restored.requested_by == "cli"
      assert restored.created_at == @ts
      assert restored.expires_at == @later
      assert restored.metadata["api_key"] == "**REDACTED**"
      assert restored.metadata["safe"] == true
    end

    test "accepts legacy type and camelCase string keys" do
      approval =
        Approval.from_map(%{
          "id" => "approval_legacy",
          "sessionId" => "sess_1",
          "type" => "restore-checkpoint",
          "status" => "approved",
          "planId" => "plan_1",
          "planVersion" => "4",
          "planHash" => "hash_1",
          "approvedBy" => "web_user",
          "createdAt" => DateTime.to_iso8601(@ts),
          "approvedAt" => DateTime.to_iso8601(@later)
        })

      assert approval.kind == :restore_checkpoint
      assert approval.type == :restore_checkpoint
      assert approval.status == :approved
      assert approval.session_id == "sess_1"
      assert approval.plan_id == "plan_1"
      assert approval.plan_version == 4
      assert approval.plan_hash == "hash_1"
      assert approval.approved_by == "web_user"
      assert approval.created_at == @ts
      assert approval.approved_at == @later
    end

    test "unknown keys, kinds, and statuses are safe" do
      before_atoms = :erlang.system_info(:atom_count)

      approval =
        Approval.from_map(%{
          "id" => "approval_unknown",
          "kind" => "unknown_kind_that_must_not_be_an_atom_12345",
          "status" => "unknown_status_that_must_not_be_an_atom_12345",
          "unknown_approval_key_12345" => "ignored",
          "metadata" => %{"unknown_metadata_key_12345" => "kept"}
        })

      after_atoms = :erlang.system_info(:atom_count)

      assert approval.kind == :plan
      assert approval.type == :plan
      assert approval.status == :pending
      assert approval.metadata["unknown_metadata_key_12345"] == "kept"

      assert after_atoms - before_atoms < 3,
             "Unknown JSON keys/statuses/kinds should not create atoms: #{after_atoms - before_atoms}"
    end
  end

  describe "metadata sanitization" do
    test "redacts sensitive metadata and normalizes values" do
      approval =
        Approval.new(
          id: "approval_1",
          created_at: @ts,
          metadata: %{
            "Token" => "secret-token",
            :source => :planning,
            nested: %{password: "secret-password"}
          }
        )

      assert approval.metadata["Token"] == "**REDACTED**"
      assert approval.metadata[:source] == "planning"
      assert approval.metadata[:nested][:password] == "**REDACTED**"
    end

    test "sanitizes metadata at serialization boundary" do
      approval = %Approval{
        id: "approval_1",
        kind: :plan,
        type: :plan,
        status: :pending,
        created_at: @ts,
        metadata: %{api_key: "secret"}
      }

      map = Approval.to_map(approval)

      assert map[:metadata][:api_key] == "**REDACTED**"
    end
  end

  describe "expired?/1 and expired?/2" do
    test "detects time-based expiry" do
      expired = Approval.new(id: "approval_1", created_at: @ts, expires_at: @ts)
      active = Approval.new(id: "approval_2", created_at: @ts, expires_at: @later)

      assert Approval.expired?(expired, @later)
      refute Approval.expired?(active, @ts)
    end

    test "treats explicit expired status as expired" do
      approval = Approval.new(id: "approval_1", status: :expired, created_at: @ts)

      assert Approval.expired?(approval)
    end

    test "does not approve expired approvals" do
      approval = Approval.new(id: "approval_1", created_at: @ts, expires_at: @ts)

      assert {:error, :expired} = Approval.approve(approval, approved_at: @later)
    end
  end

  describe "stale?/2" do
    test "detects mismatched plan id, version, or hash" do
      approval =
        Approval.new(
          id: "approval_1",
          created_at: @ts,
          plan_id: "plan_1",
          plan_version: 2,
          plan_hash: "hash_1"
        )

      refute Approval.stale?(approval, %{"id" => "plan_1", "version" => "2", "hash" => "hash_1"})
      assert Approval.stale?(approval, %{"id" => "plan_2", "version" => "2", "hash" => "hash_1"})
      assert Approval.stale?(approval, %{"id" => "plan_1", "version" => "3", "hash" => "hash_1"})
      assert Approval.stale?(approval, %{"id" => "plan_1", "version" => "2", "hash" => "hash_2"})
    end

    test "treats explicit stale status as stale" do
      approval = Approval.new(id: "approval_1", status: :stale, created_at: @ts)

      assert Approval.stale?(approval, nil)
    end
  end
end
