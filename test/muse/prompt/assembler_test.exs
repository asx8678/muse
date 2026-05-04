defmodule Muse.Prompt.AssemblerTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.Assembler
  alias Muse.{Session, MuseProfile}

  setup do
    session =
      Session.new(
        workspace: "/tmp/test_project",
        id: "sess_test",
        status: :idle,
        created_at: ~U[2025-01-01 00:00:00Z],
        updated_at: ~U[2025-01-01 00:00:00Z]
      )

    profile =
      MuseProfile.new!(
        id: :planning,
        display_name: "Planning Muse",
        role: :planning,
        prompt: "You are the Planning Muse. Inspect and plan.",
        tools: ["list_files", "read_file", "repo_search", "git_status"]
      )

    %{session: session, profile: profile}
  end

  describe "build/4 deterministic layer order" do
    test "produces layers in canonical priority order", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "inspect the project",
          id: "pb_test",
          turn_id: "turn_1",
          created_at: ~U[2025-01-01 00:00:00Z],
          model: "fake-planning-model",
          project_rules?: false
        )

      # Core layers should appear in deterministic order
      assert {:muse_core_invariants, 1} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:active_mode_policy, 2} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:muse_profile, 3} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:muse_identity, 4} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:workspace_policy, 5} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:approval_policy, 6} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:tool_policy, 7} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:model_requirements, 8} in Enum.map(bundle.layers, &{&1.id, &1.priority})
      assert {:current_user_message, 15} in Enum.map(bundle.layers, &{&1.id, &1.priority})

      # Priorities should be ascending
      priorities = Enum.map(bundle.layers, & &1.priority)
      assert priorities == Enum.sort(priorities)
    end

    test "skips nil layers (no project rules by default when no files exist)", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      # Should have core + mode + profile + identity + workspace + approval + tool + user
      assert length(bundle.layers) >= 8
    end

    test "includes model requirements layer when model is specified", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          model: "gpt-4.1",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert Enum.any?(bundle.layers, &(&1.id == :model_requirements))
    end

    test "omits model requirements layer when model is nil", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          model: nil,
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      refute Enum.any?(bundle.layers, &(&1.id == :model_requirements))
    end

    test "includes skills layer when skills option provided", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          skills: "Skill: always run tests after changes.",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert Enum.any?(bundle.layers, &(&1.id == :skills))
    end

    test "omits skills layer when no skills provided", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      refute Enum.any?(bundle.layers, &(&1.id == :skills))
    end

    test "includes global rules layer when provided", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          global_rules: "Global: prefer small functions.",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert Enum.any?(bundle.layers, &(&1.id == :global_rules))
    end

    test "includes recent history layer when messages provided", %{
      session: session,
      profile: profile
    } do
      recent = [
        Muse.LLM.Message.user("previous question"),
        Muse.LLM.Message.assistant("previous answer")
      ]

      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          recent_messages: recent,
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert Enum.any?(bundle.layers, &(&1.id == :recent_history))
    end
  end

  describe "build/4 core safety layer" do
    test "includes guidance-only safety statement in core layer", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      core_layer = Enum.find(bundle.layers, &(&1.id == :muse_core_invariants))
      assert core_layer.content =~ "guidance only"
      assert core_layer.content =~ "Runtime safety"
      assert core_layer.content =~ "enforced by Elixir code"
      assert core_layer.content =~ "Workspace"
      assert core_layer.content =~ "ApprovalGate"
    end
  end

  describe "build/4 messages" do
    test "builds system message from non-user layers and user message", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "inspect the project",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert length(bundle.messages) >= 2

      system_msg = Enum.find(bundle.messages, &(&1.role == :system))
      user_msg = Enum.find(bundle.messages, &(&1.role == :user))

      assert system_msg != nil
      assert user_msg != nil
      assert user_msg.content == "inspect the project"
    end

    test "system message contains core invariants content", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      system_msg = Enum.find(bundle.messages, &(&1.role == :system))
      assert system_msg.content =~ "Muse"
      assert system_msg.content =~ "guidance only"
    end
  end

  describe "build/4 bundle fields" do
    test "populates bundle with correct session and muse info", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          turn_id: "turn_1",
          model: "fake-planning-model",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert bundle.id == "pb_test"
      assert bundle.session_id == "sess_test"
      assert bundle.turn_id == "turn_1"
      assert bundle.muse_id == :planning
      assert bundle.model == "fake-planning-model"
      assert bundle.created_at == ~U[2025-01-01 00:00:00Z]
    end

    test "populates tools from profile, excluding blocked", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          blocked_tools: ["git_status"],
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      tool_names = Enum.map(bundle.tools, & &1[:name])
      assert "list_files" in tool_names
      assert "read_file" in tool_names
      refute "git_status" in tool_names
    end

    test "populates token_estimate", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert bundle.token_estimate != nil
      assert bundle.token_estimate > 0
    end

    test "stores blocked_tools in metadata", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          blocked_tools: ["shell_command", "network_call"],
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      assert bundle.metadata.blocked_tools == ["shell_command", "network_call"]
    end
  end

  describe "build/4 determinism" do
    test "same inputs produce same layer order", %{session: session, profile: profile} do
      opts = [
        id: "pb_test",
        project_rules?: false,
        created_at: ~U[2025-01-01 00:00:00Z],
        model: "fake"
      ]

      bundle1 = Assembler.build(session, profile, "hello", opts)
      bundle2 = Assembler.build(session, profile, "hello", opts)

      ids1 = Enum.map(bundle1.layers, & &1.id)
      ids2 = Enum.map(bundle2.layers, & &1.id)
      assert ids1 == ids2
    end

    test "layers are always sorted by priority after nil rejection", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_sort",
          model: "fake",
          skills: "Skill: run tests.",
          global_rules: "Global: prefer functions.",
          recent_messages: [Muse.LLM.Message.user("hi")],
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      priorities = Enum.map(bundle.layers, & &1.priority)
      assert priorities == Enum.sort(priorities)
    end
  end

  describe "build/4 memory and plan layers" do
    test "includes memory_summary layer when session has string memory", %{
      session: session,
      profile: profile
    } do
      session_with_memory = %{session | memory: "User prefers Elixir conventions."}

      bundle =
        Assembler.build(session_with_memory, profile, "hello",
          id: "pb_mem",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      memory_layer = Enum.find(bundle.layers, &(&1.id == :memory_summary))
      assert memory_layer != nil
      assert memory_layer.priority == 12
      assert memory_layer.content =~ "Elixir conventions"
      assert memory_layer.visibility == :debug_preview
    end

    test "includes memory_summary layer when session has map memory", %{
      session: session,
      profile: profile
    } do
      session_with_memory = %{session | memory: %{notes: "prefers tabs", count: 5}}

      bundle =
        Assembler.build(session_with_memory, profile, "hello",
          id: "pb_mem_map",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      memory_layer = Enum.find(bundle.layers, &(&1.id == :memory_summary))
      assert memory_layer != nil
      assert memory_layer.content =~ "notes"
    end

    test "omits memory_summary layer when session memory is nil", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_no_mem",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      refute Enum.any?(bundle.layers, &(&1.id == :memory_summary))
    end

    test "includes active_plan_state layer when session has active_plan_id", %{
      session: session,
      profile: profile
    } do
      session_with_plan = %{session | active_plan_id: "plan_42", active_task_id: "task_7"}

      bundle =
        Assembler.build(session_with_plan, profile, "hello",
          id: "pb_plan",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      plan_layer = Enum.find(bundle.layers, &(&1.id == :active_plan_state))
      assert plan_layer != nil
      assert plan_layer.priority == 13
      assert plan_layer.content =~ "plan_42"
      assert plan_layer.content =~ "task_7"
      assert plan_layer.visibility == :debug_preview
    end

    test "includes active_plan_state layer when session has only active_plan_id", %{
      session: session,
      profile: profile
    } do
      session_with_plan = %{session | active_plan_id: "plan_99"}

      bundle =
        Assembler.build(session_with_plan, profile, "hello",
          id: "pb_plan_only",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      plan_layer = Enum.find(bundle.layers, &(&1.id == :active_plan_state))
      assert plan_layer != nil
      assert plan_layer.content =~ "plan_99"
      refute plan_layer.content =~ "Active task"
    end

    test "omits active_plan_state layer when session has no plan or task", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_no_plan",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      refute Enum.any?(bundle.layers, &(&1.id == :active_plan_state))
    end
  end

  describe "build/4 no dynamic atom creation" do
    test "layer ids are compile-time atoms", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      for layer <- bundle.layers do
        assert is_atom(layer.id)
        # Verify it's a known atom, not dynamically created from user input
        assert layer.id in [
                 :muse_core_invariants,
                 :active_mode_policy,
                 :muse_profile,
                 :muse_identity,
                 :workspace_policy,
                 :approval_policy,
                 :tool_policy,
                 :model_requirements,
                 :global_rules,
                 :project_rules,
                 :skills,
                 :memory_summary,
                 :active_plan_state,
                 :recent_history,
                 :current_user_message
               ]
      end
    end

    test "no Agent/Bot/Code Puppy labels in user-facing text", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_test",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      all_content = Enum.map_join(bundle.layers, " ", & &1.content)

      refute all_content =~ ~r/\bAgent\b/i
      refute all_content =~ ~r/\bBot\b/i
      refute all_content =~ ~r/Code Puppy/i
    end
  end
end
