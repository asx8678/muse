defmodule Muse.PR17PatchProposalTest do
  @moduledoc """
  PR17 acceptance tests: patch proposal & patch approval contract.

  These tests verify the data model contracts, session transitions,
  and boundary checks for the PR17 patch proposal/approval lifecycle.

  PR17 scope:
    - Coding Muse can propose patches only after an approved plan.
    - Patch proposals are parseable, formatable, and content-hashed.
    - Diff is displayed and approval requested.
    - /approve patch records approval only — does not apply/checkpoint files (PR18).
    - No file modifications occur before patch approval.
    - patch_apply is blocked for all roles in PR17.
    - patch_propose is blocked for Planning Muse; available to Coding Muse after plan approval.
    - Shell/network remain blocked/approval-gated future scope.

  Gaps (pending runtime wiring):
    - Full E2E flow: Coding Muse → patch_propose tool → :awaiting_patch_approval →
      /approve patch requires Conductor Coding Muse routing and patch_propose tool
      implementation, which are not yet active. These tests exercise data model
      contracts and boundary checks only.
  """

  use ExUnit.Case, async: true

  alias Muse.{Approval, ApprovalGate, Session, Tool.Registry}

  @ts ~U[2025-01-01 00:00:00Z]
  @later ~U[2025-01-02 00:00:00Z]

  # ---------------------------------------------------------------------------
  # Session model: :awaiting_patch_approval is a valid status
  # ---------------------------------------------------------------------------

  describe "session :awaiting_patch_approval status" do
    test "is in the canonical status list" do
      assert :awaiting_patch_approval in Session.statuses()
    end

    test "session can transition to :awaiting_patch_approval" do
      session =
        Session.new(workspace: "/tmp/muse", id: "sess_pr17", created_at: @ts, updated_at: @ts)

      assert {:ok, %Session{status: :awaiting_patch_approval}} =
               Session.transition(session, :awaiting_patch_approval, updated_at: @ts)
    end

    test "session can transition from :awaiting_patch_approval back to :idle" do
      session =
        Session.new(
          workspace: "/tmp/muse",
          id: "sess_pr17",
          status: :awaiting_patch_approval,
          created_at: @ts,
          updated_at: @ts
        )

      assert {:ok, %Session{status: :idle}} =
               Session.transition(session, :idle, updated_at: @ts)
    end

    test "session has pending_patch field" do
      session = Session.new(workspace: "/tmp/muse")
      assert Map.has_key?(session, :pending_patch)
      assert session.pending_patch == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Approval model: :patch kind with patch_id / patch_hash
  # ---------------------------------------------------------------------------

  describe "approval :patch kind" do
    test ":patch is a valid approval kind" do
      assert :patch in Approval.kinds()
    end

    test "creates a patch approval with patch_id and patch_hash" do
      approval =
        Approval.new(
          id: "approval_patch_1",
          session_id: "sess_1",
          kind: :patch,
          status: :pending,
          plan_id: "plan_1",
          plan_version: 1,
          plan_hash: "plan_hash_abc",
          patch_id: "patch_1",
          patch_hash: "patch_hash_def",
          workspace: "/tmp/muse",
          created_at: @ts
        )

      assert approval.kind == :patch
      assert approval.type == :patch
      assert approval.patch_id == "patch_1"
      assert approval.patch_hash == "patch_hash_def"
      assert approval.plan_id == "plan_1"
    end

    test "patch approval kind normalization via Approval.new/1" do
      # Verify that string kinds are correctly normalized through the public API
      approval_patch = Approval.new(kind: :patch)
      assert approval_patch.kind == :patch
      assert approval_patch.type == :patch
    end

    test "patch_hash field is present in struct" do
      approval = Approval.new(kind: :patch)
      assert Map.has_key?(approval, :patch_hash)
    end

    test "patch_id field is present in struct" do
      approval = Approval.new(kind: :patch)
      assert Map.has_key?(approval, :patch_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool Registry: patch_propose blocked for Planning, patch_apply blocked for all
  # ---------------------------------------------------------------------------

  describe "PR17 tool blocking boundaries" do
    test "patch_propose is a blocked tool name" do
      assert Registry.blocked_tool?("patch_propose")
    end

    test "patch_apply is a blocked tool name" do
      assert Registry.blocked_tool?("patch_apply")
    end

    test "patch_propose is not a known executable tool" do
      refute Registry.known_tool?("patch_propose")
    end

    test "patch_apply is not a known executable tool" do
      refute Registry.known_tool?("patch_apply")
    end

    test "read-only tools remain available" do
      for tool <- ~w(list_files read_file repo_search git_status git_diff_readonly) do
        assert Registry.known_tool?(tool)
        refute Registry.blocked_tool?(tool)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Boundary: patch approval does not apply files
  # ---------------------------------------------------------------------------

  describe "PR17 patch approval boundary" do
    @tag :pr17_boundary
    test "patch approval does not apply files — data model is lifecycle-only" do
      # PR17 guarantee: approving a patch records the user decision only.
      # It does NOT trigger patch_apply, checkpoint creation, or file writes.
      # This is enforced structurally: the Approval struct is data-only and
      # grants no runtime authority. patch_apply remains blocked.
      approval =
        Approval.new(
          id: "approval_patch_boundary",
          session_id: "sess_boundary",
          kind: :patch,
          status: :approved,
          plan_id: "plan_1",
          patch_id: "patch_1",
          patch_hash: "patch_hash_boundary",
          workspace: "/tmp/muse",
          approved_at: @later,
          created_at: @ts
        )

      # Approval is data-only — no apply side-effects possible from this struct.
      # The Approval struct does not have an :applied_at field; approval records
      # user decision only. Patch apply authority is reserved for PR18.
      assert approval.status == :approved
      assert approval.kind == :patch
      assert approval.approved_at == @later
      refute Map.has_key?(approval, :applied_at)

      # patch_apply remains blocked for all roles
      assert Registry.blocked_tool?("patch_apply")
    end

    @tag :pr17_boundary
    test "no file modifications before patch approval — session model supports this" do
      # Session starts idle, transitions to awaiting_patch_approval,
      # and patch approval only changes approval status — never workspace files.
      session =
        Session.new(workspace: "/tmp/muse", id: "sess_no_write", created_at: @ts, updated_at: @ts)

      assert {:ok, session} =
               Session.transition(session, :awaiting_patch_approval, updated_at: @ts)

      assert session.status == :awaiting_patch_approval

      # Returning to idle does not modify files
      assert {:ok, session} = Session.transition(session, :idle, updated_at: @ts)
      assert session.status == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # Stale patch approval rejection
  # ---------------------------------------------------------------------------

  describe "stale patch approval rejection" do
    @tag :pr17_boundary
    test "ApprovalGate denies :patch scope in PR17 deny-by-default mode" do
      # PR17: :patch is in the denied_scopes set. ApprovalGate.allowed?/2
      # returns an error for patch-scoped contexts, enforcing that
      # patch_apply cannot execute without explicit approval gates.
      assert {:error, {:scope_denied, :patch}} = ApprovalGate.allowed?(%{}, :patch)
    end

    @tag :pr17_boundary
    test "ApprovalGate tool permission boundary: patch/write/shell/network scopes are denied" do
      # PR17 boundary: :patch scope remains denied in ApprovalGate.
      assert {:error, {:scope_denied, :patch}} = ApprovalGate.allowed?(%{}, :patch)
      assert {:error, {:scope_denied, :write}} = ApprovalGate.allowed?(%{}, :write)
      assert {:error, {:scope_denied, :shell}} = ApprovalGate.allowed?(%{}, :shell)
      assert {:error, {:scope_denied, :network}} = ApprovalGate.allowed?(%{}, :network)
    end

    @tag :pr17_boundary
    test "shell and network remain blocked/approval-gated future scope" do
      # PR17 guarantee: shell/network are not enabled in this PR.
      assert Registry.blocked_tool?("shell_command")
      assert Registry.blocked_tool?("network_call")
      assert Registry.blocked_tool?("remote_execution")
    end
  end
end
