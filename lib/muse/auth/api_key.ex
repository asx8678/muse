defmodule Muse.Auth.ApiKey do
  @moduledoc """
  Deterministic API-key credential resolution with testable env/app/provider sources.

  Resolves an API key from multiple configuration sources with clear, documented
  precedence. The function is **pure** when given an explicit env map — it never
  calls `System.get_env/1` unless `system_env?: true` (the default at runtime).

  ## Precedence (highest to lowest)

    1. **`opts[:api_key]`** — explicit key value, no lookup needed
    2. **`opts[:env]` / `opts[:env_map]`** — explicit env map with provider `env_key`
    3. **`opts[:app_config][:api_key]`** — application config secret
    4. **`System.get_env(env_key)`** — runtime system env (only when `system_env?: true`)

  Empty or whitespace-only values are treated as "not configured" and do not
  short-circuit to lower-precedence sources.

  ## Security

    * Errors include source labels and env var names but **never** raw values.
    * Returned credentials carry a `redacted` field; `inspect/1` never leaks secrets.
    * No tokens are persisted or written to disk.

  ## Provider config integration

  `Muse.LLM.ProviderConfig` stores `env_key` (default: `"MUSE_OPENAI_API_KEY"`
  for OpenAI-compatible providers). Pass the provider config directly:

      {:ok, cred} = Muse.Auth.ApiKey.resolve(provider_config)

  or with explicit overrides:

      {:ok, cred} = Muse.Auth.ApiKey.resolve(provider_config, api_key: "sk-...")
      {:ok, cred} = Muse.Auth.ApiKey.resolve(provider_config, env: %{"MUSE_OPENAI_API_KEY" => "sk-..."})
      {:ok, cred} = Muse.Auth.ApiKey.resolve(provider_config, system_env?: false)
  """

  alias Muse.Auth.Credential
  alias Muse.LLM.ProviderConfig

  @default_env_key "MUSE_OPENAI_API_KEY"

  @type error_reason ::
          {:missing, String.t()}
          | {:empty, String.t()}
          | {:unknown_env_key, String.t()}

  @type resolve_opt ::
          {:api_key, String.t()}
          | {:env, %{String.t() => String.t()}}
          | {:env_map, %{String.t() => String.t()}}
          | {:app_config, keyword()}
          | {:system_env?, boolean()}

  @doc """
  Resolve an API key credential from provider config and options.

  Returns `{:ok, %Credential{}}` with `type: :api_key` and a populated
  `redacted` field, or `{:error, reason}` where `reason` is a safe string
  referencing the source/env var name but never the secret value.

  ## Options

    * `:api_key`     — explicit key value (highest precedence)
    * `:env` / `:env_map` — explicit env map to look up `env_key`
    * `:app_config`  — keyword list with `:api_key` entry
    * `:system_env?` — whether to fall back to `System.get_env/1` (default `true`)

  ## Examples

      iex> Muse.Auth.ApiKey.resolve(%Muse.LLM.ProviderConfig{env_key: "MY_KEY"}, api_key: "sk-test-secret")
      {:ok, %Muse.Auth.Credential{type: :api_key, source: :provider_config, ...}}

      iex> Muse.Auth.ApiKey.resolve(%Muse.LLM.ProviderConfig{env_key: "MY_KEY"}, env: %{"MY_KEY" => "sk-test-secret"})
      {:ok, %Muse.Auth.Credential{type: :api_key, source: :env, ...}}

      iex> Muse.Auth.ApiKey.resolve(%Muse.LLM.ProviderConfig{env_key: "MY_KEY"}, system_env?: false)
      {:error, {:missing, "MY_KEY"}}
  """
  @spec resolve(ProviderConfig.t() | map(), [resolve_opt()]) ::
          {:ok, Credential.t()} | {:error, error_reason()}
  def resolve(provider_config, opts \\ [])

  def resolve(%ProviderConfig{} = pc, opts) do
    env_key = pc.env_key || @default_env_key
    resolve_from_sources(env_key, opts)
  end

  def resolve(%{env_key: env_key} = _provider_map, opts) when is_binary(env_key) do
    resolve_from_sources(env_key, opts)
  end

  def resolve(_provider_config, opts) do
    resolve_from_sources(@default_env_key, opts)
  end

  # ---------------------------------------------------------------------------
  # Resolution pipeline (pure except System.get_env when allowed)
  # ---------------------------------------------------------------------------

  defp resolve_from_sources(env_key, opts) do
    case resolve_value(env_key, opts) do
      {:ok, {value, source}} ->
        {:ok, build_credential(value, source)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Precedence 1: explicit opts[:api_key]
  defp resolve_value(env_key, opts) do
    with {:skip, :not_found} <- try_explicit_api_key(opts),
         {:skip, :not_found} <- try_env_map(env_key, opts),
         {:skip, :not_found} <- try_app_config(opts),
         {:skip, :not_found} <- try_system_env(env_key, opts) do
      {:error, {:missing, env_key}}
    else
      result -> result
    end
  end

  defp try_explicit_api_key(opts) do
    case Keyword.get(opts, :api_key) do
      nil -> {:skip, :not_found}
      value -> check_value(value, :provider_config)
    end
  end

  defp try_env_map(env_key, opts) do
    env_map = opts[:env] || opts[:env_map]

    case env_map do
      nil ->
        {:skip, :not_found}

      map when is_map(map) ->
        case Map.get(map, env_key) do
          nil -> {:skip, :not_found}
          value -> check_value(value, :env)
        end
    end
  end

  defp try_app_config(opts) do
    case Keyword.get(opts, :app_config) do
      nil ->
        {:skip, :not_found}

      app_config ->
        case Keyword.get(app_config, :api_key) do
          nil -> {:skip, :not_found}
          value -> check_value(value, :app_config)
        end
    end
  end

  defp try_system_env(env_key, opts) do
    system_env? = Keyword.get(opts, :system_env?, true)

    if system_env? do
      case System.get_env(env_key) do
        nil -> {:skip, :not_found}
        value -> check_value(value, :env)
      end
    else
      {:skip, :not_found}
    end
  end

  # Check a resolved value: empty/whitespace → error, otherwise ok.
  defp check_value(value, source) when is_binary(value) do
    if blank?(value) do
      {:error, {:empty, source_label(source)}}
    else
      {:ok, {value, source}}
    end
  end

  defp check_value(_non_binary, source) do
    {:error, {:empty, source_label(source)}}
  end

  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # Source labels for error messages — include the source identifier
  # but never the raw key value.
  defp source_label(:env), do: "system_env"
  defp source_label(:app_config), do: "app_config[:api_key]"
  defp source_label(:provider_config), do: "opts[:api_key]"

  # ---------------------------------------------------------------------------
  # Credential construction
  # ---------------------------------------------------------------------------

  defp build_credential(value, source) do
    %Credential{
      type: :api_key,
      value: value,
      source: source,
      redacted: Credential.redact_value(value)
    }
  end
end
