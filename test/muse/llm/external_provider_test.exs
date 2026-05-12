defmodule Muse.LLM.ExternalProviderTest do
  @moduledoc """
  Integration tests for real (external) LLM providers.

  These tests make actual network calls to provider APIs and require valid
  API keys configured in the environment. They are EXCLUDED from the default
  `mix test` run and must be explicitly opted-in:

      mix test --include external_provider

  ## Safety

    * These tests are tagged `@tag :external_provider` and excluded by default.
    * They NEVER run in CI or during normal `mix test`.
    * API keys are read from environment but never logged or printed.
    * Each test validates configuration before making network calls.
    * Tests are designed to be resilient to transient provider errors.

  ## Required environment variables

    * `MUSE_PROVIDER` — set to the provider to test (e.g., "openrouter")
    * `MUSE_MODEL` or provider-specific model var (e.g., `MUSE_OPENROUTER_MODEL`)
    * API key env var (e.g., `MUSE_OPENROUTER_API_KEY`)
  """

  use ExUnit.Case, async: true

  # Tag all tests in this module as external_provider — excluded by default
  @moduletag :external_provider

  alias Muse.LLM.{ProviderConfig, ProviderStatus}

  describe "provider connectivity (requires network)" do
    test "configured provider reports reachable or unreachable" do
      config = resolve_test_provider_config()

      status =
        ProviderStatus.from_config(config,
          connectivity_check?: true,
          config_source: "external_provider_test"
        )

      # Status should be :reachable or :unreachable (not :configured, since we
      # explicitly opted in to connectivity check)
      assert status.status in [:reachable, :unreachable, :ok]
    end
  end

  describe "provider config validation (requires env)" do
    test "non-fake provider config resolves and validates" do
      config = resolve_test_provider_config()
      provider = ProviderConfig.provider_atom(config)

      # If the test is running, a non-fake provider should be configured
      unless provider == :fake do
        assert config.model != nil
        assert config.base_url != nil
      end
    end
  end

  describe "/provider test command (requires network)" do
    test "dispatches :provider_test and returns reachable or unreachable status" do
      config = resolve_test_provider_config()
      context = %{provider_config: config}

      {_status, output, _effects} = Muse.CommandDispatcher.dispatch(:provider_test, nil, context)

      assert is_binary(output)
      # Output should not contain secrets regardless of outcome
      refute output =~ "sk-"
      refute output =~ "api_key"
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp resolve_test_provider_config do
    case Muse.Config.llm_provider_config(System.get_env()) do
      {:ok, config} ->
        config

      {:error, reason} ->
        safe_reason = reason |> to_string() |> Muse.Prompt.Redactor.redact_text()
        flunk("Cannot run external provider test: invalid config — #{safe_reason}")
    end
  end
end
