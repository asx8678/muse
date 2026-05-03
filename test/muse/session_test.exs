defmodule Muse.SessionTest do
  use ExUnit.Case, async: true

  alias Muse.Session

  describe "new/1" do
    test "creates a session with required workspace" do
      session = Session.new(workspace: "/tmp/project")

      assert %Session{} = session
      assert session.workspace == "/tmp/project"
      assert session.status == :idle
      assert session.id == nil
    end

    test "raises on missing workspace" do
      assert_raise KeyError, fn ->
        Session.new([])
      end
    end

    test "accepts deterministic id for testing" do
      session = Session.new(workspace: "/tmp", id: "sess_1")
      assert session.id == "sess_1"
    end

    test "accepts deterministic timestamps for testing" do
      ts = ~U[2025-01-01 00:00:00Z]
      session = Session.new(workspace: "/tmp", id: "sess_1", created_at: ts, updated_at: ts)

      assert session.created_at == ts
      assert session.updated_at == ts
    end

    test "defaults timestamps to DateTime.utc_now when not overridden" do
      session = Session.new(workspace: "/tmp")

      assert %DateTime{} = session.created_at
      assert %DateTime{} = session.updated_at
    end

    test "defaults all collection fields to empty" do
      session = Session.new(workspace: "/tmp")

      assert session.messages == []
      assert session.plans == %{}
      assert session.approvals == []
      assert session.checkpoints == []
      assert session.tool_calls == []
      assert session.artifacts == []
      assert session.pending_patch == nil
    end

    test "defaults optional fields to nil" do
      session = Session.new(workspace: "/tmp")

      assert session.active_muse == nil
      assert session.active_plan_id == nil
      assert session.active_task_id == nil
      assert session.provider_state == nil
      assert session.memory == nil
    end

    test "accepts active_muse option" do
      session = Session.new(workspace: "/tmp", active_muse: "planning_muse")
      assert session.active_muse == "planning_muse"
    end

    test "accepts custom initial status" do
      session = Session.new(workspace: "/tmp", status: :running)
      assert session.status == :running
    end
  end

  describe "statuses/0" do
    test "returns the canonical list of session statuses" do
      statuses = Session.statuses()

      assert :idle in statuses
      assert :running in statuses
      assert :planning in statuses
      assert :awaiting_plan_approval in statuses
      assert :executing in statuses
      assert :awaiting_patch_approval in statuses
      assert :awaiting_shell_approval in statuses
      assert :verifying in statuses
      assert :reviewing in statuses
      assert :repairing in statuses
      assert :done in statuses
      assert :failed in statuses
      assert :error in statuses
      assert :cancelled in statuses
    end

    test "all statuses are atoms" do
      for status <- Session.statuses() do
        assert is_atom(status)
      end
    end
  end

  describe "valid_status?/1" do
    test "returns true for canonical statuses" do
      for status <- Session.statuses() do
        assert Session.valid_status?(status)
      end
    end

    test "returns false for non-canonical values" do
      refute Session.valid_status?(:unknown)
      refute Session.valid_status?(nil)
      refute Session.valid_status?("idle")
    end
  end

  describe "transition/3" do
    test "transitions to a valid status" do
      ts = ~U[2025-01-01 00:00:00Z]
      session = Session.new(workspace: "/tmp", id: "sess_1", created_at: ts, updated_at: ts)

      assert {:ok, updated} = Session.transition(session, :running)
      assert updated.status == :running
    end

    test "updates updated_at on transition" do
      ts = ~U[2025-01-01 00:00:00Z]
      session = Session.new(workspace: "/tmp", id: "sess_1", created_at: ts, updated_at: ts)

      {:ok, updated} = Session.transition(session, :running, updated_at: ts)
      assert updated.updated_at == ts
    end

    test "allows deterministic updated_at for testing" do
      ts = ~U[2025-01-01 00:00:00Z]
      session = Session.new(workspace: "/tmp", id: "sess_1", created_at: ts, updated_at: ts)
      future = ~U[2025-06-01 00:00:00Z]

      {:ok, updated} = Session.transition(session, :planning, updated_at: future)
      assert updated.updated_at == future
    end

    test "rejects invalid status" do
      session = Session.new(workspace: "/tmp")

      assert {:error, {:invalid_status, :unknown}} = Session.transition(session, :unknown)
    end

    test "preserves other fields through transition" do
      session = Session.new(workspace: "/tmp", id: "sess_1", active_muse: "planning_muse")
      {:ok, updated} = Session.transition(session, :running)

      assert updated.id == "sess_1"
      assert updated.workspace == "/tmp"
      assert updated.active_muse == "planning_muse"
    end
  end
end
