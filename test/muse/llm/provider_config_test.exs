defmodule Muse.LLM.ProviderConfigTest do
  # Not async: tests mutate global env vars (MUSE_PROVIDER, MUSE_MODEL, etc.)
  # and must not run concurrently with other env-mutating tests.
  use ExUnit.Case, async: false

  alias Muse.LLM.ProviderConfig

  # ---------------------------------------------------------------------------
  # Default / Fake constructor
  # ---------------------------------------------------------------------------

  describe "default/0 and fake/0" do
    test "default/0 returns the fake provider config" do
      config = ProviderConfig.default()
      assert config.id == "fake"
      assert config.name == "Fake Provider"
      assert config.wire_api == nil
      assert config.transport == :none
      assert config.model == "fake-planning-model"
      assert config.auth == :none
      assert config.supports_streaming == true
      assert config.supports_tools == true
      assert config.timeout_ms == 120_000
      assert config.max_retries == 0
    end

    test "fake/0 returns the same config as default/0" do
      assert ProviderConfig.fake() == ProviderConfig.default()
    end

    test "fake provider has no network/auth dependencies" do
      config = ProviderConfig.fake()
      assert config.base_url == nil
      assert config.env_key == nil
      assert config.bearer_command == nil
      assert config.transport == :none
    end
  end

  # ---------------------------------------------------------------------------
  # Pure env-map loading
  # ---------------------------------------------------------------------------

  describe "load/1 and from_env/1" do
    test "default fake config succeeds from an empty env map" do
      assert {:ok, config} = ProviderConfig.load(%{})
      assert config == ProviderConfig.fake()
    end

    test "from_env/1 is a pure env-map alias for load/1" do
      env = %{"MUSE_PROVIDER" => "fake", "MUSE_MODEL" => "fake-custom-model"}

      assert ProviderConfig.from_env(env) == ProviderConfig.load(env)
      assert {:ok, config} = ProviderConfig.from_env(env)
      assert config.id == "fake"
      assert config.model == "fake-custom-model"
    end

    test "openai_compatible config succeeds with base URL and model" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini",
        "MUSE_LLM_TIMEOUT_MS" => "60000",
        "MUSE_LLM_MAX_RETRIES" => "3",
        "MUSE_OPENAI_API_KEY" => "sk-env-secret-should-not-be-stored"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.id == "openai_compatible"
      assert config.name == "OpenAI Compatible"
      assert config.base_url == "https://api.example.test/v1"
      assert config.model == "gpt-4.1-mini"
      assert config.wire_api == :responses
      assert config.transport == :sse
      assert config.auth == :api_key
      assert config.env_key == "MUSE_OPENAI_API_KEY"
      assert config.timeout_ms == 60_000
      assert config.max_retries == 3

      refute inspect(Map.from_struct(config)) =~ "sk-env-secret-should-not-be-stored"
    end

    test "unknown provider errors without creating atoms" do
      provider = "definitely_not_a_real_provider_xyz_456"

      assert {:error, {:validation_error, reason}} =
               ProviderConfig.load(%{"MUSE_PROVIDER" => provider})

      assert reason =~ "unknown provider"
      assert reason =~ provider
      assert reason =~ ":fake"
      assert reason =~ ":openai_compatible"
      assert ProviderConfig.provider_atom(%ProviderConfig{id: provider}) == :unknown

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(provider)
      end
    end

    test "invalid timeout env returns a structured clear error" do
      assert {:error, {:invalid_env, "MUSE_LLM_TIMEOUT_MS", "abc", message}} =
               ProviderConfig.load(%{"MUSE_LLM_TIMEOUT_MS" => "abc"})

      assert message =~ "integer"

      assert {:error, {:invalid_env, "MUSE_LLM_TIMEOUT_MS", "0", message}} =
               ProviderConfig.load(%{"MUSE_LLM_TIMEOUT_MS" => "0"})

      assert message =~ "positive integer"
    end

    test "invalid retries env returns a structured clear error" do
      assert {:error, {:invalid_env, "MUSE_LLM_MAX_RETRIES", "-1", message}} =
               ProviderConfig.load(%{"MUSE_LLM_MAX_RETRIES" => "-1"})

      assert message =~ "non-negative integer"
    end

    test "missing model for network provider errors" do
      assert {:error, {:validation_error, reason}} =
               ProviderConfig.load(%{
                 "MUSE_PROVIDER" => "openai_compatible",
                 "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1"
               })

      assert reason =~ "model is required"
    end

    test "missing base URL for network provider errors" do
      assert {:error, {:validation_error, reason}} =
               ProviderConfig.load(%{
                 "MUSE_PROVIDER" => "openai_compatible",
                 "MUSE_MODEL" => "gpt-4.1-mini"
               })

      assert reason =~ "base_url is required"
    end
  end

  # ---------------------------------------------------------------------------
  # Validation — fake always valid
  # ---------------------------------------------------------------------------

  describe "validate/1 — fake provider" do
    test "default fake config validates as :ok" do
      assert ProviderConfig.validate(ProviderConfig.fake()) == :ok
    end

    test "fake config validates even with unusual fields" do
      config = %{ProviderConfig.fake() | model: nil, base_url: "not-a-url"}
      assert ProviderConfig.validate(config) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Validation — non-fake providers
  # ---------------------------------------------------------------------------

  describe "validate/1 — non-fake providers" do
    setup do
      # A minimally valid non-fake config.
      # NOTE: auth/key presence is NOT validated in PR03 — the config
      # records the auth mode but does not check whether the key exists.
      %{
        valid_non_fake: %ProviderConfig{
          id: "openai_compatible",
          name: "Test",
          base_url: "https://api.openai.com/v1",
          wire_api: :responses,
          transport: :sse,
          model: "gpt-4",
          auth: :api_key,
          env_key: "TEST_KEY",
          supports_streaming: true,
          supports_websockets: false,
          supports_tools: true
        }
      }
    end

    test "valid non-fake config returns :ok", %{valid_non_fake: config} do
      assert ProviderConfig.validate(config) == :ok
    end

    test "unknown provider atom fails safely with {:error, reason}", %{valid_non_fake: config} do
      config = %{config | id: "unknown_provider"}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "unknown provider"
      assert reason =~ ":fake"
      assert reason =~ ":openai_compatible"
    end

    test "nil id maps to :unknown provider and fails safely" do
      config = %ProviderConfig{id: nil, model: "gpt-4"}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "unknown provider"
    end

    test "unknown wire_api fails safely", %{valid_non_fake: config} do
      config = %{config | wire_api: :grpc}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "unknown wire_api"
      assert reason =~ ":grpc"
      assert reason =~ ":responses"
      assert reason =~ ":chat_completions"
    end

    test "unknown transport fails safely", %{valid_non_fake: config} do
      config = %{config | transport: :grpc}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "unknown transport"
      assert reason =~ ":grpc"
      assert reason =~ ":none"
      assert reason =~ ":sse"
      assert reason =~ ":websocket"
    end

    test "nil model fails safely", %{valid_non_fake: config} do
      config = %{config | model: nil}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "model is required"
    end

    test "empty string model fails safely", %{valid_non_fake: config} do
      config = %{config | model: ""}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "model is required"
    end

    test "nil base_url fails safely for network provider (transport != :none)", %{
      valid_non_fake: config
    } do
      config = %{config | base_url: nil}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "base_url is required"
    end

    test "non-HTTP(S) base_url fails safely", %{valid_non_fake: config} do
      config = %{config | base_url: "ftp://example.com"}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "base_url must be a valid HTTP(S) URL"
    end

    test "non-positive timeout_ms fails safely", %{valid_non_fake: config} do
      config = %{config | timeout_ms: 0}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "timeout_ms must be a positive integer"
    end

    test "negative max_retries fails safely", %{valid_non_fake: config} do
      config = %{config | max_retries: -1}
      assert {:error, reason} = ProviderConfig.validate(config)
      assert reason =~ "max_retries must be a non-negative integer"
    end

    test "nil transport is valid (no network) when base_url is present" do
      config = %{
        ProviderConfig.fake()
        | id: "openai_compatible",
          model: "gpt-4",
          transport: nil,
          base_url: "https://example.com"
      }

      assert ProviderConfig.validate(config) == :ok
    end

    test "nil wire_api is valid" do
      config = %{
        ProviderConfig.fake()
        | id: "openai_compatible",
          model: "gpt-4",
          wire_api: nil,
          transport: :sse,
          base_url: "https://example.com"
      }

      assert ProviderConfig.validate(config) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Redacted inspect
  # ---------------------------------------------------------------------------

  describe "redacted_inspect/1" do
    test "redacted_inspect does not contain sk- prefixed strings" do
      config = %ProviderConfig{
        id: "openai",
        name: "OpenAI",
        env_key: "OPENAI_API_KEY",
        headers: %{authorization: "Bearer sk-test-12345"},
        model: "gpt-4",
        base_url: "https://api.openai.com/v1",
        wire_api: :responses,
        transport: :sse
      }

      safe = ProviderConfig.redacted_inspect(config)

      refute safe =~ "sk-test-12345",
             "redacted_inspect should not contain raw API key"

      # MetadataSanitizer uses "**REDACTED**" as its placeholder
      assert safe =~ "REDACTED",
             "redacted_inspect should contain a REDACTED placeholder"
    end

    test "redacted_inspect does not contain Bearer tokens" do
      config = %ProviderConfig{
        id: "test",
        headers: %{authorization: "Bearer my-secret-token-xyz"}
      }

      safe = ProviderConfig.redacted_inspect(config)

      refute safe =~ "my-secret-token-xyz",
             "redacted_inspect should not contain Bearer token value"
    end

    test "redacted_inspect does not leak api_key in headers" do
      config = %ProviderConfig{
        id: "test",
        headers: %{api_key: "sk-proj-abc123def"}
      }

      safe = ProviderConfig.redacted_inspect(config)

      refute safe =~ "sk-proj-abc123def",
             "redacted_inspect should not contain api_key value"
    end

    test "redacted/1 returns a secret-safe map" do
      config = %ProviderConfig{
        id: "test",
        base_url: "https://user:pass@example.test/v1",
        headers: %{
          "x-api-key" => "sk-header-secret-456",
          "x-request-id" => "visible-request-id",
          authorization: "Bearer sk-map-secret-123"
        }
      }

      safe = ProviderConfig.redacted(config)
      safe_text = inspect(safe, limit: :infinity)

      refute safe_text =~ "sk-map-secret-123"
      refute safe_text =~ "sk-header-secret-456"
      refute safe_text =~ "user:pass"
      assert safe_text =~ "visible-request-id"
      assert safe_text =~ "REDACTED"
    end

    test "raw inspect uses the secret-safe Inspect implementation" do
      config = %ProviderConfig{
        id: "test",
        bearer_command: "printf 'Bearer raw-bearer-secret-xyz'",
        headers: %{
          authorization: "Bearer sk-raw-inspect-secret-123",
          api_key: "sk-raw-api-key-secret-456"
        }
      }

      safe = inspect(config, limit: :infinity)

      refute safe =~ "raw-bearer-secret-xyz"
      refute safe =~ "sk-raw-inspect-secret-123"
      refute safe =~ "sk-raw-api-key-secret-456"
      assert safe =~ "#Muse.LLM.ProviderConfig<"
      assert safe =~ "REDACTED"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  describe "helper functions" do
    test "known_providers/0 returns [:fake, :openai_compatible]" do
      assert ProviderConfig.known_providers() == [:fake, :openai_compatible]
    end

    test "known_wire_apis/0 returns [:responses, :chat_completions]" do
      assert ProviderConfig.known_wire_apis() == [:responses, :chat_completions]
    end

    test "known_transports/0 returns [:none, :sse, :websocket]" do
      assert ProviderConfig.known_transports() == [:none, :sse, :websocket]
    end

    test "provider_atom/1 returns atom from string id" do
      config = %ProviderConfig{id: "fake"}
      assert ProviderConfig.provider_atom(config) == :fake
    end

    test "provider_atom/1 passes through atom ids" do
      config = %ProviderConfig{id: :fake}
      assert ProviderConfig.provider_atom(config) == :fake
    end

    test "provider_atom/1 returns :unknown for nil id" do
      config = %ProviderConfig{id: nil}
      # nil id returns :unknown to avoid atom-table issues
      assert ProviderConfig.provider_atom(config) == :unknown
    end

    test "provider_atom/1 returns :unknown for unknown string id (no atom leak)" do
      config = %ProviderConfig{id: "totally_made_up_provider_xyz"}
      assert ProviderConfig.provider_atom(config) == :unknown
    end

    test "from_env/0 with unknown MUSE_PROVIDER does not create new atoms" do
      # Set an unknown provider env var — from_env/0 should NOT call String.to_atom/1
      System.put_env("MUSE_PROVIDER", "definitely_not_a_real_provider_xyz_123")

      on_exit(fn ->
        System.delete_env("MUSE_PROVIDER")
      end)

      config = ProviderConfig.from_env()

      # The config should exist but provider_atom should return :unknown
      assert ProviderConfig.provider_atom(config) == :unknown
      assert config.id == "definitely_not_a_real_provider_xyz_123"

      # Functional verification: the unknown string must NOT have been
      # converted to an atom — String.to_existing_atom should fail for it.
      assert_raise ArgumentError, fn ->
        String.to_existing_atom("definitely_not_a_real_provider_xyz_123")
      end
    end

    test "from_env/0 with known MUSE_PROVIDER returns correct provider" do
      System.put_env("MUSE_PROVIDER", "fake")

      on_exit(fn ->
        System.delete_env("MUSE_PROVIDER")
      end)

      config = ProviderConfig.from_env()
      assert ProviderConfig.provider_atom(config) == :fake
    end

    test "from_env/0 without MUSE_PROVIDER defaults to fake" do
      System.delete_env("MUSE_PROVIDER")

      config = ProviderConfig.from_env()
      assert ProviderConfig.provider_atom(config) == :fake
    end
  end
end
