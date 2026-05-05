defmodule Muse.PR17PatchProposalE2ETest do
  @moduledoc """
  Offline deterministic integration test for the PR17 patch proposal flow.

  Exercises: approved plan → Coding Muse patch_propose → awaiting_patch_approval
  → /approve patch → idle (no workspace writes, no apply).

  Uses direct GenServer calls to set up deterministic state without
  requiring a real LLM provider. The patch proposal panel and event
  stream rendering are tested separately in home_live_test and
  event_stream_test.
  """
  use ExUnit.Case, async: false

  alias Muse.{Patch, Plan, SessionServer, State}

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

  describe "PR17 patch proposal offline E2E" do
    @tag :pr17_patch_proposal
    test "propose_patch with approved plan → awaiting_patch_approval → approve_patch → idle, no workspace writes",
         %{workspace: workspace} do
      session_id = pr17_session_id("patch-approve")
      pid = start_server(session_id)

      # Set up an approved plan in the session state
      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {paths_before, hashes_before} = workspace_snapshot(workspace)

      # Step 1: Propose a patch
      {:ok, patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      assert %Patch{} = patch
      assert patch.status == :proposed
      assert patch.hash != nil
      assert patch.affected_files == ["lib/muse/example.ex"]

      # Step 2: Session should be in :awaiting_patch_approval
      status = SessionServer.status(pid)
      assert status.status == :awaiting_patch_approval
      assert status.pending_patch != nil
      assert status.pending_patch.status == :proposed

      # Step 3: Verify patch_proposed and patch_approval_requested events emitted
      events = State.events()
      patch_proposed_events = Enum.filter(events, &(&1.type == :patch_proposed))

      patch_approval_requested_events =
        Enum.filter(events, &(&1.type == :patch_approval_requested))

      assert length(patch_proposed_events) >= 1
      assert length(patch_approval_requested_events) >= 1

      proposed_event = hd(patch_proposed_events)
      assert proposed_event.visibility == :user

      # Step 4: Approve the patch via SessionServer
      {:ok, approved_patch} = SessionServer.approve_patch(pid, :cli)

      assert %Patch{} = approved_patch
      assert approved_patch.status == :approved

      # Step 5: Session should be back to idle
      status = SessionServer.status(pid)
      assert status.status == :idle
      assert status.pending_patch == nil

      # Step 6: Verify patch_approved event was emitted
      events = State.events()
      patch_approved_events = Enum.filter(events, &(&1.type == :patch_approved))
      assert length(patch_approved_events) >= 1

      approved_event = hd(patch_approved_events)
      assert approved_event.visibility == :user

      # Step 7: NO workspace writes
      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end

    @tag :pr17_patch_proposal
    test "propose_patch → reject_patch → idle, no workspace writes",
         %{workspace: workspace} do
      session_id = pr17_session_id("patch-reject")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {paths_before, hashes_before} = workspace_snapshot(workspace)

      {:ok, patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      assert patch.status == :proposed
      assert SessionServer.status(pid).status == :awaiting_patch_approval

      # Reject the patch
      {:ok, rejected_patch} = SessionServer.reject_patch(pid, :cli)

      assert rejected_patch.status == :rejected
      assert SessionServer.status(pid).status == :idle
      assert SessionServer.status(pid).pending_patch == nil

      # Verify patch_rejected event
      events = State.events()
      patch_rejected_events = Enum.filter(events, &(&1.type == :patch_rejected))
      assert length(patch_rejected_events) >= 1
      assert hd(patch_rejected_events).visibility == :user

      # NO workspace writes
      {paths_after, hashes_after} = workspace_snapshot(workspace)
      assert paths_after == paths_before
      assert hashes_after == hashes_before
    end

    @tag :pr17_patch_proposal
    test "approve_patch without pending patch returns error" do
      session_id = pr17_session_id("no-patch")
      pid = start_server(session_id)

      result = SessionServer.approve_patch(pid, :cli)
      assert {:error, :no_pending_patch} = result
    end

    @tag :pr17_patch_proposal
    test "double approve on same patch returns error",
         %{workspace: workspace} do
      session_id = pr17_session_id("double-approve")
      pid = start_server(session_id)

      plan = create_approved_plan(session_id, workspace)
      :ok = GenServer.call(pid, {:store_approved_plan, plan})

      {:ok, _patch} =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      {:ok, _approved} = SessionServer.approve_patch(pid, :cli)

      # Second approve should fail — no pending patch
      result = SessionServer.approve_patch(pid, :cli)
      assert {:error, :no_pending_patch} = result
    end

    @tag :pr17_patch_proposal
    test "propose_patch without approved plan returns error" do
      session_id = pr17_session_id("no-plan")
      pid = start_server(session_id)

      result =
        SessionServer.propose_patch(pid,
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      assert {:error, :no_active_plan} = result
    end

    @tag :pr17_patch_proposal
    test "store_pending_patch → approve_patch via SessionServer (direct patch test)" do
      session_id = pr17_session_id("direct-patch")
      pid = start_server(session_id)

      # Create a patch directly and store it
      {:ok, patch} =
        Patch.new(
          session_id: session_id,
          plan_id: "test-plan",
          plan_version: 1,
          plan_hash: String.duplicate("a", 64),
          diff: @simple_diff,
          affected_files: ["lib/muse/example.ex"]
        )

      :ok = GenServer.call(pid, {:store_pending_patch, patch})

      assert SessionServer.status(pid).status == :awaiting_patch_approval

      {:ok, approved} = SessionServer.approve_patch(pid, :cli)
      assert approved.status == :approved
      assert SessionServer.status(pid).status == :idle
    end

    @tag :pr17_patch_proposal
    test "patch proposal events are in EventStream chat_messages and EventDisplay summary" do
      # Create synthetic patch events and verify they flow through display/stream
      alias Muse.{Event, EventDisplay, EventStream}

      patch_data = %{
        patch_id: "patch_test123",
        plan_id: "plan_abc",
        hash: String.duplicate("a", 64),
        affected_files: ["lib/muse/example.ex"],
        diff: @simple_diff
      }

      proposed_event =
        Event.new(:conductor, :patch_proposed, patch_data,
          id: 100,
          timestamp: ~U[2025-06-15 12:00:00Z],
          session_id: "test-session",
          turn_id: "turn-1",
          seq: 10,
          visibility: :user
        )

      approval_event =
        Event.new(
          :conductor,
          :patch_approval_requested,
          %{
            patch_id: "patch_test123",
            plan_id: "plan_abc",
            hash: String.duplicate("a", 64)
          },
          id: 101,
          timestamp: ~U[2025-06-15 12:00:01Z],
          session_id: "test-session",
          turn_id: "turn-1",
          seq: 11,
          visibility: :user
        )

      # EventDisplay should produce summaries for patch lifecycle events
      summary = EventDisplay.summary(proposed_event)
      assert summary =~ "Patch proposed"
      assert summary =~ "patch_test123"

      approval_summary = EventDisplay.summary(approval_event)
      assert approval_summary =~ "Patch approval requested"
      assert approval_summary =~ "/approve patch"

      # EventStream.chat_messages should include patch events as system messages
      messages = EventStream.chat_messages([proposed_event, approval_event])
      assert length(messages) == 2
      assert Enum.all?(messages, &(&1.role == :system))
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp pr17_session_id(prefix) do
    "pr17-#{prefix}-#{:erlang.unique_integer([:positive, :monotonic])}"
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
      id: "pr17-test-plan-#{:erlang.unique_integer([:positive])}",
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
