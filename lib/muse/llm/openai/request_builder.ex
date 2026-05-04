defmodule Muse.LLM.OpenAI.RequestBuilder do
  @moduledoc """
  Builds a non-streaming Chat Completions HTTP request spec from a `Muse.LLM.Request`.

  This module is pure data preparation — it constructs a request specification
  (URL, headers, payload, Req options) but performs no HTTP calls. The spec can
  be handed to `Req.request/2` or similar by a provider executor in a later PR.

  ## Behaviour

    * Uses `Muse.LLM.OpenAI.ChatCompletionsMapper.to_payload/1` for the wire
      payload and `endpoint_path/0` for the path component.
    * **Forces `"stream" => false`** in the payload regardless of the incoming
      `request.stream` value. Non-streaming is the only mode supported in PR12.
    * Resolves `base_url` from `request.options[:base_url]` or
      `request.options["base_url"]`; trims trailing slashes and appends
      `/chat/completions` exactly once.
    * Validates `base_url` is HTTP(S), has a host, and uses no unsupported
      scheme. Returns `{:error, reason}` — never raises.
    * Carries explicit headers from `request.options[:headers]` or
      `request.options["headers"]`. Does **not** read env vars or synthesize
      auth headers in PR12.
    * Carries `timeout_ms` and `max_retries` from `request.options` when valid.
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
    * `:req_options` — keyword list with `:timeout_ms` / `:max_retries` when valid
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
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

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

  # Redact the scheme for error messages — never leak full URLs in errors.
  defp redact_url(scheme), do: scheme <> "://[REDACTED]"
end
