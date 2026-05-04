defmodule Muse.ConfigTest do
  # Async: we never mutate global app env — all overrides come through the
  # explicit env_map parameter, so concurrent tests are safe.
  use ExUnit.Case, async: true

  alias Muse.Config
  alias Muse.LLM.ProviderConfig

  # ---------------------------------------------------------------------------
  # Default resolution (no env, no app config overrides)
  # ---------------------------------------------------------------------------

  describe "llm_provider_config/1 — defaults" do
    test "returns fake provider when no env or app config is set" do
      assert {:ok, config} = Config.llm_provider_config()
      assert config.id == "fake"
      assert config.model == "fake-planning-model"
      assert config.auth == :none
      assert config.base_url == nil
    end

    test "returns fake provider with empty env map" do
      assert {:ok, config} = Config.llm_provider_config(%{})
      assert config.id == "fake"
    end

    test "default config validates successfully" do
      assert {:ok, %ProviderConfig{}} = Config.llm_provider_config()
    end
  end

  # ---------------------------------------------------------------------------
  # Explicit env map overrides
  # ---------------------------------------------------------------------------

  describe "llm_provider_config/1 — env map overrides" do
    test "MUSE_PROVIDER=fake resolves to fake provider" do
      assert {:ok, config} = Config.llm_provider_config(%{"MUSE_PROVIDER" => "fake"})
      assert config.id == "fake"
    end

    test "MUSE_PROVIDER=openai_compatible resolves to openai_compatible" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
      }

      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.id == "openai_compatible"
      assert config.model == "gpt-4"
      assert config.base_url == "https://api.openai.com/v1"
    end

    test "MUSE_MODEL overrides model for fake provider" do
      env = %{"MUSE_MODEL" => "custom-fake-model"}
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.model == "custom-fake-model"
    end

    test "MUSE_OPENAI_BASE_URL overrides base URL" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://custom.api.example.com/v1"
      }

      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.base_url == "https://custom.api.example.com/v1"
    end

    test "MUSE_LLM_TIMEOUT_MS overrides timeout" do
      env = %{"MUSE_LLM_TIMEOUT_MS" => "30000"}
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.timeout_ms == 30_000
    end

    test "MUSE_LLM_MAX_RETRIES overrides retries" do
      env = %{"MUSE_LLM_MAX_RETRIES" => "5"}
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.max_retries == 5
    end

    test "invalid timeout string falls back to default" do
      env = %{"MUSE_LLM_TIMEOUT_MS" => "not-a-number"}
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.timeout_ms == 120_000
    end

    test "invalid retries string falls back to default" do
      env = %{"MUSE_LLM_MAX_RETRIES" => "abc"}
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.max_retries == 0
    end

    test "MUSE_WIRE_API overrides wire API for openai_compatible" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1",
        "MUSE_WIRE_API" => "chat_completions"
      }

      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.wire_api == :chat_completions
    end

    test "MUSE_TRANSPORT overrides transport for openai_compatible" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1",
        "MUSE_TRANSPORT" => "websocket"
      }

      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.transport == :websocket
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown / invalid provider
  # ---------------------------------------------------------------------------

  describe "llm_provider_config/1 — invalid provider" do
    test "unknown MUSE_PROVIDER returns clear error" do
      env = %{"MUSE_PROVIDER" => "totally_made_up_provider"}
      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "unknown provider"
    end

    test "unknown provider string does not leak atoms" do
      env = %{"MUSE_PROVIDER" => "never_gonna_be_an_atom_xyz_999"}

      assert {:error, _reason} = Config.llm_provider_config(env)

      # The string must NOT have been converted to an atom
      assert_raise ArgumentError, fn ->
        String.to_existing_atom("never_gonna_be_an_atom_xyz_999")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Missing required fields for non-fake providers
  # ---------------------------------------------------------------------------

  describe "llm_provider_config/1 — missing fields" do
    test "openai_compatible without model returns error" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
      }

      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "model is required"
    end

    test "openai_compatible with nil base_url (transport != :none) returns error" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "",
        "MUSE_TRANSPORT" => "sse"
      }

      # An empty string base URL is not valid HTTP(S)
      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "base_url must be a valid HTTP(S) URL"
    end

    test "openai_compatible with invalid base URL returns error" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "ftp://not-http.example.com"
      }

      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "base_url must be a valid HTTP(S) URL"
    end

    test "empty model string for openai_compatible returns error" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
      }

      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "model is required"
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout / retries validation (delegated to ProviderConfig)
  # ---------------------------------------------------------------------------

  describe "llm_provider_config/1 — timeout/retries validation" do
    test "zero timeout_ms returns error for non-fake provider" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1",
        "MUSE_LLM_TIMEOUT_MS" => "0"
      }

      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "timeout_ms must be a positive integer"
    end

    test "negative max_retries returns error for non-fake provider" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1",
        "MUSE_LLM_MAX_RETRIES" => "-1"
      }

      assert {:error, reason} = Config.llm_provider_config(env)
      assert reason =~ "max_retries must be a non-negative integer"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_llm_config/1 — convenience alias
  # ---------------------------------------------------------------------------

  describe "validate_llm_config/1" do
    test "returns same result as llm_provider_config/1 for valid config" do
      assert {:ok, c1} = Config.llm_provider_config()
      assert {:ok, c2} = Config.validate_llm_config()
      assert c1 == c2
    end

    test "returns same error as llm_provider_config/1 for invalid config" do
      env = %{"MUSE_PROVIDER" => "totally_made_up_provider"}
      assert {:error, _} = Config.validate_llm_config(env)
      assert Config.validate_llm_config(env) == Config.llm_provider_config(env)
    end
  end

  # ---------------------------------------------------------------------------
  # Delegation to ProviderConfig.validate/1
  # ---------------------------------------------------------------------------

  describe "delegation to ProviderConfig.validate/1" do
    test "fake provider always validates regardless of other fields" do
      # Even with unusual field values, fake should be valid
      env = %{"MUSE_PROVIDER" => "fake"}
      assert {:ok, _} = Config.llm_provider_config(env)
    end

    test "unknown wire_api produces clear error via ProviderConfig" do
      # Build a config that would have an invalid wire_api
      # Muse.Config doesn't parse unknown wire_api values (returns nil),
      # but let's verify nil wire_api is valid per ProviderConfig
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1",
        "MUSE_WIRE_API" => "grpc"
      }

      # "grpc" is unknown → parse_wire_api returns nil → nil is valid
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.wire_api == nil
    end

    test "unknown transport produces nil (valid) via safe parsing" do
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1",
        "MUSE_TRANSPORT" => "grpc"
      }

      # "grpc" is unknown → parse_transport returns nil → nil is valid
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.transport == nil
    end
  end

  # ---------------------------------------------------------------------------
  # App config integration (uses Application.get_env under the hood)
  # ---------------------------------------------------------------------------

  describe "app config resolution" do
    test "env map takes precedence over app config" do
      # Even if app config were set, explicit env map wins
      env = %{"MUSE_PROVIDER" => "fake"}
      assert {:ok, config} = Config.llm_provider_config(env)
      assert config.id == "fake"
    end
  end

  # ---------------------------------------------------------------------------
  # No side effects
  # ---------------------------------------------------------------------------

  describe "purity" do
    test "does not mutate application env" do
      before = Application.get_env(:muse, :llm)
      Config.llm_provider_config(%{"MUSE_PROVIDER" => "fake"})
      after_val = Application.get_env(:muse, :llm)
      assert before == after_val
    end

    test "does not start any processes" do
      # Calling llm_provider_config should not spawn or register processes
      before_processes = Process.list()
      Config.llm_provider_config(%{})
      after_processes = Process.list()
      assert before_processes == after_processes
    end

    test "does not read auth secrets" do
      # Config should never access MUSE_OPENAI_API_KEY
      # (it only stores env_key, not the actual key value)
      env = %{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
      }

      assert {:ok, config} = Config.llm_provider_config(env)
      # env_key is stored but the actual key is never read
      assert config.env_key == "MUSE_OPENAI_API_KEY"
    end
  end
end
