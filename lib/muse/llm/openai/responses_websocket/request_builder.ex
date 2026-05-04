defmodule Muse.LLM.OpenAI.ResponsesWebsocket.RequestBuilder do
  @moduledoc """
  Builds pure Responses WebSocket connection/frame specs from a `Muse.LLM.Request`.

  This module performs no network calls and does not resolve credentials. It
  derives a `ws://` or `wss://` URL, carries caller-provided headers, and builds
  the initial `response.create` frame for a WebSocket transport executor.

  URL errors are intentionally generic and never echo full URLs. Embedded
  credentials in URL userinfo, query strings, and fragments are rejected so
  bearer/API material can be carried only in Authorization headers.
  """

  alias Muse.LLM.OpenAI.ResponsesMapper
  alias Muse.LLM.Request

  @supported_wire_apis [nil, :responses]

  @type spec :: %{
          websocket_url: String.t(),
          endpoint_path: String.t(),
          frame: map(),
          headers: [{String.t(), String.t()}],
          connect_options: keyword(),
          req_options: keyword()
        }

  @type error_reason ::
          {:unsupported_wire_api, term()}
          | {:invalid_base_url, String.t()}
          | {:missing_base_url, String.t()}
          | {:invalid_websocket_url, String.t()}
          | {:missing_websocket_url, String.t()}

  @doc """
  Build a Responses WebSocket connection spec from a provider-neutral request.
  """
  @spec build(Request.t()) :: {:ok, spec()} | {:error, error_reason()}
  def build(%Request{} = request) do
    with :ok <- validate_wire_api(request.wire_api),
         {:ok, websocket_url} <- resolve_websocket_url(request.options) do
      payload =
        request
        |> ResponsesMapper.to_payload()
        |> Map.put("stream", true)

      {:ok,
       %{
         websocket_url: websocket_url,
         endpoint_path: ResponsesMapper.endpoint_path(),
         frame: %{"type" => "response.create", "response" => payload},
         headers: resolve_headers(request.options),
         connect_options: resolve_connect_options(request.options),
         req_options: resolve_req_options(request.options)
       }}
    end
  end

  defp validate_wire_api(wire_api) when wire_api in @supported_wire_apis, do: :ok
  defp validate_wire_api(wire_api), do: {:error, {:unsupported_wire_api, wire_api}}

  defp resolve_websocket_url(options) when is_map(options) do
    case option_value(options, :websocket_url) || option_value(options, "websocket_url") do
      nil -> derive_websocket_url(options)
      url -> validate_websocket_url(url)
    end
  end

  defp resolve_websocket_url(_options),
    do: {:error, {:missing_base_url, "base_url is required for OpenAI WebSocket requests"}}

  defp derive_websocket_url(options) do
    with {:ok, base_url} <- resolve_base_url(options) do
      base_url_to_websocket_url(base_url)
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
          {:ok, String.trim(value)}
        end
    end
  end

  defp base_url_to_websocket_url(base_url) do
    trimmed = String.trim_trailing(base_url, "/")

    case strict_uri(trimmed, :base_url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        case validate_safe_url_parts(uri, :base_url) do
          :ok -> {:ok, websocket_url_from_base_uri(uri)}
          error -> error
        end

      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" ->
        {:error,
         {:invalid_base_url,
          "base_url must use http or https scheme, got: #{redact_scheme(scheme)}"}}

      {:ok, _other} ->
        {:error, {:invalid_base_url, "base_url must be a valid HTTP(S) URL with a host"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_websocket_url(url) when not is_binary(url) do
    {:error, {:invalid_websocket_url, "websocket_url must be a string"}}
  end

  defp validate_websocket_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" do
      {:error, {:missing_websocket_url, "websocket_url must not be empty"}}
    else
      validate_websocket_url_parsed(trimmed)
    end
  end

  defp validate_websocket_url_parsed(url) do
    case strict_uri(url, :websocket_url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        case validate_safe_url_parts(uri, :websocket_url) do
          :ok -> {:ok, URI.to_string(uri)}
          error -> error
        end

      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" ->
        {:error,
         {:invalid_websocket_url,
          "websocket_url must use ws or wss scheme, got: #{redact_scheme(scheme)}"}}

      {:ok, _other} ->
        {:error, {:invalid_websocket_url, "websocket_url must be a valid ws/wss URL with a host"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp strict_uri(url, field) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> invalid_uri(field)
    end
  end

  defp invalid_uri(:base_url) do
    {:error, {:invalid_base_url, "base_url must be a valid HTTP(S) URL with a host"}}
  end

  defp invalid_uri(:websocket_url) do
    {:error, {:invalid_websocket_url, "websocket_url must be a valid ws/wss URL with a host"}}
  end

  defp websocket_url_from_base_uri(%URI{scheme: scheme} = uri) do
    ws_scheme = if scheme == "https", do: "wss", else: "ws"

    uri
    |> Map.put(:scheme, ws_scheme)
    |> Map.put(:path, append_endpoint_path(uri.path))
    |> URI.to_string()
  end

  defp append_endpoint_path(nil), do: ResponsesMapper.endpoint_path()

  defp append_endpoint_path(path) when is_binary(path) do
    String.trim_trailing(path, "/") <> ResponsesMapper.endpoint_path()
  end

  defp validate_safe_url_parts(%URI{userinfo: userinfo}, field) when userinfo not in [nil, ""] do
    invalid_url(field, "must not contain embedded credentials (userinfo)")
  end

  defp validate_safe_url_parts(%URI{query: query}, field) when query not in [nil, ""] do
    invalid_url(field, "must not contain a query string")
  end

  defp validate_safe_url_parts(%URI{fragment: fragment}, field) when fragment not in [nil, ""] do
    invalid_url(field, "must not contain a fragment")
  end

  defp validate_safe_url_parts(_uri, _field), do: :ok

  defp invalid_url(:base_url, message), do: {:error, {:invalid_base_url, "base_url #{message}"}}

  defp invalid_url(:websocket_url, message),
    do: {:error, {:invalid_websocket_url, "websocket_url #{message}"}}

  defp resolve_headers(options) when is_map(options) do
    case option_value(options, :headers) || option_value(options, "headers") do
      nil -> []
      headers when is_map(headers) -> normalize_headers(headers)
      headers when is_list(headers) -> normalize_headers(headers)
      _other -> []
    end
  end

  defp resolve_headers(_options), do: []

  defp normalize_headers(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _other -> []
    end)
    |> Enum.sort_by(fn {key, _value} -> String.downcase(key) end)
  end

  defp resolve_connect_options(options) when is_map(options) do
    []
    |> put_positive_integer(:timeout_ms, options)
  end

  defp resolve_connect_options(_options), do: []

  defp resolve_req_options(options) when is_map(options) do
    []
    |> put_positive_integer(:receive_timeout, options)
    |> put_non_negative_integer(:max_retries, options)
  end

  defp resolve_req_options(_options), do: []

  defp put_positive_integer(opts, key, options) do
    case option_value(options, key) || option_value(options, Atom.to_string(key)) do
      value when is_integer(value) and value > 0 -> Keyword.put(opts, key, value)
      _other -> opts
    end
  end

  defp put_non_negative_integer(opts, key, options) do
    case option_value(options, key) || option_value(options, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> Keyword.put(opts, key, value)
      _other -> opts
    end
  end

  defp option_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp redact_scheme(scheme), do: scheme <> "://[REDACTED]"
end
