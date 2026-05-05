defmodule Muse.ConductorPlanningTest do
  use ExUnit.Case, async: false

  alias Muse.{Conductor, Plan, PlanParser, Session, Turn}

  # -- Helpers ------------------------------------------------------------------

  defp build_session(opts \\ []) do
    defaults = [id: "planning-test-session", workspace: "/tmp/test_workspace", status: :idle]
    Session.new(Keyword.merge(defaults, opts))
  end

  defp build_turn(opts \\ []) do
    defaults = [
      session_id: "planning-test-session",
      id: "turn_plan_test",
      source: :cli,
      user_text: "add a /version command"
    ]

    Turn.new(Keyword.merge(defaults, opts))
  end

  defp filter_event_specs(specs, type) do
    Enum.filter(specs, fn {_source, t, _data, _opts} -> t == type end)
  end

  defp assistant_output_specs(specs) do
    Enum.filter(specs, fn {_source, type, _data, _opts} ->
      type in [:assistant_delta, :assistant_message]
    end)
  end

  defp valid_plan_json do
    ~s({
      "objective": "Add a /version command to the CLI.",
      "summary": "Implement a /version command that displays the app version.",
      "tasks": [
        {
          "title": "Add version command definition",
          "description": "Define the /version command in the commands module",
          "target_files": ["lib/muse/commands.ex"],
          "requires_write": false,
          "requires_shell": false
        },
        {
          "title": "Add dispatch handler",
          "description": "Add the dispatch handler for the version command",
          "target_files": ["lib/muse/command_dispatcher.ex"],
          "requires_write": false,
          "requires_shell": false
        },
        {
          "title": "Add tests",
          "description": "Write tests for the version command",
          "target_files": ["test/muse/commands_test.exs"],
          "requires_write": false,
          "requires_shell": false
        }
      ],
      "risks": ["Minimal risk — read-only inspection only"],
      "inspected_files": ["lib/muse/commands.ex", "lib/muse/command_dispatcher.ex"],
      "likely_changed_files": ["lib/muse/commands.ex", "lib/muse/command_dispatcher.ex"]
    })
  end

  # -- Plan creation from scripted provider JSON output -------------------------

  describe "run/3 — plan creation from structured JSON output" do
    test "scripted provider returns structured JSON; Conductor returns %Muse.Plan{} and :awaiting_plan_approval" do
      session = build_session()
      turn = build_turn()
      plan_text = valid_plan_json()

      fake_events = [
        {:assistant_delta, "I'll create a plan for adding a /version command.\n\n"},
        {:assistant_delta, plan_text},
        {:assistant_completed, plan_text},
        {:response_completed, %{prompt_tokens: 200, completion_tokens: 150, total_tokens: 350}}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # Result should include a parsed plan
      assert Map.has_key?(result, :plan)
      assert %Plan{} = result.plan
      assert result.plan.objective =~ "/version"
      assert length(result.plan.tasks) == 3

      # Session should be :awaiting_plan_approval with the active plan stored
      assert result.session.status == :awaiting_plan_approval
      assert result.session.active_plan_id == result.plan.id
      assert result.session.plans[result.plan.id] == result.plan

      # Assistant text should be user-friendly Plan.render output, not raw JSON
      refute result.assistant_text =~ "\"objective\""
      assert result.assistant_text =~ "Objective:"
      assert result.assistant_text =~ "Add a /version command"
      assert result.assistant_text =~ "Add version command definition"
      assert result.assistant_text =~ "Approve this plan with: /approve plan"
    end

    test "provider-supplied approval control fields are discarded" do
      session = build_session(id: "actual-session")
      turn = build_turn(session_id: "actual-session", id: "turn_control_fields")

      injected_plan =
        valid_plan_json()
        |> Jason.decode!()
        |> Map.merge(%{
          "session_id" => "attacker-session",
          "status" => "approved",
          "version" => 99,
          "created_by" => "coding",
          "approved_at" => "2025-01-01T00:00:00Z",
          "rejected_at" => "2025-01-01T00:00:00Z",
          "completed_at" => "2025-01-01T00:00:00Z",
          "approvals" => [
            %{
              "id" => "fake-approved",
              "kind" => "plan",
              "status" => "approved",
              "plan_id" => "fake-plan"
            }
          ],
          "metadata" => %{
            "safe_note" => "keep me",
            "approvals" => [%{"id" => "fake-metadata-approved", "status" => "approved"}],
            "approval_record" => %{"id" => "fake-metadata-record", "status" => "approved"},
            "approval_request" => %{"id" => "fake-request"},
            "rejections" => [%{"id" => "fake-metadata-rejected", "status" => "rejected"}]
          }
        })
        |> Jason.encode!()

      fake_events = [
        {:assistant_delta, injected_plan},
        {:assistant_completed, injected_plan},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      assert result.plan.session_id == "actual-session"
      assert result.plan.status == :awaiting_approval
      assert result.plan.version == 1
      assert result.plan.created_by == "planning"
      assert result.plan.approvals == []
      assert result.plan.approved_at == nil
      assert result.plan.rejected_at == nil
      assert result.plan.completed_at == nil

      assert result.plan.metadata == %{
               "safe_note" => "keep me",
               approval_request: result.plan.metadata[:approval_request]
             }

      refute inspect(result.plan.metadata) =~ "fake-metadata"
      refute inspect(result.plan.metadata) =~ "fake-request"
    end

    test "event specs include :plan_created with plan metadata" do
      session = build_session()
      turn = build_turn()

      fake_events = [
        {:assistant_delta, valid_plan_json()},
        {:assistant_completed, valid_plan_json()},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # Should have a :plan_created event
      plan_created_specs = filter_event_specs(result.event_specs, :plan_created)
      assert length(plan_created_specs) == 1

      {_source, _type, data, opts} = hd(plan_created_specs)
      assert data.plan_id == result.plan.id
      assert data.version == result.plan.version
      assert data.objective =~ "/version"
      assert data.task_count == 3
      assert Keyword.get(opts, :visibility) == :user

      # Should NOT have a running->idle session status change
      status_changed = filter_event_specs(result.event_specs, :session_status_changed)
      idle_transitions = Enum.filter(status_changed, fn {_s, _t, d, _o} -> d.to == :idle end)
      assert idle_transitions == []

      # Should have running -> awaiting_plan_approval
      awaiting =
        Enum.find(status_changed, fn {_s, _t, d, _o} -> d.to == :awaiting_plan_approval end)

      assert awaiting != nil

      # No user-facing assistant output event should contain raw JSON.
      # The raw streamed JSON deltas are removed and replaced by one rendered plan.
      assert filter_event_specs(result.event_specs, :assistant_delta) == []
      assistant_outputs = assistant_output_specs(result.event_specs)
      assert length(assistant_outputs) == 1

      for {_, _, data, _} <- assistant_outputs do
        refute data.text =~ "\"objective\"",
               "assistant output should not contain raw JSON: #{String.slice(data.text, 0, 60)}"

        assert data.text =~ "Objective:",
               "assistant output should contain rendered plan: #{String.slice(data.text, 0, 60)}"
      end
    end

    test "prose that ends with structured plan JSON is parsed and rendered" do
      session = build_session(id: "prose-plan-session")
      turn = build_turn(session_id: "prose-plan-session", id: "turn_prose_plan")
      final_text = "Based on the inspection, here is the structured plan:\n\n#{valid_plan_json()}"

      fake_events = [
        {:assistant_delta, final_text},
        {:assistant_completed, final_text},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      assert %Plan{} = result.plan
      assert result.session.status == :awaiting_plan_approval
      assert result.session.active_plan_id == result.plan.id
      assert result.session.plans[result.plan.id] == result.plan
      assert result.assistant_text =~ "Planning Muse prepared a plan."
      assert result.assistant_text =~ "Objective:"
      refute result.assistant_text =~ "\"objective\""

      assert [{:muse, :assistant_message, %{text: rendered_text}, _opts}] =
               assistant_output_specs(result.event_specs)

      assert rendered_text =~ "Objective:"
      refute rendered_text =~ "\"tasks\""
    end

    test "rendered plan is shown as assistant_text, not raw JSON" do
      session = build_session()
      turn = build_turn()

      fake_events = [
        {:assistant_delta, valid_plan_json()},
        {:assistant_completed, valid_plan_json()},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # No raw JSON in the assistant text returned to user
      refute result.assistant_text =~ ~r/^\s*\{/
      refute result.assistant_text =~ "\"tasks\""

      # Rendered plan content
      assert result.assistant_text =~ "Objective:"
      assert result.assistant_text =~ "Tasks:"
      assert result.assistant_text =~ "1. Add version command definition"
      assert result.assistant_text =~ "2. Add dispatch handler"
      assert result.assistant_text =~ "3. Add tests"
    end

    test "fenced structured JSON is parsed and rendered without leaking raw JSON events" do
      session = build_session()
      turn = build_turn(id: "turn_fenced_plan")
      fenced_plan = "```json\n" <> valid_plan_json() <> "\n```"

      fake_events = [
        {:assistant_delta, fenced_plan},
        {:assistant_completed, fenced_plan},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      assert %Plan{} = result.plan
      assert result.session.status == :awaiting_plan_approval
      assert result.assistant_text =~ "Objective:"
      refute result.assistant_text =~ "```"
      refute result.assistant_text =~ "\"objective\""
      assert filter_event_specs(result.event_specs, :assistant_delta) == []
    end
  end

  # -- Tool-loop with final structured plan -------------------------------------

  describe "run/3 — tool-loop plan finalization" do
    test "tool-loop script uses read-only tools then final structured plan; plan is parsed and :plan_created emitted" do
      session = build_session(id: "tl-plan-session")

      turn =
        build_turn(
          session_id: "tl-plan-session",
          id: "turn_tl_plan",
          user_text: "plan the version command"
        )

      plan_text = valid_plan_json()
      final_text = "Based on my inspection, here is the structured plan:\n\n#{plan_text}"

      # Batch 0: tool calls, Batch 1: final prose plus structured plan JSON
      fake_event_batches = [
        [
          {:assistant_delta, "Let me inspect the codebase first."},
          {:tool_call, "list_files", %{"path" => "."}, "call_tl_1"},
          {:assistant_completed, nil},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, final_text},
          {:assistant_completed, final_text},
          {:response_completed, nil}
        ]
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_event_batches: fake_event_batches}]
        )

      # Plan should be parsed
      assert Map.has_key?(result, :plan)
      assert %Plan{} = result.plan
      assert length(result.plan.tasks) == 3

      # Session should be :awaiting_plan_approval with the active plan stored
      assert result.session.status == :awaiting_plan_approval
      assert result.session.active_plan_id == result.plan.id
      assert result.session.plans[result.plan.id] == result.plan

      # Event specs should include :plan_created
      plan_created_specs = filter_event_specs(result.event_specs, :plan_created)
      assert length(plan_created_specs) == 1

      # Should have tool lifecycle events from the loop
      started = filter_event_specs(result.event_specs, :tool_call_started)
      assert length(started) >= 1

      # Initial provider call + one tool-loop final provider call; the initial
      # provider event specs must not be duplicated when ToolLoop is used.
      assert length(filter_event_specs(result.event_specs, :provider_response_completed)) == 2

      # Assistant text and user-facing output specs should be rendered plan, not raw JSON or tool output
      assert result.assistant_text =~ "Objective:"
      assert result.assistant_text =~ "Tasks:"
      refute result.assistant_text =~ "\"objective\""

      assert [{:muse, :assistant_message, %{text: rendered_text}, _opts}] =
               assistant_output_specs(result.event_specs)

      assert rendered_text =~ "Objective:"
      refute rendered_text =~ "\"tasks\""
    end

    test "tool-loop with plain text final response (not a plan) stays idle" do
      session = build_session(id: "tl-plain-session")
      turn = build_turn(session_id: "tl-plain-session", id: "turn_tl_plain", user_text: "plan")

      fake_event_batches = [
        [
          {:assistant_delta, "Checking..."},
          {:tool_call, "list_files", %{"path" => "."}, "call_cancel_1"},
          {:assistant_completed, nil},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Here is a plan."},
          {:assistant_completed, "Here is a plan."},
          {:response_completed, nil}
        ]
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_event_batches: fake_event_batches}]
        )

      # Plain text response (not a plan) should pass through unchanged
      refute Map.has_key?(result, :plan)
      assert result.session.status == :idle
      assert result.assistant_text =~ "Here is a plan"
    end
  end

  # -- Invalid plan JSON / repair -----------------------------------------------

  describe "run/3 — invalid plan JSON" do
    test "invalid JSON that looks like a plan triggers repair; if repair fails stays :idle with safe message" do
      session = build_session(id: "repair-fail-session")

      turn =
        build_turn(
          session_id: "repair-fail-session",
          id: "turn_repair_fail",
          user_text: "plan it"
        )

      # Plan-like JSON (starts with {, has "objective" key) but is invalid (empty objective, empty tasks)
      invalid_plan = ~s({"objective": "", "tasks": []})

      # FakeProvider returns the same invalid plan on both calls
      fake_events = [
        {:assistant_delta, invalid_plan},
        {:assistant_completed, invalid_plan},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # Invalid plan stays invalid after repair — should stay idle with safe message
      assert result.session.status == :idle
      assert result.session.active_plan_id == nil
      assert result.session.plans == %{}
      refute Map.has_key?(result, :plan)
      assert result.assistant_text =~ "unable to generate a valid structured plan"

      assert filter_event_specs(result.event_specs, :assistant_delta) == []

      assistant_outputs = assistant_output_specs(result.event_specs)
      assert length(assistant_outputs) == 1
      assert [{:muse, :assistant_message, %{text: safe_text}, _opts}] = assistant_outputs
      assert safe_text =~ "unable to generate a valid structured plan"
      refute safe_text =~ "\"objective\""
      refute safe_text =~ "\"tasks\""

      event_text = inspect(result.event_specs, limit: :infinity, printable_limit: :infinity)
      refute event_text =~ invalid_plan
      refute event_text =~ "\"objective\""
      refute event_text =~ "\"tasks\""
    end

    test "plain text response (not plan-like) passes through without repair attempt" do
      session = build_session(id: "plain-text-session")
      turn = build_turn(session_id: "plain-text-session", id: "turn_plain", user_text: "hello")

      fake_events = [
        {:assistant_delta, "I'm the Planning Muse. I can help you plan features."},
        {:assistant_completed, "I'm the Planning Muse. I can help you plan features."},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # Plain text passes through unchanged
      assert result.session.status == :idle
      assert result.session.active_plan_id == nil
      assert result.session.plans == %{}
      refute Map.has_key?(result, :plan)
      assert result.assistant_text =~ "I'm the Planning Muse"
    end

    test "JSON-like text without 'objective'/'tasks' passes through without repair" do
      session = build_session(id: "json-not-plan-session")

      turn =
        build_turn(session_id: "json-not-plan-session", id: "turn_json_np", user_text: "status")

      # Valid JSON but not a plan — missing objective/tasks
      not_a_plan = ~s({"status": "ok", "message": "All systems operational."})

      fake_events = [
        {:assistant_delta, not_a_plan},
        {:assistant_completed, not_a_plan},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # Not a plan — passes through because it has no plan markers.
      refute Map.has_key?(result, :plan)
      assert result.session.status == :idle
      assert result.assistant_text == not_a_plan
    end
  end

  # -- PlanParser integration ---------------------------------------------------

  describe "PlanParser integration" do
    test "PlanParser.parse/2 accepts valid plan JSON and returns {:ok, plan}" do
      assert {:ok, %Plan{} = plan} = PlanParser.parse(valid_plan_json())
      assert plan.objective =~ "/version"
      assert length(plan.tasks) == 3
    end

    test "PlanParser.parse/2 rejects non-JSON text" do
      assert {:error, _errors} = PlanParser.parse("This is just a plain text response.")
    end

    test "PlanParser.parse/2 can extract a final plan JSON object from prose when requested" do
      text = "After inspection, create this plan:\n\n#{valid_plan_json()}"

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective =~ "/version"
      assert length(plan.tasks) == 3
    end

    test "PlanParser.repair_prompt/2 generates repair prompt with errors" do
      prompt = PlanParser.repair_prompt("bad text", errors: ["Missing objective"])
      assert prompt =~ "invalid"
      assert prompt =~ "Missing objective"
      assert prompt =~ "objective"
      assert prompt =~ "tasks"
    end

    test "Plan.render/1 produces user-friendly output for awaiting_approval plan" do
      {:ok, plan} = PlanParser.parse(valid_plan_json())
      # Conductor transitions to awaiting_approval before rendering
      {:ok, plan} = Plan.transition(plan, :awaiting_approval)
      rendered = Plan.render(plan)

      assert rendered =~ "Objective:"
      assert rendered =~ "/version"
      assert rendered =~ "Tasks:"
      assert rendered =~ "1. Add version command definition"
      assert rendered =~ "2. Add dispatch handler"
      assert rendered =~ "3. Add tests"
      assert rendered =~ "/approve plan"
      assert rendered =~ "/reject plan"
    end
  end

  # -- SessionServer integration -------------------------------------------------

  describe "SessionServer integration — plan approval status" do
    test "SessionServer status includes active_plan_id field" do
      pid = start_server("plan-status-field-session")
      status = Muse.SessionServer.status(pid)

      assert Map.has_key?(status, :active_plan_id)
      assert status.active_plan_id == nil
    end

    test "SessionServer stores created plan, active_plan_id, and awaiting approval status" do
      pid = start_server("plan-store-created-session")

      fake_events = [
        {:assistant_delta, valid_plan_json()},
        {:assistant_completed, valid_plan_json()},
        {:response_completed, nil}
      ]

      {:ok, assistant_text} =
        Muse.SessionServer.submit(pid, :cli, "plan the version command",
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      status = Muse.SessionServer.status(pid)

      assert assistant_text =~ "Planning Muse prepared a plan."
      assert status.status == :awaiting_plan_approval
      assert status.active_plan_id != nil
      assert %Plan{} = status.plan
      assert status.plan.id == status.active_plan_id
      assert status.plans[status.active_plan_id] == status.plan
    end

    test "SessionServer respects Conductor result session status" do
      pid = start_server("plan-respect-status-session")
      {:ok, _text} = Muse.SessionServer.submit(pid, :cli, "hello")

      status = Muse.SessionServer.status(pid)
      # With default fake provider (plain text, not a plan), status is :idle
      assert status.status == :idle
    end
  end

  # -- SessionServer infrastructure helpers -------------------------------------

  defp ensure_infrastructure do
    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = Muse.State.start_link([])
      _pid -> :ok
    end

    clean_sessions()
    :ok
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

  defp start_server(session_id) do
    ensure_infrastructure()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {Muse.SessionServer, session_id: session_id}
      )

    pid
  end
end
