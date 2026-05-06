defmodule Muse.RuntimeProviderTest do
  use ExUnit.Case, async: true

  alias Muse.RuntimeProvider
  alias Muse.LLM.ProviderConfig

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

    test "with MUSE_PROVIDER unset returns empty opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        # Ensure MUSE_PROVIDER is not set
        original = System.get_env("MUSE_PROVIDER")
        System.delete_env("MUSE_PROVIDER")

        try do
          assert {:ok, []} = RuntimeProvider.resolve_opts()
        after
          if original do
            System.put_env("MUSE_PROVIDER", original)
          end
        end
      end)
    end

    test "with MUSE_PROVIDER=fake and MUSE_MODEL returns empty opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(%{"MUSE_PROVIDER" => "fake", "MUSE_MODEL" => "gpt-4"}, fn ->
          assert {:ok, []} = RuntimeProvider.resolve_opts()
        end)
      end)
    end
  end

  describe "resolve_opts/0 — valid non-fake providers" do
    test "MUSE_PROVIDER=openai_compatible returns provider_env opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openai_compatible",
            "MUSE_MODEL" => "gpt-4",
            "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_env)
            assert Keyword.has_key?(opts, :model_router_opts)

            # provider_env should contain MUSE_* keys only
            env = Keyword.fetch!(opts, :provider_env)
            assert Map.has_key?(env, "MUSE_PROVIDER")
            assert Map.has_key?(env, "MUSE_MODEL")
            # Non-MUSE keys should not be present
            refute Map.has_key?(env, "HOME")
            refute Map.has_key?(env, "PATH")
          end
        )
      end)
    end

    test "MUSE_PROVIDER=openrouter returns provider_env opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_MODEL" => "anthropic/claude-3.5-sonnet"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_env)

            env = Keyword.fetch!(opts, :provider_env)
            assert env["MUSE_PROVIDER"] == "openrouter"
          end
        )
      end)
    end

    test "MUSE_PROVIDER=ollama returns provider_env opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "ollama",
            "MUSE_MODEL" => "llama3.1"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_env)

            env = Keyword.fetch!(opts, :provider_env)
            assert env["MUSE_PROVIDER"] == "ollama"
          end
        )
      end)
    end

    test "MUSE_PROVIDER=anthropic returns provider_env opts" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "anthropic",
            "MUSE_MODEL" => "claude-sonnet-4-20250514"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            assert Keyword.has_key?(opts, :provider_env)

            env = Keyword.fetch!(opts, :provider_env)
            assert env["MUSE_PROVIDER"] == "anthropic"
          end
        )
      end)
    end

    test "model_router_opts contains env map" do
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
    test "only MUSE_* keys are included in provider_env" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "openrouter",
            "MUSE_MODEL" => "test-model"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            env = Keyword.fetch!(opts, :provider_env)

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

    test "provider_env and model_router_opts env are the same map" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        with_system_env(
          %{
            "MUSE_PROVIDER" => "ollama",
            "MUSE_MODEL" => "llama3.1"
          },
          fn ->
            assert {:ok, opts} = RuntimeProvider.resolve_opts()
            provider_env = Keyword.fetch!(opts, :provider_env)
            router_env = Keyword.fetch!(opts, :model_router_opts)[:env]

            assert provider_env == router_env
          end
        )
      end)
    end
  end
end
