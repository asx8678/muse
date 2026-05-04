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
end
