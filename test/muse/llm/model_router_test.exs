defmodule Muse.LLM.ModelRouterTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{ModelRouter, ProviderConfig}

  describe "resolve/3 — no pins" do
    test "returns base config unchanged when opts is empty" do
      config = ProviderConfig.fake()
      assert {:ok, ^config} = ModelRouter.resolve(:planning, config, [])
    end

    test "returns base config unchanged when opts have no matching pins" do
      config = ProviderConfig.fake()

      assert {:ok, ^config} =
               ModelRouter.resolve(:planning, config, model_pins: %{coding: "other-model"})
    end

    test "accepts empty keyword opts" do
      config = ProviderConfig.fake()

      assert {:ok, ^config} =
               ModelRouter.resolve(:planning, config, model_pins: %{}, provider_pins: %{})
    end
  end

  describe "resolve/3 — model pins with explicit opts" do
    test "atom muse id with matching model_pins key overrides model" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve(:planning, config, model_pins: %{planning: "planner-model"})

      assert result.model == "planner-model"
      # Other fields unchanged
      assert result.id == config.id
    end

    test "string muse id with matching model_pins key overrides model" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve("planning", config, model_pins: %{"planning" => "planner-model"})

      assert result.model == "planner-model"
    end

    test "atom key matches when string id is passed" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve("planning", config, model_pins: %{planning: "planner-model"})

      assert result.model == "planner-model"
    end

    test "string key matches when atom id is passed" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve(:planning, config, model_pins: %{"planning" => "planner-model"})

      assert result.model == "planner-model"
    end

    test "different muse IDs get different pinned models" do
      config = ProviderConfig.fake()

      {:ok, planning} =
        ModelRouter.resolve(:planning, config,
          model_pins: %{planning: "planner-model", coding: "coder-model"}
        )

      {:ok, coding} =
        ModelRouter.resolve(:coding, config,
          model_pins: %{planning: "planner-model", coding: "coder-model"}
        )

      assert planning.model == "planner-model"
      assert coding.model == "coder-model"
    end

    test "unknown model pin keys are ignored safely" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve(:planning, config, model_pins: %{unknown_muse: "ignored"})

      assert result.model == config.model
    end

    test "accepts MuseProfile struct" do
      config = ProviderConfig.fake()

      profile = %Muse.MuseProfile{
        id: :planning,
        display_name: "Test",
        role: :planning,
        prompt: "test",
        tools: []
      }

      {:ok, result} =
        ModelRouter.resolve(profile, config, model_pins: %{planning: "profile-pinned"})

      assert result.model == "profile-pinned"
    end

    test "nil model_pins value does not crash" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, model_pins: %{planning: nil})
      assert result.model == config.model
    end

    test "non-map model_pins is ignored" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, model_pins: "not-a-map")
      assert result.model == config.model
    end
  end

  describe "resolve/3 — env map model pins" do
    test "env map with matching var name overrides model" do
      config = ProviderConfig.fake()
      env = %{"MUSE_PLANNING_MODEL" => "env-planner-model"}
      {:ok, result} = ModelRouter.resolve(:planning, config, env: env)
      assert result.model == "env-planner-model"
    end

    test "explicit model_pins takes precedence over env pins" do
      config = ProviderConfig.fake()
      env = %{"MUSE_PLANNING_MODEL" => "env-planner-model"}

      {:ok, result} =
        ModelRouter.resolve(:planning, config,
          model_pins: %{planning: "explicit-model"},
          env: env
        )

      assert result.model == "explicit-model"
    end

    test "env pin for coding muse uses MUSE_CODING_MODEL" do
      config = ProviderConfig.fake()

      env = %{
        "MUSE_CODING_MODEL" => "env-coder-model",
        "MUSE_PLANNING_MODEL" => "env-planner-model"
      }

      {:ok, result} = ModelRouter.resolve(:coding, config, env: env)
      assert result.model == "env-coder-model"
    end

    test "env pin for reviewing muse uses MUSE_REVIEWING_MODEL" do
      config = ProviderConfig.fake()
      env = %{"MUSE_REVIEWING_MODEL" => "env-reviewer-model"}
      {:ok, result} = ModelRouter.resolve(:reviewing, config, env: env)
      assert result.model == "env-reviewer-model"
    end

    test "env pin for testing muse uses MUSE_TESTING_MODEL" do
      config = ProviderConfig.fake()
      env = %{"MUSE_TESTING_MODEL" => "env-tester-model"}
      {:ok, result} = ModelRouter.resolve(:testing, config, env: env)
      assert result.model == "env-tester-model"
    end

    test "env pin for memory muse uses MUSE_MEMORY_MODEL" do
      config = ProviderConfig.fake()
      env = %{"MUSE_MEMORY_MODEL" => "env-memory-model"}
      {:ok, result} = ModelRouter.resolve(:memory, config, env: env)
      assert result.model == "env-memory-model"
    end

    test "env pin for restoration muse uses MUSE_RESTORATION_MODEL" do
      config = ProviderConfig.fake()
      env = %{"MUSE_RESTORATION_MODEL" => "env-restoration-model"}
      {:ok, result} = ModelRouter.resolve(:restoration, config, env: env)
      assert result.model == "env-restoration-model"
    end

    test "no env map means no env pin applied" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, [])
      assert result.model == config.model
    end

    test "non-map env value is ignored" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, env: "not-a-map")
      assert result.model == config.model
    end

    test "missing env var for known muse is ignored" do
      config = ProviderConfig.fake()
      env = %{"UNRELATED_VAR" => "value"}
      {:ok, result} = ModelRouter.resolve(:planning, config, env: env)
      assert result.model == config.model
    end
  end

  describe "resolve/3 — provider pins" do
    test "explicit provider_pins to fake returns fake config" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, provider_pins: %{planning: "fake"})
      assert is_struct(result, ProviderConfig)
      assert result.id == "fake"
    end

    test "atom muse id with matching provider_pins key" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, provider_pins: %{planning: "fake"})
      assert result.id == "fake"
    end

    test "string muse id with matching provider_pins key" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve("planning", config, provider_pins: %{"planning" => "fake"})

      assert result.id == "fake"
    end

    test "unknown provider pin returns error without atom creation" do
      config = ProviderConfig.fake()

      assert {:error, {:unknown_provider, "nope"}} =
               ModelRouter.resolve(:planning, config, provider_pins: %{planning: "nope"})
    end

    test "atom key in provider_pins matches string muse_id" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve("planning", config, provider_pins: %{planning: "fake"})
      assert result.id == "fake"
    end

    test "string key in provider_pins matches atom muse_id" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve(:planning, config, provider_pins: %{"planning" => "fake"})

      assert result.id == "fake"
    end

    test "provider pin overrides model field from new config" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, provider_pins: %{planning: "fake"})
      # The fake provider config has model "fake-planning-model"
      assert is_binary(result.model)
    end

    test "missing provider pin key leaves config unchanged" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:coding, config, provider_pins: %{planning: "fake"})
      assert result == config
    end

    test "empty provider_pins map leaves config unchanged" do
      config = ProviderConfig.fake()
      {:ok, result} = ModelRouter.resolve(:planning, config, provider_pins: %{})
      assert result == config
    end
  end

  describe "resolve/3 — env provider pins" do
    test "env map with MUSE_PLANNING_PROVIDER resolves to fake provider" do
      config = ProviderConfig.fake()
      env = %{"MUSE_PLANNING_PROVIDER" => "fake"}
      {:ok, result} = ModelRouter.resolve(:planning, config, env: env)
      assert result.id == "fake"
    end

    test "explicit provider_pins takes precedence over env provider pins" do
      config = ProviderConfig.fake()
      env = %{"MUSE_PLANNING_PROVIDER" => "openai_compatible"}

      {:ok, result} =
        ModelRouter.resolve(:planning, config, provider_pins: %{planning: "fake"}, env: env)

      assert result.id == "fake"
    end

    test "unknown provider in env returns error" do
      config = ProviderConfig.fake()
      env = %{"MUSE_PLANNING_PROVIDER" => "unknown_provider_xyz"}

      assert {:error, {:unknown_provider, "unknown_provider_xyz"}} =
               ModelRouter.resolve(:planning, config, env: env)
    end

    test "env provider pin for coding uses MUSE_CODING_PROVIDER" do
      config = ProviderConfig.fake()
      env = %{"MUSE_CODING_PROVIDER" => "fake"}
      {:ok, result} = ModelRouter.resolve(:coding, config, env: env)
      assert result.id == "fake"
    end

    test "missing env var for provider pin leaves config unchanged" do
      config = ProviderConfig.fake()
      env = %{"UNRELATED" => "value"}
      {:ok, result} = ModelRouter.resolve(:planning, config, env: env)
      assert result == config
    end
  end

  describe "resolve/3 — combined pins" do
    test "model_pins and provider_pins can be combined" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve(:planning, config,
          model_pins: %{planning: "pinned-model"},
          provider_pins: %{planning: "fake"}
        )

      # Provider pin loads a fresh fake config (which has model "fake-planning-model"),
      # replacing the earlier model pin — this is expected because provider pin
      # swaps the entire config object.
      assert result.id == "fake"
      assert is_binary(result.model)
    end

    test "model pin applies first then provider pin overrides model from new config" do
      config = ProviderConfig.fake()
      # ProviderConfig for fake has model "fake-planning-model"
      # model_pins overrides it first, then provider_pins loads a fresh fake config
      # The fresh fake config also has model "fake-planning-model"
      {:ok, result} =
        ModelRouter.resolve(:planning, config,
          model_pins: %{planning: "pinned-model"},
          provider_pins: %{planning: "fake"}
        )

      # Since provider pin replaces the whole config (not just model field),
      # the model comes from the loaded fake config
      assert result.model == "fake-planning-model"
    end
  end

  describe "resolve/3 — edge cases" do
    test "unknown string muse_id returns base config unchanged" do
      config = ProviderConfig.fake()

      {:ok, result} =
        ModelRouter.resolve("nonexistent_muse", config, model_pins: %{planning: "model"})

      assert result == config
    end

    test "nil muse_id returns base config unchanged" do
      config = ProviderConfig.fake()
      # nil is an atom, so it matches the is_atom clause — there's no special
      # handling for nil, but do_resolve will treat it as an unknown muse id
      # and return the base config unchanged since no pins match nil
      {:ok, result} = ModelRouter.resolve(nil, config, model_pins: %{planning: "model"})
      assert result == config
    end

    test "ProviderConfig with openai_compatible provider pin fails gracefully" do
      config = ProviderConfig.fake()
      # openai_compatible requires MUSE_OPENAI_BASE_URL — without it, load fails
      result =
        ModelRouter.resolve(:planning, config, provider_pins: %{planning: "openai_compatible"})

      assert match?({:error, _}, result)
    end

    test "env pins cannot override non-matching muse id" do
      config = ProviderConfig.fake()
      env = %{"MUSE_PLANNING_MODEL" => "env-model"}
      {:ok, coding} = ModelRouter.resolve(:coding, config, env: env)
      assert coding.model == config.model
    end
  end
end
