defmodule Muse.PR17HardeningTest do
  @moduledoc """
  PR17 hardening tests: exercises the full real path through SessionServer/TurnRunner
  with an approved plan and fake provider patch_propose tool call.

  Tests:
    A. pending_patch survives from Conductor result through handle_task_result
    B. patch_propose requires approved plan context in tool authorization
    C. Patch.new auto-generates stable id when absent
    D. Approval records (%Muse.Approval{kind: :patch}) are appended on patch approval/rejection
    E. pending_patch is restored from snapshot
    F. Patch decision history survives after clearing pending_patch
    G. patch_proposed events avoid raw diff in event payloads
    H. True E2E: submit/4 → TurnRunner → Conductor → ToolLoop → handle_task_result
    I. Snapshot restore degrades safely when pending_patch cannot be restored
    J. Conductor path persists pending_patch to patches.jsonl
    K. Conductor path patch_proposed events use diff_ref not raw diff
  """
  use ExUnit.Case, async: false

  alias Muse.{Approval, Patch, Plan, SessionServer, State}

  import Muse.PR09ApprovalGateWorkspaceHelpers,
    only: [tmp_dir!: 0, seed_workspace: 1, workspace_snapshot: 1]

  @simple_diff """
  --- a/lib/muse/example.ex
  +++ b/lib/muse/example.ex
  @@ -1,3 +1,4 @@
   defmodule Muse.Example do
  +  @moduledoc "Example module"
     def hello, do: :world
   end
  """

  setup do
    cleanup_infrastructure()
    ensure_infrastructure()

    workspace = tmp_dir!()
    seed_workspace(workspace)

    on_exit(fn ->
      cleanup_infrastructure()
      File.rm_rf!(workspace)
    end)

    %{workspace: workspace}
  end

  # -- Gap A: pending_patch survives handle_task_result --------------------------

  describe "Gap A: pending_patch propagation from Conductor result" do
    @tag :pr17_hardening
    test "propose_patch stores pending_patch and status is :awaiting_patch_approval",
         %{workspace: workspace} do
      session_id = unique_id("gap-a-propose")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      assert %Patch{} = patch
      assert patch.status == :proposed

      status = SessionServer.status(pid)
      assert status.status == :awaiting_patch_approval
      assert status.pending_patch != nil
      # pending_patch should be a %Patch{} struct, not a raw map
      assert match?(%Patch{}, status.pending_patch)
    end
  end

  # -- Gap B: patch_propose requires approved plan context ----------------------

  describe "Gap B: patch_propose tool authorization requires approved plan context" do
    alias Muse.ApprovalGate
    alias Muse.Tool.Registry

    @tag :pr17_hardening
    test "patch_propose is allowed for Coding Muse WITH approved plan context" do
      spec = Registry.get("patch_propose")

      context = %{
        muse_id: :coding,
        plan_status: :approved,
        plan_id: "plan_1",
        plan_hash: "abc123"
      }

      assert ApprovalGate.authorize_tool(spec, context) == :ok
    end

    @tag :pr17_hardening
    test "patch_propose is blocked for Coding Muse WITHOUT plan context" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :coding}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    @tag :pr17_hardening
    test "patch_propose is blocked for Coding Muse with non-approved plan status" do
      spec = Registry.get("patch_propose")

      for plan_status <- [:pending, :draft, :awaiting_approval, :rejected] do
        context = %{muse_id: :coding, plan_status: plan_status, plan_id: "p1", plan_hash: "abc"}
        assert {:blocked, _} = ApprovalGate.authorize_tool(spec, context)
      end
    end

    @tag :pr17_hardening
    test "patch_propose is blocked for Coding Muse with approved plan but missing plan_id" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :coding, plan_status: :approved, plan_hash: "abc123"}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    @tag :pr17_hardening
    test "patch_propose is blocked for Coding Muse with approved plan but missing plan_hash" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :coding, plan_status: :approved, plan_id: "plan_1"}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    @tag :pr17_hardening
    test "patch_propose is blocked for Planning Muse even with approved plan context" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :planning, plan_status: :approved, plan_id: "plan_1", plan_hash: "abc"}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    @tag :pr17_hardening
    test "direct Runner.run blocks patch_propose for Coding Muse without plan context" do
      context = %{workspace: "/tmp", muse_id: :coding, session_id: "s1", turn_id: "t1"}
      result = Muse.Tool.Runner.run("patch_propose", %{"diff" => "some diff"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    @tag :pr17_hardening
    test "direct Runner.run allows patch_propose for Coding Muse WITH approved plan context" do
      # Create a workspace with some files for validation
      workspace = Path.join(System.tmp_dir!(), "muse_gap_b_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/foo.ex"), "defmodule Foo do end\n")

      context = %{
        workspace: workspace,
        muse_id: :coding,
        session_id: "s1",
        turn_id: "t1",
        plan_status: :approved,
        plan_id: "plan_1",
        plan_hash: "abc123"
      }

      diff =
        "diff --git a/lib/foo.ex b/lib/foo.ex\n--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1 +1,2 @@\n defmodule Foo do\n+  @moduledoc \"doc\"\nend\n"

      result = Muse.Tool.Runner.run("patch_propose", %{"diff" => diff}, context)
      assert result.success

      File.rm_rf!(workspace)
    end
  end

  # -- Gap C: Patch auto-generates stable id ------------------------------------

  describe "Gap C: Patch.new auto-generates stable id" do
    @tag :pr17_hardening
    test "Patch.new generates patch_id from content hash when id is nil" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: @simple_diff
        )

      assert patch.id != nil
      assert String.starts_with?(patch.id, "patch_")
      # The id should be patch_<12-char hash prefix>
      assert patch.id == "patch_#{String.slice(patch.hash, 0, 12)}"
    end

    @tag :pr17_hardening
    test "Patch.new preserves explicit id when provided" do
      {:ok, patch} =
        Patch.new(
          id: "my_custom_id",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: @simple_diff
        )

      assert patch.id == "my_custom_id"
    end

    @tag :pr17_hardening
    test "Patch.from_map auto-generates patch_id when id is absent" do
      {:ok, patch} =
        Patch.from_map(%{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "diff" => @simple_diff
        })

      assert patch.id != nil
      assert String.starts_with?(patch.id, "patch_")
    end

    @tag :pr17_hardening
    test "auto-generated patch id is deterministic" do
      {:ok, p1} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: @simple_diff,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      {:ok, p2} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: @simple_diff,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      # Same content → same hash → same auto-id
      assert p1.id == p2.id
    end
  end

  # -- Gap D: Approval records appended on patch lifecycle transitions -----------

  describe "Gap D: approval records on patch lifecycle" do
    @tag :pr17_hardening
    test "approve_patch appends %Approval{kind: :patch} to session approvals",
         %{workspace: workspace} do
      session_id = unique_id("gap-d-approve")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      # Before approval, check approvals count
      status_before = SessionServer.status(pid)
      approvals_before = length(status_before.approvals)

      # Approve the patch
      {:ok, approved_patch} = SessionServer.approve_patch(pid, :cli)
      assert approved_patch.status == :approved

      # After approval, there should be a new Approval{kind: :patch}
      status_after = SessionServer.status(pid)
      new_approvals = status_after.approvals
      assert length(new_approvals) > approvals_before

      patch_approval =
        Enum.find(new_approvals, fn a ->
          match?(%Approval{kind: :patch}, a)
        end)

      assert patch_approval != nil
      assert patch_approval.kind == :patch
      assert patch_approval.status == :approved
      assert patch_approval.patch_id == approved_patch.id
      assert patch_approval.patch_hash == approved_patch.hash
      assert patch_approval.plan_id == approved_patch.plan_id
      assert patch_approval.plan_version == approved_patch.plan_version
      assert patch_approval.approved_by == "cli"
      assert patch_approval.approved_at != nil
    end

    @tag :pr17_hardening
    test "reject_patch appends %Approval{kind: :patch} with rejected status",
         %{workspace: workspace} do
      session_id = unique_id("gap-d-reject")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, rejected_patch} = SessionServer.reject_patch(pid, :cli)
      assert rejected_patch.status == :rejected

      status = SessionServer.status(pid)

      patch_approval =
        Enum.find(status.approvals, fn a ->
          match?(%Approval{kind: :patch}, a)
        end)

      assert patch_approval != nil
      assert patch_approval.kind == :patch
      assert patch_approval.status == :rejected
      assert patch_approval.patch_id == rejected_patch.id
      assert patch_approval.rejected_by == "cli"
      assert patch_approval.rejected_at != nil
    end
  end

  # -- Gap E: pending_patch restored from snapshot ------------------------------

  describe "Gap E: pending_patch snapshot restore" do
    @tag :pr17_hardening
    test "pending_patch is persisted to snapshot and restored on session restart",
         %{workspace: workspace} do
      session_id = unique_id("gap-e-snapshot")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      assert patch.status == :proposed
      assert SessionServer.status(pid).status == :awaiting_patch_approval

      # Kill the session server
      GenServer.stop(pid)

      # Restart the session — should restore from snapshot
      {:ok, pid2} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {SessionServer, session_id: session_id}
        )

      status = SessionServer.status(pid2)
      # pending_patch should be restored
      assert status.pending_patch != nil
      assert match?(%Patch{}, status.pending_patch)
      assert status.pending_patch.id == patch.id
      assert status.pending_patch.hash == patch.hash
      assert status.pending_patch.status == :proposed
      assert status.status == :awaiting_patch_approval

      # Approval should still work after restore
      {:ok, approved} = SessionServer.approve_patch(pid2, :cli)
      assert approved.status == :approved
      assert SessionServer.status(pid2).status == :idle
    end
  end

  # -- Gap F: Patch decision history survives clearing pending_patch ------------

  describe "Gap F: patch decision audit trail" do
    @tag :pr17_hardening
    test "approval record persists in approvals after pending_patch is cleared",
         %{workspace: workspace} do
      session_id = unique_id("gap-f-audit")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, _approved} = SessionServer.approve_patch(pid, :cli)

      # pending_patch is cleared
      status = SessionServer.status(pid)
      assert status.pending_patch == nil
      assert status.status == :idle

      # But the approval record is still there
      patch_approvals =
        Enum.filter(status.approvals, fn a ->
          match?(%Approval{kind: :patch}, a)
        end)

      assert length(patch_approvals) >= 1

      approval = hd(patch_approvals)
      assert approval.patch_id == patch.id
      assert approval.patch_hash == patch.hash
      assert approval.plan_id == patch.plan_id
      assert approval.kind == :patch
      assert approval.status == :approved
    end

    @tag :pr17_hardening
    test "rejection record persists in approvals after pending_patch is cleared",
         %{workspace: workspace} do
      session_id = unique_id("gap-f-reject-audit")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, _rejected} = SessionServer.reject_patch(pid, :cli)

      status = SessionServer.status(pid)
      assert status.pending_patch == nil

      patch_approvals =
        Enum.filter(status.approvals, fn a ->
          match?(%Approval{kind: :patch, status: :rejected}, a)
        end)

      assert length(patch_approvals) >= 1
      approval = hd(patch_approvals)
      assert approval.patch_id == patch.id
      assert approval.kind == :patch
      assert approval.status == :rejected
    end
  end

  # -- Gap G: patch_proposed events avoid raw diff ------------------------------

  describe "Gap G: event payloads avoid unrestricted raw diff" do
    @tag :pr17_hardening
    test "patch_proposed event uses diff_ref instead of raw diff",
         %{workspace: workspace} do
      session_id = unique_id("gap-g-event")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      State.clear()

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      events = State.events()
      patch_proposed = Enum.find(events, &(&1.type == :patch_proposed))

      assert patch_proposed != nil
      # Event should NOT contain raw diff
      assert Map.get(patch_proposed.data, :diff) == nil
      assert Map.get(patch_proposed.data, "diff") == nil
      # Event SHOULD contain diff_ref
      assert Map.get(patch_proposed.data, :diff_ref) != nil
      # Event should still have patch_id, hash, affected_files
      assert Map.get(patch_proposed.data, :patch_id) != nil
      assert Map.get(patch_proposed.data, :hash) != nil
      assert Map.get(patch_proposed.data, :affected_files) != nil
    end
  end

  # -- Full path: approve and reject lifecycle-only (no workspace writes) -------

  describe "PR17 full lifecycle: no workspace writes" do
    @tag :pr17_hardening
    test "approve patch: lifecycle-only, no workspace files changed",
         %{workspace: workspace} do
      session_id = unique_id("full-approve")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {paths_before, hashes_before} = workspace_snapshot(workspace)

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, approved} = SessionServer.approve_patch(pid, :cli)
      assert approved.status == :approved
      assert SessionServer.status(pid).status == :idle

      # No workspace writes
      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end

    @tag :pr17_hardening
    test "reject patch: lifecycle-only, no workspace files changed",
         %{workspace: workspace} do
      session_id = unique_id("full-reject")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {paths_before, hashes_before} = workspace_snapshot(workspace)

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, rejected} = SessionServer.reject_patch(pid, :cli)
      assert rejected.status == :rejected
      assert SessionServer.status(pid).status == :idle

      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end
  end

  # -- Gap H: True E2E through SessionServer.submit → TurnRunner → Conductor -----

  describe "Gap H: submit/4 → TurnRunner → Conductor → ToolLoop patch_propose → handle_task_result" do
    @simple_diff """
    diff --git a/lib/muse/example.ex b/lib/muse/example.ex
    --- a/lib/muse/example.ex
    +++ b/lib/muse/example.ex
    @@ -1,3 +1,4 @@
     defmodule Muse.Example do
    +  @moduledoc "Example module"
       def hello, do: :world
     end
    """

    @tag :pr17_hardening
    test "patch_propose through real TurnRunner path sets pending_patch and :awaiting_patch_approval",
         %{workspace: workspace} do
      session_id = unique_id("gap-h-e2e")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {paths_before, hashes_before} = workspace_snapshot(workspace)

      State.clear()

      # Build fake provider batches that will cause the Coding Muse to
      # call patch_propose via the ToolLoop, just like a real LLM would.
      batch0 = [
        {:tool_call, "patch_propose",
         %{
           "diff" => @simple_diff,
           "affected_files" => ["lib/muse/example.ex"],
           "summary" => "Add moduledoc to example.ex"
         }},
        {:response_completed, nil}
      ]

      batch1 = [
        {:assistant_delta, "I've proposed a patch."},
        {:assistant_completed, "I've proposed a patch."},
        {:response_completed, nil}
      ]

      request_options = [options: %{fake_event_batches: [batch0, batch1]}]

      # Submit through the REAL path: submit/4 → do_submit → TurnRunner.async →
      # Conductor.run → ToolLoop (patch_propose) → handle_task_result
      {:ok, assistant_text} =
        SessionServer.submit(pid, :cli, "implement the plan",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: request_options
        )

      # Assert: assistant text mentions awaiting approval
      assert assistant_text =~ "Awaiting approval",
             "Expected assistant text to mention awaiting approval, got: #{inspect(assistant_text)}"

      # Assert: session status is :awaiting_patch_approval
      status = SessionServer.status(pid)

      assert status.status == :awaiting_patch_approval,
             "Expected :awaiting_patch_approval, got: #{inspect(status.status)}"

      # Assert: pending_patch is a %Patch{} struct
      assert status.pending_patch != nil

      assert match?(%Patch{}, status.pending_patch),
             "Expected pending_patch to be %Patch{}, got: #{inspect(status.pending_patch)}"

      # Assert: /approve patch works and appends approval record
      {:ok, approved} = SessionServer.approve_patch(pid, :cli)
      assert approved.status == :approved

      status_after = SessionServer.status(pid)
      assert status_after.status == :idle
      assert status_after.pending_patch == nil

      # Assert: a patch approval record was appended
      patch_approvals =
        Enum.filter(status_after.approvals, fn a ->
          match?(%Approval{kind: :patch}, a)
        end)

      assert length(patch_approvals) >= 1
      approval = hd(patch_approvals)
      assert approval.kind == :patch
      assert approval.status == :approved

      # Assert: no workspace files changed
      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end
  end

  # -- Gap I: Snapshot restore safety when pending_patch is invalid ---------------

  describe "Gap I: snapshot restore degrades safely when pending_patch cannot be restored" do
    @tag :pr17_hardening
    test "awaiting_patch_approval with binary patch in pending_patch degrades to :idle",
         %{workspace: _workspace} do
      session_id = unique_id("gap-i-binary-patch")

      # Write a snapshot with status "awaiting_patch_approval" and a pending_patch
      # containing a GIT binary patch which Patch.from_map will reject
      corrupt_data = %{
        "status" => "awaiting_patch_approval",
        "pending_patch" => %{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "diff" => "GIT binary patch\nliteral 0\nHcmV?00001\n",
          "hash" => String.duplicate("a", 64),
          "status" => "proposed"
        },
        "active_plan_id" => nil,
        "approval_binding" => nil,
        "active_approval" => nil,
        "approvals" => [],
        "plan" => nil,
        "plans" => %{}
      }

      :ok = Muse.SessionStore.save_session(session_id, corrupt_data)

      # Start the session server — it should restore from the snapshot
      # without crashing and degrade to :idle since pending_patch is invalid
      # (binary patches are rejected by DiffParser.validate)
      pid = start_server(session_id)

      status = SessionServer.status(pid)

      assert status.status == :idle,
             "Expected :idle (safe degradation), got: #{inspect(status.status)}"

      assert status.pending_patch == nil,
             "Expected pending_patch to be nil after failed restore"

      GenServer.stop(pid)
    end

    @tag :pr17_hardening
    test "awaiting_patch_approval with nil pending_patch in snapshot degrades to :idle",
         %{workspace: _workspace} do
      session_id = unique_id("gap-i-nil-patch")

      snapshot_data = %{
        "status" => "awaiting_patch_approval",
        "pending_patch" => nil,
        "active_plan_id" => nil,
        "approval_binding" => nil,
        "active_approval" => nil,
        "approvals" => [],
        "plan" => nil,
        "plans" => %{}
      }

      :ok = Muse.SessionStore.save_session(session_id, snapshot_data)

      pid = start_server(session_id)
      status = SessionServer.status(pid)

      assert status.status == :idle,
             "Expected :idle (safe degradation), got: #{inspect(status.status)}"

      assert status.pending_patch == nil

      GenServer.stop(pid)
    end
  end

  # -- Gap J: Conductor path persists patch to patches.jsonl --------------------

  describe "Gap J: patch persisted to patches.jsonl via Conductor path" do
    @simple_diff """
    diff --git a/lib/muse/example.ex b/lib/muse/example.ex
    --- a/lib/muse/example.ex
    +++ b/lib/muse/example.ex
    @@ -1,3 +1,4 @@
     defmodule Muse.Example do
    +  @moduledoc "Example module"
       def hello, do: :world
     end
    """

    @tag :pr17_hardening
    test "Conductor path (submit/4) persists pending_patch to patches.jsonl",
         %{workspace: workspace} do
      session_id = unique_id("gap-j-persist")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      State.clear()

      batch0 = [
        {:tool_call, "patch_propose",
         %{
           "diff" => @simple_diff,
           "affected_files" => ["lib/muse/example.ex"],
           "summary" => "Add moduledoc"
         }},
        {:response_completed, nil}
      ]

      batch1 = [
        {:assistant_delta, "Patch proposed."},
        {:assistant_completed, "Patch proposed."},
        {:response_completed, nil}
      ]

      request_options = [options: %{fake_event_batches: [batch0, batch1]}]

      {:ok, _text} =
        SessionServer.submit(pid, :cli, "implement the plan",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: request_options
        )

      # Verify patches.jsonl was written
      {:ok, patches, %{skipped: skipped}} =
        Muse.SessionStore.load_patches(session_id)

      assert skipped == 0
      assert length(patches) >= 1

      patch_map = hd(patches)
      assert Map.get(patch_map, "hash") != nil
      assert Map.get(patch_map, "affected_files") != nil
    end

    @tag :pr17_hardening
    test "direct propose_patch also persists to patches.jsonl without duplicates",
         %{workspace: workspace} do
      session_id = unique_id("gap-j-direct")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, patches, %{skipped: skipped}} =
        Muse.SessionStore.load_patches(session_id)

      assert skipped == 0
      assert length(patches) == 1

      patch_map = hd(patches)
      assert Map.get(patch_map, "hash") != nil
    end
  end

  # -- Gap K: patch_proposed events avoid raw diff (Conductor path) ---------------

  describe "Gap K: Conductor path patch_proposed events use diff_ref not raw diff" do
    @simple_diff """
    diff --git a/lib/muse/example.ex b/lib/muse/example.ex
    --- a/lib/muse/example.ex
    +++ b/lib/muse/example.ex
    @@ -1,3 +1,4 @@
     defmodule Muse.Example do
    +  @moduledoc "Example module"
       def hello, do: :world
     end
    """

    @tag :pr17_hardening
    test "patch_proposed event from Conductor path has no raw diff",
         %{workspace: workspace} do
      session_id = unique_id("gap-k-event")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      State.clear()

      batch0 = [
        {:tool_call, "patch_propose",
         %{
           "diff" => @simple_diff,
           "affected_files" => ["lib/muse/example.ex"],
           "summary" => "Add moduledoc"
         }},
        {:response_completed, nil}
      ]

      batch1 = [
        {:assistant_delta, "Patch proposed."},
        {:assistant_completed, "Patch proposed."},
        {:response_completed, nil}
      ]

      request_options = [options: %{fake_event_batches: [batch0, batch1]}]

      {:ok, _text} =
        SessionServer.submit(pid, :cli, "implement the plan",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: request_options
        )

      events = State.events()
      patch_proposed = Enum.find(events, &(&1.type == :patch_proposed))

      assert patch_proposed != nil
      # Event should NOT contain raw diff
      assert Map.get(patch_proposed.data, :diff) == nil
      assert Map.get(patch_proposed.data, "diff") == nil
      # Event SHOULD contain diff_ref
      assert Map.get(patch_proposed.data, :diff_ref) != nil
      assert Map.get(patch_proposed.data, :patch_id) != nil
      assert Map.get(patch_proposed.data, :hash) != nil
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp unique_id(prefix) do
    "pr17h-#{prefix}-#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp start_server(session_id) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {SessionServer, session_id: session_id}
      )

    pid
  end

  defp create_approved_plan(session_id, _workspace) do
    plan_attrs = [
      id: "pr17h-plan-#{:erlang.unique_integer([:positive])}",
      objective: "Test objective for patch proposal flow",
      session_id: session_id,
      version: 1,
      tasks: [
        %{
          title: "Add moduledoc",
          description: "Add @moduledoc to example.ex",
          target_files: ["lib/muse/example.ex"]
        }
      ],
      status: :approved
    ]

    Plan.new(plan_attrs)
  end

  defp ensure_infrastructure do
    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _pid -> State.clear()
    end

    clean_sessions()
    File.rm_rf!(".muse/sessions")
    :ok
  end

  defp cleanup_infrastructure do
    clean_sessions()

    case Process.whereis(Muse.State) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    File.rm_rf!(".muse/sessions")
  end

  defp clean_sessions do
    case Process.whereis(Muse.SessionSupervisor) do
      nil ->
        :ok

      pid ->
        pid
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            try do
              DynamicSupervisor.terminate_child(Muse.SessionSupervisor, child_pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end)

        Process.sleep(10)
    end
  end
end
