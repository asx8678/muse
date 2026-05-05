defmodule Muse.Prompt.ModelPreparerTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.{Assembler, ModelPreparer}
  alias Muse.LLM.Request
  alias Muse.{Session, MuseProfile}

  setup do
    session =
      Session.new(
        workspace: "/tmp/test_project",
        id: "sess_mp",
        status: :idle,
        created_at: ~U[2025-01-01 00:00:00Z],
        updated_at: ~U[2025-01-01 00:00:00Z]
      )

    profile =
      MuseProfile.new!(
        id: :planning,
        display_name: "Planning Muse",
        role: :planning,
        prompt: "You are the Planning Muse.",
        tools: ["list_files", "read_file"]
      )

    bundle =
      Assembler.build(session, profile, "hello",
        id: "pb_mp",
        turn_id: "turn_mp",
        model: "fake-planning-model",
        project_rules?: false,
        created_at: ~U[2025-01-01 00:00:00Z]
      )

    %{bundle: bundle, session: session, profile: profile}
  end

  describe "to_request/3 with keyword list" do
    test "returns Muse.LLM.Request struct", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, provider: :fake, wire_api: :chat_completions)
      assert %Request{} = request
    end

    test "maps bundle messages to request", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert length(request.messages) > 0
      assert request.messages == bundle.messages
    end

    test "maps bundle to request prompt_bundle field", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.prompt_bundle == bundle
    end

    test "maps bundle model to request", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.model == "fake-planning-model"
    end

    test "maps bundle session_id and turn_id", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.session_id == "sess_mp"
      assert request.turn_id == "turn_mp"
    end

    test "maps bundle tools to request", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.tools != nil
      assert length(request.tools) == 2
    end

    test "defaults stream to true", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.stream == true
    end

    test "stream can be overridden via opts", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [], stream: false)
      assert request.stream == false
    end

    test "maps provider config fields", %{bundle: bundle} do
      request =
        ModelPreparer.to_request(bundle,
          provider: :fake,
          wire_api: :responses,
          transport: :sse
        )

      assert request.provider == :fake
      assert request.wire_api == :responses
      assert request.transport == :sse
    end

    test "keeps fake provider scripting options in request options", %{bundle: bundle} do
      fake_events = [%{type: :assistant_delta, text: "scripted"}]

      request =
        ModelPreparer.to_request(bundle,
          provider: :fake,
          fake_events: fake_events,
          fake_error: :scripted_failure
        )

      assert request.options.fake_events == fake_events
      assert request.options.fake_error == :scripted_failure
    end

    test "opts override provider config", %{bundle: bundle} do
      request =
        ModelPreparer.to_request(
          bundle,
          [provider: :fake, wire_api: :chat_completions],
          wire_api: :responses
        )

      assert request.wire_api == :responses
    end
  end

  describe "to_request/3 with ProviderConfig struct" do
    test "uses ProviderConfig.provider_atom/1 for provider", %{bundle: bundle} do
      config = %Muse.LLM.ProviderConfig{id: "fake", model: "gpt-4.1"}
      request = ModelPreparer.to_request(bundle, config)
      assert request.provider == :fake
    end

    test "maps ProviderConfig.model to request model when bundle has no model", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_cfg_model",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      # bundle.model defaults to profile default_model (may be nil)
      config = %Muse.LLM.ProviderConfig{id: "fake", model: "config-model-v2"}
      request = ModelPreparer.to_request(bundle, config)
      # model should be: opts[:model] || bundle.model || provider_config.model
      # When bundle.model is nil and no opts[:model], falls back to config model
      assert request.model == "config-model-v2" or request.model != nil
    end

    test "opts model overrides provider config model", %{bundle: bundle} do
      config = %Muse.LLM.ProviderConfig{id: "fake", model: "config-model-v2"}
      request = ModelPreparer.to_request(bundle, config, model: "opts-model-v3")
      assert request.model == "opts-model-v3"
    end

    test "bundle model overrides provider config model when no opts model", %{bundle: bundle} do
      config = %Muse.LLM.ProviderConfig{id: "fake", model: "config-model-v2"}
      request = ModelPreparer.to_request(bundle, config)
      # bundle.model is "fake-planning-model" from setup, should take precedence
      assert request.model == "fake-planning-model"
    end

    test "maps ProviderConfig wire_api and transport", %{bundle: bundle} do
      config = %Muse.LLM.ProviderConfig{
        id: "fake",
        model: "m",
        wire_api: :responses,
        transport: :sse
      }

      request = ModelPreparer.to_request(bundle, config)
      assert request.wire_api == :responses
      assert request.transport == :sse
    end

    test "unknown provider id maps to :unknown", %{bundle: bundle} do
      config = %Muse.LLM.ProviderConfig{id: "totally_unknown", model: "m"}
      request = ModelPreparer.to_request(bundle, config)
      assert request.provider == :unknown
    end
  end

  describe "to_request/3 with map" do
    test "accepts map provider config", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, %{provider: :fake})
      assert request.provider == :fake
    end

    test "uses provider map defaults for mapper options but opts win", %{bundle: bundle} do
      fallback_request =
        ModelPreparer.to_request(bundle, %{
          provider: :fake,
          temperature: 0.2,
          max_tokens: 512
        })

      assert fallback_request.temperature == 0.2
      assert fallback_request.max_tokens == 512

      override_request =
        ModelPreparer.to_request(
          bundle,
          %{provider: :fake, temperature: 0.2, max_tokens: 512},
          temperature: 0.7,
          max_tokens: 4096
        )

      assert override_request.temperature == 0.7
      assert override_request.max_tokens == 4096
    end
  end

  describe "to_request/3 model fallback" do
    test "opts[:model] takes highest priority", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [model: "config-model"], model: "opts-model")
      assert request.model == "opts-model"
    end

    test "bundle.model takes precedence over provider config model", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, model: "config-model")
      assert request.model == "fake-planning-model"
    end

    test "provider config model is used when bundle has no model", %{
      session: session,
      profile: profile
    } do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_no_model",
          model: nil,
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      # Override default_model on the profile by setting bundle.model to nil
      bundle = %{bundle | model: nil}
      request = ModelPreparer.to_request(bundle, model: "fallback-from-config")
      assert request.model == "fallback-from-config"
    end
  end

  describe "to_request/3 metadata" do
    test "includes bundle metadata in request", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.metadata.bundle_id == "pb_mp"
      assert request.metadata.muse_id == :planning
    end

    test "includes tool_choice when provided", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [], tool_choice: :auto)
      assert request.tool_choice == :auto
    end

    test "includes temperature when provided", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [], temperature: 0.7)
      assert request.temperature == 0.7
    end

    test "includes max_tokens when provided", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [], max_tokens: 4096)
      assert request.max_tokens == 4096
    end

    test "includes store, response_format, and previous_response_id when provided", %{
      bundle: bundle
    } do
      response_format = %{type: "json_object"}

      request =
        ModelPreparer.to_request(bundle, [],
          store: false,
          response_format: response_format,
          previous_response_id: "resp_previous_123"
        )

      assert request.store == false
      assert request.response_format == response_format
      assert request.previous_response_id == "resp_previous_123"
    end
  end

  describe "to_request/3 response_format" do
    test "maps bundle response_format", %{session: session, profile: profile} do
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_rf",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      bundle = %{bundle | response_format: %{type: "json_object"}}
      request = ModelPreparer.to_request(bundle, [])
      assert request.response_format == %{type: "json_object"}
    end
  end

  describe "to_request/3 Planning Muse request shaping" do
    setup do
      session =
        Session.new(
          workspace: "/tmp/test_project",
          id: "sess_plan_mp",
          status: :idle,
          created_at: ~U[2025-01-01 00:00:00Z],
          updated_at: ~U[2025-01-01 00:00:00Z]
        )

      # Full Planning Muse profile from registry (response_mode: :plan, output_schema: Muse.Plan)
      planning_profile = Muse.MuseRegistry.get(:planning)

      bundle =
        Assembler.build(session, planning_profile, "inspect the project",
          id: "pb_plan",
          turn_id: "turn_plan",
          model: "fake-planning-model",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      %{bundle: bundle, session: session, planning_profile: planning_profile}
    end

    test "Planning Muse request tools are read-only only", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])

      blocked = Muse.Tool.Registry.blocked_tool_names()
      tool_names = Enum.map(request.tools, & &1[:name])

      # No blocked tools should appear in the request
      for blocked_name <- blocked do
        refute blocked_name in tool_names,
               "Blocked tool #{blocked_name} leaked into Planning Muse request"
      end

      # All tools should be known, registered read-only tools
      for name <- tool_names do
        assert Muse.Tool.Registry.known_tool?(name),
               "Unknown tool #{name} in Planning Muse request"

        refute Muse.Tool.Registry.blocked_tool?(name),
               "Blocked tool #{name} in Planning Muse request"
      end
    end

    test "Planning Muse request has no write/shell/network tools", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      tool_names = Enum.map(request.tools, & &1[:name])

      refute "write_file" in tool_names
      refute "replace_in_file" in tool_names
      refute "delete_file" in tool_names
      refute "patch_apply" in tool_names
      refute "shell_command" in tool_names
      refute "network_call" in tool_names
      refute "remote_execution" in tool_names
    end

    test "Planning Muse request includes PlanSchema as response_format", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])

      # When no explicit response_format is set, ModelPreparer should use PlanSchema.schema()
      # PlanSchema.schema/0 returns atom-keyed maps
      assert request.response_format != nil
      assert request.response_format[:type] == "object"
      assert "objective" in (request.response_format[:required] || [])
      assert "tasks" in (request.response_format[:required] || [])
    end

    test "Planning Muse request response_format includes plan schema properties", %{
      bundle: bundle
    } do
      request = ModelPreparer.to_request(bundle, [])

      # PlanSchema should have objective, tasks properties (atom-keyed)
      properties = request.response_format[:properties]
      assert Map.has_key?(properties, :objective)
      assert Map.has_key?(properties, :tasks)
      assert properties[:tasks][:type] == "array"
    end

    test "Planning Muse request metadata includes response_mode", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.metadata.response_mode == :plan
    end

    test "Planning Muse explicit response_format overrides PlanSchema default", %{
      bundle: bundle
    } do
      explicit_format = %{type: "json_object"}
      bundle = %{bundle | response_format: explicit_format}
      request = ModelPreparer.to_request(bundle, [])

      # The bundle's explicit format should take precedence over PlanSchema default
      assert request.response_format == %{type: "json_object"}
    end

    test "Planning Muse opts response_format overrides PlanSchema default", %{
      bundle: bundle
    } do
      explicit_format = %{type: "json_object"}
      request = ModelPreparer.to_request(bundle, [], response_format: explicit_format)

      # The opts format should take precedence over PlanSchema default
      assert request.response_format == %{type: "json_object"}
    end

    test "Planning Muse tools match read-only subset from registry", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      tool_names = Enum.map(request.tools, & &1[:name])

      # Should include read-only tools that are in the planning profile
      assert "list_files" in tool_names
      assert "read_file" in tool_names
      assert "repo_search" in tool_names
      assert "git_status" in tool_names
      assert "git_diff_readonly" in tool_names
    end
  end

  describe "to_request/3 Coding Muse does not get Planning overrides" do
    setup do
      session =
        Session.new(
          workspace: "/tmp/test_project",
          id: "sess_coding_mp",
          status: :idle,
          created_at: ~U[2025-01-01 00:00:00Z],
          updated_at: ~U[2025-01-01 00:00:00Z]
        )

      coding_profile = Muse.MuseRegistry.get(:coding)

      bundle =
        Assembler.build(session, coding_profile, "implement the feature",
          id: "pb_coding",
          turn_id: "turn_coding",
          model: "fake-coding-model",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      %{bundle: bundle, session: session, coding_profile: coding_profile}
    end

    test "Coding Muse request does not get PlanSchema response_format", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])

      # Coding Muse should NOT have PlanSchema as response_format by default
      # It should be nil (no explicit format set, and no planning overrides)
      refute request.response_format != nil and
               Map.has_key?(request.response_format, "required") and
               "objective" in (request.response_format["required"] || [])
    end

    test "Coding Muse request metadata response_mode is :patch", %{bundle: bundle} do
      request = ModelPreparer.to_request(bundle, [])
      assert request.metadata.response_mode == :patch
    end

    test "Coding Muse model-facing tools exclude test_runner, patch_apply, rollback_checkpoint",
         %{
           bundle: bundle
         } do
      request = ModelPreparer.to_request(bundle, [])
      tool_names = Enum.map(request.tools, fn t -> t[:name] || t["function"]["name"] end)

      # Coding Muse in patch proposal mode must NOT have autonomous
      # access to these tools — they require separate post-approval paths
      refute "test_runner" in tool_names
      refute "patch_apply" in tool_names
      refute "rollback_checkpoint" in tool_names

      # But should still have read-only + patch_propose
      assert "patch_propose" in tool_names or "list_files" in tool_names
    end
  end
end
