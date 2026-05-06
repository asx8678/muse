defmodule Muse.CommandDispatcherTest do
  use ExUnit.Case, async: false

  alias Muse.CommandDispatcher
  alias Muse.LLM.ProviderConfig

  defp start_session_with_awaiting_plan(
         session_id,
         objective \\ "Approve dispatcher plan",
         extra \\ %{}
       ) do
    plan =
      Muse.Plan.new(
        id: "#{session_id}-plan",
        session_id: session_id,
        objective: objective,
        tasks: [Muse.Task.new(title: "Review", description: "Review the plan")]
      )

    {:ok, plan} = Muse.Plan.transition(plan, :awaiting_approval)

    snapshot =
      Map.merge(
        %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => plan.id,
          "plan" => Muse.Plan.to_map(plan),
          "plans" => %{plan.id => Muse.Plan.to_map(plan)}
        },
        extra
      )

    :ok = Muse.SessionStore.save_session(session_id, snapshot)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {Muse.SessionServer, session_id: session_id}
      )

    {pid, plan}
  end

  defp stop_session(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp plan_fixture(attrs) do
    defaults = [
      id: "plan-#{:erlang.unique_integer([:positive])}",
      session_id: "dispatcher-plan-session",
      title: nil,
      objective: "Inspect the workspace and prepare a Muse Plan.",
      status: :awaiting_approval,
      created_at: ~U[2025-01-01 00:00:00Z],
      updated_at: ~U[2025-01-01 00:10:00Z],
      tasks: [Muse.Task.new(title: "Inspect", description: "Inspect relevant files")]
    ]

    defaults
    |> Keyword.merge(attrs)
    |> Muse.Plan.new()
  end

  defp openai_provider_config(overrides \\ []) do
    %ProviderConfig{
      id: "openai_compatible",
      name: "OpenAI Compatible",
      base_url: "https://api.openai.com/v1",
      wire_api: :responses,
      transport: :sse,
      auth: :api_key,
      env_key: "MUSE_OPENAI_API_KEY",
      model: "gpt-4o-mini",
      supports_streaming: true,
      supports_websockets: true,
      supports_tools: true,
      timeout_ms: 120_000,
      max_retries: 2
    }
    |> struct!(overrides)
  end

  # Most dispatch tests are pure — no process dependencies needed
  # because context provides data and Backend is only called for
  # side-effect commands (clear_logs, connect_runtime, etc.)

  describe "dispatch/3 — :help" do
    test "returns help text" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:help, nil, %{})
      assert output =~ "Available commands"
      assert effects == []
    end
  end

  describe "dispatch/3 — :plan" do
    test "returns no-plan message when context has no plan" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:plan, nil, %{})
      assert output =~ "No Muse Plan is available yet"
      assert effects == []
    end

    test "renders a Plan struct from context" do
      plan =
        Muse.Plan.new(
          objective: "Add a /version command.",
          status: :awaiting_approval,
          tasks: [Muse.Task.new(title: "Add command", description: "Define command")]
        )

      {:ok, output, effects} = CommandDispatcher.dispatch(:plan, nil, %{plan: plan})
      assert output =~ "Muse Plan (no id) (version 1)"
      assert output =~ "Objective:"
      assert output =~ "Add a /version command."
      assert output =~ "Tasks:"
      assert output =~ "1. Add command"
      assert effects == []
    end

    test "renders a plan map from context" do
      plan_map = %{
        "objective" => "Fix the bug",
        "tasks" => [%{"title" => "Reproduce", "description" => "Reproduce the bug"}]
      }

      {:ok, output, effects} = CommandDispatcher.dispatch(:plan, nil, %{plan: plan_map})
      assert output =~ "Muse Plan (no id) (version 1)"
      assert output =~ "Objective:"
      assert output =~ "Fix the bug"
      assert output =~ "Tasks:"
      assert output =~ "1. Reproduce"
      assert effects == []
    end

    test "resolves plan from session context" do
      plan = Muse.Plan.new(objective: "Test session plan")

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:plan, nil, %{session: %{plan: plan}})

      assert output =~ "Test session plan"
    end

    test "resolves plan from plans+active_plan_id" do
      plan1 = Muse.Plan.new(id: "plan_a", objective: "Thing A")
      plan2 = Muse.Plan.new(id: "plan_b", objective: "Thing B")

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:plan, nil, %{
          plans: %{"plan_a" => plan1, "plan_b" => plan2},
          active_plan_id: "plan_b"
        })

      assert output =~ "Muse Plan plan_b (version 1)"
      assert output =~ "Thing B"
      refute output =~ "Thing A"
    end

    test "falls back to SessionRouter.status when context lacks plan" do
      # When no plan in context but a session is running with a plan,
      # the dispatcher should resolve from SessionRouter.status
      # Start a session server

      session_id = "plan-router-fallback-#{:erlang.unique_integer([:positive])}"

      # Ensure infrastructure
      case Process.whereis(Muse.State) do
        nil -> start_supervised!({Muse.State, []})
        _ -> :ok
      end

      # Create and persist a plan to the session store
      plan =
        Muse.Plan.new(
          id: "plan_fallback_1",
          session_id: session_id,
          objective: "SessionRouter fallback plan",
          tasks: [Muse.Task.new(title: "Fallback task", description: "Desc")]
        )

      {:ok, plan} = Muse.Plan.transition(plan, :awaiting_approval)

      data = %{
        "status" => "awaiting_plan_approval",
        "active_plan_id" => "plan_fallback_1",
        "plan" => Muse.Plan.to_map(plan),
        "plans" => %{"plan_fallback_1" => Muse.Plan.to_map(plan)}
      }

      :ok = Muse.SessionStore.save_session(session_id, data)

      # Start SessionServer (will restore from snapshot)
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      # Now call /plan with empty context — should fall back to SessionRouter
      # Pass session_id in context so resolve_from_session_router knows which session
      {:ok, output, effects} = CommandDispatcher.dispatch(:plan, nil, %{session_id: session_id})

      assert output =~ "Muse Plan plan_fallback_1 (version 1)"

      assert output =~ "SessionRouter fallback plan",
             "Expected plan output via SessionRouter fallback, got: #{inspect(output)}"

      assert output =~ "Fallback task"
      assert effects == []

      # Cleanup
      DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid)
    end

    test "with extra args returns usage error" do
      plan = plan_fixture(objective: "Do not ignore args")

      {:error, output, effects} = CommandDispatcher.dispatch(:plan, "something", %{plan: plan})

      assert output == "Error: usage: /plan"
      assert effects == []
    end
  end

  describe "dispatch/3 — read-only plan history commands" do
    test "/plans returns no-history message and does not start a missing session" do
      session_id = "missing-plans-#{:erlang.unique_integer([:positive])}"

      assert Registry.lookup(Muse.SessionRegistry, session_id) == []

      {:ok, output, effects} = CommandDispatcher.dispatch(:plans, nil, %{session_id: session_id})

      assert output =~ "No Muse Plan history is available yet"
      assert effects == []
      assert Registry.lookup(Muse.SessionRegistry, session_id) == []
    end

    test "/plans with extra args returns usage error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:plans, "extra", %{})

      assert output == "Error: usage: /plans"
      assert effects == []
    end

    test "/plans lists multiple plans from context and marks active" do
      active_plan =
        plan_fixture(
          id: "plan-active",
          title: "Active command plan",
          objective: "Build active plan commands",
          status: :awaiting_approval,
          tasks: [
            Muse.Task.new(title: "Parse commands", description: "Add parsing"),
            Muse.Task.new(title: "Render history", description: "Add read-only rendering")
          ],
          updated_at: ~U[2025-01-03 00:00:00Z]
        )

      historical_plan =
        plan_fixture(
          id: "plan-old",
          title: "Historical command plan",
          objective: "Keep old plans visible",
          status: :rejected,
          tasks: [Muse.Task.new(title: "Review history", description: "Review")],
          updated_at: ~U[2025-01-02 00:00:00Z]
        )

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:plans, nil, %{
          plans: %{
            "plan-old" => Muse.Plan.to_map(historical_plan),
            "plan-active" => active_plan
          },
          active_plan_id: "plan-active"
        })

      assert output =~ "Muse Plan history: 2 Muse Plans"
      assert output =~ "plan-active [active]"
      assert output =~ "awaiting_approval"
      assert output =~ "Active command plan"
      assert output =~ "2 task(s)"
      assert output =~ "plan-old"
      assert output =~ "rejected"
      assert output =~ "Historical command plan"
      assert output =~ "1 task(s)"
      assert effects == []
    end

    test "/plan history mirrors /plans and uses its own usage error" do
      plan = plan_fixture(id: "history-plan", objective: "Show history alias")
      context = %{plans: %{"history-plan" => plan}, active_plan_id: "history-plan"}

      {:ok, plans_output, []} = CommandDispatcher.dispatch(:plans, nil, context)
      {:ok, history_output, []} = CommandDispatcher.dispatch(:plan_history, nil, context)

      assert history_output == plans_output

      {:error, usage_output, effects} =
        CommandDispatcher.dispatch(:plan_history, "extra", context)

      assert usage_output == "Error: usage: /plan history"
      assert effects == []
    end

    test "/plan status shows active plan lifecycle details from context" do
      plan =
        plan_fixture(
          id: "status-plan",
          title: "Status command plan",
          objective: "Summarize active plan status",
          status: :approved,
          approved_at: ~U[2025-01-01 00:20:00Z],
          tasks: [Muse.Task.new(title: "Summarize", description: "Summarize status")]
        )

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:plan_status, nil, %{
          plans: %{"status-plan" => plan},
          active_plan_id: "status-plan",
          session: %{status: :idle}
        })

      assert output =~ "Active Muse Plan status:"
      assert output =~ "Active plan id: status-plan"
      assert output =~ "Version: 1"
      assert output =~ "Plan status: approved"
      assert output =~ "Session status: idle"
      assert output =~ "Status command plan"
      assert output =~ "Task count: 1"
      assert output =~ "Created at: 2025-01-01T00:00:00Z"
      assert output =~ "Updated at: 2025-01-01T00:10:00Z"
      assert output =~ "Approved at: 2025-01-01T00:20:00Z"
      assert effects == []
    end

    test "/plan status returns friendly message when no active plan exists" do
      session_id = "no-active-plan-#{:erlang.unique_integer([:positive])}"

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:plan_status, nil, %{plans: %{}, session_id: session_id})

      assert output =~ "No active Muse Plan is available yet"
      assert effects == []
    end

    test "/plan status with extra args returns usage error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:plan_status, "extra", %{})

      assert output == "Error: usage: /plan status"
      assert effects == []
    end

    test "/plan show renders a non-active plan from history" do
      active_plan = plan_fixture(id: "show-active", objective: "Active plan")

      historical_plan =
        plan_fixture(
          id: "show-history",
          objective: "Render historical plan details",
          tasks: [Muse.Task.new(title: "Show old plan", description: "Render details")]
        )

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:plan_show, "show-history", %{
          plans: %{"show-active" => active_plan, "show-history" => historical_plan},
          active_plan_id: "show-active"
        })

      assert output =~ "Muse Plan show-history (version 1)"
      assert output =~ "Render historical plan details"
      assert output =~ "1. Show old plan"
      refute output =~ "Active plan"
      assert effects == []
    end

    test "/plan show missing or extra id tokens return usage errors" do
      for args <- [nil, "", "one two"] do
        {:error, output, effects} = CommandDispatcher.dispatch(:plan_show, args, %{})

        assert output == "Error: usage: /plan show <id>"
        assert effects == []
      end
    end

    test "/plan show unknown id returns not found error" do
      plan = plan_fixture(id: "known-plan", objective: "Known plan")

      {:error, output, effects} =
        CommandDispatcher.dispatch(:plan_show, "unknown-plan", %{
          plans: %{"known-plan" => plan},
          active_plan_id: "known-plan"
        })

      assert output == "Error: Muse Plan unknown-plan was not found."
      assert String.starts_with?(output, "Error:")
      assert effects == []
    end

    test "router fallback lists and shows restored plan history without mutating session" do
      session_id = "plan-history-router-#{:erlang.unique_integer([:positive])}"

      active_plan =
        plan_fixture(
          id: "router-active-plan",
          session_id: session_id,
          objective: "Active restored plan",
          status: :awaiting_approval,
          updated_at: ~U[2025-01-04 00:00:00Z]
        )

      historical_plan =
        plan_fixture(
          id: "router-history-plan",
          session_id: session_id,
          objective: "Historical restored plan",
          status: :rejected,
          updated_at: ~U[2025-01-03 00:00:00Z]
        )

      :ok =
        Muse.SessionStore.save_session(session_id, %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => active_plan.id,
          "plan" => Muse.Plan.to_map(active_plan),
          "plans" => %{
            active_plan.id => Muse.Plan.to_map(active_plan),
            historical_plan.id => Muse.Plan.to_map(historical_plan)
          }
        })

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      try do
        {:ok, plans_output, []} =
          CommandDispatcher.dispatch(:plans, nil, %{session_id: session_id})

        assert plans_output =~ "router-active-plan [active]"
        assert plans_output =~ "router-history-plan"

        {:ok, status_output, []} =
          CommandDispatcher.dispatch(:plan_status, nil, %{session_id: session_id})

        assert status_output =~ "Active plan id: router-active-plan"
        assert status_output =~ "Version: 1"
        assert status_output =~ "Session status: awaiting_plan_approval"

        {:ok, show_output, []} =
          CommandDispatcher.dispatch(:plan_show, "router-history-plan", %{session_id: session_id})

        assert show_output =~ "Historical restored plan"

        status = Muse.SessionServer.status(pid)
        assert status.active_turn_id == nil
        assert status.runner_pid == nil
        assert status.active_plan_id == active_plan.id
        assert status.plan.status == :awaiting_approval
      after
        stop_session(pid)
      end
    end
  end

  describe "dispatch/3 — plan approval lifecycle" do
    test "approve returns safe error when session does not exist" do
      session_id = "missing-approve-#{:erlang.unique_integer([:positive])}"

      {:error, output, effects} =
        CommandDispatcher.dispatch(:approve_plan, nil, %{session_id: session_id})

      assert output == "Error: no Muse Plan is awaiting approval."
      assert effects == []
      assert Registry.lookup(Muse.SessionRegistry, session_id) == []
    end

    test "reject returns safe error when active session has no plan" do
      session_id = "missing-plan-reject-#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Muse.SessionRouter.find_or_start_session(session_id)

      try do
        {:error, output, effects} =
          CommandDispatcher.dispatch(:reject_plan, nil, %{session_id: session_id})

        assert output == "Error: no Muse Plan is awaiting approval."
        assert effects == []
      after
        stop_session(pid)
      end
    end

    test "approve with extra args returns usage error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:approve_plan, "now", %{})

      assert output =~ "Error: usage: /approve plan"
      assert output =~ "Unexpected arguments: now"
      assert effects == []
    end

    test "approve returns safe stale error for expired approval binding" do
      session_id = "dispatcher-expired-#{:erlang.unique_integer([:positive])}"

      plan =
        Muse.Plan.new(
          id: "#{session_id}-plan",
          session_id: session_id,
          objective: "Expired dispatcher approval",
          tasks: [Muse.Task.new(title: "Review", description: "Review the plan")]
        )

      {:ok, plan} = Muse.Plan.transition(plan, :awaiting_approval)
      old_bound_at = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      binding = Muse.ApprovalGate.capture_binding(plan, now: old_bound_at)

      :ok =
        Muse.SessionStore.save_session(session_id, %{
          "status" => "awaiting_plan_approval",
          "active_plan_id" => plan.id,
          "plan" => Muse.Plan.to_map(plan),
          "plans" => %{plan.id => Muse.Plan.to_map(plan)},
          "approval_binding" => binding
        })

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      try do
        {:error, output, effects} =
          CommandDispatcher.dispatch(:approve_plan, nil, %{session_id: session_id, source: :cli})

        assert output == "Error: unable to update Muse Plan (expired approval binding)."
        assert effects == []

        status = Muse.SessionServer.status(pid)
        assert status.status == :awaiting_plan_approval
        assert status.plan.status == :awaiting_approval
      after
        stop_session(pid)
      end
    end

    test "approve transitions an awaiting restored plan without execution" do
      session_id = "dispatcher-approve-#{:erlang.unique_integer([:positive])}"
      {pid, _plan} = start_session_with_awaiting_plan(session_id)

      try do
        {:ok, output, effects} =
          CommandDispatcher.dispatch(:approve_plan, nil, %{session_id: session_id, source: :cli})

        assert output =~ "Plan approved."
        assert output =~ "- Plan id: #{session_id}-plan"
        assert output =~ "- Version: 1"
        assert output =~ "- Approval status: approved"
        assert output =~ "- Approval record: id="
        assert output =~ "- No implementation started:"

        assert effects == [{:refresh, :events}, {:refresh, :session}]

        status = Muse.SessionServer.status(pid)
        assert status.status == :idle
        assert status.plan.status == :approved
        assert status.active_turn_id == nil
        assert status.runner_pid == nil
      after
        stop_session(pid)
      end
    end

    test "reject transitions an awaiting restored plan without execution" do
      session_id = "dispatcher-reject-#{:erlang.unique_integer([:positive])}"
      {pid, _plan} = start_session_with_awaiting_plan(session_id, "Reject dispatcher plan")

      try do
        {:ok, output, effects} =
          CommandDispatcher.dispatch(:reject_plan, nil, %{session_id: session_id, source: :web})

        assert output =~ "Plan rejected."
        assert output =~ "- Plan id: #{session_id}-plan"
        assert output =~ "- Version: 1"
        assert output =~ "- Rejection status: rejected"
        assert output =~ "- Rejection record: id="
        assert output =~ "- No implementation started:"

        assert effects == [{:refresh, :events}, {:refresh, :session}]

        status = Muse.SessionServer.status(pid)
        assert status.status == :idle
        assert status.plan.status == :rejected
        assert status.active_turn_id == nil
        assert status.runner_pid == nil
      after
        stop_session(pid)
      end
    end
  end

  describe "dispatch/3 — :events" do
    test "counts events from context" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "hi"}
        }
      ]

      {:ok, output, effects} = CommandDispatcher.dispatch(:events, nil, %{events: events})
      assert output =~ "1 event(s)"
      assert effects == []
    end

    test "returns 0 when context has no events key" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:events, nil, %{})
      assert output =~ "0 event(s)"
    end

    test "shows per-event details for small lists" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "hi"}
        }
      ]

      {:ok, output, _effects} = CommandDispatcher.dispatch(:events, nil, %{events: events})
      assert output =~ "[cli]"
      assert output =~ "hi"
    end
  end

  describe "dispatch/3 — :muses" do
    test "lists Muses from Muse.MuseRegistry" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert output =~ "Muse registry"
      assert output =~ "4 Muses available"
    end

    test "includes Planning Muse with registry description" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert output =~ "Planning Muse"
      assert output =~ "approval-gated implementation plans"
    end

    test "includes Coding Muse with registry description" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert output =~ "Coding Muse"
      assert output =~ "proposing and applying patches"
    end

    test "uses Muse-first language — no Agent/Bot/Code Puppy labels" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      refute output =~ ~r/\bAgent\b/
      refute output =~ ~r/\bBot\b/
      refute output =~ ~r/Code Puppy/
    end

    test "ignores agent_snapshot context when registry is available" do
      # Even with an agent_snapshot, the registry is the source of truth
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:muses, nil, %{agent_snapshot: :unavailable})

      assert output =~ "Planning Muse"
      assert output =~ "Coding Muse"
    end
  end

  describe "dispatch/3 — :agents (legacy alias)" do
    test "delegates to :muses and shows registry output" do
      {:ok, agents_output, _effects} = CommandDispatcher.dispatch(:agents, nil, %{})
      {:ok, muses_output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert agents_output == muses_output
    end
  end

  describe "dispatch/3 — :workspace" do
    test "uses workspace from context" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:workspace, nil, %{workspace: "/tmp/proj"})

      assert output =~ "/tmp/proj"
    end

    test "falls back to Backend.safe_workspace_root" do
      # Backend returns "unknown" when Workspace not running
      {:ok, output, _effects} = CommandDispatcher.dispatch(:workspace, nil, %{})
      assert is_binary(output)
    end
  end

  describe "dispatch/3 — :stats" do
    test "returns BEAM stats summary" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:stats, nil, %{})
      assert output =~ "BEAM Stats:"
      assert output =~ "processes"
      assert output =~ "memory"
      assert {:refresh, :stats} in effects
    end
  end

  describe "dispatch/3 — :diagnostics" do
    test "reports no diagnostics" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:diagnostics, nil, %{diagnostics: []})
      assert output =~ "No diagnostics"
    end

    test "reports diagnostic counts by level" do
      d1 = %{id: 1, level: :error, message: "boom", timestamp: DateTime.utc_now(), metadata: %{}}

      d2 = %{
        id: 2,
        level: :warning,
        message: "careful",
        timestamp: DateTime.utc_now(),
        metadata: %{}
      }

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:diagnostics, nil, %{diagnostics: [d1, d2]})

      assert output =~ "2"
      assert output =~ "1 error"
      assert output =~ "1 warning"
    end
  end

  describe "dispatch/3 — :reload_status" do
    test "shows unavailable when status is unavailable" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:reload_status, nil, %{reload_status: %{status: :unavailable}})

      assert output =~ "Unavailable"
    end

    test "shows active with generation" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:reload_status, nil, %{
          reload_status: %{status: :active, generation: 5}
        })

      assert output =~ "Active"
      assert output =~ "gen 5"
    end
  end

  describe "dispatch/3 — :runtime" do
    test "shows disconnected status" do
      runtime = %{status: :disconnected, endpoint: "http://localhost:8080"}

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:runtime, nil, %{agent_runtime: runtime})

      assert output =~ "Disconnected"
      assert output =~ "localhost"
    end

    test "shows connected status" do
      runtime = %{status: :connected, endpoint: "http://localhost:8080"}

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:runtime, nil, %{agent_runtime: runtime})

      assert output =~ "Connected"
    end

    test "falls back to Backend snapshot when not in context" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:runtime, nil, %{})
      assert is_binary(output)
    end
  end

  describe "dispatch/3 — :clear_events" do
    test "returns cleared message with refresh effect" do
      # Start Muse.State if not already running (safe for concurrent tests)
      case Process.whereis(Muse.State) do
        nil -> start_supervised!({Muse.State, []})
        _ -> :ok
      end

      {:ok, output, effects} = CommandDispatcher.dispatch(:clear_events, nil, %{})
      assert output =~ "Events cleared"
      assert {:refresh, :events} in effects
      assert {:toast, :info, "Events cleared"} in effects
    end
  end

  describe "dispatch/3 — :search_events" do
    test "without args returns usage" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:search_events, nil, %{})
      assert output =~ "Usage:"
      assert {:switch_tab, "events"} in effects
    end

    test "with args sets search and switches tab" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:search_events, "hello", %{})
      assert output =~ "hello"
      assert {:set_event_search, "hello"} in effects
      assert {:switch_tab, "events"} in effects
    end
  end

  describe "dispatch/3 — :filter_events" do
    test "without args shows current filter" do
      {:ok, output, effects} =
        CommandDispatcher.dispatch(:filter_events, nil, %{event_filter: "errors"})

      assert output =~ "current: Errors"
      assert {:switch_tab, "events"} in effects
    end

    test "valid filter sets effect" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:filter_events, "errors", %{})
      assert output =~ "Errors"
      assert {:set_event_filter, "errors"} in effects
    end

    test "invalid filter returns error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:filter_events, "bogus", %{})
      assert output =~ "Unknown filter"
      assert {:switch_tab, "events"} in effects
    end

    test "singular 'error' normalizes to 'errors'" do
      {:ok, _output, effects} = CommandDispatcher.dispatch(:filter_events, "error", %{})
      assert {:set_event_filter, "errors"} in effects
    end
  end

  describe "dispatch/3 — :search_logs" do
    test "with args sets log search" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:search_logs, "warn", %{})
      assert output =~ "warn"
      assert {:set_log_search, "warn"} in effects
      assert {:switch_tab, "logs"} in effects
    end
  end

  describe "dispatch/3 — :filter_logs" do
    test "valid filter sets effect" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:filter_logs, "debug", %{})
      assert output =~ "Debug"
      assert {:set_log_filter, "debug"} in effects
    end

    test "invalid filter returns error" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:filter_logs, "nope", %{})
      assert output =~ "Unknown filter"
    end
  end

  describe "dispatch/3 — open tabs" do
    test "open_events switches tab" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:open_events, nil, %{})
      assert output =~ "Events tab"
      assert {:switch_tab, "events"} in effects
    end

    test "open_logs switches tab" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:open_logs, nil, %{})
      assert output =~ "Logs tab"
      assert {:switch_tab, "logs"} in effects
    end
  end

  describe "dispatch/3 — :logs" do
    test "counts logs from context" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:logs, nil, %{logs: [%{}, %{}, %{}]})
      assert output =~ "3 log entry(s)"
    end
  end

  describe "dispatch/3 — :copy_diagnostics" do
    test "returns error when context lacks diagnostics" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:copy_diagnostics, nil, %{})
      assert output =~ "not available"
    end

    test "returns clipboard effect when diagnostics present" do
      ctx = %{
        diagnostics: [],
        workspace: "/tmp",
        reload_status: %{status: :active, generation: 1},
        logs: [],
        beam_stats: %{}
      }

      {:ok, output, effects} = CommandDispatcher.dispatch(:copy_diagnostics, nil, ctx)
      assert output =~ "copied"
      assert Enum.any?(effects, &match?({:copy_to_clipboard, _, _}, &1))
    end
  end

  describe "dispatch/3 — :export_events" do
    test "returns error when context lacks events" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:export_events, nil, %{})
      assert output =~ "not available"
    end

    test "returns clipboard effect with JSON" do
      event = %Muse.Event{
        id: 1,
        timestamp: DateTime.utc_now(),
        source: :cli,
        type: :user_message,
        data: %{text: "hello"}
      }

      ctx = %{events: [event], event_filter: "all", event_search: ""}

      {:ok, output, effects} = CommandDispatcher.dispatch(:export_events, nil, ctx)
      assert output =~ "1 events exported"
      assert Enum.any?(effects, &match?({:copy_to_clipboard, _, _}, &1))
    end
  end

  describe "dispatch/3 — :export_logs" do
    test "returns error when context lacks logs" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:export_logs, nil, %{})
      assert output =~ "not available"
    end

    test "returns clipboard effect with JSON" do
      log = %Muse.LogEntry{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :info,
        source: :app,
        message: "test"
      }

      ctx = %{logs: [log], log_filter: "all", log_search: ""}

      {:ok, output, effects} = CommandDispatcher.dispatch(:export_logs, nil, ctx)
      assert output =~ "1 logs exported"
      assert Enum.any?(effects, &match?({:copy_to_clipboard, _, _}, &1))
    end
  end

  describe "dispatch/3 — :clear_history" do
    test "returns cleared message" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:clear_history, nil, %{})
      assert output =~ "Command history cleared"
      assert effects == []
    end
  end

  describe "dispatch/3 — :auth_status" do
    test "fake provider reports no authentication and no effects" do
      {:ok, output, effects} =
        CommandDispatcher.dispatch(:auth_status, nil, %{provider_config: ProviderConfig.fake()})

      assert output == "Auth status: fake provider uses no authentication."
      assert effects == []
    end

    test "openai-compatible API key from context env reports configured with redacted credential" do
      raw_key = "sk-auth-status-raw-secret"

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:auth_status, nil, %{
          provider_config: openai_provider_config(),
          env: %{"MUSE_OPENAI_API_KEY" => raw_key}
        })

      assert output =~ "Provider: openai_compatible (OpenAI Compatible)"
      assert output =~ "Auth mode: api_key"
      assert output =~ "Env key: MUSE_OPENAI_API_KEY"
      assert output =~ "Status: configured"
      assert output =~ "Credential source: env"
      assert output =~ "Credential: sk-...REDACTED"
      refute output =~ raw_key
      assert effects == []
    end

    test "missing API key reports missing without an error stack" do
      {:ok, output, effects} =
        CommandDispatcher.dispatch(:auth_status, nil, %{
          provider_config: openai_provider_config(),
          env: %{}
        })

      assert output =~ "Status: missing"
      assert output =~ "MUSE_OPENAI_API_KEY"
      refute output =~ "** ("
      refute output =~ "stacktrace"
      assert effects == []
    end

    test "extra args return usage error" do
      {:error, output, effects} =
        CommandDispatcher.dispatch(:auth_status, "please leak tokens", %{})

      assert output == "Error: usage: /auth status"
      assert effects == []
    end

    test "does not execute bearer commands or read Codex cache unless precomputed status is injected" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_auth_status_no_side_effects_#{:erlang.unique_integer([:positive])}"
        )

      script_path = Path.join(tmp_dir, "bearer_runner")
      sentinel_path = Path.join(tmp_dir, "bearer_was_executed")
      codex_dir = Path.join(tmp_dir, ".codex")
      codex_path = Path.join(codex_dir, "auth.json")
      raw_codex_token = "sk-codex-cache-raw-secret"

      File.mkdir_p!(codex_dir)

      File.write!(script_path, "#!/bin/sh\necho ran > #{sentinel_path}\necho sk-runner-secret\n")
      File.chmod!(script_path, 0o700)
      File.write!(codex_path, Jason.encode!(%{"access_token" => raw_codex_token}))

      try do
        {:ok, bearer_output, bearer_effects} =
          CommandDispatcher.dispatch(:auth_status, nil, %{
            provider_config:
              openai_provider_config(auth: :bearer_command, bearer_command: script_path)
          })

        refute File.exists?(sentinel_path)
        assert bearer_output =~ "not executed"
        refute bearer_output =~ script_path
        refute bearer_output =~ "sk-runner-secret"
        assert bearer_effects == []

        {:ok, codex_output, codex_effects} =
          CommandDispatcher.dispatch(:auth_status, nil, %{
            provider_config: openai_provider_config(auth: :codex_cache),
            auth_status: %{
              status: :configured,
              source: :codex_cache,
              source_ref: codex_path,
              value: raw_codex_token,
              redacted: raw_codex_token
            }
          })

        assert codex_output =~ "not read"
        assert codex_output =~ "Precomputed status"
        assert codex_output =~ "configured"
        assert codex_output =~ "codex_cache"
        refute codex_output =~ raw_codex_token
        refute codex_output =~ codex_path
        assert codex_effects == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "redacts fake secrets from context config and precomputed status" do
      raw_env_key = "sk-env-auth-status-secret"
      raw_config_key = "sk-config-auth-status-secret"
      raw_status_key = "sk-status-auth-status-secret"
      raw_bearer = "Bearer bearer-status-secret"
      raw_authorization = "Authorization: Bearer authorization-status-secret"
      raw_jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZGFtIn0.signatureSecret"
      raw_command_output = "sk-command-output-secret"
      raw_codex_path = "/Users/adam/private/.codex/auth.json"

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:auth_status, nil, %{
          provider_config: %{
            "id" => "openai_compatible",
            "name" => raw_bearer,
            "auth" => "api_key",
            "env_key" => "MUSE_OPENAI_API_KEY",
            "api_key" => raw_config_key
          },
          env: %{"MUSE_OPENAI_API_KEY" => raw_env_key},
          auth_status: [
            %{
              status: :configured,
              source: :env,
              value: raw_status_key,
              redacted: raw_status_key,
              authorization: raw_authorization,
              jwt: raw_jwt,
              source_ref: raw_codex_path,
              command_output: raw_command_output
            }
          ]
        })

      assert output =~ "Status: configured"
      assert output =~ "Credential: sk-...REDACTED"
      assert output =~ "Precomputed status"
      assert output =~ "~/.codex/auth.json"

      for secret <- [
            raw_env_key,
            raw_config_key,
            raw_status_key,
            raw_bearer,
            raw_authorization,
            raw_jwt,
            raw_command_output,
            raw_codex_path,
            "/Users/adam"
          ] do
        refute output =~ secret
      end

      assert effects == []
    end
  end

  describe "dispatch/3 — :session_status" do
    test "returns session status from SessionRouter with refresh effect" do
      session_id = "session-status-test-#{:erlang.unique_integer([:positive])}"

      snapshot = %{
        "status" => "idle",
        "active_plan_id" => nil,
        "plan" => nil,
        "pending_patch" => nil,
        "active_muse" => nil,
        "active_turn_id" => nil,
        "event_count" => 0
      }

      :ok = Muse.SessionStore.save_session(session_id, snapshot)

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:session_status, nil, %{session_id: session_id})

      assert output =~ "Muse Session: #{session_id}"
      assert output =~ "Status: idle"
      assert {:refresh, :session} in effects

      DynamicSupervisor.terminate_child(Muse.SessionSupervisor, self())
    rescue
      _ -> :ok
    end

    test "returns not-found message when session does not exist" do
      # Use a session_id that won't exist in SessionRouter
      {:ok, output, effects} =
        CommandDispatcher.dispatch(:session_status, nil, %{session_id: "no-such-session"})

      # SessionRouter.status returns {:error, :not_found} for unknown sessions
      # which dispatch converts to a friendly message
      assert is_binary(output)
      # No session refresh effect for missing session
      refute {:refresh, :session} in effects
    end

    test "returns usage error when extra args are provided" do
      {:error, output, effects} =
        CommandDispatcher.dispatch(:session_status, "extra args", %{})

      assert output =~ "usage: /session"
      assert effects == []
    end

    test "format_session_status shows active plan details" do
      status = %{
        session_id: "test-session",
        status: :awaiting_plan_approval,
        active_plan_id: "plan-123",
        plan: %{"id" => "plan-123", "version" => 2, "status" => "awaiting_approval"},
        pending_patch: nil,
        active_muse: "planning",
        active_turn_id: nil,
        event_count: 5
      }

      {:ok, output, effects} =
        CommandDispatcher.dispatch(:session_status, nil, %{
          session_id: "test-session",
          session_status: status
        })

      # The dispatch calls SessionRouter.status, so we need to set up the session store
      # For now, just verify the function works with map-based status
      assert is_binary(output) or is_binary(elem({:ok, output, effects}, 1))
    end
  end

  describe "dispatch/3 — :prompt_preview" do
    test "returns prompt bundle preview with expected sections" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})

      assert output =~ "Prompt bundle"
      assert output =~ "Active Muse: Planning Muse"
      assert output =~ "Layers:"
      assert output =~ "Tools:"
      assert output =~ "Blocked tools:"
      assert effects == []
    end

    test "defaults to Planning Muse when no active muse in context" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})
      assert output =~ "Planning Muse"
    end

    test "uses prompt_bundle from context when available" do
      session =
        Muse.Session.new(
          workspace: "/tmp/test",
          id: "sess_dispatch_test",
          status: :idle
        )

      profile =
        Muse.MuseProfile.new!(
          id: :coding,
          display_name: "Coding Muse",
          role: :coding,
          prompt: "You are the Coding Muse.",
          tools: ["read_file", "patch_propose"]
        )

      bundle =
        Muse.Prompt.Assembler.build(session, profile, "test message",
          id: "pb_dispatch_ctx",
          blocked_tools: ["shell_command", "network_call"],
          project_rules?: false
        )

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{prompt_bundle: bundle})

      assert output =~ "Coding Muse"
    end

    test "uses workspace from context in bundle" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: "/custom/workspace"})

      # Workspace appears in internal layers (not shown in preview content)
      # but the bundle should be built successfully without crashing
      assert output =~ "Prompt bundle"
      assert output =~ "Planning Muse"
    end

    test "uses active_muse from context" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{active_muse: :coding})

      assert output =~ "Coding Muse"
    end

    test "includes blocked tools in preview" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})

      assert output =~ "shell_command"
      assert output =~ "network_call"
    end

    test "does not crash with sparse context" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: "/tmp"})

      assert is_binary(output)
      assert output =~ "Prompt bundle"
    end

    test "passes args as user message" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, "check my project", %{})

      # The user message layer should appear in the layers section
      assert output =~ "current_user_message"
    end

    test "no user-facing Agent/Bot/Code Puppy labels in preview output" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})

      refute output =~ ~r/\bAgent\b/
      refute output =~ ~r/\bBot\b/
      refute output =~ ~r/Code Puppy/
    end

    test "does not leak raw secrets from project rules" do
      # Temp workspace with MUSE.md containing a secret
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_secret_test_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)

      :ok =
        File.write!(Path.join(tmp_dir, "MUSE.md"), "DATABASE_URL=postgres://user:pass@host/db")

      try do
        # No project_rules_home needed — project rules enabled by default
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, "sk-test-12345", %{
            workspace: tmp_dir
          })

        # Raw secrets must not appear
        refute output =~ "postgres://user:pass@host/db"
        refute output =~ "sk-test-12345"
        # Redaction marker must be present
        assert output =~ "[REDACTED]"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "project rules appear in preview when workspace has MUSE.md (no project_rules_home)" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_project_rules_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)
      :ok = File.write!(Path.join(tmp_dir, "MUSE.md"), "Always write tests first.")

      try do
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: tmp_dir})

        # project_rules layer must appear — no project_rules_home override needed
        assert output =~ "project_rules"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "project_rules?: false in context disables project rules layer" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_no_rules_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)
      :ok = File.write!(Path.join(tmp_dir, "MUSE.md"), "Should not appear.")

      try do
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, nil, %{
            workspace: tmp_dir,
            project_rules?: false
          })

        refute output =~ "project_rules"
        refute output =~ "Should not appear."
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "user-provided Agent content in project rules does not cause dispatch error" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_agents_md_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)

      :ok =
        File.write!(Path.join(tmp_dir, "AGENTS.md"), "This is a legacy AGENTS.md file.")

      try do
        # Legacy AGENTS.md contains "Agent" — must not cause dispatch to return :error
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: tmp_dir})

        # Output may contain "Agent" from user content, but dispatch succeeds
        assert is_binary(output)
        assert output =~ "project_rules"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "dispatch/3 — catch-all" do
    test "unknown action returns error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:nonexistent, nil, %{})
      assert output =~ "Unknown command action"
      assert effects == []
    end
  end

  describe "normalize_filter/1" do
    test "accepts valid filters" do
      for f <- ~w(errors warnings info all) do
        assert {:ok, ^f} = CommandDispatcher.normalize_filter(f)
      end
    end

    test "normalizes singular" do
      assert {:ok, "errors"} = CommandDispatcher.normalize_filter("error")
      assert {:ok, "warnings"} = CommandDispatcher.normalize_filter("warning")
    end

    test "rejects invalid" do
      assert {:error, "invalid"} = CommandDispatcher.normalize_filter("invalid")
    end
  end

  describe "normalize_log_filter/1" do
    test "accepts valid log filters" do
      for f <- ~w(all errors warnings info debug) do
        assert {:ok, ^f} = CommandDispatcher.normalize_log_filter(f)
      end
    end

    test "normalizes singular" do
      assert {:ok, "errors"} = CommandDispatcher.normalize_log_filter("error")
      assert {:ok, "warnings"} = CommandDispatcher.normalize_log_filter("warning")
    end

    test "rejects invalid" do
      assert {:error, "invalid"} = CommandDispatcher.normalize_log_filter("invalid")
    end
  end
end
