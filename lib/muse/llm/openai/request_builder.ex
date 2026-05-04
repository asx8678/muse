defmodule Muse.LLM.OpenAI.RequestBuilder do
  @moduledoc """
  Builds pure Chat Completions HTTP request specs from a `Muse.LLM.Request`.

  This module is pure data preparation — it constructs a request specification
  (URL, headers, payload, Req options) but performs no HTTP calls. The spec can
  be handed to `Req.request/2` or similar by a provider executor in a later PR.

  ## Behaviour

    * Uses `Muse.LLM.OpenAI.ChatCompletionsMapper.to_payload/1` for the wire
      payload and `endpoint_path/0` for the path component.
    * `build_chat_completions/1` **forces `"stream" => false`** in the payload
      regardless of the incoming `request.stream` value.
    * `build_chat_completions_stream/1` **forces `"stream" => true`**, adds
      default stream usage options, and prepares SSE-friendly headers.
    * Resolves `base_url` from `request.options[:base_url]` or
      `request.options["base_url"]`; trims trailing slashes and appends
      `/chat/completions` exactly once.
    * Validates `base_url` is HTTP(S), has a host, and uses no unsupported
      scheme. Returns `{:error, reason}` — never raises.
    * Carries explicit headers from `request.options[:headers]` or
      `request.options["headers"]`. Streaming specs add
      `Accept: text/event-stream` unless the caller already provided an Accept
      header. Does **not** read env vars or synthesize auth headers.
    * Carries `timeout_ms`, `receive_timeout`, and `max_retries` from `request.options` when valid.
    * The result payload and headers are JSON/request-safe: no atom keys, no
      `metadata`, `options`, or debug data.
    * Unsupported `wire_api` values return a clear error.

  ## Supported `wire_api` values

    * `nil` — defaults to Chat Completions
    * `:chat_completions` — explicit Chat Completions

  All other values (e.g. `:responses`) return
  `{:error, {:unsupported_wire_api, value}}`.
  """

  alias Muse.LLM.OpenAI.ChatCompletionsMapper
  alias Muse.LLM.Request

  @default_stream_options %{"include_usage" => true}

  @type spec :: %{
          url: String.t(),
          endpoint_path: String.t(),
          payload: map(),
          headers: [{String.t(), String.t()}],
          req_options: keyword()
        }

  @type error_reason ::
          {:unsupported_wire_api, atom()}
          | {:invalid_base_url, String.t()}
          | {:missing_base_url, String.t()}

  @doc """
  Build a non-streaming Chat Completions request spec from a `Muse.LLM.Request`.

  Returns `{:ok, spec}` or `{:error, reason}`.

  The spec map contains:

    * `:url`          — the full request URL (base_url + endpoint_path)
    * `:endpoint_path`— `"/chat/completions"`
    * `:payload`     — JSON-ready map with string keys and `"stream" => false`
    * `:headers`     — list of `{name, value}` tuples from caller-provided options
    * `:req_options` — keyword list with `:timeout_ms`, `:receive_timeout`, and `:max_retries` when valid
  """
  @spec build_chat_completions(Request.t()) :: {:ok, spec()} | {:error, error_reason()}
  def build_chat_completions(%Request{} = request) do
    with :ok <- validate_wire_api(request.wire_api),
         {:ok, base_url} <- resolve_base_url(request.options),
         {:ok, url} <- build_url(base_url) do
      payload =
        request
        |> ChatCompletionsMapper.to_payload()
        |> Map.put("stream", false)

      headers = resolve_headers(request.options)
      req_options = resolve_req_options(request.options)

      {:ok,
       %{
         url: url,
         endpoint_path: ChatCompletionsMapper.endpoint_path(),
         payload: payload,
         headers: headers,
         req_options: req_options
       }}
    end
  end

  @doc """
  Build a streaming Chat Completions request spec from a `Muse.LLM.Request`.

  Returns `{:ok, spec}` or `{:error, reason}`.

  The streaming spec uses the same URL, payload mapper, caller headers, and Req
  option handling as `build_chat_completions/1`, with streaming-specific wire
  settings:

    * `"stream" => true` is forced in the payload
    * `"stream_options" => %{"include_usage" => true}` is included by default
    * `Accept: text/event-stream` is added unless an Accept header already exists
  """
  @spec build_chat_completions_stream(Request.t()) :: {:ok, spec()} | {:error, error_reason()}
  def build_chat_completions_stream(%Request{} = request) do
    with :ok <- validate_wire_api(request.wire_api),
         {:ok, base_url} <- resolve_base_url(request.options),
         {:ok, url} <- build_url(base_url) do
      payload =
        request
        |> ChatCompletionsMapper.to_payload()
        |> Map.put("stream", true)
        |> put_stream_options(request.options)

      headers =
        request.options
        |> resolve_headers()
        |> ensure_sse_accept_header()

      req_options = resolve_req_options(request.options)

      {:ok,
       %{
         url: url,
         endpoint_path: ChatCompletionsMapper.endpoint_path(),
         payload: payload,
         headers: headers,
         req_options: req_options
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # wire_api validation
  # ---------------------------------------------------------------------------

  @supported_wire_apis [nil, :chat_completions]

  defp validate_wire_api(wire_api) when wire_api in @supported_wire_apis, do: :ok

  defp validate_wire_api(wire_api),
    do: {:error, {:unsupported_wire_api, wire_api}}

  # ---------------------------------------------------------------------------
  # base_url resolution
  # ---------------------------------------------------------------------------

  defp resolve_base_url(options) when is_map(options) do
    base_url = option_value(options, :base_url) || option_value(options, "base_url")

    case base_url do
      nil ->
        {:error, {:missing_base_url, "base_url is required for OpenAI provider requests"}}

      value when not is_binary(value) ->
        {:error, {:invalid_base_url, "base_url must be a string"}}

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:missing_base_url, "base_url is required for OpenAI provider requests"}}
        else
          {:ok, value}
        end
    end
  end

  defp resolve_base_url(_options),
    do: {:error, {:missing_base_url, "base_url is required for OpenAI provider requests"}}

  # ---------------------------------------------------------------------------
  # URL construction & validation
  # ---------------------------------------------------------------------------

  defp build_url(base_url) do
    trimmed = String.trim_trailing(base_url, "/")
    path = ChatCompletionsMapper.endpoint_path()
    url = trimmed <> path

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: userinfo}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if userinfo != nil and userinfo != "" do
          {:error,
           {:invalid_base_url, "base_url must not contain embedded credentials (userinfo)"}}
        else
          {:ok, url}
        end

      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" ->
        {:error,
         {:invalid_base_url, "base_url must use http or https scheme, got: #{redact_url(scheme)}"}}

      _ ->
        {:error, {:invalid_base_url, "base_url must be a valid HTTP(S) URL with a host"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Headers resolution
  # ---------------------------------------------------------------------------

  defp resolve_headers(options) when is_map(options) do
    case option_value(options, :headers) || option_value(options, "headers") do
      nil -> []
      headers when is_map(headers) -> normalize_headers(headers)
      headers when is_list(headers) -> normalize_headers(headers)
      _ -> []
    end
  end

  defp resolve_headers(_options), do: []

  defp ensure_sse_accept_header(headers) do
    if has_header?(headers, "accept") do
      headers
    else
      headers ++ [{"Accept", "text/event-stream"}]
    end
  end

  defp has_header?(headers, wanted_name) do
    Enum.any?(headers, fn {name, _value} -> String.downcase(name) == wanted_name end)
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  # ---------------------------------------------------------------------------
  # Streaming options resolution
  # ---------------------------------------------------------------------------

  defp put_stream_options(payload, options) do
    case resolve_stream_options(options) do
      :omit -> Map.delete(payload, "stream_options")
      stream_options -> Map.put(payload, "stream_options", stream_options)
    end
  end

  defp resolve_stream_options(options) when is_map(options) do
    case fetch_stream_options(options) do
      {:ok, value} -> normalize_stream_options(value)
      :error -> @default_stream_options
    end
  end

  defp resolve_stream_options(_options), do: @default_stream_options

  defp fetch_stream_options(options) do
    case Map.fetch(options, :stream_options) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(options, "stream_options")
    end
  end

  defp normalize_stream_options(value) when value in [nil, false], do: :omit
  defp normalize_stream_options(value) when is_map(value), do: json_value(value)
  defp normalize_stream_options(_value), do: @default_stream_options

  # ---------------------------------------------------------------------------
  # Req options resolution
  # ---------------------------------------------------------------------------

  defp resolve_req_options(options) when is_map(options) do
    opts = []

    opts =
      case option_value(options, :timeout_ms) || option_value(options, "timeout_ms") do
        n when is_integer(n) and n > 0 -> Keyword.put(opts, :timeout_ms, n)
        _ -> opts
      end

    opts =
      case option_value(options, :receive_timeout) || option_value(options, "receive_timeout") do
        n when is_integer(n) and n > 0 -> Keyword.put(opts, :receive_timeout, n)
        _ -> opts
      end

    opts =
      case option_value(options, :max_retries) || option_value(options, "max_retries") do
        n when is_integer(n) and n >= 0 -> Keyword.put(opts, :max_retries, n)
        _ -> opts
      end

    opts
  end

  defp resolve_req_options(_options), do: []

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp option_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp json_value(value)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value) do
    value
  end

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {json_key(key), json_value(nested_value)} end)
  end

  defp json_value(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_number(key), do: to_string(key)
  defp json_key(key), do: inspect(key, limit: :infinity, printable_limit: :infinity)

  # Redact the scheme for error messages — never leak full URLs in errors.
  defp redact_url(scheme), do: scheme <> "://[REDACTED]"
end
