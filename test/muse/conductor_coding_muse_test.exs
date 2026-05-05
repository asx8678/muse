defmodule Muse.ConductorCodingMuseTest do
  @moduledoc """
  PR17 lane05: Coding Muse routing / fake-provider proposal flow.

  Tests:
    - unapproved plan cannot route to Coding Muse proposal path;
    - approved plan can select/run Coding Muse for patch proposal;
    - fake provider emits patch_propose and runtime records proposal/waits for /approve patch;
    - no workspace files changed during proposal path;
    - planning lifecycle regressions still pass.
  """
  use ExUnit.Case, async: true

  alias Muse.Conductor
  alias Muse.Session
  alias Muse.Turn
  alias Muse.Plan
  alias Muse.Tool.Registry
  alias Muse.ApprovalGate

  # -- Helpers ------------------------------------------------------------------

  defp make_session(opts \\ []) do
    status = Keyword.get(opts, :status, :idle)
    id = Keyword.get(opts, :id, "test-session-#{:erlang.unique_integer([:positive])}")

    workspace =
      Keyword.get(
        opts,
        :workspace,
        "/tmp/muse_test_workspace_#{:erlang.unique_integer([:positive])}"
      )

    session =
      Session.new(workspace: workspace, id: id, status: status)

    plans = Keyword.get(opts, :plans, %{})
    active_plan_id = Keyword.get(opts, :active_plan_id, nil)
    pending_patch = Keyword.get(opts, :pending_patch, nil)

    %{session | plans: plans, active_plan_id: active_plan_id, pending_patch: pending_patch}
  end

  defp make_approved_plan(opts \\ []) do
    id = Keyword.get(opts, :id, "plan_#{:erlang.unique_integer([:positive])}")
    session_id = Keyword.get(opts, :session_id, "test-session")

    plan =
      Plan.new(
        objective: Keyword.get(opts, :objective, "Test objective"),
        session_id: session_id,
        tasks: Keyword.get(opts, :tasks, [])
      )

    {:ok, approved} = Plan.transition(plan, :approved)
    %{approved | id: id}
  end

  defp make_turn(user_text \\ "implement the plan") do
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"
    turn_id = "turn_#{:erlang.unique_integer([:positive])}"

    %Turn{
      id: turn_id,
      session_id: session_id,
      source: :cli,
      status: :pending,
      started_at: DateTime.utc_now(),
      user_text: user_text
    }
  end

  defp conductor_opts_for_coding_muse(patch_propose_script) do
    [
      request_options: [options: %{fake_events: patch_propose_script}],
      tool_runner: Muse.Tool.Runner
    ]
  end

  # -- select_muse routing tests ------------------------------------------------

  describe "select_muse/2 routing" do
    test "idle session without plan selects Planning Muse" do
      session = make_session(status: :idle)
      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end

    test "idle session with unapproved plan selects Planning Muse" do
      plan = Plan.new(objective: "Test", session_id: "test-session")
      # Plan is in :pending status (default), not :approved
      plans = %{plan.id => plan}
      session = make_session(status: :idle, plans: plans, active_plan_id: plan.id)
      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end

    test "idle session with approved plan selects Coding Muse" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      session = make_session(status: :idle, plans: plans, active_plan_id: approved.id)
      muse = Conductor.select_muse(session, [])
      assert muse.id == :coding
    end

    test "running session selects Planning Muse even with approved plan" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      session = make_session(status: :running, plans: plans, active_plan_id: approved.id)
      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end

    test "awaiting_plan_approval session selects Planning Muse even with approved plan" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}

      session =
        make_session(status: :awaiting_plan_approval, plans: plans, active_plan_id: approved.id)

      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end

    test "awaiting_patch_approval session selects Planning Muse" do
      pending = %{patch_content: "diff", target_files: ["lib/foo.ex"], description: "test"}
      approved = make_approved_plan()
      plans = %{approved.id => approved}

      session =
        make_session(
          status: :awaiting_patch_approval,
          plans: plans,
          active_plan_id: approved.id,
          pending_patch: pending
        )

      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end

    test "idle session with nil active_plan_id selects Planning Muse" do
      session = make_session(status: :idle, active_plan_id: nil)
      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end

    test "idle session with active_plan_id pointing to missing plan selects Planning Muse" do
      session = make_session(status: :idle, plans: %{}, active_plan_id: "nonexistent")
      muse = Conductor.select_muse(session, [])
      assert muse.id == :planning
    end
  end

  # -- ApprovalGate patch_propose authorization tests ---------------------------

  describe "ApprovalGate.authorize_tool/2 for patch_propose" do
    test "patch_propose is allowed for Coding Muse with approved plan context" do
      spec = Registry.get("patch_propose")
      assert spec != nil

      context = %{
        muse_id: :coding,
        plan_status: :approved,
        plan_id: "plan_1",
        plan_hash: "abc123"
      }

      assert ApprovalGate.authorize_tool(spec, context) == :ok
    end

    test "patch_propose is blocked for Coding Muse without approved plan context" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :coding}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    test "patch_propose is blocked for Coding Muse with non-approved plan" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :coding, plan_status: :pending, plan_id: "plan_1", plan_hash: "abc123"}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    test "patch_propose is blocked for Planning Muse" do
      spec = Registry.get("patch_propose")
      context = %{muse_id: :planning}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    test "patch_propose is blocked when no muse context provided" do
      spec = Registry.get("patch_propose")
      context = %{}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end
  end

  # -- Tool Registry patch_propose registration tests --------------------------

  describe "Tool Registry patch_propose" do
    test "patch_propose is registered and known" do
      assert Registry.known_tool?("patch_propose")
      assert not Registry.blocked_tool?("patch_propose")
    end

    test "patch_propose spec has correct properties" do
      spec = Registry.get("patch_propose")
      assert spec.name == "patch_propose"
      assert spec.permission == :patch
      assert spec.kind == :patch
      assert spec.handler == Muse.Tools.PatchPropose
      assert :coding in spec.allowed_muses
      assert spec.requires_approval
    end

    test "patch_propose is included in coding muse specs" do
      specs = Registry.specs_for_muse(:coding)
      names = Enum.map(specs, & &1.name)
      assert "patch_propose" in names
    end

    test "patch_propose is NOT included in planning muse specs" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)
      refute "patch_propose" in names
    end
  end

  # -- Conductor.run end-to-end Coding Muse tests -------------------------------

  describe "Conductor.run/3 with Coding Muse" do
    @tag :m1_readonly
    test "Coding Muse is selected when session has approved plan" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      session = make_session(status: :idle, plans: plans, active_plan_id: approved.id)
      turn = make_turn("implement the plan")

      script = [
        {:assistant_delta, "I'll read the files."},
        {:assistant_completed, "I'll read the files."},
        {:response_completed, nil}
      ]

      opts = conductor_opts_for_coding_muse(script)

      {:ok, result} = Conductor.run(session, turn, opts)

      # Coding Muse should be selected for idle session with approved plan
      assert result.selected_muse.id == :coding
      # Session returns to :idle after turn completes
      assert result.session.status == :idle
    end

    @tag :m1_readonly
    test "Coding Muse without patch_propose stays at :idle" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      session = make_session(status: :idle, plans: plans, active_plan_id: approved.id)
      turn = make_turn("just read the files")

      script = [
        {:tool_call, "read_file", %{"path" => "lib/foo.ex"}},
        {:assistant_delta, "I've read the file."},
        {:assistant_completed, "I've read the file."},
        {:response_completed, nil}
      ]

      opts = conductor_opts_for_coding_muse(script)

      {:ok, result} = Conductor.run(session, turn, opts)

      # Session should stay at :idle (no patch proposed)
      assert result.session.status == :idle
      assert result.session.pending_patch == nil
    end

    @tag :m1_readonly
    test "no workspace files changed during Coding Muse turn" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      workspace = "/tmp/muse_test_workspace_#{:erlang.unique_integer([:positive])}"
      File.mkdir_p!(workspace)

      session =
        make_session(
          status: :idle,
          plans: plans,
          active_plan_id: approved.id,
          workspace: workspace
        )

      turn = make_turn("implement the plan")

      # Record files before the run
      files_before = File.ls!(workspace) |> MapSet.new()

      script = [
        {:tool_call, "read_file", %{"path" => "."}},
        {:assistant_delta, "Proposed a patch."},
        {:assistant_completed, "Proposed a patch."},
        {:response_completed, nil}
      ]

      opts = conductor_opts_for_coding_muse(script)

      {:ok, _result} = Conductor.run(session, turn, opts)

      # No new files should have been created in the workspace
      files_after = File.ls!(workspace) |> MapSet.new()
      assert MapSet.equal?(files_before, files_after)

      # Cleanup
      File.rm_rf!(workspace)
    end
  end

  # -- Regression: muse-cnb patch_proposals propagated through Conductor.run/3 ---

  describe "Conductor.run/3 propagates patch_proposals (muse-cnb regression)" do
    @simple_diff """
    diff --git a/lib/example.ex b/lib/example.ex
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -1,3 +1,4 @@
     defmodule Example do
    +  @moduledoc "Example"
       def hello, do: :world
     end
    """

    @tag :m1_readonly
    test "patch_propose tool call through ToolLoop captures pending patch and transitions to :awaiting_patch_approval" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      workspace = "/tmp/muse_test_workspace_#{:erlang.unique_integer([:positive])}"
      File.mkdir_p!(workspace)

      session =
        make_session(
          status: :idle,
          plans: plans,
          active_plan_id: approved.id,
          workspace: workspace
        )

      turn = make_turn("implement the plan")

      batch0 = [
        {:tool_call, "patch_propose",
         %{
           "diff" => @simple_diff,
           "affected_files" => ["lib/example.ex"],
           "summary" => "Add moduledoc to Example"
         }},
        {:response_completed, nil}
      ]

      batch1 = [
        {:assistant_delta, "I've proposed a patch."},
        {:assistant_completed, "I've proposed a patch."},
        {:response_completed, nil}
      ]

      opts = [
        request_options: [options: %{fake_event_batches: [batch0, batch1], fake_iteration: 0}],
        tool_runner: Muse.Tool.Runner
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      # Session should transition to :awaiting_patch_approval
      assert result.session.status == :awaiting_patch_approval,
             "Expected session to be :awaiting_patch_approval, got: #{result.session.status}"

      # pending_patch should be present with expected fields
      pending = result.session.pending_patch
      assert pending != nil, "Expected pending_patch to be set"
      assert pending[:hash] != nil, "Expected pending_patch hash to be present"
      assert pending[:affected_files] == ["lib/example.ex"]
      assert pending[:summary] == "Add moduledoc to Example"
      assert pending[:proposed_at] != nil, "Expected proposed_at timestamp"
      assert pending[:tool_call_id] != nil, "Expected tool_call_id from ToolLoop"

      # Assistant guidance should mention awaiting approval
      assert result.assistant_text =~ "Awaiting approval",
             "Expected assistant text to mention awaiting approval, got: #{inspect(result.assistant_text)}"

      assert result.assistant_text =~ "/approve patch",
             "Expected assistant text to mention /approve patch"

      assert result.assistant_text =~ "lib/example.ex",
             "Expected assistant text to list affected files"

      # :patch_proposed event spec should be present
      patch_proposed_specs =
        Enum.filter(result.event_specs, fn
          {:conductor, :patch_proposed, _, _} -> true
          _ -> false
        end)

      assert length(patch_proposed_specs) >= 1,
             "Expected at least one :patch_proposed event spec"

      # No workspace files should have been created
      assert File.ls!(workspace) == [],
             "Expected no files in workspace, got: #{inspect(File.ls!(workspace))}"

      # Cleanup
      File.rm_rf!(workspace)
    end

    @tag :m1_readonly
    test "Coding Muse with read-only tool calls and no patch_propose stays at :idle" do
      approved = make_approved_plan()
      plans = %{approved.id => approved}
      workspace = "/tmp/muse_test_workspace_#{:erlang.unique_integer([:positive])}"
      File.mkdir_p!(workspace)

      session =
        make_session(
          status: :idle,
          plans: plans,
          active_plan_id: approved.id,
          workspace: workspace
        )

      turn = make_turn("just read the files")

      batch0 = [
        {:tool_call, "list_files", %{"path" => "."}},
        {:response_completed, nil}
      ]

      batch1 = [
        {:assistant_delta, "I've listed the files."},
        {:assistant_completed, "I've listed the files."},
        {:response_completed, nil}
      ]

      opts = [
        request_options: [options: %{fake_event_batches: [batch0, batch1], fake_iteration: 0}],
        tool_runner: Muse.Tool.Runner
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      # Session should stay at :idle (no patch proposed)
      assert result.session.status == :idle
      assert result.session.pending_patch == nil

      # No patch_proposed events
      patch_proposed_specs =
        Enum.filter(result.event_specs, fn
          {:conductor, :patch_proposed, _, _} -> true
          _ -> false
        end)

      assert patch_proposed_specs == []

      # Cleanup
      File.rm_rf!(workspace)
    end
  end

  # -- Unapproved plan cannot route to Coding Muse proposal path ----------------

  describe "unapproved plan cannot route to Coding Muse" do
    @tag :m1_readonly
    test "session with pending (not approved) plan runs Planning Muse, not Coding Muse" do
      # Create a plan that is NOT approved (default :pending status)
      plan = Plan.new(objective: "Test objective", session_id: "test-session")
      plans = %{plan.id => plan}
      session = make_session(status: :idle, plans: plans, active_plan_id: plan.id)
      turn = make_turn("implement the plan")

      # Even if the script includes patch_propose, Planning Muse is selected
      # and patch_propose should be blocked
      script = [
        {:assistant_delta, "I need to create a plan first."},
        {:assistant_completed, "I need to create a plan first."},
        {:response_completed, nil}
      ]

      opts = [
        request_options: [options: %{fake_events: script}],
        tool_runner: Muse.Tool.Runner
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      # Should be Planning Muse, not Coding Muse
      assert result.selected_muse.id == :planning
      # No pending_patch since Planning Muse didn't propose one
      assert result.session.pending_patch == nil
    end
  end

  # -- normalize_scope patch_propose test ---------------------------------------

  describe "ApprovalGate normalize_scope for patch_propose" do
    test "patch_propose is allowed for Coding Muse with approved plan via authorize_tool" do
      spec = Registry.get("patch_propose")
      assert spec != nil
      assert spec.permission == :patch

      context = %{
        muse_id: :coding,
        plan_status: :approved,
        plan_id: "plan_1",
        plan_hash: "abc123"
      }

      assert ApprovalGate.authorize_tool(spec, context) == :ok
    end

    test "patch_propose is blocked for Coding Muse without approved plan via authorize_tool" do
      spec = Registry.get("patch_propose")
      assert spec != nil
      context = %{muse_id: :coding}
      assert {:blocked, _reason} = ApprovalGate.authorize_tool(spec, context)
    end

    test "patch_propose permission is :patch (shared scope with patch_apply)" do
      spec = Registry.get("patch_propose")
      # patch_propose uses :patch permission scope; ApprovalGate distinguishes
      # patch_propose from patch_apply via authorize_tool/2 muse context checks
      assert spec.permission == :patch
    end
  end

  # -- Regression: planning lifecycle still works -------------------------------

  describe "planning lifecycle regression" do
    @tag :m1_readonly
    test "Planning Muse still creates plans normally" do
      session = make_session(status: :idle)
      turn = make_turn("create a plan")

      plan_json =
        Jason.encode!(%{
          objective: "Add a feature",
          tasks: [
            %{
              title: "Write the code",
              description: "Implement the feature",
              target_files: ["lib/foo.ex"],
              requires_write: false,
              requires_shell: false
            }
          ],
          risks: ["Low risk"],
          inspected_files: ["lib/foo.ex"],
          likely_changed_files: ["lib/foo.ex"]
        })

      script = [
        {:assistant_delta, plan_json},
        {:assistant_completed, plan_json},
        {:response_completed, nil}
      ]

      opts = [
        request_options: [options: %{fake_events: script}],
        tool_runner: Muse.Tool.Runner
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      assert result.selected_muse.id == :planning
      # Plan should have been created
      assert result.session.active_plan_id != nil
      assert result.session.status == :awaiting_plan_approval
    end

    @tag :m1_readonly
    test "Planning Muse read-only tool calls still work" do
      session = make_session(status: :idle)
      turn = make_turn("list files")

      script = [
        {:tool_call, "list_files", %{"path" => "."}},
        {:assistant_delta, "Here are the files."},
        {:assistant_completed, "Here are the files."},
        {:response_completed, nil}
      ]

      opts = [
        request_options: [options: %{fake_events: script}],
        tool_runner: Muse.Tool.Runner
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      assert result.selected_muse.id == :planning
      assert result.session.status == :idle
    end
  end

  # -- ModelPreparer coding muse tool filtering ---------------------------------

  describe "ModelPreparer Coding Muse tool filtering" do
    test "Coding Muse bundle includes patch_propose tool" do
      alias Muse.Prompt.Assembler
      alias Muse.MuseRegistry

      session = make_session(status: :idle)
      muse = MuseRegistry.get(:coding)
      bundle = Assembler.build(session, muse, "implement the plan", turn_id: "test-turn")

      tool_names =
        bundle.tools
        |> Enum.map(fn t -> t[:name] || t["function"]["name"] end)

      assert "patch_propose" in tool_names
    end

    test "Planning Muse bundle does NOT include patch_propose tool" do
      alias Muse.Prompt.Assembler
      alias Muse.MuseRegistry

      session = make_session(status: :idle)
      muse = MuseRegistry.get(:planning)
      bundle = Assembler.build(session, muse, "plan the feature", turn_id: "test-turn")

      tool_names =
        bundle.tools
        |> Enum.map(fn t -> t[:name] || t["function"]["name"] end)

      refute "patch_propose" in tool_names
    end
  end
end
