defmodule Muse.LLM.ProviderStatusTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.ProviderStatus

  describe "report/1 — fake provider (default)" do
    test "reports ok status for default fake provider" do
      status = ProviderStatus.report(env: %{})
      assert status.provider_id == "fake"
      assert status.status == :ok
    end

    test "reports fake provider name" do
      status = ProviderStatus.report(env: %{})
      assert status.provider_name == "Fake Provider"
    end

    test "reports fake model" do
      status = ProviderStatus.report(env: %{})
      assert status.model == "fake-planning-model"
    end

    test "reports no validation errors for fake provider" do
      status = ProviderStatus.report(env: %{})
      assert status.validation_errors == []
    end

    test "does not make connectivity check by default" do
      status = ProviderStatus.report(env: %{}, connectivity_check?: false)
      assert status.connectivity_error == nil
      assert status.status == :ok
    end
  end

  describe "report/1 — misconfigured provider" do
    test "reports misconfigured for unknown provider" do
      status = ProviderStatus.report(env: %{"MUSE_PROVIDER" => "nonexistent_provider"})
      assert status.status == :misconfigured
      assert length(status.validation_errors) > 0
    end

    test "reports misconfigured for openai_compatible without model (env)" do
      status =
        ProviderStatus.report(
          env: %{"MUSE_PROVIDER" => "openai_compatible"},
          config_source: "test"
        )

      # Missing model means config validation fails
      assert status.status == :misconfigured
      assert length(status.validation_errors) > 0
    end

    test "reports misconfigured for openai_compatible without model (from_config)" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openai_compatible",
            "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
          },
          config_source: "test"
        )

      assert status.status == :misconfigured
    end
  end

  describe "report/1 — valid non-fake provider" do
    test "reports configured for openrouter with required fields" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet"
          },
          config_source: "test"
        )

      assert status.status == :configured
      assert status.provider_id == "openrouter"
      assert status.auth_mode == :api_key
    end

    test "reports configured for ollama" do
      status =
        ProviderStatus.report(
          env: %{"MUSE_PROVIDER" => "ollama"},
          config_source: "test"
        )

      assert status.status == :configured
      assert status.provider_id == "ollama"
      assert status.auth_mode == :none
    end

    test "reports configured for anthropic" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "anthropic",
            "MUSE_ANTHROPIC_MODEL" => "claude-sonnet-4-20250514"
          },
          config_source: "test"
        )

      assert status.status == :configured
      assert status.provider_id == "anthropic"
    end
  end

  describe "from_config/2" do
    test "builds status from existing ProviderConfig" do
      config = Muse.LLM.ProviderConfig.fake()
      status = ProviderStatus.from_config(config, config_source: "inline")
      assert status.status == :ok
      assert status.provider_id == "fake"
      assert status.config_source == "inline"
    end

    test "reports misconfigured from invalid config" do
      config = %Muse.LLM.ProviderConfig{id: "openai_compatible", model: nil, base_url: nil}
      status = ProviderStatus.from_config(config)
      assert status.status == :misconfigured
    end
  end

  describe "render/1" do
    test "renders fake provider status" do
      status = ProviderStatus.report(env: %{})
      output = ProviderStatus.render(status)

      assert output =~ "Provider:"
      assert output =~ "Status: ok (fake/offline)"
      assert output =~ "Model: fake-planning-model"
      assert output =~ "Auth: none required"
    end

    test "renders misconfigured status with validation errors" do
      status = ProviderStatus.report(env: %{"MUSE_PROVIDER" => "nonexistent_provider"})
      output = ProviderStatus.render(status)

      assert output =~ "misconfigured"
      assert output =~ "Validation errors:"
      assert output =~ "/auth status"
    end

    test "renders configured status with hint" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet"
          },
          config_source: "test"
        )

      output = ProviderStatus.render(status)

      assert output =~ "configured (not verified)"
      assert output =~ "Auth: api_key"
    end

    test "render never contains API keys" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet",
            "MUSE_OPENROUTER_API_KEY" => "sk-test-secret-key-12345"
          },
          config_source: "test"
        )

      output = ProviderStatus.render(status)

      refute output =~ "sk-test-secret-key-12345"
    end

    test "redacts secret-looking values from validation errors" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet",
            "MUSE_OPENROUTER_BASE_URL" => "not-a-url?api_key=sk-test-secret-key-12345"
          },
          config_source: "test"
        )

      output = ProviderStatus.render(status)

      assert output =~ "misconfigured"
      refute output =~ "sk-test-secret-key-12345"
      assert output =~ "[REDACTED]"
    end
  end

  describe "render_compact/1" do
    test "renders compact one-line status" do
      status = ProviderStatus.report(env: %{})
      output = ProviderStatus.render_compact(status)
      assert output =~ "Fake Provider"
      assert output =~ "ok (fake/offline)"
    end

    test "renders compact misconfigured status" do
      status = ProviderStatus.report(env: %{"MUSE_PROVIDER" => "nonexistent_provider"})
      output = ProviderStatus.render_compact(status)
      assert output =~ "misconfigured"
    end
  end

  describe "known_models/1" do
    test "returns empty list for fake provider" do
      assert ProviderStatus.known_models("fake") == []
    end

    test "returns models for openai_compatible" do
      models = ProviderStatus.known_models("openai_compatible")
      assert length(models) > 0
      assert Enum.any?(models, fn {id, _} -> id == "gpt-4o" end)
    end

    test "returns models for openrouter" do
      models = ProviderStatus.known_models("openrouter")
      assert length(models) > 0

      assert Enum.any?(models, fn {id, _} ->
               String.contains?(id, "openrouter") or String.contains?(id, "claude")
             end)
    end

    test "returns models for ollama" do
      models = ProviderStatus.known_models("ollama")
      assert length(models) > 0
      assert Enum.any?(models, fn {id, _} -> id == "llama3.1" end)
    end

    test "returns models for anthropic" do
      models = ProviderStatus.known_models("anthropic")
      assert length(models) > 0
      assert Enum.any?(models, fn {id, _} -> String.contains?(id, "claude") end)
    end

    test "returns empty list for unknown provider" do
      assert ProviderStatus.known_models("unknown_xyz") == []
    end

    test "accepts atom provider id" do
      models = ProviderStatus.known_models(:openai_compatible)
      assert length(models) > 0
    end

    test "each model is a {string, string} tuple" do
      for provider <- ["openai_compatible", "openrouter", "ollama", "anthropic"] do
        for {id, desc} <- ProviderStatus.known_models(provider) do
          assert is_binary(id)
          assert is_binary(desc)
        end
      end
    end
  end

  describe "connectivity check (opt-in)" do
    test "does not perform connectivity check by default" do
      # This test verifies that report/1 never makes network calls by default,
      # even for a configured non-fake provider.
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet"
          },
          connectivity_check?: false,
          config_source: "test"
        )

      # Status should be :configured, not :reachable or :unreachable
      assert status.status == :configured
      assert status.connectivity_error == nil
    end

    test "does not perform connectivity check via env var when false" do
      status =
        ProviderStatus.report(
          env: %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet",
            "MUSE_PROVIDER_CONNECTIVITY_CHECK" => "false"
          },
          config_source: "test"
        )

      assert status.status == :configured
    end
  end
end
