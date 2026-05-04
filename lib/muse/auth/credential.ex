defmodule Muse.Auth.Credential do
  @moduledoc """
  A resolved authentication credential for an LLM provider.

  The `value` field contains the secret — handle with extreme care.
  Never emit the `value` field into logs, events, or debug output.
  Use explicit APIs such as `to_header/1` when the raw credential value is
  required for an outbound provider request.

  ## Security rules

    * `inspect/1` and all status/diagnostic output show safe redacted data,
      never `value`.
    * `value` is never emitted into `Muse.Event`, prompt previews, or log output.
    * Errors reference safe labels only; they never include credential values.
    * Metadata, warnings, and source references are sanitized and bounded before
      public status/inspect rendering.
  """

  alias Muse.MetadataSanitizer
  alias Muse.Prompt.Redactor

  @supported_types [:api_key, :bearer, :oauth_token]
  @supported_sources [:env, :app_config, :provider_config, :command, :codex_cache, :prompt, :none]

  @public_redacted "[REDACTED]"
  @max_source_ref_length 200
  @max_error_length 120
  @max_status_string_length 300

  @type auth_type :: :api_key | :bearer | :oauth_token
  @type source ::
          :env | :app_config | :provider_config | :command | :codex_cache | :prompt | :none
  @type warning :: term()
  @type error_reason ::
          :missing_type
          | :missing_source
          | :missing_value
          | :empty_value
          | {:unsupported_type, term()}
          | {:unsupported_source, term()}
          | {:invalid_credential, String.t()}
          | {:invalid_value, String.t()}
          | {:invalid_expires_at, String.t()}
          | {:invalid_metadata, String.t()}
          | {:invalid_attributes, String.t()}

  @enforce_keys [:type, :value, :source]
  defstruct [
    :type,
    :value,
    :source,
    :source_ref,
    :expires_at,
    :redacted,
    metadata: %{},
    warnings: []
  ]

  @type t :: %__MODULE__{
          type: auth_type(),
          value: String.t(),
          source: source(),
          source_ref: String.t() | nil,
          expires_at: DateTime.t() | nil,
          redacted: String.t(),
          metadata: map(),
          warnings: [warning()]
        }

  @doc """
  Safely construct a credential from a map or keyword list.

  Supported credential types are `:api_key`, `:bearer`, and `:oauth_token`.
  Supported sources are `:env`, `:app_config`, `:provider_config`, `:command`,
  `:codex_cache`, `:prompt`, and `:none`.

  The raw `:value` must be a non-empty string. It is retained in the returned
  struct for explicit provider-bound APIs, while `:redacted` is populated from
  the value for safe display. Errors never include the raw value.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, error_reason()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <- attrs_to_map(attrs),
         {:ok, type} <- attrs |> attr(:type) |> normalize_type(),
         {:ok, source} <- attrs |> attr(:source) |> normalize_source(),
         {:ok, value} <- attrs |> attr(:value) |> normalize_value(),
         {:ok, source_ref} <- attrs |> attr(:source_ref) |> normalize_source_ref(),
         {:ok, expires_at} <- attrs |> attr(:expires_at) |> normalize_expires_at(),
         {:ok, metadata} <- attrs |> attr(:metadata, %{}) |> normalize_metadata(),
         {:ok, warnings} <- attrs |> attr(:warnings, []) |> normalize_warnings() do
      {:ok,
       %__MODULE__{
         type: type,
         value: value,
         source: source,
         source_ref: source_ref,
         expires_at: expires_at,
         metadata: metadata,
         warnings: warnings,
         redacted: redact_value(value)
       }}
    end
  end

  def new(_attrs),
    do: {:error, {:invalid_attributes, "attributes must be a map or keyword list"}}

  @doc """
  Safely construct a credential, raising `ArgumentError` on invalid input.

  The raised message is redaction-safe and never includes the raw credential
  value or metadata secrets.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, credential} ->
        credential

      {:error, reason} ->
        raise ArgumentError, "invalid Muse.Auth.Credential: #{safe_error_text(reason)}"
    end
  end

  @doc """
  Build a redacted display string from a raw secret value.

  Shows the first 3 characters (if long enough) followed by `...REDACTED`.
  Short or empty values become `***REDACTED***` to avoid leaking length info.
  Prefer `to_status/1` or `inspect/1` for public output; those surfaces further
  normalize secret-shaped redaction prefixes to a generic placeholder.
  """
  @spec redact_value(String.t() | term()) :: String.t()
  def redact_value(value) when is_binary(value) do
    prefix_len = 3

    if String.length(value) > prefix_len do
      String.slice(value, 0, prefix_len) <> "...REDACTED"
    else
      "***REDACTED***"
    end
  end

  def redact_value(_value), do: "***REDACTED***"

  @doc """
  Return `true` when a credential has a non-empty raw value.
  """
  @spec present?(t() | term()) :: boolean()
  def present?(%__MODULE__{value: value}), do: value_present?(value)
  def present?(_credential), do: false

  @doc """
  Return `true` when a credential has an expiry in the past or at the current instant.

  Credentials without an expiry are treated as not expired.
  """
  @spec expired?(t() | term(), DateTime.t()) :: boolean()
  def expired?(credential, now \\ DateTime.utc_now())

  def expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) in [:lt, :eq]
  end

  def expired?(_credential, _now), do: false

  @doc """
  Convert a credential into an OpenAI-compatible Authorization header.

  This is the only public API in this module that intentionally returns the raw
  credential value. API keys, bearer tokens, and OAuth tokens are all sent as
  `Bearer` tokens for OpenAI-compatible providers.
  """
  @spec to_header(t()) :: {String.t(), String.t()} | {:error, error_reason()}
  def to_header(%__MODULE__{type: type, value: value}) do
    cond do
      not supported_type?(type) ->
        {:error, {:unsupported_type, safe_error_term(type)}}

      not value_present?(value) ->
        {:error, :missing_value}

      true ->
        {"Authorization", "Bearer #{value}"}
    end
  end

  def to_header(_credential),
    do: {:error, {:invalid_credential, "expected a Muse.Auth.Credential struct"}}

  @doc """
  Return a redaction-safe public status map for `/auth status` and diagnostics.

  The returned map never contains `:value`. Metadata and warnings are sanitized,
  redacted, and bounded. Unsupported type/source values in manually-built
  structs are flagged without leaking secret-shaped terms.
  """
  @spec to_status(t() | nil) :: map()
  def to_status(nil) do
    %{
      type: nil,
      source: :none,
      source_ref: nil,
      expires_at: nil,
      redacted: nil,
      metadata: %{},
      warnings: []
    }
  end

  def to_status(%__MODULE__{} = credential) do
    %{
      type: public_type(credential.type),
      source: public_source(credential.source),
      source_ref: public_source_ref(credential.source_ref),
      expires_at: public_expires_at(credential.expires_at),
      redacted: public_redacted(credential),
      metadata: public_metadata(credential.metadata),
      warnings: public_warnings(credential.warnings)
    }
  end

  def to_status(_credential), do: to_status(nil)

  @doc """
  Return a safe map representation for logging/diagnostics.

  The `value` field is omitted entirely; only safe public fields are included.
  """
  @spec safe_map(t()) :: map()
  def safe_map(%__MODULE__{} = credential), do: to_status(credential)

  # -- Construction helpers -----------------------------------------------------

  defp attrs_to_map(attrs) when is_map(attrs), do: {:ok, attrs}

  defp attrs_to_map(attrs) when is_list(attrs) do
    {:ok, Map.new(attrs)}
  rescue
    _exception -> {:error, {:invalid_attributes, "attributes must be a map or keyword list"}}
  end

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_type(nil), do: {:error, :missing_type}

  defp normalize_type(type) when is_atom(type) do
    if supported_type?(type),
      do: {:ok, type},
      else: {:error, {:unsupported_type, safe_error_term(type)}}
  end

  defp normalize_type(type) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "" -> {:error, :missing_type}
      "api_key" -> {:ok, :api_key}
      "api-key" -> {:ok, :api_key}
      "bearer" -> {:ok, :bearer}
      "oauth_token" -> {:ok, :oauth_token}
      "oauth-token" -> {:ok, :oauth_token}
      _other -> {:error, {:unsupported_type, safe_error_term(type)}}
    end
  end

  defp normalize_type(type), do: {:error, {:unsupported_type, safe_error_term(type)}}

  defp normalize_source(nil), do: {:error, :missing_source}

  defp normalize_source(source) when is_atom(source) do
    if supported_source?(source),
      do: {:ok, source},
      else: {:error, {:unsupported_source, safe_error_term(source)}}
  end

  defp normalize_source(source) when is_binary(source) do
    case source |> String.trim() |> String.downcase() do
      "" -> {:error, :missing_source}
      "env" -> {:ok, :env}
      "app_config" -> {:ok, :app_config}
      "app-config" -> {:ok, :app_config}
      "provider_config" -> {:ok, :provider_config}
      "provider-config" -> {:ok, :provider_config}
      "command" -> {:ok, :command}
      "codex_cache" -> {:ok, :codex_cache}
      "codex-cache" -> {:ok, :codex_cache}
      "prompt" -> {:ok, :prompt}
      "none" -> {:ok, :none}
      _other -> {:error, {:unsupported_source, safe_error_term(source)}}
    end
  end

  defp normalize_source(source), do: {:error, {:unsupported_source, safe_error_term(source)}}

  defp normalize_value(nil), do: {:error, :missing_value}

  defp normalize_value(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :empty_value}
    else
      {:ok, value}
    end
  end

  defp normalize_value(_value),
    do: {:error, {:invalid_value, "value must be a non-empty string"}}

  defp normalize_source_ref(nil), do: {:ok, nil}

  defp normalize_source_ref(source_ref) do
    {:ok, source_ref |> safe_public_text(@max_source_ref_length) |> blank_to_nil()}
  end

  defp normalize_expires_at(nil), do: {:ok, nil}
  defp normalize_expires_at(%DateTime{} = expires_at), do: {:ok, expires_at}

  defp normalize_expires_at(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _error -> {:error, {:invalid_expires_at, "expires_at must be a DateTime or ISO8601 string"}}
    end
  end

  defp normalize_expires_at(_expires_at),
    do: {:error, {:invalid_expires_at, "expires_at must be a DateTime or ISO8601 string"}}

  defp normalize_metadata(nil), do: {:ok, %{}}

  defp normalize_metadata(metadata) when is_map(metadata) do
    {:ok, public_metadata(metadata)}
  end

  defp normalize_metadata(_metadata), do: {:error, {:invalid_metadata, "metadata must be a map"}}

  defp normalize_warnings(nil), do: {:ok, []}
  defp normalize_warnings(warnings) when is_list(warnings), do: {:ok, public_warnings(warnings)}
  defp normalize_warnings(warning), do: {:ok, public_warnings([warning])}

  # -- Public/safe rendering helpers ------------------------------------------

  defp public_type(type) do
    if supported_type?(type), do: type, else: {:unsupported, safe_error_term(type)}
  end

  defp public_source(source) do
    if supported_source?(source), do: source, else: {:unsupported, safe_error_term(source)}
  end

  defp public_source_ref(source_ref) when is_nil(source_ref), do: nil

  defp public_source_ref(source_ref),
    do: source_ref |> safe_public_text(@max_source_ref_length) |> blank_to_nil()

  defp public_expires_at(%DateTime{} = expires_at), do: expires_at
  defp public_expires_at(_expires_at), do: nil

  defp public_redacted(%__MODULE__{} = credential) do
    if present?(credential), do: @public_redacted, else: nil
  end

  defp public_metadata(metadata) when is_map(metadata), do: sanitize_public_term(metadata)
  defp public_metadata(_metadata), do: %{}

  defp public_warnings(warnings) do
    warnings
    |> List.wrap()
    |> sanitize_public_term(max_list_length: 20, max_string_len: @max_status_string_length)
    |> List.wrap()
  end

  defp sanitize_public_term(term, opts \\ []) do
    sanitizer_opts =
      Keyword.merge(
        [
          max_depth: 4,
          max_map_keys: 20,
          max_list_length: 20,
          max_string_len: @max_status_string_length
        ],
        opts
      )

    term
    |> MetadataSanitizer.sanitize(sanitizer_opts)
    |> Redactor.redact_term()
  end

  defp safe_public_text(binary, max_length) when is_binary(binary) do
    binary
    |> Redactor.redact_text()
    |> truncate(max_length)
  end

  defp safe_public_text(atom, _max_length) when is_atom(atom), do: Atom.to_string(atom)

  defp safe_public_text(term, max_length) do
    term
    |> inspect(limit: 5, printable_limit: max_length)
    |> Redactor.redact_text()
    |> truncate(max_length)
  end

  defp safe_error_text(reason) do
    reason
    |> safe_error_term()
    |> inspect(limit: 5, printable_limit: @max_error_length)
    |> Redactor.redact_text()
    |> truncate(@max_error_length)
  end

  defp safe_error_term(binary) when is_binary(binary),
    do: safe_public_text(binary, @max_error_length)

  defp safe_error_term(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> safe_public_text(@max_error_length)
  end

  defp safe_error_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&safe_error_term/1)
    |> List.to_tuple()
  end

  defp safe_error_term(list) when is_list(list) do
    list
    |> Enum.take(10)
    |> Enum.map(&safe_error_term/1)
  end

  defp safe_error_term(map) when is_map(map) do
    map
    |> Enum.take(10)
    |> Enum.into(%{}, fn {key, value} -> {safe_error_term(key), safe_error_term(value)} end)
  end

  defp safe_error_term(term), do: safe_public_text(term, @max_error_length)

  defp supported_type?(type), do: type in @supported_types
  defp supported_source?(source), do: source in @supported_sources

  defp value_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp value_present?(_value), do: false

  defp truncate(binary, max_length) when is_binary(binary) do
    if String.length(binary) > max_length do
      String.slice(binary, 0, max_length) <> "…"
    else
      binary
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(binary) when is_binary(binary) do
    if String.trim(binary) == "", do: nil, else: binary
  end
end

defimpl Inspect, for: Muse.Auth.Credential do
  import Inspect.Algebra

  def inspect(credential, opts) do
    safe = Muse.Auth.Credential.safe_map(credential)
    concat(["#Muse.Auth.Credential<", to_doc(safe, opts), ">"])
  end
end
