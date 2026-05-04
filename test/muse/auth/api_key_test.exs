defmodule Muse.Auth.ApiKeyTest do
  # Not async: could conflict with system-env-mutating tests.
  use ExUnit.Case, async: false

  alias Muse.Auth.ApiKey
  alias Muse.Auth.Credential
  alias Muse.LLM.ProviderConfig

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp openai_config(overrides \\ []) do
    struct!(
      ProviderConfig,
      [
        id: "openai_compatible",
        name: "OpenAI Compatible",
        base_url: "https://api.openai.com/v1",
        wire_api: :responses,
        transport: :sse,
        auth: :api_key,
        env_key: "MUSE_OPENAI_API_KEY",
        model: "gpt-4o",
        supports_streaming: true,
        supports_websockets: true,
        supports_tools: true,
        timeout_ms: 120_000,
        max_retries: 2
      ] ++ overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Resolve from explicit opts[:api_key]
  # ---------------------------------------------------------------------------

  describe "resolve/2 with explicit opts[:api_key]" do
    test "resolves from explicit api_key option (highest precedence)" do
      assert {:ok, %Credential{} = cred} =
               ApiKey.resolve(openai_config(), api_key: "sk-test-secret")

      assert cred.type == :api_key
      assert cred.value == "sk-test-secret"
      assert cred.source == :provider_config
      assert cred.redacted == "sk-...REDACTED"
    end

    test "explicit api_key takes precedence over env map" do
      assert {:ok, cred} =
               ApiKey.resolve(
                 openai_config(),
                 api_key: "sk-explicit",
                 env: %{"MUSE_OPENAI_API_KEY" => "sk-from-env"}
               )

      assert cred.value == "sk-explicit"
      assert cred.source == :provider_config
    end

    test "explicit api_key takes precedence over app_config" do
      assert {:ok, cred} =
               ApiKey.resolve(
                 openai_config(),
                 api_key: "sk-explicit",
                 app_config: [api_key: "sk-from-app"]
               )

      assert cred.value == "sk-explicit"
      assert cred.source == :provider_config
    end
  end

  # ---------------------------------------------------------------------------
  # Resolve from env map
  # ---------------------------------------------------------------------------

  describe "resolve/2 with env map" do
    test "resolves from env map using provider env_key" do
      assert {:ok, cred} =
               ApiKey.resolve(
                 openai_config(),
                 env: %{"MUSE_OPENAI_API_KEY" => "sk-test-secret"},
                 system_env?: false
               )

      assert cred.value == "sk-test-secret"
      assert cred.source == :env
    end

    test "resolves from env_map alias" do
      assert {:ok, cred} =
               ApiKey.resolve(
                 openai_config(),
                 env_map: %{"MUSE_OPENAI_API_KEY" => "sk-test-secret"},
                 system_env?: false
               )

      assert cred.value == "sk-test-secret"
      assert cred.source == :env
    end

    test "resolves using custom env_key on provider config" do
      config = openai_config(env_key: "MY_CUSTOM_KEY")

      assert {:ok, cred} =
               ApiKey.resolve(config, env: %{"MY_CUSTOM_KEY" => "sk-custom"}, system_env?: false)

      assert cred.value == "sk-custom"
    end

    test "resolves with default MUSE_OPENAI_API_KEY when provider config has no env_key" do
      # A bare map provider config
      assert {:ok, cred} =
               ApiKey.resolve(
                 %{env_key: nil},
                 env_key: "MUSE_OPENAI_API_KEY",
                 env: %{"MUSE_OPENAI_API_KEY" => "sk-default-key"},
                 system_env?: false
               )

      assert cred.value == "sk-default-key"
    end
  end

  # ---------------------------------------------------------------------------
  # system_env? false prevents System.get_env use (canary)
  # ---------------------------------------------------------------------------

  describe "resolve/2 with system_env? false" do
    test "does not call System.get_env when system_env? is false" do
      # Even if MUSE_OPENAI_API_KEY is set in the real env, system_env?: false
      # must not read it. We can't easily assert it wasn't _called_, but we
      # can assert the result is an error when no other source is available.
      assert {:error, {:missing, "MUSE_OPENAI_API_KEY"}} =
               ApiKey.resolve(openai_config(), system_env?: false, env: %{}, app_config: [])
    end
  end

  # ---------------------------------------------------------------------------
  # app_config source
  # ---------------------------------------------------------------------------

  describe "resolve/2 with app_config" do
    test "resolves from app_config api_key when no higher-precedence source" do
      assert {:ok, cred} =
               ApiKey.resolve(openai_config(),
                 app_config: [api_key: "sk-app-config"],
                 system_env?: false
               )

      assert cred.value == "sk-app-config"
      assert cred.source == :app_config
    end
  end

  # ---------------------------------------------------------------------------
  # Precedence correctness
  # ---------------------------------------------------------------------------

  describe "precedence" do
    test "opts[:api_key] > env map > app_config > System.get_env" do
      # explicit > env map
      assert {:ok, cred} =
               ApiKey.resolve(openai_config(),
                 api_key: "sk-1-explicit",
                 env: %{"MUSE_OPENAI_API_KEY" => "sk-2-env"},
                 app_config: [api_key: "sk-3-app"],
                 system_env?: false
               )

      assert cred.value == "sk-1-explicit"

      # env map > app_config
      assert {:ok, cred} =
               ApiKey.resolve(openai_config(),
                 env: %{"MUSE_OPENAI_API_KEY" => "sk-2-env"},
                 app_config: [api_key: "sk-3-app"],
                 system_env?: false
               )

      assert cred.value == "sk-2-env"

      # app_config > nothing
      assert {:ok, cred} =
               ApiKey.resolve(openai_config(),
                 app_config: [api_key: "sk-3-app"],
                 system_env?: false
               )

      assert cred.value == "sk-3-app"
    end
  end

  # ---------------------------------------------------------------------------
  # Missing / empty values
  # ---------------------------------------------------------------------------

  describe "missing or empty values" do
    test "missing env key in env map returns safe error" do
      assert {:error, {:missing, "MUSE_OPENAI_API_KEY"}} =
               ApiKey.resolve(openai_config(), env: %{"OTHER_KEY" => "val"}, system_env?: false)
    end

    test "empty string in env map returns safe error" do
      assert {:error, {:empty, "system_env"}} =
               ApiKey.resolve(
                 openai_config(),
                 env: %{"MUSE_OPENAI_API_KEY" => ""},
                 system_env?: false
               )
    end

    test "whitespace-only value returns safe error" do
      assert {:error, {:empty, "system_env"}} =
               ApiKey.resolve(
                 openai_config(),
                 env: %{"MUSE_OPENAI_API_KEY" => "   "},
                 system_env?: false
               )
    end

    test "empty explicit api_key returns safe error" do
      assert {:error, {:empty, "opts[:api_key]"}} =
               ApiKey.resolve(openai_config(), api_key: "", system_env?: false)
    end

    test "no sources at all returns missing error" do
      assert {:error, {:missing, "MUSE_OPENAI_API_KEY"}} =
               ApiKey.resolve(openai_config(), system_env?: false)
    end
  end

  # ---------------------------------------------------------------------------
  # Credential inspect/status redaction
  # ---------------------------------------------------------------------------

  describe "credential redaction" do
    test "inspect never includes raw API key" do
      {:ok, cred} = ApiKey.resolve(openai_config(), api_key: "sk-test-secret")
      inspected = inspect(cred)

      assert inspected =~ "REDACTED"
      refute inspected =~ "sk-test-secret"
    end

    test "safe_map omits value field" do
      {:ok, cred} = ApiKey.resolve(openai_config(), api_key: "sk-test-secret")
      safe = Credential.safe_map(cred)

      assert Map.has_key?(safe, :type)
      assert Map.has_key?(safe, :source)
      assert Map.has_key?(safe, :redacted)
      refute Map.has_key?(safe, :value)
      refute safe.redacted =~ "sk-test-secret"
    end

    test "redacted field uses prefix pattern for long keys" do
      {:ok, cred} = ApiKey.resolve(openai_config(), api_key: "sk-proj-abcdefghijklmnop123456")
      assert cred.redacted == "sk-...REDACTED"
    end

    test "redacted field uses full redaction for short keys" do
      {:ok, cred} = ApiKey.resolve(openai_config(), api_key: "ab")
      assert cred.redacted == "***REDACTED***"
    end
  end

  # ---------------------------------------------------------------------------
  # Error messages never include values
  # ---------------------------------------------------------------------------

  describe "error safety" do
    test "error reasons are safe — no key values embedded" do
      errors = [
        ApiKey.resolve(openai_config(), api_key: "", system_env?: false),
        ApiKey.resolve(openai_config(), env: %{"MUSE_OPENAI_API_KEY" => ""}, system_env?: false),
        ApiKey.resolve(openai_config(),
          env: %{"MUSE_OPENAI_API_KEY" => "  "},
          system_env?: false
        ),
        ApiKey.resolve(openai_config(), system_env?: false)
      ]

      for {:error, reason} <- errors do
        reason_str = inspect(reason)

        refute reason_str =~ "sk-test-secret",
               "Error #{inspect(reason)} leaks secret value"
      end
    end
  end
end
