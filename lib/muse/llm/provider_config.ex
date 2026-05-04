defmodule Muse.LLM.ProviderConfig do
  @moduledoc """
  Provider configuration struct with validation, defaults, and redacted inspect.

  Supports configuration for all provider types — fake, OpenAI-compatible,
  OpenRouter, Ollama — with safe validation that rejects unknown providers,
  wire APIs, and transports.

  ## Fields

  See `t:t/0` for full type documentation. Key fields:

    * `id`                      — unique provider identifier (e.g. `"openai"`, `"fake"`)
    * `name`                    — human-readable name
    * `base_url`                — API base URL (nil for fake/no-network providers)
    * `wire_api`                — `:responses` | `:chat_completions` | `nil`
    * `transport`               — `:none` | `:sse` | `:websocket` | `nil`
    * `model`                   — model identifier
    * `auth`                    — `:none` | `:api_key` | `:bearer_command` | `:codex_cache` | `:openai_oauth` | `nil`
    * `env_key`                 — environment variable name for the API key
    * `bearer_command`          — shell command that outputs a bearer token
    * `supports_streaming`      — whether the provider supports streaming
    * `supports_websockets`     — whether the provider supports WebSocket transport
    * `supports_tools`          — whether the provider supports tool/function calling
    * `headers`                 — extra HTTP headers
    * `max_tokens_per_session`  — token budget per session
    * `max_api_calls_per_minute`— rate limit
    * `timeout_ms`              — per-request timeout (default 120 000 ms)
    * `max_retries`             — retry count for transient failures (default 2)

  ## Constructors

    * `default/0` — returns the fake provider config (safe, no network)
    * `fake/0`    — alias for `default/0`
    * `from_env/0`— builds config from `MUSE_*` environment variables

  ## Validation

  `validate/1` returns `:ok` or `{:error, reason}`. It checks:

    * Provider is a known atom (`:fake`, `:openai_compatible`)
    * Wire API is known (`:responses`, `:chat_completions`, or nil)
    * Transport is known (`:none`, `:sse`, `:websocket`, or nil)
    * Model is present when provider is not `:fake`
    * Base URL is valid HTTP(S) when provider is not `:fake`

  Auth/key validation is **deferred** to the auth layer (post-PR03) — the
  config records `auth` and `env_key` for later use but does not verify
  whether an API key is actually present or that the fields are valid.

  Validation **never raises** — it always returns `{:error, reason}` for
  invalid config, allowing the caller to fall back to the fake provider.

  ## Redacted Inspect

  `redacted_inspect/1` returns a safe string representation with secrets
  replaced by `[REDACTED]`.  Use this for logging, debugging, and any
  output that may be visible to users or stored in events.
  """

  @type auth_mode :: :none | :api_key | :bearer_command | :codex_cache | :openai_oauth
  @type wire_api :: :responses | :chat_completions | nil
  @type transport :: :none | :sse | :websocket | nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          base_url: String.t() | nil,
          wire_api: wire_api(),
          transport: transport(),
          model: String.t() | nil,
          auth: auth_mode() | nil,
          env_key: String.t() | nil,
          bearer_command: String.t() | nil,
          supports_streaming: boolean() | nil,
          supports_websockets: boolean() | nil,
          supports_tools: boolean() | nil,
          headers: map() | nil,
          max_tokens_per_session: non_neg_integer() | nil,
          max_api_calls_per_minute: non_neg_integer() | nil,
          timeout_ms: non_neg_integer(),
          max_retries: non_neg_integer()
        }

  defstruct [
    :id,
    :name,
    :base_url,
    :wire_api,
    :transport,
    :model,
    :auth,
    :env_key,
    :bearer_command,
    :supports_streaming,
    :supports_websockets,
    :supports_tools,
    :headers,
    :max_tokens_per_session,
    :max_api_calls_per_minute,
    timeout_ms: 120_000,
    max_retries: 2
  ]

  @known_providers [:fake, :openai_compatible]
  @known_wire_apis [:responses, :chat_completions]
  @known_transports [:none, :sse, :websocket]

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Return the default provider config (fake provider, no network required).
  """
  @spec default() :: t()
  def default, do: fake()

  @doc """
  Return a fake provider config that requires no network or authentication.

  This is the safe default for tests and offline development.
  """
  @spec fake() :: t()
  def fake do
    %__MODULE__{
      id: "fake",
      name: "Fake Provider",
      wire_api: nil,
      transport: :none,
      model: "fake-planning-model",
      auth: :none,
      supports_streaming: true,
      supports_websockets: false,
      supports_tools: true,
      timeout_ms: 120_000,
      max_retries: 0
    }
  end

  @doc """
  Build a provider config from environment variables.

  Reads:
    * `MUSE_PROVIDER`     — provider atom (default: `"fake"`)
    * `MUSE_MODEL`         — model identifier (default: `"fake-planning-model"` for fake)
    * `MUSE_OPENAI_BASE_URL` — base URL for OpenAI-compatible providers
    * `MUSE_LLM_TIMEOUT_MS` — per-request timeout in ms (default: `120_000`)
    * `MUSE_LLM_MAX_RETRIES` — max retries (default: `2`)

  Does **not** read `MUSE_OPENAI_API_KEY` — that is handled by the auth
  layer, not the config struct. The config only stores the `env_key` field
  indicating which env var to check.
  """
  @spec from_env() :: t()
  def from_env do
    provider_str = System.get_env("MUSE_PROVIDER") || "fake"
    provider = parse_provider(provider_str)

    base_config =
      case provider do
        :fake -> fake()
        :openai_compatible -> openai_compatible_defaults()
        _ -> %__MODULE__{id: provider_str, name: provider_str}
      end

    %{base_config | model: resolve_model(provider)}
    |> maybe_set_env_overrides(provider)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate a provider config, returning `:ok` or `{:error, reason}`.

  Validation is safe — it never raises.  Unknown providers, wire APIs,
  transports, or missing required fields produce clear error reasons.

  The fake provider always validates successfully regardless of other
  fields — it requires no network, auth, or model configuration.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = config) do
    # Fake provider is always valid
    if provider_atom(config) == :fake do
      :ok
    else
      with :ok <- validate_provider(config),
           :ok <- validate_wire_api(config),
           :ok <- validate_transport(config),
           :ok <- validate_model(config),
           :ok <- validate_base_url(config),
           :ok <- validate_timeout(config),
           :ok <- validate_retries(config) do
        :ok
      end
    end
  end

  defp validate_provider(config) do
    provider = provider_atom(config)

    if provider in @known_providers do
      :ok
    else
      {:error, "unknown provider: #{inspect(provider)}. Known: #{inspect(@known_providers)}"}
    end
  end

  defp validate_wire_api(%__MODULE__{wire_api: nil}), do: :ok

  defp validate_wire_api(%__MODULE__{wire_api: api}) do
    if api in @known_wire_apis do
      :ok
    else
      {:error, "unknown wire_api: #{inspect(api)}. Known: #{inspect(@known_wire_apis)}"}
    end
  end

  defp validate_transport(%__MODULE__{transport: nil}), do: :ok

  defp validate_transport(%__MODULE__{transport: transport}) do
    if transport in @known_transports do
      :ok
    else
      {:error, "unknown transport: #{inspect(transport)}. Known: #{inspect(@known_transports)}"}
    end
  end

  defp validate_model(%__MODULE__{model: nil}) do
    {:error, "model is required for non-fake providers"}
  end

  defp validate_model(%__MODULE__{model: ""}) do
    {:error, "model is required for non-fake providers"}
  end

  defp validate_model(%__MODULE__{model: _model}), do: :ok

  defp validate_base_url(%__MODULE__{base_url: nil, transport: :none}), do: :ok

  defp validate_base_url(%__MODULE__{base_url: nil}) do
    {:error, "base_url is required for network providers"}
  end

  defp validate_base_url(%__MODULE__{base_url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> :ok
      _ -> {:error, "base_url must be a valid HTTP(S) URL, got: #{url}"}
    end
  end

  defp validate_timeout(%__MODULE__{timeout_ms: n}) when is_integer(n) and n > 0, do: :ok

  defp validate_timeout(%__MODULE__{timeout_ms: other}) do
    {:error, "timeout_ms must be a positive integer, got: #{inspect(other)}"}
  end

  defp validate_retries(%__MODULE__{max_retries: n}) when is_integer(n) and n >= 0, do: :ok

  defp validate_retries(%__MODULE__{max_retries: other}) do
    {:error, "max_retries must be a non-negative integer, got: #{inspect(other)}"}
  end

  # ---------------------------------------------------------------------------
  # Redacted Inspect
  # ---------------------------------------------------------------------------

  @doc """
  Return a redacted string representation of the config for logging/debugging.

  Secrets (API keys, bearer tokens) are replaced with `[REDACTED]`.
  Uses `Muse.EventPayloadRedactor` and `Muse.MetadataSanitizer` for
  consistent redaction across the system.
  """
  @spec redacted_inspect(t()) :: String.t()
  def redacted_inspect(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Muse.EventPayloadRedactor.redact()
    |> Muse.MetadataSanitizer.sanitize()
    |> inspect(limit: :infinity, printable_limit: 200)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of known provider atoms.
  """
  @spec known_providers() :: [atom()]
  def known_providers, do: @known_providers

  @doc """
  Return the list of known wire APIs.
  """
  @spec known_wire_apis() :: [atom()]
  def known_wire_apis, do: @known_wire_apis

  @doc """
  Return the list of known transports.
  """
  @spec known_transports() :: [atom()]
  def known_transports, do: @known_transports

  # Safe lookup from known provider strings to atoms — never creates new atoms
  # from user-controlled input, preventing atom-table exhaustion attacks.
  @known_provider_strings %{
    "fake" => :fake,
    "openai_compatible" => :openai_compatible
  }

  @doc """
  Convert the config's `id` field to a provider atom.

  Returns `:unknown` for nil or unrecognized IDs.  Never calls
  `String.to_atom/1`, so unknown provider strings cannot exhaust
  the atom table.
  """
  @spec provider_atom(t()) :: atom()
  def provider_atom(%__MODULE__{id: nil}), do: :unknown
  def provider_atom(%__MODULE__{id: id}) when is_atom(id), do: id

  def provider_atom(%__MODULE__{id: id}) when is_binary(id) do
    Map.get(@known_provider_strings, id, :unknown)
  end

  # ---------------------------------------------------------------------------
  # Private helpers for from_env/0
  # ---------------------------------------------------------------------------

  defp parse_provider("fake"), do: :fake
  defp parse_provider("openai_compatible"), do: :openai_compatible
  # Unknown provider strings must NOT create atoms — return :unknown and
  # let validate/1 produce the error.  This avoids atom-table exhaustion
  # from user-controlled env vars.
  defp parse_provider(_other), do: :unknown

  defp resolve_model(:fake), do: System.get_env("MUSE_MODEL") || "fake-planning-model"
  defp resolve_model(_provider), do: System.get_env("MUSE_MODEL") || nil

  defp openai_compatible_defaults do
    %__MODULE__{
      id: "openai_compatible",
      name: "OpenAI Compatible",
      base_url: System.get_env("MUSE_OPENAI_BASE_URL") || "https://api.openai.com/v1",
      wire_api: :responses,
      transport: :sse,
      auth: :api_key,
      env_key: "MUSE_OPENAI_API_KEY",
      supports_streaming: true,
      supports_websockets: true,
      supports_tools: true,
      max_tokens_per_session: 100_000,
      max_api_calls_per_minute: 60
    }
  end

  defp maybe_set_env_overrides(config, _provider) do
    timeout =
      case System.get_env("MUSE_LLM_TIMEOUT_MS") do
        nil -> config.timeout_ms
        val -> String.to_integer(val)
      end

    retries =
      case System.get_env("MUSE_LLM_MAX_RETRIES") do
        nil -> config.max_retries
        val -> String.to_integer(val)
      end

    %{config | timeout_ms: timeout, max_retries: retries}
  rescue
    ArgumentError -> config
  end
end

defimpl Inspect, for: Muse.LLM.ProviderConfig do
  def inspect(config, _opts) do
    Muse.LLM.ProviderConfig.redacted_inspect(config)
  end
end
