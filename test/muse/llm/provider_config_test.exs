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
  # SSE / transport / wire_api config via env
  # ---------------------------------------------------------------------------

  describe "load/1 — SSE transport and wire_api env overrides" do
    test "openai_compatible defaults to wire_api :responses and transport :sse" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :responses
      assert config.transport == :sse
      assert config.supports_streaming == true
    end

    test "MUSE_WIRE_API=chat_completions overrides wire_api for openai_compatible" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini",
        "MUSE_WIRE_API" => "chat_completions"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :chat_completions
      assert config.transport == :sse
    end

    test "MUSE_TRANSPORT=websocket overrides transport for openai_compatible" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini",
        "MUSE_TRANSPORT" => "websocket"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.transport == :websocket
      assert config.wire_api == :responses
    end

    test "MUSE_WIRE_API and MUSE_TRANSPORT both overridden together" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini",
        "MUSE_WIRE_API" => "chat_completions",
        "MUSE_TRANSPORT" => "sse"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :chat_completions
      assert config.transport == :sse
      assert config.supports_streaming == true
    end

    test "unknown MUSE_WIRE_API falls back to :responses default" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini",
        "MUSE_WIRE_API" => "grpc"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      # Unknown wire_api strings fall back to the default (:responses)
      assert config.wire_api == :responses
    end

    test "unknown MUSE_TRANSPORT falls back to :sse default" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
        "MUSE_MODEL" => "gpt-4.1-mini",
        "MUSE_TRANSPORT" => "quic"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      # Unknown transport strings fall back to the default (:sse)
      assert config.transport == :sse
    end

    test "atom value for MUSE_WIRE_API is handled by parse_wire_api" do
      # ProviderConfig.load/1 reads strings from env, but parse_wire_api
      # also accepts atoms. Verify that openai_compatible config with
      # wire_api :chat_completions + transport :sse validates OK.
      config = %ProviderConfig{
        id: "openai_compatible",
        name: "Test",
        base_url: "https://api.openai.com/v1",
        wire_api: :chat_completions,
        transport: :sse,
        model: "gpt-4",
        auth: :api_key,
        env_key: "TEST_KEY",
        supports_streaming: true,
        supports_websockets: false,
        supports_tools: true
      }

      assert ProviderConfig.validate(config) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # parse_transport/1 and parse_wire_api/1
  # ---------------------------------------------------------------------------

  describe "parse_transport/1" do
    test "parses known string values" do
      assert ProviderConfig.parse_transport("none") == :none
      assert ProviderConfig.parse_transport("sse") == :sse
      assert ProviderConfig.parse_transport("websocket") == :websocket
    end

    test "passes through known atom values" do
      assert ProviderConfig.parse_transport(:none) == :none
      assert ProviderConfig.parse_transport(:sse) == :sse
      assert ProviderConfig.parse_transport(:websocket) == :websocket
    end

    test "returns nil for unknown strings" do
      assert ProviderConfig.parse_transport("grpc") == nil
      assert ProviderConfig.parse_transport("http2") == nil
      assert ProviderConfig.parse_transport("") == nil
    end

    test "returns nil for unknown atoms" do
      assert ProviderConfig.parse_transport(:grpc) == nil
      assert ProviderConfig.parse_transport(:http2) == nil
    end

    test "returns nil for nil input" do
      assert ProviderConfig.parse_transport(nil) == nil
    end

    test "never creates new atoms — unknown string stays a string" do
      unknown = "totally_not_a_transport_xyz"
      assert ProviderConfig.parse_transport(unknown) == nil

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(unknown)
      end
    end
  end

  describe "parse_wire_api/1" do
    test "parses known string values" do
      assert ProviderConfig.parse_wire_api("responses") == :responses
      assert ProviderConfig.parse_wire_api("chat_completions") == :chat_completions
    end

    test "passes through known atom values" do
      assert ProviderConfig.parse_wire_api(:responses) == :responses
      assert ProviderConfig.parse_wire_api(:chat_completions) == :chat_completions
    end

    test "returns nil for unknown strings" do
      assert ProviderConfig.parse_wire_api("grpc") == nil
      assert ProviderConfig.parse_wire_api("") == nil
    end

    test "returns nil for unknown atoms" do
      assert ProviderConfig.parse_wire_api(:grpc) == nil
    end

    test "returns nil for nil input" do
      assert ProviderConfig.parse_wire_api(nil) == nil
    end

    test "never creates new atoms — unknown string stays a string" do
      unknown = "totally_not_a_wire_api_xyz"
      assert ProviderConfig.parse_wire_api(unknown) == nil

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(unknown)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # OpenRouter provider
  # ---------------------------------------------------------------------------

  describe "load/1 — openrouter provider" do
    test "openrouter config succeeds with model" do
      env = %{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_MODEL" => "anthropic/claude-3.5-sonnet"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.id == "openrouter"
      assert config.name == "OpenRouter"
      assert config.base_url == "https://openrouter.ai/api/v1"
      assert config.wire_api == :chat_completions
      assert config.transport == :sse
      assert config.auth == :api_key
      assert config.env_key == "MUSE_OPENROUTER_API_KEY"
      assert config.model == "anthropic/claude-3.5-sonnet"
      assert config.supports_streaming == true
      assert config.supports_websockets == false
      assert config.supports_tools == true
    end

    test "openrouter model from MUSE_OPENROUTER_MODEL" do
      env = %{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_OPENROUTER_MODEL" => "google/gemini-pro"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.model == "google/gemini-pro"
    end

    test "MUSE_MODEL takes precedence over MUSE_OPENROUTER_MODEL" do
      env = %{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_MODEL" => "anthropic/claude-3.5-sonnet",
        "MUSE_OPENROUTER_MODEL" => "google/gemini-pro"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.model == "anthropic/claude-3.5-sonnet"
    end

    test "openrouter without model returns validation error" do
      env = %{"MUSE_PROVIDER" => "openrouter"}

      assert {:error, {:validation_error, reason}} = ProviderConfig.load(env)
      assert reason =~ "model is required"
    end

    test "MUSE_OPENROUTER_BASE_URL overrides default base URL" do
      env = %{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_MODEL" => "test-model",
        "MUSE_OPENROUTER_BASE_URL" => "https://custom.openrouter.test/api/v1"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.base_url == "https://custom.openrouter.test/api/v1"
    end

    test "MUSE_WIRE_API and MUSE_TRANSPORT override defaults" do
      env = %{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_MODEL" => "test-model",
        "MUSE_WIRE_API" => "responses",
        "MUSE_TRANSPORT" => "websocket"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :responses
      assert config.transport == :websocket
    end
  end

  # ---------------------------------------------------------------------------
  # Ollama provider
  # ---------------------------------------------------------------------------

  describe "load/1 — ollama provider" do
    test "ollama config succeeds with default model llama3.1" do
      env = %{"MUSE_PROVIDER" => "ollama"}

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.id == "ollama"
      assert config.name == "Ollama"
      assert config.base_url == "http://127.0.0.1:11434/v1"
      assert config.wire_api == :chat_completions
      assert config.transport == :sse
      assert config.auth == :none
      assert config.model == "llama3.1"
      assert config.supports_streaming == true
      assert config.supports_websockets == false
      assert config.supports_tools == true
    end

    test "ollama model from MUSE_OLLAMA_MODEL" do
      env = %{
        "MUSE_PROVIDER" => "ollama",
        "MUSE_OLLAMA_MODEL" => "codellama"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.model == "codellama"
    end

    test "MUSE_MODEL takes precedence over MUSE_OLLAMA_MODEL" do
      env = %{
        "MUSE_PROVIDER" => "ollama",
        "MUSE_MODEL" => "mistral",
        "MUSE_OLLAMA_MODEL" => "codellama"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.model == "mistral"
    end

    test "MUSE_OLLAMA_BASE_URL overrides default base URL" do
      env = %{
        "MUSE_PROVIDER" => "ollama",
        "MUSE_OLLAMA_BASE_URL" => "http://ollama-host:11434/v1"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.base_url == "http://ollama-host:11434/v1"
    end

    test "ollama has no auth (no API key needed)" do
      env = %{"MUSE_PROVIDER" => "ollama"}

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.auth == :none
      assert config.env_key == nil
    end

    test "ollama MUSE_WIRE_API and MUSE_TRANSPORT overrides" do
      env = %{
        "MUSE_PROVIDER" => "ollama",
        "MUSE_WIRE_API" => "responses",
        "MUSE_TRANSPORT" => "none"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :responses
      assert config.transport == :none
    end
  end

  # ---------------------------------------------------------------------------
  # Anthropic provider
  # ---------------------------------------------------------------------------

  describe "load/1 — anthropic provider" do
    test "anthropic config succeeds with model" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "claude-sonnet-4-20250514"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.id == "anthropic"
      assert config.name == "Anthropic"
      assert config.base_url == "https://api.anthropic.com/v1"
      assert config.wire_api == :anthropic_messages
      assert config.transport == :none
      assert config.auth == :api_key
      assert config.env_key == "MUSE_ANTHROPIC_API_KEY"
      assert config.model == "claude-sonnet-4-20250514"
      assert config.supports_streaming == true
      assert config.supports_websockets == false
      assert config.supports_tools == true
    end

    test "anthropic model from MUSE_ANTHROPIC_MODEL" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_ANTHROPIC_MODEL" => "claude-haiku-4-20250414"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.model == "claude-haiku-4-20250414"
    end

    test "MUSE_MODEL takes precedence over MUSE_ANTHROPIC_MODEL" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "claude-sonnet-4-20250514",
        "MUSE_ANTHROPIC_MODEL" => "claude-haiku-4-20250414"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.model == "claude-sonnet-4-20250514"
    end

    test "anthropic without model returns validation error" do
      env = %{"MUSE_PROVIDER" => "anthropic"}

      assert {:error, {:validation_error, reason}} = ProviderConfig.load(env)
      assert reason =~ "model is required"
    end

    test "MUSE_ANTHROPIC_BASE_URL overrides default base URL" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "claude-sonnet-4-20250514",
        "MUSE_ANTHROPIC_BASE_URL" => "https://custom.anthropic.test/v1"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.base_url == "https://custom.anthropic.test/v1"
    end

    test "anthropic wire_api defaults to :anthropic_messages" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "claude-sonnet-4-20250514"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :anthropic_messages
    end

    test "MUSE_WIRE_API can override anthropic wire_api" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "claude-sonnet-4-20250514",
        "MUSE_WIRE_API" => "chat_completions"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.wire_api == :chat_completions
    end

    test "anthropic transport defaults to :none" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "claude-sonnet-4-20250514"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.transport == :none
    end
  end

  # ---------------------------------------------------------------------------
  # parse_wire_api with anthropic_messages
  # ---------------------------------------------------------------------------

  describe "parse_wire_api/1 — anthropic_messages" do
    test "parses string \"anthropic_messages\"" do
      assert ProviderConfig.parse_wire_api("anthropic_messages") == :anthropic_messages
    end

    test "passes through atom :anthropic_messages" do
      assert ProviderConfig.parse_wire_api(:anthropic_messages) == :anthropic_messages
    end
  end

  # ---------------------------------------------------------------------------
  # API key env values not stored/leaked
  # ---------------------------------------------------------------------------

  describe "API key safety for new providers" do
    test "openrouter does not store API key value in config" do
      env = %{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_MODEL" => "test-model",
        "MUSE_OPENROUTER_API_KEY" => "sk-or-secret-should-not-appear"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.env_key == "MUSE_OPENROUTER_API_KEY"
      refute inspect(Map.from_struct(config)) =~ "sk-or-secret-should-not-appear"
    end

    test "anthropic does not store API key value in config" do
      env = %{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_MODEL" => "test-model",
        "MUSE_ANTHROPIC_API_KEY" => "sk-ant-secret-should-not-appear"
      }

      assert {:ok, config} = ProviderConfig.load(env)
      assert config.env_key == "MUSE_ANTHROPIC_API_KEY"
      refute inspect(Map.from_struct(config)) =~ "sk-ant-secret-should-not-appear"
    end

    test "redacted_inspect does not leak API keys for openrouter" do
      config = %ProviderConfig{
        id: "openrouter",
        name: "OpenRouter",
        env_key: "MUSE_OPENROUTER_API_KEY",
        headers: %{"Authorization" => "Bearer sk-or-redacted-test"}
      }

      safe = ProviderConfig.redacted_inspect(config)
      refute safe =~ "sk-or-redacted-test"
      assert safe =~ "REDACTED"
    end

    test "redacted_inspect does not leak API keys for anthropic" do
      config = %ProviderConfig{
        id: "anthropic",
        name: "Anthropic",
        env_key: "MUSE_ANTHROPIC_API_KEY",
        headers: %{"x-api-key" => "sk-ant-redacted-test"}
      }

      safe = ProviderConfig.redacted_inspect(config)
      refute safe =~ "sk-ant-redacted-test"
      assert safe =~ "REDACTED"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  describe "helper functions" do
    test "known_providers/0 returns all known provider atoms" do
      assert :fake in ProviderConfig.known_providers()
      assert :openai_compatible in ProviderConfig.known_providers()
      assert :openrouter in ProviderConfig.known_providers()
      assert :ollama in ProviderConfig.known_providers()
      assert :anthropic in ProviderConfig.known_providers()
    end

    test "known_wire_apis/0 returns all known wire API atoms" do
      assert :responses in ProviderConfig.known_wire_apis()
      assert :chat_completions in ProviderConfig.known_wire_apis()
      assert :anthropic_messages in ProviderConfig.known_wire_apis()
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

  # ---------------------------------------------------------------------------
  # Structured outputs support
  # ---------------------------------------------------------------------------

  describe "supports_structured_outputs/1" do
    test "defaults to true when nil" do
      config = ProviderConfig.fake()
      assert config.supports_structured_outputs == nil
      assert ProviderConfig.supports_structured_outputs?(config) == true
    end

    test "returns false when explicitly set to false" do
      config = %{ProviderConfig.fake() | supports_structured_outputs: false}
      assert ProviderConfig.supports_structured_outputs?(config) == false
    end

    test "returns true when explicitly set to true" do
      config = %{ProviderConfig.fake() | supports_structured_outputs: true}
      assert ProviderConfig.supports_structured_outputs?(config) == true
    end
  end

  describe "parse_structured_outputs/1" do
    test "parses 'true' string to true" do
      assert ProviderConfig.parse_structured_outputs("true") == true
    end

    test "parses 'false' string to false" do
      assert ProviderConfig.parse_structured_outputs("false") == false
    end

    test "passes through boolean true" do
      assert ProviderConfig.parse_structured_outputs(true) == true
    end

    test "passes through boolean false" do
      assert ProviderConfig.parse_structured_outputs(false) == false
    end

    test "returns nil for nil" do
      assert ProviderConfig.parse_structured_outputs(nil) == nil
    end

    test "returns nil for unrecognized strings" do
      assert ProviderConfig.parse_structured_outputs("maybe") == nil
    end
  end

  describe "MUSE_STRUCTURED_OUTPUTS env var" do
    test "load/1 respects MUSE_STRUCTURED_OUTPUTS=false" do
      assert {:ok, config} =
               ProviderConfig.load(%{
                 "MUSE_PROVIDER" => "openai_compatible",
                 "MUSE_MODEL" => "gpt-4.1",
                 "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
                 "MUSE_STRUCTURED_OUTPUTS" => "false"
               })

      assert config.supports_structured_outputs == false
      assert ProviderConfig.supports_structured_outputs?(config) == false
    end

    test "load/1 respects MUSE_STRUCTURED_OUTPUTS=true" do
      assert {:ok, config} =
               ProviderConfig.load(%{
                 "MUSE_PROVIDER" => "openai_compatible",
                 "MUSE_MODEL" => "gpt-4.1",
                 "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
                 "MUSE_STRUCTURED_OUTPUTS" => "true"
               })

      assert config.supports_structured_outputs == true
      assert ProviderConfig.supports_structured_outputs?(config) == true
    end

    test "load/1 defaults to nil when MUSE_STRUCTURED_OUTPUTS is unset" do
      assert {:ok, config} =
               ProviderConfig.load(%{
                 "MUSE_PROVIDER" => "openai_compatible",
                 "MUSE_MODEL" => "gpt-4.1",
                 "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1"
               })

      assert config.supports_structured_outputs == nil
      assert ProviderConfig.supports_structured_outputs?(config) == true
    end

    test "load/1 ignores invalid MUSE_STRUCTURED_OUTPUTS value" do
      assert {:ok, config} =
               ProviderConfig.load(%{
                 "MUSE_PROVIDER" => "openai_compatible",
                 "MUSE_MODEL" => "gpt-4.1",
                 "MUSE_OPENAI_BASE_URL" => "https://api.example.test/v1",
                 "MUSE_STRUCTURED_OUTPUTS" => "maybe"
               })

      # Invalid values are ignored — stays nil (defaults to true)
      assert config.supports_structured_outputs == nil
    end
  end
end
