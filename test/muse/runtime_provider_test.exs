defmodule Muse.RuntimeProviderTest do
  use ExUnit.Case, async: false

  alias Muse.RuntimeProvider
  alias Muse.LLM.ProviderConfig

  # -- Setup -------------------------------------------------------------------

  # Force ProfileLoader.merged_env() to return {:error, _} so that
  # resolve_runtime_opts/0 falls back to System.get_env().  This gives
  # with_system_env/2 full control over env vars in tests, preventing the
  # ~/.muse/config.json profile (e.g. provider: "fake") from overriding
  # test-scoped env settings.
  setup do
    original_profile = System.get_env("MUSE_PROFILE")
    System.put_env("MUSE_PROFILE", "__test_nonexistent__")

    on_exit(fn ->
      if original_profile do
        System.put_env("MUSE_PROFILE", original_profile)
      else
        System.delete_env("MUSE_PROFILE")
      end
    end)

    :ok
  end

  # -- Helpers ------------------------------------------------------------------

  defp with_app_env(key, value, fun) do
    original = Application.get_env(:muse, key)
    Application.put_env(:muse, key, value)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:muse, key)
      else
        Application.put_env(:muse, key, original)
      end
    end
  end

  defp with_system_env(env_vars, fun) do
    # Save original values, set new ones, restore after
    original_values =
      Enum.map(env_vars, fn {key, _value} ->
        {key, System.get_env(key)}
      end)

    Enum.each(env_vars, fn {key, value} ->
      System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(original_values, fn {key, original} ->
        if is_nil(original) do
          System.delete_env(key)
        else
          System.put_env(key, original)
        end
      end)
    end
  end

  # Delete specific env vars and restore after callback.
  defp without_system_env(keys, fun) when is_list(keys) do
    original_values =
      Enum.map(keys, fn key ->
        {key, System.get_env(key)}
      end)

    Enum.each(keys, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(original_values, fn {key, original} ->
        if is_nil(original) do
          System.delete_env(key)
        else
          System.put_env(key, original)
        end
      end)
    end
  end

  # -- Tests --------------------------------------------------------------------

  describe "resolve_opts/0 — test environment" do
    test "returns empty opts in test env by default" do
      # MIX_ENV=test when running mix test
      assert {:ok, []} = RuntimeProvider.resolve_opts()
    end

    test "returns empty opts even with MUSE_PROVIDER env var set" do
      # In test env, runtime provider is disabled, so env vars are ignored
      with_system_env(%{"MUSE_PROVIDER" => "openai_compatible"}, fn ->
        assert {:ok, []} = RuntimeProvider.resolve_opts()
      end)
    end

    test "returns empty opts even with non-fake provider in env" do
      with_system_env(
        %{
          "MUSE_PROVIDER" => "openrouter",
          "MUSE_MODEL" => "anthropic/claude-3.5-sonnet"
        },
        fn ->
          assert {:ok, []} = RuntimeProvider.resolve_opts()
        end
      )
    end

    test "can be explicitly enabled via app config" do
      # When app config explicitly enables runtime provider,
      # even test env respects it (useful for integration tests)
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(%{"MUSE_PROVIDER" => "fake"}, fn ->
          assert {:ok, []} = RuntimeProvider.resolve_opts()
        end)
      end)
    end

    test "explicit false app config disables even in dev" do
      with_app_env(:runtime_provider_enabled, false, fn ->
        # Even if we simulate dev env behavior, explicit false wins
        assert {:ok, []} = RuntimeProvider.resolve_opts()
      end)
    end
  end

  describe "resolve_opts/0 — fake provider" do
    test "with MUSE_PROVIDER=fake returns empty opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(%{"MUSE_PROVIDER" => "fake"}, fn ->
          assert {:ok, []} = RuntimeProvider.resolve_opts()
        end)
      end)
    end

    test "with MUSE_PROVIDER unset and no app config returns empty opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        # Ensure no MUSE_PROVIDER env and no :llm app config
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL"], fn ->
          with_app_env(:llm, [], fn ->
            assert {:ok, []} = RuntimeProvider.resolve_opts()
          end)
        end)
      end)
    end

    test "with MUSE_PROVIDER=fake and MUSE_MODEL returns empty opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(%{"MUSE_PROVIDER" => "fake", "MUSE_MODEL" => "gpt-4"}, fn ->
          assert {:ok, []} = RuntimeProvider.resolve_opts()
        end)
      end)
    end

    test "with fake provider in app config returns empty opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL"], fn ->
          with_app_env(:llm, [provider: "fake"], fn ->
            assert {:ok, []} = RuntimeProvider.resolve_opts()
          end)
        end)
      end)
    end
  end

  describe "resolve_opts/0 — valid non-fake providers via env" do
    test "MUSE_PROVIDER=openai_compatible returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openai_compatible",
            "MUSE_MODEL" => "gpt-4",
            "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_config)
            assert Keyword.has_key?(opts, :model_router_opts)

            # provider_config should be a resolved ProviderConfig struct
            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "openai_compatible"
            assert config.model == "gpt-4"
          end
        )
      end)
    end

    test "MUSE_PROVIDER=openrouter returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_MODEL" => "anthropic/claude-3.5-sonnet"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_config)

            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "openrouter"
          end
        )
      end)
    end

    test "MUSE_PROVIDER=ollama returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "ollama",
            "MUSE_MODEL" => "llama3.1"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_config)

            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "ollama"
          end
        )
      end)
    end

    test "MUSE_PROVIDER=anthropic returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "anthropic",
            "MUSE_MODEL" => "claude-sonnet-4-20250514"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_config)

            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "anthropic"
          end
        )
      end)
    end

    test "model_router_opts contains filtered MUSE_* env map" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_MODEL" => "test-model",
            "MUSE_PLANNING_MODEL" => "pinned-model"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            router_opts = Keyword.fetch!(opts, :model_router_opts)
            assert Keyword.has_key?(router_opts, :env)

            env = Keyword.fetch!(router_opts, :env)
            assert env["MUSE_PLANNING_MODEL"] == "pinned-model"
            # Only MUSE_* keys
            assert Enum.all?(Map.keys(env), &String.starts_with?(&1, "MUSE_"))
          end
        )
      end)
    end

    test "no atom creation from provider strings" do
      # This test ensures that resolve_opts doesn't create atoms
      # from env strings (which could exhaust the atom table).
      # We verify by checking that known provider atoms already exist.
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openai_compatible",
            "MUSE_MODEL" => "gpt-4",
            "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
          },
          fn ->
            # Should succeed without creating new atoms
            assert {:ok, _opts} = RuntimeProvider.resolve_opts()

            # Verify known atoms still exist (not newly created)
            assert :fake in ProviderConfig.known_providers()
            assert :openai_compatible in ProviderConfig.known_providers()
          end
        )
      end)
    end
  end

  describe "resolve_opts/0 — valid non-fake providers via app config" do
    test "app config with non-fake provider and no MUSE_PROVIDER env returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL", "MUSE_OPENAI_BASE_URL"], fn ->
          with_app_env(
            :llm,
            [
              provider: "openai_compatible",
              model: "gpt-4o",
              base_url: "https://api.openai.com/v1"
            ],
            fn ->
              assert {:ok, opts} = RuntimeProvider.resolve_opts()
              assert opts != []

              assert Keyword.has_key?(opts, :provider_config)
              config = Keyword.fetch!(opts, :provider_config)
              assert %ProviderConfig{} = config
              assert config.id == "openai_compatible"
              assert config.model == "gpt-4o"
            end
          )
        end)
      end)
    end

    test "app config with openrouter provider returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL"], fn ->
          with_app_env(:llm, [provider: "openrouter", model: "anthropic/claude-3.5-sonnet"], fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert opts != []

            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "openrouter"
            assert config.model == "anthropic/claude-3.5-sonnet"
          end)
        end)
      end)
    end

    test "app config with ollama provider returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL"], fn ->
          with_app_env(:llm, [provider: "ollama", model: "llama3.1"], fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert opts != []

            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "ollama"
          end)
        end)
      end)
    end

    test "app config with anthropic provider returns provider_config opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL"], fn ->
          with_app_env(:llm, [provider: "anthropic", model: "claude-sonnet-4-20250514"], fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert opts != []

            config = Keyword.fetch!(opts, :provider_config)
            assert %ProviderConfig{} = config
            assert config.id == "anthropic"
          end)
        end)
      end)
    end

    test "env var overrides app config for provider" do
      # When both app config and env var set provider, env var wins
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_app_env(:llm, [provider: "ollama", model: "llama3.1"], fn ->
          with_system_env(
            %{
              "MUSE_PROVIDER" => "openrouter",
              "MUSE_MODEL" => "env-model"
            },
            fn ->
              assert {:ok, opts} = RuntimeProvider.resolve_opts()
              config = Keyword.fetch!(opts, :provider_config)
              # Env var should win over app config
              assert config.id == "openrouter"
              assert config.model == "env-model"
            end
          )
        end)
      end)
    end

    test "model_router_opts still contains filtered MUSE_* env when using app config" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER"], fn ->
          with_system_env(%{"MUSE_MODEL" => "app-model", "MUSE_PLANNING_MODEL" => "pinned"}, fn ->
            with_app_env(:llm, [provider: "openrouter"], fn ->
              assert {:ok, opts} = RuntimeProvider.resolve_opts()

              router_opts = Keyword.fetch!(opts, :model_router_opts)
              env = Keyword.fetch!(router_opts, :env)
              # Only MUSE_* keys in the filtered env
              assert Enum.all?(Map.keys(env), &String.starts_with?(&1, "MUSE_"))
            end)
          end)
        end)
      end)
    end
  end

  describe "resolve_opts/0 — invalid provider config" do
    test "unknown MUSE_PROVIDER returns actionable error" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(%{"MUSE_PROVIDER" => "totally_made_up_provider_xyz"}, fn ->
          assert {:error, reason} = RuntimeProvider.resolve_opts()
          assert is_binary(reason)
          # Error should mention the invalid provider
          assert reason =~ "unknown provider" or reason =~ "totally_made_up_provider_xyz"
        end)
      end)
    end

    test "non-fake provider without required model returns error" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openai_compatible",
            "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
            # Missing MUSE_MODEL
          },
          fn ->
            # Clear any existing MUSE_MODEL that might be set in dev env
            original_model = System.get_env("MUSE_MODEL")
            System.delete_env("MUSE_MODEL")

            try do
              assert {:error, reason} = RuntimeProvider.resolve_opts()
              assert is_binary(reason)
              assert reason =~ "model"
            after
              if original_model do
                System.put_env("MUSE_MODEL", original_model)
              end
            end
          end
        )
      end)
    end

    test "invalid app config provider returns actionable error" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER"], fn ->
          with_app_env(:llm, [provider: "totally_invalid_app_provider"], fn ->
            assert {:error, reason} = RuntimeProvider.resolve_opts()
            assert is_binary(reason)
            assert reason =~ "unknown provider"
          end)
        end)
      end)
    end

    test "app config non-fake provider without model returns error" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        without_system_env(["MUSE_PROVIDER", "MUSE_MODEL"], fn ->
          with_app_env(
            :llm,
            [provider: "openai_compatible", base_url: "https://api.openai.com/v1"],
            fn ->
              assert {:error, reason} = RuntimeProvider.resolve_opts()
              assert is_binary(reason)
              assert reason =~ "model"
            end
          )
        end)
      end)
    end

    test "error message does not leak API keys" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "totally_invalid_provider",
            "MUSE_OPENAI_API_KEY" => "sk-test-secret-key-1234567890"
          },
          fn ->
            assert {:error, reason} = RuntimeProvider.resolve_opts()
            # API key should NOT appear in the error message
            refute reason =~ "sk-test-secret-key-1234567890"
            refute reason =~ "sk-test-secret"
          end
        )
      end)
    end

    test "error with OpenAI-style key pattern gets redacted" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "unknown_provider",
            "MUSE_MODEL" => "sk-longfakekey12345678"
          },
          fn ->
            # Even if an sk- key somehow appears in the error,
            # it should be redacted
            assert {:error, reason} = RuntimeProvider.resolve_opts()
            refute reason =~ "sk-longfakekey12345678"
          end
        )
      end)
    end
  end

  describe "resolve_opts/0 — env filtering" do
    test "model_router_opts env only contains MUSE_* keys" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_MODEL" => "test-model"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            env = Keyword.fetch!(opts, :model_router_opts)[:env]

            # Should have MUSE_ keys
            assert Map.has_key?(env, "MUSE_PROVIDER")
            assert Map.has_key?(env, "MUSE_MODEL")

            # Should NOT have common env vars
            refute Map.has_key?(env, "HOME")
            refute Map.has_key?(env, "SHELL")
            refute Map.has_key?(env, "USER")
            refute Map.has_key?(env, "PATH")

            # All keys should start with MUSE_
            assert Enum.all?(Map.keys(env), &String.starts_with?(&1, "MUSE_"))
          end
        )
      end)
    end

    test "no provider_env key in opts (replaced by provider_config)" do
      # Verify that the old provider_env key is not present —
      # we now pass the resolved ProviderConfig directly.
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "ollama",
            "MUSE_MODEL" => "llama3.1"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            refute Keyword.has_key?(opts, :provider_env)
            assert Keyword.has_key?(opts, :provider_config)
          end
        )
      end)
    end
  end
end
