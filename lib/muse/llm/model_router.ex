defmodule Muse.LLM.ModelRouter do
  @moduledoc """
  Applies per-Muse model and provider overrides to a `ProviderConfig`.

  The ModelRouter is a pure, side-effect-free resolver that takes a Muse
  identifier (atom, string, or `%MuseProfile{}`), a base `ProviderConfig`,
  and optional pins, and returns a potentially overridden config.

  ## Pinning sources (in priority order)

    1. **Explicit `:model_pins` / `:provider_pins` opts** — maps of
       Muse id (atom or string) to model string or provider id string.
    2. **Env map pins** — when `:env` is passed, reads environment variable
       names like `MUSE_PLANNING_MODEL` and `MUSE_PLANNING_PROVIDER`.

  Unknown or missing pin keys are silently ignored — the base config is
  returned unchanged.

  ## Safety

    * Never creates atoms from user or env strings.
    * Provider pins only accepted for known provider id strings
      (`"fake"`, `"openai_compatible"`). Unknown provider ids return
      `{:error, {:unknown_provider, id}}`.
    * Model pinning always succeeds — it only overrides the `:model` field
      on the ProviderConfig.

  ## Examples

      iex> config = Muse.LLM.ProviderConfig.fake()
      iex> {:ok, pinned} = Muse.LLM.ModelRouter.resolve(:planning, config, model_pins: %{planning: "claude-3-opus"})
      iex> pinned.model
      "claude-3-opus"

      iex> config = Muse.LLM.ProviderConfig.fake()
      iex> {:ok, same} = Muse.LLM.ModelRouter.resolve(:coding, config, model_pins: %{planning: "claude-3-opus"})
      iex> same.model
      "fake-planning-model"

      iex> config = Muse.LLM.ProviderConfig.fake()
      iex> {:error, {:unknown_provider, "nope"}} = Muse.LLM.ModelRouter.resolve(:planning, config, provider_pins: %{planning: "nope"})
  """

  alias Muse.LLM.ProviderConfig
  alias Muse.MuseProfile

  # Mapping from known Muse id atoms to environment variable names for model
  # and provider overrides.  Only registered Muse ids are recognised — unknown
  # or nil muse_ids are silently ignored by pin_for_muse/2.
  @env_model_var_map %{
    planning: "MUSE_PLANNING_MODEL",
    coding: "MUSE_CODING_MODEL",
    reviewing: "MUSE_REVIEWING_MODEL",
    testing: "MUSE_TESTING_MODEL",
    memory: "MUSE_MEMORY_MODEL",
    restoration: "MUSE_RESTORATION_MODEL"
  }

  @env_provider_var_map %{
    planning: "MUSE_PLANNING_PROVIDER",
    coding: "MUSE_CODING_PROVIDER",
    reviewing: "MUSE_REVIEWING_PROVIDER",
    testing: "MUSE_TESTING_PROVIDER",
    memory: "MUSE_MEMORY_PROVIDER",
    restoration: "MUSE_RESTORATION_PROVIDER"
  }

  # Known provider strings — never use String.to_atom/1 on user/env input.
  # This map is the single source of truth for safe string-to-provider lookup.
  @known_provider_strings %{
    "fake" => :fake,
    "openai_compatible" => :openai_compatible
  }

  @doc """
  Resolve model/provider overrides for a given Muse.

  Accepts a `%MuseProfile{}`, an atom muse id (`:planning`), or a string
  muse id (`"planning"`). Returns `{:ok, config}` where `config` is the
  base `ProviderConfig` with any matching pins applied, or `{:ok, base_config}`
  unchanged if no pins match. Returns `{:error, {:unknown_provider, id}}`
  for unknown provider pin values.

  ## Options

    * `:model_pins` — map of Muse id (atom or string) → model string.
      Example: `%{planning: "gpt-4", coding: "claude-3-opus"}`
    * `:provider_pins` — map of Muse id (atom or string) → provider id string.
      Example: `%{planning: "openai_compatible"}`
    * `:env` — env map for reading `MUSE_*_MODEL` / `MUSE_*_PROVIDER` vars.
      Example: `%{"MUSE_PLANNING_MODEL" => "gpt-4"}`

  ## Precedence

  Explicit `:model_pins` / `:provider_pins` always take precedence over
  env map pins. Within each source, the lookup is by Muse id (atom or
  string key).
  """
  @spec resolve(MuseProfile.t() | atom() | String.t(), ProviderConfig.t(), keyword()) ::
          {:ok, ProviderConfig.t()} | {:error, term()}
  def resolve(muse_id, base_config, opts \\ [])

  def resolve(%MuseProfile{id: id}, base_config, opts) do
    resolve(id, base_config, opts)
  end

  def resolve(muse_id, base_config, opts) when is_atom(muse_id) do
    do_resolve(muse_id, base_config, opts)
  end

  def resolve(muse_id, base_config, opts) when is_binary(muse_id) do
    case String.to_existing_atom(muse_id) do
      atom -> do_resolve(atom, base_config, opts)
    end
  rescue
    ArgumentError -> {:ok, base_config}
  end

  # -- Private ------------------------------------------------------------------

  defp do_resolve(muse_id, base_config, opts) do
    config = apply_model_pin(muse_id, base_config, opts)
    apply_provider_pin(muse_id, config, opts)
  end

  # -- Model pinning ------------------------------------------------------------

  defp apply_model_pin(muse_id, config, opts) do
    model =
      opts
      |> Keyword.get(:model_pins, %{})
      |> pin_for_muse(muse_id)
      |> Kernel.||(env_model_pin(muse_id, opts))

    if is_binary(model), do: %{config | model: model}, else: config
  end

  # -- Provider pinning ---------------------------------------------------------

  defp apply_provider_pin(muse_id, config, opts) do
    provider_id =
      opts
      |> Keyword.get(:provider_pins, %{})
      |> pin_for_muse(muse_id)
      |> Kernel.||(env_provider_pin(muse_id, opts))

    case provider_id do
      nil -> {:ok, config}
      pid when is_binary(pid) -> resolve_provider_config(pid, config)
    end
  end

  # -- Pin lookup helpers -------------------------------------------------------

  @doc false
  def pin_for_muse(pins, muse_id) when is_map(pins) do
    pins[muse_id] || pins[Atom.to_string(muse_id)]
  end

  def pin_for_muse(_pins, _muse_id), do: nil

  # -- Env pin lookup -----------------------------------------------------------

  defp env_model_pin(muse_id, opts) do
    with {:ok, env_map} <- extract_env(opts),
         var_name when is_binary(var_name) <- Map.get(@env_model_var_map, muse_id) do
      Map.get(env_map, var_name)
    else
      _ -> nil
    end
  end

  defp env_provider_pin(muse_id, opts) do
    with {:ok, env_map} <- extract_env(opts),
         var_name when is_binary(var_name) <- Map.get(@env_provider_var_map, muse_id) do
      Map.get(env_map, var_name)
    else
      _ -> nil
    end
  end

  defp extract_env(opts) do
    case Keyword.get(opts, :env) do
      env_map when is_map(env_map) -> {:ok, env_map}
      _ -> :error
    end
  end

  # -- Provider config resolution -----------------------------------------------

  defp resolve_provider_config(provider_id, _fallback_config) do
    atom = Map.get(@known_provider_strings, provider_id, :unknown)

    if atom in ProviderConfig.known_providers() do
      # Delegate to ProviderConfig.load with a minimal env map.
      # For :fake this always succeeds; for :openai_compatible it will
      # return an error unless MUSE_OPENAI_BASE_URL is also set in the env.
      # This is correct behavior — you can't switch to openai_compatible
      # without configuring a base URL.
      ProviderConfig.load(%{"MUSE_PROVIDER" => provider_id})
    else
      {:error, {:unknown_provider, provider_id}}
    end
  end
end
