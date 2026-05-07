defmodule Muse.LLM.ProviderStatus do
  @moduledoc """
  Provider health and configuration status reporting.

  Reports the current configured provider's status without making network
  calls by default.  A connectivity check (actual HTTP request) is available
  but requires explicit opt-in via `connectivity_check?: true` or the
  `MUSE_PROVIDER_CONNECTIVITY_CHECK` environment variable.

  ## Status values

    * `:ok`            — provider is fake or config validates successfully
    * `:configured`    — non-fake provider with valid config (auth/key status unknown)
    * `:misconfigured` — config validation failed
    * `:unreachable`   — connectivity check failed (opt-in only)
    * `:reachable`     — connectivity check succeeded (opt-in only)

  ## Safety

    * Never makes network calls by default.
    * All output is secret-safe (redacted via `ProviderConfig.redacted/1`).
    * Connectivity checks are opt-in only and never run during `mix test`.
    * Error messages include actionable hints (e.g., "Check your API key
      with: /auth status").
  """

  alias Muse.LLM.ProviderConfig

  @type status :: :ok | :configured | :misconfigured | :unreachable | :reachable
  @type t :: %__MODULE__{
          provider_id: String.t() | nil,
          provider_name: String.t() | nil,
          status: status(),
          model: String.t() | nil,
          auth_mode: ProviderConfig.auth_mode() | nil,
          wire_api: ProviderConfig.wire_api() | nil,
          transport: ProviderConfig.transport() | nil,
          validation_errors: [String.t()],
          connectivity_error: String.t() | nil,
          config_source: String.t()
        }

  defstruct [
    :provider_id,
    :provider_name,
    :status,
    :model,
    :auth_mode,
    :wire_api,
    :transport,
    validation_errors: [],
    connectivity_error: nil,
    config_source: "unknown"
  ]

  @doc """
  Build a provider status report from the current environment configuration.

  Does not make network calls unless `connectivity_check?: true` is passed
  or `MUSE_PROVIDER_CONNECTIVITY_CHECK` is set to `"true"` in the environment.

  ## Options

    * `:connectivity_check?` — opt-in to make a real HTTP request to verify
      the provider endpoint is reachable. Default: `false`.
    * `:env` — explicit env map (default: reads `System.get_env/0`).
    * `:config_source` — label for where the config came from (default: `"env"`).

  ## Examples

      iex> status = Muse.LLM.ProviderStatus.report()
      iex> status.provider_id
      "fake"

      iex> status = Muse.LLM.ProviderStatus.report(connectivity_check?: false)
      iex> status.status in [:ok, :configured, :misconfigured]
      true
  """
  @spec report(keyword()) :: t()
  def report(opts \\ []) do
    env_map = Keyword.get(opts, :env, System.get_env())
    config_source = Keyword.get(opts, :config_source, "env")

    case Muse.Config.llm_provider_config(env_map) do
      {:ok, %ProviderConfig{} = config} ->
        build_status(config, config_source, opts)

      {:error, reason} ->
        # Config resolution failed entirely — build a misconfigured status
        %__MODULE__{
          provider_id: nil,
          provider_name: nil,
          status: :misconfigured,
          model: nil,
          auth_mode: nil,
          wire_api: nil,
          transport: nil,
          validation_errors: [safe_error(reason)],
          connectivity_error: nil,
          config_source: config_source
        }
    end
  end

  @doc """
  Build a provider status from an already-resolved `ProviderConfig`.

  Useful when the caller has already resolved config and wants a status
  report without re-reading the environment.

  ## Options

    * `:connectivity_check?` — opt-in to verify reachability.
    * `:config_source` — label for where the config came from.
  """
  @spec from_config(ProviderConfig.t(), keyword()) :: t()
  def from_config(%ProviderConfig{} = config, opts \\ []) do
    config_source = Keyword.get(opts, :config_source, "resolved")
    build_status(config, config_source, opts)
  end

  @doc """
  Render a human-readable status summary string.

  All output is secret-safe.  Error messages include actionable hints.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = status) do
    lines = [
      header_line(status),
      status_line(status),
      model_line(status),
      auth_line(status),
      wire_api_line(status),
      transport_line(status),
      config_source_line(status)
    ]

    lines =
      lines ++
        validation_error_lines(status) ++
        connectivity_error_lines(status) ++
        actionable_hint_lines(status)

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Render a compact one-line status summary.
  """
  @spec render_compact(t()) :: String.t()
  def render_compact(%__MODULE__{} = status) do
    provider = status.provider_name || status.provider_id || "unknown"
    status_label = status_label(status.status)

    case status.status do
      :misconfigured ->
        errors = length(status.validation_errors)
        "#{provider}: #{status_label} (#{errors} error(s))"

      :unreachable ->
        "#{provider}: #{status_label}"

      _ ->
        "#{provider}: #{status_label}"
    end
  end

  @doc """
  List known models for a given provider type.

  Returns a list of `{model_id, description}` tuples for known models.
  This is a static catalog — it does not make API calls to discover models.

  For unknown providers or the fake provider, returns an empty list.
  """
  @spec known_models(String.t() | atom()) :: [{String.t(), String.t()}]
  def known_models(provider_id) when is_binary(provider_id) do
    case parse_provider_id(provider_id) do
      :fake -> []
      :openai_compatible -> openai_models()
      :openrouter -> openrouter_models()
      :ollama -> ollama_models()
      :anthropic -> anthropic_models()
      _ -> []
    end
  end

  def known_models(provider_id) when is_atom(provider_id) do
    known_models(Atom.to_string(provider_id))
  end

  # -- Private ----------------------------------------------------------------

  defp build_status(config, config_source, opts) do
    provider_atom = ProviderConfig.provider_atom(config)

    base = %__MODULE__{
      provider_id: safe_string(config.id),
      provider_name: safe_string(config.name),
      model: safe_string(config.model),
      auth_mode: config.auth,
      wire_api: config.wire_api,
      transport: config.transport,
      config_source: config_source
    }

    # Validate config
    case ProviderConfig.validate(config) do
      :ok ->
        status = if provider_atom == :fake, do: :ok, else: :configured
        base = %{base | status: status}
        maybe_connectivity_check(base, config, opts)

      {:error, reason} ->
        %{base | status: :misconfigured, validation_errors: [safe_error(reason)]}
    end
  end

  defp maybe_connectivity_check(base, _config, opts) do
    check? =
      Keyword.get(opts, :connectivity_check?, false) ||
        connectivity_check_env?(opts)

    if check? and base.status == :configured do
      # Only check connectivity for non-fake, valid-config providers
      do_connectivity_check(base)
    else
      base
    end
  end

  defp connectivity_check_env?(opts) do
    env_map = Keyword.get(opts, :env, %{})

    case Map.get(env_map, "MUSE_PROVIDER_CONNECTIVITY_CHECK") do
      "true" -> true
      _ -> false
    end
  end

  defp do_connectivity_check(base) do
    # Use a simple HEAD request to the provider's base URL with a short timeout.
    # This is the only place in ProviderStatus that makes a network call,
    # and it's strictly opt-in.
    base_url = get_base_url_for_check(base)

    if base_url do
      url_charlist = String.to_charlist(base_url)

      case :httpc.request(:head, {url_charlist, []}, [timeout: 5000], []) do
        {:ok, _} ->
          %{base | status: :reachable}

        {:error, reason} ->
          %{base | status: :unreachable, connectivity_error: format_connectivity_error(reason)}
      end
    else
      # No base URL to check (shouldn't happen for non-fake configured providers)
      base
    end
  end

  defp get_base_url_for_check(%__MODULE__{provider_id: id}) do
    # Use a well-known health endpoint for each provider type.
    # This avoids hitting expensive endpoints just for connectivity.
    case id do
      "openai_compatible" -> "https://api.openai.com/v1/models"
      "openrouter" -> "https://openrouter.ai/api/v1/models"
      "ollama" -> "http://127.0.0.1:11434/api/tags"
      "anthropic" -> "https://api.anthropic.com/v1/messages"
      _ -> nil
    end
  end

  defp format_connectivity_error(reason) do
    case reason do
      {:failed_connect, _} -> "Connection refused or unreachable"
      {:connection_closed, _} -> "Connection closed by remote"
      {:timeout, _} -> "Connection timed out (5s)"
      other -> "Connection error: #{inspect(other)}"
    end
  end

  defp parse_provider_id("openai_compatible"), do: :openai_compatible
  defp parse_provider_id("openrouter"), do: :openrouter
  defp parse_provider_id("ollama"), do: :ollama
  defp parse_provider_id("anthropic"), do: :anthropic
  defp parse_provider_id("fake"), do: :fake
  defp parse_provider_id(_), do: :unknown

  # -- Render helpers ---------------------------------------------------------

  defp header_line(status) do
    provider = status.provider_name || status.provider_id || "Unknown"
    "Provider: #{provider}"
  end

  defp status_line(status) do
    "Status: #{status_label(status.status)}"
  end

  defp model_line(%__MODULE__{model: nil}), do: "Model: (not configured)"
  defp model_line(%__MODULE__{model: model}), do: "Model: #{model}"

  defp auth_line(%__MODULE__{auth_mode: nil}), do: "Auth: (not configured)"
  defp auth_line(%__MODULE__{auth_mode: :none}), do: "Auth: none required"
  defp auth_line(%__MODULE__{auth_mode: mode}), do: "Auth: #{mode}"

  defp wire_api_line(%__MODULE__{wire_api: nil}), do: nil
  defp wire_api_line(%__MODULE__{wire_api: api}), do: "Wire API: #{api}"

  defp transport_line(%__MODULE__{transport: nil}), do: nil
  defp transport_line(%__MODULE__{transport: transport}), do: "Transport: #{transport}"

  defp config_source_line(%__MODULE__{config_source: source}), do: "Config source: #{source}"

  defp validation_error_lines(%__MODULE__{validation_errors: []}), do: []

  defp validation_error_lines(%__MODULE__{validation_errors: errors}) do
    ["Validation errors:"] ++ Enum.map(errors, &"  - #{&1}")
  end

  defp connectivity_error_lines(%__MODULE__{connectivity_error: nil}), do: []

  defp connectivity_error_lines(%__MODULE__{connectivity_error: error}) do
    ["Connectivity: #{error}"]
  end

  defp actionable_hint_lines(%__MODULE__{status: :ok}), do: []
  defp actionable_hint_lines(%__MODULE__{status: :configured}), do: []

  defp actionable_hint_lines(%__MODULE__{status: :misconfigured}) do
    ["Hint: Review provider configuration. Use /auth status to check credentials."]
  end

  defp actionable_hint_lines(%__MODULE__{status: :unreachable}) do
    [
      "Hint: Provider endpoint is unreachable. Check your network connection and base URL.",
      "Use /auth status to verify your credentials are configured."
    ]
  end

  defp actionable_hint_lines(%__MODULE__{status: :reachable}), do: []

  defp status_label(:ok), do: "ok (fake/offline)"
  defp status_label(:configured), do: "configured (not verified)"
  defp status_label(:misconfigured), do: "misconfigured"
  defp status_label(:unreachable), do: "unreachable"
  defp status_label(:reachable), do: "reachable"

  defp safe_error(reason) do
    reason
    |> safe_to_string()
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value), do: inspect(value, limit: 10, printable_limit: 200)

  defp safe_string(nil), do: nil
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value), do: to_string(value)

  # -- Static model catalogs ---------------------------------------------------

  defp openai_models do
    [
      {"gpt-4o", "GPT-4o (latest multimodal)"},
      {"gpt-4o-mini", "GPT-4o Mini (cost-effective)"},
      {"gpt-4-turbo", "GPT-4 Turbo"},
      {"gpt-4", "GPT-4"},
      {"gpt-3.5-turbo", "GPT-3.5 Turbo (legacy)"},
      {"o1", "o1 (reasoning)"},
      {"o1-mini", "o1 Mini (reasoning, cost-effective)"},
      {"o3-mini", "o3 Mini (reasoning, cost-effective)"}
    ]
  end

  defp openrouter_models do
    [
      {"anthropic/claude-sonnet-4-20250514", "Claude Sonnet 4 (via OpenRouter)"},
      {"anthropic/claude-3.5-sonnet", "Claude 3.5 Sonnet (via OpenRouter)"},
      {"openai/gpt-4o", "GPT-4o (via OpenRouter)"},
      {"openai/gpt-4o-mini", "GPT-4o Mini (via OpenRouter)"},
      {"google/gemini-2.0-flash-001", "Gemini 2.0 Flash (via OpenRouter)"},
      {"meta-llama/llama-3.1-70b-instruct", "Llama 3.1 70B (via OpenRouter)"}
    ]
  end

  defp ollama_models do
    [
      {"llama3.1", "Llama 3.1 (default)"},
      {"llama3.1:70b", "Llama 3.1 70B"},
      {"codellama", "Code Llama"},
      {"mistral", "Mistral"},
      {"gemma2", "Gemma 2"},
      {"qwen2.5-coder", "Qwen 2.5 Coder"}
    ]
  end

  defp anthropic_models do
    [
      {"claude-sonnet-4-20250514", "Claude Sonnet 4 (latest)"},
      {"claude-3.7-sonnet-20250219", "Claude 3.7 Sonnet"},
      {"claude-3.5-sonnet-20241022", "Claude 3.5 Sonnet (v2)"},
      {"claude-3.5-haiku-20241022", "Claude 3.5 Haiku (fast)"},
      {"claude-3-opus-20240229", "Claude 3 Opus (powerful)"}
    ]
  end
end
