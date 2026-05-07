defmodule Muse.LLM.ProviderConfig do
  @moduledoc """
  Provider configuration struct with validation, defaults, and redacted inspect.

  Supports configuration for all provider types — fake, OpenAI-compatible,
  OpenRouter, Ollama, Anthropic — with safe validation that rejects unknown
  providers, wire APIs, and transports.

  ## Fields

  See `t:t/0` for full type documentation. Key fields:

    * `id`                      — unique provider identifier (e.g. `"openai"`, `"fake"`)
    * `name`                    — human-readable name
    * `base_url`                — API base URL (nil for fake/no-network providers)
    * `wire_api`                — `:responses` | `:chat_completions` | `:anthropic_messages` | `nil`
    * `transport`               — `:none` | `:sse` | `:websocket` | `nil`

  The `wire_api` and `transport` fields can be overridden via `MUSE_WIRE_API`
  and `MUSE_TRANSPORT` environment variables when loading config from env.
  Unknown values safely fall back to defaults; see `parse_wire_api/1` and
  `parse_transport/1`.
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

    * `default/0`  — returns the fake provider config (safe, no network)
    * `fake/0`     — alias for `default/0`
    * `load/0`     — strictly loads and validates current `MUSE_*` env
    * `load/1`     — strictly loads and validates a provided env map
    * `from_env/1` — pure env-map alias for `load/1`
    * `from_env/0` — legacy best-effort struct load from current env

  ## Validation

  `validate/1` returns `:ok` or `{:error, reason}`. It checks:

    * Provider is a known atom (`:fake`, `:openai_compatible`, `:openrouter`, `:ollama`, `:anthropic`)
    * Wire API is known (`:responses`, `:chat_completions`, `:anthropic_messages`, or nil)
    * Transport is known (`:none`, `:sse`, `:websocket`, or nil)
    * Model is present when provider is not `:fake`
    * Base URL is valid HTTP(S) when provider is not `:fake`

  Auth/key validation is **deferred** to the auth layer — the config records
  `auth` and `env_key` for later use but does not verify whether an API key is
  actually present. The env loaders intentionally do **not** read
  `MUSE_OPENAI_API_KEY`; auth remains PR13 scope.

  Validation **never raises** — it always returns `{:error, reason}` for
  invalid config, allowing the caller to fall back to the fake provider.

  ## Redacted Inspect

  `redacted_inspect/1` and the `Inspect` implementation return safe string
  representations with secrets replaced by redaction placeholders. Use them for
  logging, debugging, and any output that may be visible to users or stored in
  events.
  """

  @type auth_mode :: :none | :api_key | :bearer_command | :codex_cache | :openai_oauth
  @type wire_api :: :responses | :chat_completions | :anthropic_messages | nil
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
          max_tokens: non_neg_integer() | nil,
          max_tokens_per_session: non_neg_integer() | nil,
          max_api_calls_per_minute: non_neg_integer() | nil,
          timeout_ms: non_neg_integer(),
          max_retries: non_neg_integer()
        }

  @type error_reason ::
          {:invalid_env, String.t(), term(), String.t()}
          | {:validation_error, String.t()}

  @type load_result :: {:ok, t()} | {:error, error_reason()}

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
    :max_tokens,
    :max_tokens_per_session,
    :max_api_calls_per_minute,
    timeout_ms: 120_000,
    max_retries: 2
  ]

  @known_providers [:fake, :openai_compatible, :openrouter, :ollama, :anthropic]
  @known_wire_apis [:responses, :chat_completions, :anthropic_messages]
  @known_transports [:none, :sse, :websocket]

  # Safe lookup from known provider strings to atoms — never creates new atoms
  # from user-controlled input, preventing atom-table exhaustion attacks.
  @known_provider_strings %{
    "fake" => :fake,
    "openai_compatible" => :openai_compatible,
    "openrouter" => :openrouter,
    "ollama" => :ollama,
    "anthropic" => :anthropic
  }

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
  Strictly load and validate a provider config from environment variables.

  With no argument, reads the current process environment via `System.get_env/0`.
  Passing an env map keeps the function pure and deterministic for tests and
  callers that already have configuration data.

  Reads (common):
    * `MUSE_PROVIDER` — provider identifier (default: `"fake"`)
    * `MUSE_MODEL` — model identifier (default: `"fake-planning-model"` for fake)
    * `MUSE_WIRE_API` — wire API override (provider-specific defaults apply)
    * `MUSE_TRANSPORT` — transport override (provider-specific defaults apply)
    * `MUSE_LLM_TIMEOUT_MS` — per-request timeout in ms (default: `120_000`)
    * `MUSE_LLM_MAX_RETRIES` — max retries (default: `2`, `0` for fake)

  Provider-specific env vars:
    * OpenAI: `MUSE_OPENAI_BASE_URL` (required for openai_compatible)
    * OpenRouter: `MUSE_OPENROUTER_BASE_URL`, `MUSE_OPENROUTER_MODEL`,
      `MUSE_OPENROUTER_API_KEY`
    * Ollama: `MUSE_OLLAMA_BASE_URL`, `MUSE_OLLAMA_MODEL`
    * Anthropic: `MUSE_ANTHROPIC_BASE_URL`, `MUSE_ANTHROPIC_MODEL`,
      `MUSE_ANTHROPIC_API_KEY`

  Unknown `MUSE_WIRE_API` or `MUSE_TRANSPORT` values fall back to their defaults
  (`:responses` and `:sse` respectively) rather than raising — this mirrors
  `Muse.Config`'s safe-parsing behavior.

  Invalid env values return structured `{:error, reason}` tuples instead of
  raising or being silently swallowed. Auth/key presence is intentionally not
  checked here; this function does **not** read `MUSE_OPENAI_API_KEY` and only
  stores the `env_key` metadata needed by the future auth layer.
  """
  @spec load() :: load_result()
  @spec load(map()) :: load_result()
  def load(env_map \\ System.get_env()) when is_map(env_map) do
    with {:ok, config} <- build_from_env(env_map, strict?: true) do
      case validate(config) do
        :ok -> {:ok, config}
        {:error, reason} -> {:error, {:validation_error, reason}}
      end
    end
  end

  @doc """
  Pure env-map API for loading and validating provider config.

  This is an alias for `load/1`. It never reads global process environment.
  """
  @spec from_env(map()) :: load_result()
  def from_env(env_map) when is_map(env_map), do: load(env_map)

  @doc """
  Legacy best-effort provider config loader from current environment.

  Prefer `load/0` or `load/1` for new code. This function preserves the earlier
  PR behavior of returning a struct directly. It does not validate the result
  and ignores malformed timeout/retry overrides instead of raising.
  """
  @spec from_env() :: t()
  def from_env do
    case build_from_env(System.get_env(), strict?: false) do
      {:ok, config} -> config
      {:error, _reason} -> fake()
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate a provider config, returning `:ok` or `{:error, reason}`.

  Validation is safe — it never raises. Unknown providers, wire APIs,
  transports, or missing required fields produce clear error reasons.

  The fake provider always validates successfully regardless of other fields —
  it requires no network, auth, or model configuration.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = config) do
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
      {:error,
       "unknown provider: #{inspect(config.id)} (parsed as #{inspect(provider)}). Known: #{inspect(@known_providers)}"}
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

  defp validate_model(%__MODULE__{model: model}) when model in [nil, ""] do
    {:error, "model is required for non-fake providers"}
  end

  defp validate_model(%__MODULE__{model: model}) when is_binary(model) do
    if String.trim(model) == "" do
      {:error, "model is required for non-fake providers"}
    else
      :ok
    end
  end

  defp validate_model(%__MODULE__{model: other}) do
    {:error, "model must be a string for non-fake providers, got: #{inspect(other)}"}
  end

  defp validate_base_url(%__MODULE__{base_url: nil, transport: :none}), do: :ok

  defp validate_base_url(%__MODULE__{base_url: base_url}) when base_url in [nil, ""] do
    {:error, "base_url is required for network providers"}
  end

  defp validate_base_url(%__MODULE__{base_url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, "base_url must be a valid HTTP(S) URL, got: #{url}"}
    end
  end

  defp validate_base_url(%__MODULE__{base_url: other}) do
    {:error, "base_url must be a valid HTTP(S) URL, got: #{inspect(other)}"}
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
  Return a redacted map representation of the config for safe logging/debugging.

  Secret-like fields and values (API keys, bearer tokens, authorization headers,
  embedded URL credentials, etc.) are replaced with `[REDACTED]`. The returned
  map preserves non-secret values and does not include the struct marker.
  """
  @spec redacted(t()) :: map()
  def redacted(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Muse.Prompt.Redactor.redact_term()
  end

  @doc """
  Return a redacted string representation of the config for logging/debugging.

  Secrets (API keys, bearer tokens) are replaced with redaction placeholders.
  Uses `Muse.Prompt.Redactor` and `Muse.MetadataSanitizer` for consistent,
  bounded redaction across the system.
  """
  @spec redacted_inspect(t()) :: String.t()
  def redacted_inspect(%__MODULE__{} = config) do
    config
    |> redacted()
    |> Muse.MetadataSanitizer.sanitize(max_depth: 6, max_map_keys: 50, max_list_length: 50)
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

  @doc """
  Convert the config's `id` field to a provider atom.

  Returns `:unknown` for nil or unrecognized IDs. Never calls
  `String.to_atom/1`, so unknown provider strings cannot exhaust the atom table.
  """
  @spec provider_atom(t()) :: atom()
  def provider_atom(%__MODULE__{id: nil}), do: :unknown
  def provider_atom(%__MODULE__{id: id}) when is_atom(id), do: id

  def provider_atom(%__MODULE__{id: id}) when is_binary(id) do
    Map.get(@known_provider_strings, id, :unknown)
  end

  def provider_atom(%__MODULE__{}), do: :unknown

  @doc """
  Safely parse a transport value from a string or atom to a known transport atom.

  Accepts strings (`"sse"`, `"none"`, `"websocket"`) and atoms (`:sse`, `:none`,
  `:websocket`). Returns the corresponding known transport atom, or `nil` for
  unrecognized values. Never calls `String.to_atom/1`.

  ## Examples

      iex> Muse.LLM.ProviderConfig.parse_transport("sse")
      :sse
      iex> Muse.LLM.ProviderConfig.parse_transport(:websocket)
      :websocket
      iex> Muse.LLM.ProviderConfig.parse_transport("grpc")
      nil
  """
  @spec parse_transport(String.t() | atom() | nil) :: transport() | nil
  def parse_transport("none"), do: :none
  def parse_transport("sse"), do: :sse
  def parse_transport("websocket"), do: :websocket
  def parse_transport(atom) when atom in @known_transports, do: atom
  def parse_transport(_), do: nil

  @doc """
  Safely parse a wire API value from a string or atom to a known wire API atom.

  Accepts strings (`"responses"`, `"chat_completions"`) and atoms (`:responses`,
  `:chat_completions`). Returns the corresponding known wire API atom, or `nil`
  for unrecognized values. Never calls `String.to_atom/1`.

  ## Examples

      iex> Muse.LLM.ProviderConfig.parse_wire_api("chat_completions")
      :chat_completions
      iex> Muse.LLM.ProviderConfig.parse_wire_api(:responses)
      :responses
      iex> Muse.LLM.ProviderConfig.parse_wire_api("grpc")
      nil
  """
  @spec parse_wire_api(String.t() | atom() | nil) :: wire_api() | nil
  def parse_wire_api("responses"), do: :responses
  def parse_wire_api("chat_completions"), do: :chat_completions
  def parse_wire_api("anthropic_messages"), do: :anthropic_messages
  def parse_wire_api(atom) when atom in @known_wire_apis, do: atom
  def parse_wire_api(_), do: nil

  # ---------------------------------------------------------------------------
  # Private helpers for env loading
  # ---------------------------------------------------------------------------

  defp build_from_env(env_map, opts) do
    strict? = Keyword.fetch!(opts, :strict?)
    provider_str = env_value(env_map, "MUSE_PROVIDER") || "fake"
    provider = parse_provider(provider_str)

    config =
      provider
      |> base_config(provider_str, env_map, strict?)
      |> Map.put(:model, resolve_model(provider, env_map))

    maybe_set_env_overrides(config, env_map, strict?)
  end

  defp base_config(:fake, _provider_str, _env_map, _strict?), do: fake()

  defp base_config(:openai_compatible, _provider_str, env_map, strict?) do
    openai_compatible_defaults(env_map, strict?)
  end

  defp base_config(:openrouter, _provider_str, env_map, strict?) do
    openrouter_defaults(env_map, strict?)
  end

  defp base_config(:ollama, _provider_str, env_map, strict?) do
    ollama_defaults(env_map, strict?)
  end

  defp base_config(:anthropic, _provider_str, env_map, strict?) do
    anthropic_defaults(env_map, strict?)
  end

  defp base_config(:unknown, provider_str, _env_map, _strict?) do
    %__MODULE__{id: provider_str, name: provider_str}
  end

  # Unknown provider strings must NOT create atoms — return :unknown and let
  # validate/1 produce the error. This avoids atom-table exhaustion from
  # user-controlled env vars.
  defp parse_provider(provider) when is_binary(provider) do
    Map.get(@known_provider_strings, String.trim(provider), :unknown)
  end

  defp parse_provider(_other), do: :unknown

  defp resolve_model(:fake, env_map),
    do: env_value(env_map, "MUSE_MODEL") || "fake-planning-model"

  defp resolve_model(:openrouter, env_map),
    do: env_value(env_map, "MUSE_MODEL") || env_value(env_map, "MUSE_OPENROUTER_MODEL")

  defp resolve_model(:ollama, env_map),
    do: env_value(env_map, "MUSE_MODEL") || env_value(env_map, "MUSE_OLLAMA_MODEL") || "llama3.1"

  defp resolve_model(:anthropic, env_map),
    do: env_value(env_map, "MUSE_MODEL") || env_value(env_map, "MUSE_ANTHROPIC_MODEL")

  defp resolve_model(_provider, env_map), do: env_value(env_map, "MUSE_MODEL")

  defp openai_compatible_defaults(env_map, strict?) do
    base_url = env_value(env_map, "MUSE_OPENAI_BASE_URL")
    base_url = if strict?, do: base_url, else: base_url || "https://api.openai.com/v1"

    wire_api =
      case env_value(env_map, "MUSE_WIRE_API") do
        nil -> :responses
        value -> parse_wire_api(value) || :responses
      end

    transport =
      case env_value(env_map, "MUSE_TRANSPORT") do
        nil -> :sse
        value -> parse_transport(value) || :sse
      end

    %__MODULE__{
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

  defp openrouter_defaults(env_map, _strict?) do
    base_url = env_value(env_map, "MUSE_OPENROUTER_BASE_URL") || "https://openrouter.ai/api/v1"

    wire_api =
      case env_value(env_map, "MUSE_WIRE_API") do
        nil -> :chat_completions
        value -> parse_wire_api(value) || :chat_completions
      end

    transport =
      case env_value(env_map, "MUSE_TRANSPORT") do
        nil -> :sse
        value -> parse_transport(value) || :sse
      end

    %__MODULE__{
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

  defp ollama_defaults(env_map, _strict?) do
    base_url = env_value(env_map, "MUSE_OLLAMA_BASE_URL") || "http://127.0.0.1:11434/v1"

    wire_api =
      case env_value(env_map, "MUSE_WIRE_API") do
        nil -> :chat_completions
        value -> parse_wire_api(value) || :chat_completions
      end

    transport =
      case env_value(env_map, "MUSE_TRANSPORT") do
        nil -> :sse
        value -> parse_transport(value) || :sse
      end

    %__MODULE__{
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

  defp anthropic_defaults(env_map, _strict?) do
    base_url = env_value(env_map, "MUSE_ANTHROPIC_BASE_URL") || "https://api.anthropic.com/v1"

    wire_api =
      case env_value(env_map, "MUSE_WIRE_API") do
        nil -> :anthropic_messages
        value -> parse_wire_api(value) || :anthropic_messages
      end

    transport =
      case env_value(env_map, "MUSE_TRANSPORT") do
        nil -> :none
        value -> parse_transport(value) || :none
      end

    %__MODULE__{
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

  defp maybe_set_env_overrides(config, env_map, strict?) do
    with {:ok, timeout_ms} <-
           integer_env(env_map, "MUSE_LLM_TIMEOUT_MS", config.timeout_ms, :positive, strict?),
         {:ok, max_retries} <-
           integer_env(
             env_map,
             "MUSE_LLM_MAX_RETRIES",
             config.max_retries,
             :non_negative,
             strict?
           ) do
      {:ok, %{config | timeout_ms: timeout_ms, max_retries: max_retries}}
    end
  end

  defp integer_env(env_map, key, default, rule, strict?) do
    case env_value(env_map, key) do
      nil ->
        {:ok, default}

      value ->
        value
        |> parse_integer_env()
        |> validate_integer_env(key, value, rule, default, strict?)
    end
  end

  defp parse_integer_env(value) when is_integer(value), do: {:ok, value}

  defp parse_integer_env(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, "must be an integer"}
    end
  end

  defp parse_integer_env(_value), do: {:error, "must be an integer"}

  defp validate_integer_env({:ok, integer}, _key, _value, :positive, _default, _strict?)
       when integer > 0 do
    {:ok, integer}
  end

  defp validate_integer_env({:ok, integer}, _key, _value, :non_negative, _default, _strict?)
       when integer >= 0 do
    {:ok, integer}
  end

  defp validate_integer_env({:ok, _integer}, key, value, :positive, default, strict?) do
    invalid_env(key, value, "must be a positive integer", default, strict?)
  end

  defp validate_integer_env({:ok, _integer}, key, value, :non_negative, default, strict?) do
    invalid_env(key, value, "must be a non-negative integer", default, strict?)
  end

  defp validate_integer_env({:error, message}, key, value, _rule, default, strict?) do
    invalid_env(key, value, message, default, strict?)
  end

  defp invalid_env(key, value, message, _default, true) do
    {:error, {:invalid_env, key, value, message}}
  end

  defp invalid_env(_key, _value, _message, default, false), do: {:ok, default}

  defp env_value(env_map, key) do
    Map.get(env_map, key)
  end
end

defimpl Inspect, for: Muse.LLM.ProviderConfig do
  import Inspect.Algebra

  def inspect(config, opts) do
    concat([
      "#Muse.LLM.ProviderConfig<",
      to_doc(Muse.LLM.ProviderConfig.redacted(config), opts),
      ">"
    ])
  end
end
