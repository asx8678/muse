defmodule Muse.RuntimeProvider do
  @moduledoc """
  Resolves runtime provider submit options for the current environment.

  This module bridges the gap between environment-level provider configuration
  (`MUSE_PROVIDER`, `MUSE_MODEL`, etc.) / app config (`config :muse, :llm, ...`)
  and the Conductor's opts-based provider resolution. It is the single point
  where LiveView and other web callers decide whether to route submits through
  the configured provider or keep the default fake/offline behavior.

  ## Behavior by environment

    * **test / smoke** — always returns `{:ok, []}`, preserving the fake
      provider default. No `MUSE_*` env vars are read, so tests never
      perform network calls regardless of the developer's shell env.
    * **dev / prod with fake or no provider** — returns `{:ok, []}`,
      using the Conductor's default fake provider. "No provider" means
      neither `MUSE_PROVIDER` env nor `config :muse, :llm, provider: ...`
      is set, or the resolved provider is `:fake`.
    * **dev / prod with a valid non-fake provider** — returns
      `{:ok, [provider_config: config, model_router_opts: [env: filtered_env]]}`,
      routing the submit through the configured provider with per-Muse model
      routing support. The resolved `ProviderConfig` is passed directly so
      the Conductor does not need to re-resolve from env.
    * **dev / prod with an invalid non-fake provider** — returns
      `{:error, reason}`, allowing the caller to show an actionable error
      instead of silently falling back to the fake/placeholder response.

  ## App config override

  Set `config :muse, :runtime_provider_enabled, true | false` to override
  the default environment-based detection. When set to `true`, runtime
  provider resolution is enabled even in test/smoke (useful for specific
  integration tests). When `false`, it is disabled even in dev/prod.

  Provider configuration can come from either env vars (`MUSE_PROVIDER`, etc.)
  or app config (`config :muse, :llm, provider: :openrouter, model: ...`).
  `Muse.Config.llm_provider_config/1` resolves both sources with env vars
  taking precedence over app config.

  ## Security

    * Only `MUSE_*` environment variables are passed in the filtered env map
      for `model_router_opts` (used by `ModelRouter` for per-Muse model pins).
    * The resolved `ProviderConfig` struct does not contain API key values;
      auth is deferred to the provider layer.
    * Error messages are sanitized to prevent API key/secret leakage.
    * No atoms are created from user-controlled env strings.
  """

  alias Muse.Config
  alias Muse.Env, as: AppEnv
  alias Muse.LLM.ProviderConfig

  @muse_prefix "MUSE_"

  @doc """
  Resolves submit opts for routing through the configured provider.

  Returns:

    * `{:ok, keyword()}` — opts to pass to `Muse.submit/3` or
      `SessionRouter.submit/4`. Empty list (`[]`) means use default
      (fake) provider. Non-empty list contains `:provider_config` (a
      resolved `ProviderConfig.t()`) and `:model_router_opts` for
      Conductor resolution and per-Muse model routing.
    * `{:error, String.t()}` — safe, human-readable error string when
      a non-fake provider is explicitly configured but its config is
      invalid. Callers should show this error to the user instead of
      silently falling back to the fake/placeholder response.
  """
  @spec resolve_opts() :: {:ok, keyword()} | {:error, String.t()}
  def resolve_opts do
    if runtime_provider_enabled?() do
      resolve_runtime_opts()
    else
      {:ok, []}
    end
  end

  # -- Private ------------------------------------------------------------------

  # Whether runtime provider resolution is enabled.
  # Disabled by default in test/smoke to preserve offline/fake behavior.
  # Can be explicitly enabled/disabled via app config:
  #   config :muse, :runtime_provider_enabled, true
  # Defaults to true when unset (matches historical dev/prod behavior).
  defp runtime_provider_enabled? do
    AppEnv.runtime_provider_enabled?()
  end

  defp resolve_runtime_opts do
    env_map = System.get_env()

    # Always resolve through Config.llm_provider_config/1 which honors both
    # env vars (MUSE_PROVIDER, etc.) and app config (config :muse, :llm, ...).
    # This ensures app-configured providers work for web submits even when
    # no MUSE_PROVIDER env var is set.
    case Config.llm_provider_config(env_map) do
      {:ok, %ProviderConfig{} = config} ->
        if ProviderConfig.provider_atom(config) == :fake do
          # Fake provider (either explicit or default when nothing configured)
          {:ok, []}
        else
          # Valid non-fake provider — pass resolved config directly so
          # Conductor uses it without re-resolving from env. Pass filtered
          # MUSE_* env for ModelRouter per-Muse model/provider pins.
          filtered = filter_muse_env(env_map)
          {:ok, [provider_config: config, model_router_opts: [env: filtered]]}
        end

      {:error, reason} ->
        {:error, sanitize_error(reason)}
    end
  end

  # Filter env to MUSE_* keys only for defense-in-depth.
  # Config.llm_provider_config/1 and ModelRouter only read MUSE_* keys,
  # but filtering prevents accidental leakage of unrelated env vars
  # into process state or logs.
  @spec filter_muse_env(map()) :: map()
  defp filter_muse_env(env_map) do
    env_map
    |> Map.filter(fn {key, _} -> String.starts_with?(key, @muse_prefix) end)
  end

  # Sanitize error messages to prevent leaking API keys/secrets.
  # Error reasons from Config.llm_provider_config/1 are already
  # fairly safe (they don't include API key values), but we apply
  # defense-in-depth redaction for any path that might leak a secret.
  @spec sanitize_error(term()) :: String.t()
  defp sanitize_error(reason) do
    reason
    |> to_string()
    |> redact_secrets()
  end

  @spec redact_secrets(String.t()) :: String.t()
  defp redact_secrets(text) do
    text
    # Redact OpenAI-style API key patterns
    |> String.replace(~r/sk-[a-zA-Z0-9]{8,}/, "sk-[REDACTED]")
    # Redact common key=value patterns in error strings
    |> String.replace(
      ~r/(api[_-]?key|token|secret|password)\s*[=:]\s*\S+/i,
      "\\1=[REDACTED]"
    )
  end
end
