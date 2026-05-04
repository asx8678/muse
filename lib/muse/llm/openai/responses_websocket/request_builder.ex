defmodule Muse.LLM.OpenAI.ResponsesWebsocket.RequestBuilder do
  @moduledoc """
  Builds pure Responses WebSocket connection/frame specs from a `Muse.LLM.Request`.

  This module is pure data preparation — it constructs a WebSocket connection
  specification (URL, headers, connect/req options) and a `response.create`
  frame, but performs no network calls. The spec can be handed to a WebSocket
  client by a provider executor in a later PR.

  ## Behaviour

    * Uses `Muse.LLM.OpenAI.ResponsesMapper.to_payload/1` for the wire payload
      and `endpoint_path/0` for the path component.
    * Validates `wire_api`: supported values are `nil` and `:responses`.
      All other values (e.g. `:chat_completions`) return
      `{:error, {:unsupported_wire_api, value}}`.
    * Derives WebSocket URL from `request.options[:base_url]` or
      `request.options["base_url"]`:
      * `https://host/v1` → `wss://host/v1/responses`
      * `http://host/v1`  → `ws://host/v1/responses`
    * Allows explicit override via `request.options[:websocket_url]` or
      `request.options["websocket_url"]`. Validated: `ws`/`wss` scheme,
      host present, no userinfo credentials.
    * Rejects invalid/missing base URL and invalid WebSocket URL safely —
      returns `{:error, reason}`, never raises.
    * Builds a `response.create` frame as a JSON-compatible map:
      `%{"type" => "response.create", "response" => payload}`.
    * The payload from `ResponsesMapper.to_payload/1` retains `"stream" => true`
      (the WebSocket transport is inherently streaming) and `"store"` defaults
      to `false` via the mapper.
    * Resolves caller headers from `request.options[:headers]` or
      `request.options["headers"]`. Headers are normalized (string keys,
      sorted). Does **not** synthesize Authorization headers.
    * Carries `timeout_ms`, `receive_timeout`, and `max_retries` from
      `request.options` into `connect_options` and `req_options` keyword lists
      when valid.
    * No network calls, no auth, no env reads, no dynamic atoms.

  ## Supported `wire_api` values

    * `nil` — defaults to Responses
    * `:responses` — explicit Responses

  All other values (e.g. `:chat_completions`) return
  `{:error, {:unsupported_wire_api, value}}`.
  """

  alias Muse.LLM.OpenAI.ResponsesMapper
  alias Muse.LLM.Request

  @type spec :: %{
          websocket_url: String.t(),
          endpoint_path: String.t(),
          frame: map(),
          headers: [{String.t(), String.t()}],
          connect_options: keyword(),
          req_options: keyword()
        }

  @type error_reason ::
          {:unsupported_wire_api, atom()}
          | {:invalid_base_url, String.t()}
          | {:missing_base_url, String.t()}
          | {:invalid_websocket_url, String.t()}
          | {:missing_websocket_url, String.t()}

  @supported_wire_apis [nil, :responses]

  # ---------------------------------------------------------------------------

  @doc """
  Build a Responses WebSocket connection/frame spec from a `Muse.LLM.Request`.

  Returns `{:ok, spec}` or `{:error, reason}`.

  The spec map contains:

    * `:websocket_url`   — the WebSocket URL (wss:// or ws://)
    * `:endpoint_path`   — `"/responses"`
    * `:frame`           — the `response.create` frame as a JSON-compatible map
    * `:headers`         — list of `{name, value}` tuples from caller-provided options
    * `:connect_options` — keyword list with WebSocket-specific connect options
    * `:req_options`     — keyword list with `:receive_timeout` and `:max_retries`
                          when valid
  """
  @spec build(Request.t()) :: {:ok, spec()} | {:error, error_reason()}
  def build(%Request{} = request) do
    with :ok <- validate_wire_api(request.wire_api),
         {:ok, websocket_url} <- resolve_websocket_url(request.options) do
      payload = ResponsesMapper.to_payload(request)
      frame = build_create_frame(payload)
      headers = resolve_headers(request.options)
      connect_options = resolve_connect_options(request.options)
      req_options = resolve_req_options(request.options)

      {:ok,
       %{
         websocket_url: websocket_url,
         endpoint_path: ResponsesMapper.endpoint_path(),
         frame: frame,
         headers: headers,
         connect_options: connect_options,
         req_options: req_options
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # wire_api validation
  # ---------------------------------------------------------------------------

  defp validate_wire_api(wire_api) when wire_api in @supported_wire_apis, do: :ok

  defp validate_wire_api(wire_api),
    do: {:error, {:unsupported_wire_api, wire_api}}

  # ---------------------------------------------------------------------------
  # WebSocket URL resolution
  # ---------------------------------------------------------------------------

  defp resolve_websocket_url(options) when is_map(options) do
    case explicit_websocket_url(options) do
      nil -> derive_websocket_url(options)
      url -> validate_websocket_url(url)
    end
  end

  defp resolve_websocket_url(_options),
    do: {:error, {:missing_base_url, "base_url is required for OpenAI WebSocket requests"}}

  defp explicit_websocket_url(options) do
    option_value(options, :websocket_url) || option_value(options, "websocket_url")
  end

  defp derive_websocket_url(options) do
    case resolve_base_url(options) do
      {:ok, base_url} -> base_url_to_websocket_url(base_url)
      error -> error
    end
  end

  defp resolve_base_url(options) do
    base_url = option_value(options, :base_url) || option_value(options, "base_url")

    case base_url do
      nil ->
        {:error, {:missing_base_url, "base_url is required for OpenAI WebSocket requests"}}

      value when not is_binary(value) ->
        {:error, {:invalid_base_url, "base_url must be a string"}}

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:missing_base_url, "base_url is required for OpenAI WebSocket requests"}}
        else
          {:ok, value}
        end
    end
  end

  defp base_url_to_websocket_url(base_url) do
    trimmed = String.trim_trailing(base_url, "/")
    path = ResponsesMapper.endpoint_path()

    case URI.parse(trimmed) do
      %URI{scheme: "https", host: host, userinfo: userinfo}
      when is_binary(host) and host != "" ->
        if has_userinfo?(userinfo) do
          {:error,
           {:invalid_base_url, "base_url must not contain embedded credentials (userinfo)"}}
        else
          ws_url = String.replace_prefix(trimmed, "https", "wss") <> path
          {:ok, ws_url}
        end

      %URI{scheme: "http", host: host, userinfo: userinfo}
      when is_binary(host) and host != "" ->
        if has_userinfo?(userinfo) do
          {:error,
           {:invalid_base_url, "base_url must not contain embedded credentials (userinfo)"}}
        else
          ws_url = String.replace_prefix(trimmed, "http", "ws") <> path
          {:ok, ws_url}
        end

      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" ->
        {:error,
         {:invalid_base_url,
          "base_url must use http or https scheme, got: #{redact_scheme(scheme)}"}}

      _ ->
        {:error, {:invalid_base_url, "base_url must be a valid HTTP(S) URL with a host"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Explicit websocket_url validation
  # ---------------------------------------------------------------------------

  defp validate_websocket_url(url) when not is_binary(url) do
    {:error, {:invalid_websocket_url, "websocket_url must be a string"}}
  end

  defp validate_websocket_url(url) when is_binary(url) do
    if String.trim(url) == "" do
      {:error, {:missing_websocket_url, "websocket_url must not be empty"}}
    else
      validate_websocket_url_parsed(url)
    end
  end

  defp validate_websocket_url_parsed(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: userinfo}
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        if has_userinfo?(userinfo) do
          {:error,
           {:invalid_websocket_url,
            "websocket_url must not contain embedded credentials (userinfo)"}}
        else
          {:ok, url}
        end

      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" ->
        {:error,
         {:invalid_websocket_url,
          "websocket_url must use ws or wss scheme, got: #{redact_scheme(scheme)}"}}

      _ ->
        {:error, {:invalid_websocket_url, "websocket_url must be a valid ws/wss URL with a host"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Frame building
  # ---------------------------------------------------------------------------

  defp build_create_frame(payload) do
    %{"type" => "response.create", "response" => payload}
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
  # Connect options resolution (WebSocket-specific)
  # ---------------------------------------------------------------------------

  defp resolve_connect_options(options) when is_map(options) do
    opts = []

    opts =
      case option_value(options, :timeout_ms) || option_value(options, "timeout_ms") do
        n when is_integer(n) and n > 0 -> Keyword.put(opts, :timeout_ms, n)
        _ -> opts
      end

    opts
  end

  defp resolve_connect_options(_options), do: []

  # ---------------------------------------------------------------------------
  # Req options resolution
  # ---------------------------------------------------------------------------

  defp resolve_req_options(options) when is_map(options) do
    opts = []

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

  defp has_userinfo?(nil), do: false
  defp has_userinfo?(""), do: false
  defp has_userinfo?(_), do: true

  # Redact the scheme for error messages — never leak full URLs in errors.
  defp redact_scheme(scheme), do: scheme <> "://[REDACTED]"
end
