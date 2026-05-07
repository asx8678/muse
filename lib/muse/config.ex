defmodule Muse.Config do
  @moduledoc """
  Resolves LLM provider configuration from an explicit env map and/or
  application config in a pure, testable way.

  This module is the single point of truth for turning raw configuration
  sources (environment variables, app config) into a validated
  `Muse.LLM.ProviderConfig` struct. It **never**:

    * starts network clients
    * reads auth secrets (API keys, bearer tokens)
    * mutates application environment during resolution
    * performs side effects beyond `Application.get_env/3`

  ## Resolution order

  When building a provider config, fields are resolved with the following
  precedence (highest first):

    1. **Explicit env map** — values passed directly to `llm_provider_config/1`
    2. **Application env** — `config :muse, :llm, [...]` in config/*.exs
    3. **Built-in defaults** — safe fake-provider defaults requiring no network

  ## Quick start

      # Safe default (fake provider, no network)
      {:ok, config} = Muse.Config.llm_provider_config()

      # From app config only
      {:ok, config} = Muse.Config.llm_provider_config(%{})

      # Override specific fields via explicit env map
      {:ok, config} = Muse.Config.llm_provider_config(%{
        "MUSE_PROVIDER" => "openai_compatible",
        "MUSE_MODEL" => "gpt-4",
        "MUSE_OPENAI_BASE_URL" => "https://api.openai.com/v1"
      })

      # OpenRouter provider with model from provider-specific env var
      {:ok, config} = Muse.Config.llm_provider_config(%{
        "MUSE_PROVIDER" => "openrouter",
        "MUSE_OPENROUTER_MODEL" => "anthropic/claude-3.5-sonnet"
      })

      # Ollama local provider (defaults to llama3.1 model)
      {:ok, config} = Muse.Config.llm_provider_config(%{
        "MUSE_PROVIDER" => "ollama"
      })

      # Anthropic provider
      {:ok, config} = Muse.Config.llm_provider_config(%{
        "MUSE_PROVIDER" => "anthropic",
        "MUSE_ANTHROPIC_MODEL" => "claude-sonnet-4-20250514"
      })

      # Validate without building (convenience)
      {:ok, config} = Muse.Config.validate_llm_config()
  """

  alias Muse.LLM.ProviderConfig

  @type env_map :: %{String.t() => String.t()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Resolve and validate an LLM provider config.

  Accepts an optional `env_map` (`%{"MUSE_PROVIDER" => "fake", ...}`) whose
  values take precedence over `Application.get_env(:muse, :llm, [])` and
  built-in defaults.

  Returns `{:ok, %ProviderConfig{}}` on success or `{:error, reason}` with a
  human-readable error string if the resolved config is invalid.

  ## Examples

      iex> {:ok, config} = Muse.Config.llm_provider_config()
      iex> config.id
      "fake"

      iex> {:ok, config} = Muse.Config.llm_provider_config(%{"MUSE_PROVIDER" => "fake"})
      iex> config.id
      "fake"
  """
  @spec llm_provider_config(env_map()) :: {:ok, ProviderConfig.t()} | {:error, String.t()}
  def llm_provider_config(env_map \\ %{}) when is_map(env_map) do
    config = build_provider_config(env_map)

    case ProviderConfig.validate(config) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Convenience alias for `llm_provider_config/1`.

  Semantically emphasizes validation of the resolved config rather than
  construction, but the return shape is identical.
  """
  @spec validate_llm_config(env_map()) :: {:ok, ProviderConfig.t()} | {:error, String.t()}
  def validate_llm_config(env_map \\ %{}) when is_map(env_map) do
    llm_provider_config(env_map)
  end

  # ---------------------------------------------------------------------------
  # Config building (pure — no side effects beyond Application.get_env)
  # ---------------------------------------------------------------------------

  defp build_provider_config(env_map) do
    app_config = Application.get_env(:muse, :llm, [])

    provider_str = resolve(env_map, app_config, "MUSE_PROVIDER", :provider, "fake")
    provider = parse_provider(provider_str)

    base_config =
      case provider do
        :fake -> ProviderConfig.fake()
        :openai_compatible -> openai_compatible_from_sources(env_map, app_config)
        :openrouter -> openrouter_from_sources(env_map, app_config)
        :ollama -> ollama_from_sources(env_map, app_config)
        :anthropic -> anthropic_from_sources(env_map, app_config)
        _ -> %ProviderConfig{id: provider_str, name: provider_str}
      end

    base_config
    |> maybe_override_model(env_map, app_config, provider)
    |> maybe_override_base_url(env_map, app_config)
    |> maybe_override_timeout(env_map, app_config)
    |> maybe_override_retries(env_map, app_config)
    |> maybe_override_max_tokens(env_map, app_config)
  end

  defp parse_provider("fake"), do: :fake
  defp parse_provider("openai_compatible"), do: :openai_compatible
  defp parse_provider("openrouter"), do: :openrouter
  defp parse_provider("ollama"), do: :ollama
  defp parse_provider("anthropic"), do: :anthropic
  defp parse_provider(_unknown), do: :unknown

  defp openai_compatible_from_sources(env_map, app_config) do
    base_url =
      resolve(env_map, app_config, "MUSE_OPENAI_BASE_URL", :base_url, "https://api.openai.com/v1")

    wire_api =
      resolve(env_map, app_config, "MUSE_WIRE_API", :wire_api, "responses")
      |> parse_wire_api()

    transport =
      resolve(env_map, app_config, "MUSE_TRANSPORT", :transport, "sse")
      |> parse_transport()

    %ProviderConfig{
      id: "openai_compatible",
      name: "OpenAI Compatible",
      base_url: base_url,
      wire_api: wire_api,
      transport: transport,
      auth: :api_key,
      env_key: "MUSE_OPENAI_API_KEY",
      supports_streaming: true,
      supports_websockets: true,
      supports_tools: true,
      max_tokens_per_session: 100_000,
      max_api_calls_per_minute: 60
    }
  end

  defp openrouter_from_sources(env_map, app_config) do
    base_url =
      resolve(
        env_map,
        app_config,
        "MUSE_OPENROUTER_BASE_URL",
        :base_url,
        "https://openrouter.ai/api/v1"
      )

    wire_api =
      resolve(env_map, app_config, "MUSE_WIRE_API", :wire_api, "chat_completions")
      |> parse_wire_api()

    transport =
      resolve(env_map, app_config, "MUSE_TRANSPORT", :transport, "sse")
      |> parse_transport()

    %ProviderConfig{
      id: "openrouter",
      name: "OpenRouter",
      base_url: base_url,
      wire_api: wire_api,
      transport: transport,
      auth: :api_key,
      env_key: "MUSE_OPENROUTER_API_KEY",
      supports_streaming: true,
      supports_websockets: false,
      supports_tools: true,
      max_tokens_per_session: 100_000,
      max_api_calls_per_minute: 60
    }
  end

  defp ollama_from_sources(env_map, app_config) do
    base_url =
      resolve(env_map, app_config, "MUSE_OLLAMA_BASE_URL", :base_url, "http://127.0.0.1:11434/v1")

    wire_api =
      resolve(env_map, app_config, "MUSE_WIRE_API", :wire_api, "chat_completions")
      |> parse_wire_api()

    transport =
      resolve(env_map, app_config, "MUSE_TRANSPORT", :transport, "sse")
      |> parse_transport()

    %ProviderConfig{
      id: "ollama",
      name: "Ollama",
      base_url: base_url,
      wire_api: wire_api,
      transport: transport,
      auth: :none,
      supports_streaming: true,
      supports_websockets: false,
      supports_tools: true
    }
  end

  defp anthropic_from_sources(env_map, app_config) do
    base_url =
      resolve(
        env_map,
        app_config,
        "MUSE_ANTHROPIC_BASE_URL",
        :base_url,
        "https://api.anthropic.com/v1"
      )

    wire_api =
      resolve(env_map, app_config, "MUSE_WIRE_API", :wire_api, "anthropic_messages")
      |> parse_wire_api()

    transport =
      resolve(env_map, app_config, "MUSE_TRANSPORT", :transport, "none")
      |> parse_transport()

    %ProviderConfig{
      id: "anthropic",
      name: "Anthropic",
      base_url: base_url,
      wire_api: wire_api,
      transport: transport,
      auth: :api_key,
      env_key: "MUSE_ANTHROPIC_API_KEY",
      supports_streaming: true,
      supports_websockets: false,
      supports_tools: true,
      max_tokens_per_session: 100_000,
      max_api_calls_per_minute: 60
    }
  end

  # ---------------------------------------------------------------------------
  # Field overrides (env map > app config > existing struct value)
  # ---------------------------------------------------------------------------

  defp maybe_override_model(config, env_map, app_config, provider) do
    model = resolve_model_from_sources(env_map, app_config, provider)
    %{config | model: model}
  end

  defp resolve_model_from_sources(env_map, app_config, :fake) do
    resolve(env_map, app_config, "MUSE_MODEL", :model, "fake-planning-model")
  end

  defp resolve_model_from_sources(env_map, app_config, :openrouter) do
    resolve(env_map, app_config, "MUSE_MODEL", :model, nil) ||
      resolve(env_map, app_config, "MUSE_OPENROUTER_MODEL", :openrouter_model, nil)
  end

  defp resolve_model_from_sources(env_map, app_config, :ollama) do
    resolve(env_map, app_config, "MUSE_MODEL", :model, nil) ||
      resolve(env_map, app_config, "MUSE_OLLAMA_MODEL", :ollama_model, nil) ||
      "llama3.1"
  end

  defp resolve_model_from_sources(env_map, app_config, :anthropic) do
    resolve(env_map, app_config, "MUSE_MODEL", :model, nil) ||
      resolve(env_map, app_config, "MUSE_ANTHROPIC_MODEL", :anthropic_model, nil)
  end

  defp resolve_model_from_sources(env_map, app_config, _provider) do
    resolve(env_map, app_config, "MUSE_MODEL", :model, nil)
  end

  defp maybe_override_base_url(
         %ProviderConfig{id: "openai_compatible"} = config,
         env_map,
         app_config
       ) do
    case resolve_optional(env_map, app_config, "MUSE_OPENAI_BASE_URL", :base_url) do
      nil -> config
      url -> %{config | base_url: url}
    end
  end

  defp maybe_override_base_url(%ProviderConfig{id: "openrouter"} = config, env_map, app_config) do
    case resolve_optional(env_map, app_config, "MUSE_OPENROUTER_BASE_URL", :base_url) do
      nil -> config
      url -> %{config | base_url: url}
    end
  end

  defp maybe_override_base_url(%ProviderConfig{id: "ollama"} = config, env_map, app_config) do
    case resolve_optional(env_map, app_config, "MUSE_OLLAMA_BASE_URL", :base_url) do
      nil -> config
      url -> %{config | base_url: url}
    end
  end

  defp maybe_override_base_url(%ProviderConfig{id: "anthropic"} = config, env_map, app_config) do
    case resolve_optional(env_map, app_config, "MUSE_ANTHROPIC_BASE_URL", :base_url) do
      nil -> config
      url -> %{config | base_url: url}
    end
  end

  defp maybe_override_base_url(config, _env_map, _app_config), do: config

  defp maybe_override_timeout(config, env_map, app_config) do
    case resolve(env_map, app_config, "MUSE_LLM_TIMEOUT_MS", :timeout_ms, nil) do
      nil -> config
      val -> %{config | timeout_ms: parse_integer(val, config.timeout_ms)}
    end
  end

  defp maybe_override_retries(config, env_map, app_config) do
    case resolve(env_map, app_config, "MUSE_LLM_MAX_RETRIES", :max_retries, nil) do
      nil -> config
      val -> %{config | max_retries: parse_integer(val, config.max_retries)}
    end
  end

  defp maybe_override_max_tokens(config, env_map, app_config) do
    case resolve(env_map, app_config, "MUSE_MAX_TOKENS", :max_tokens, nil) do
      nil -> config
      val -> %{config | max_tokens: parse_integer(val, config.max_tokens)}
    end
  end

  # ---------------------------------------------------------------------------
  # Resolution helpers
  # ---------------------------------------------------------------------------

  @doc false
  @spec resolve(env_map(), keyword(), String.t(), atom(), String.t() | nil) ::
          String.t() | nil
  def resolve(env_map, app_config, env_key, app_key, default) do
    # 1. Explicit env map (highest precedence)
    case Map.get(env_map, env_key) do
      nil ->
        # 2. Application config
        case Keyword.get(app_config, app_key) do
          nil -> default
          val -> to_string(val)
        end

      val ->
        to_string(val)
    end
  end

  # Like resolve/5 but returns nil instead of falling through to a default.
  defp resolve_optional(env_map, app_config, env_key, app_key) do
    case Map.get(env_map, env_key) do
      nil ->
        case Keyword.get(app_config, app_key) do
          nil -> nil
          val -> to_string(val)
        end

      val ->
        to_string(val)
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing helpers (safe — return fallback on parse failure)
  # ---------------------------------------------------------------------------

  defp parse_wire_api(value), do: ProviderConfig.parse_wire_api(value)

  defp parse_transport(value), do: ProviderConfig.parse_transport(value)

  defp parse_integer(str, fallback) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> fallback
    end
  end

  defp parse_integer(_, fallback), do: fallback
end
