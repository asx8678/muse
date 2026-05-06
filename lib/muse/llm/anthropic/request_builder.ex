defmodule Muse.LLM.Anthropic.RequestBuilder do
  @moduledoc """
  Builds Anthropic Messages API HTTP request specs from a `Muse.LLM.Request`.

  This module is pure data preparation — it constructs a request specification
  (URL, headers, payload, Req options) but performs no HTTP calls.

  ## Anthropic Messages API specifics

    * Endpoint: `<base_url>/messages`, with safe handling of trailing `/`
      and `/v1`.
    * `model` from request.model, required.
    * `max_tokens` from request.max_tokens or bounded default (1024).
    * `system` from system messages concatenated/bounded.
    * `messages` from user/assistant messages only; preserves ordering;
      ignores or safely stringifies unsupported roles.
    * `temperature` if set.
    * Optional tools mapped from OpenAI-style function schemas.

  ## Validation

    * `base_url` is required, must be HTTP(S), must have a host.
    * `model` is required.
    * Returns `{:error, reason}` — never raises.
  """

  alias Muse.LLM.{Message, Request}

  @default_max_tokens 1024
  @max_system_length 10_000

  @type spec :: %{
          url: String.t(),
          endpoint_path: String.t(),
          payload: map(),
          headers: [{String.t(), String.t()}],
          req_options: keyword()
        }

  @type error_reason ::
          {:missing_base_url, String.t()}
          | {:invalid_base_url, String.t()}
          | {:missing_model, String.t()}

  @doc """
  Returns the Anthropic Messages API endpoint path.
  """
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "/messages"

  @doc """
  Build a non-streaming Anthropic Messages request spec from a `Muse.LLM.Request`.

  Returns `{:ok, spec}` or `{:error, reason}`.
  """
  @spec build(Request.t()) :: {:ok, spec()} | {:error, error_reason()}
  def build(%Request{} = request) do
    with {:ok, base_url} <- resolve_base_url(request.options),
         {:ok, url} <- build_url(base_url),
         :ok <- validate_model(request.model) do
      payload = build_payload(request)
      headers = resolve_headers(request.options)
      req_options = resolve_req_options(request.options)

      {:ok,
       %{
         url: url,
         endpoint_path: endpoint_path(),
         payload: payload,
         headers: headers,
         req_options: req_options
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Payload construction
  # ---------------------------------------------------------------------------

  defp build_payload(%Request{} = request) do
    base = %{
      "model" => request.model,
      "max_tokens" => request.max_tokens || @default_max_tokens,
      "messages" => map_messages(request.messages)
    }

    base
    |> maybe_put_system(request.messages)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put_tools(request.tools)
  end

  defp maybe_put_system(payload, nil), do: payload

  defp maybe_put_system(payload, messages) when is_list(messages) do
    system_text =
      messages
      |> Enum.filter(&(&1.role == :system))
      |> Enum.map(& &1.content)
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n\n")

    if system_text == "" do
      payload
    else
      Map.put(payload, "system", truncate(system_text, @max_system_length))
    end
  end

  defp maybe_put_system(payload, _messages), do: payload

  # ---------------------------------------------------------------------------
  # Messages mapping — user and assistant only
  # ---------------------------------------------------------------------------

  defp map_messages(nil), do: []

  defp map_messages(messages) when is_list(messages) do
    messages
    |> Enum.filter(&supported_role?/1)
    |> Enum.map(&map_message/1)
  end

  defp map_messages(_), do: []

  defp supported_role?(%Message{role: :user}), do: true
  defp supported_role?(%Message{role: :assistant}), do: true
  defp supported_role?(_message), do: false

  defp map_message(%Message{role: :user, content: content}) do
    %{"role" => "user", "content" => stringify_content(content)}
  end

  defp map_message(%Message{role: :assistant, content: content}) do
    %{"role" => "assistant", "content" => stringify_content(content)}
  end

  defp stringify_content(nil), do: ""
  defp stringify_content(content) when is_binary(content), do: content
  defp stringify_content(content), do: inspect(content, limit: 50, printable_limit: 200)

  # ---------------------------------------------------------------------------
  # Tool mapping — OpenAI function schemas to Anthropic tool entries
  # ---------------------------------------------------------------------------

  defp maybe_put_tools(payload, nil), do: payload
  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, tools) when is_list(tools) do
    anthropic_tools =
      tools
      |> Enum.map(&map_tool/1)
      |> Enum.filter(&(&1 != :skip))

    if anthropic_tools == [] do
      payload
    else
      Map.put(payload, "tools", anthropic_tools)
    end
  end

  defp maybe_put_tools(payload, _tools), do: payload

  # OpenAI-style function tool: %{"type" => "function", "function" => %{"name" => ..., "description" => ..., "parameters" => ...}}
  defp map_tool(%{"type" => "function", "function" => function}) when is_map(function) do
    anthropic_tool = %{"type" => "custom"}

    anthropic_tool =
      case fetch_string(function, "name") do
        {:ok, name} -> Map.put(anthropic_tool, "name", name)
        :error -> :skip
      end

    anthropic_tool =
      case fetch_string(function, "description") do
        {:ok, desc} -> Map.put(anthropic_tool, "description", desc)
        :error -> anthropic_tool
      end

    case anthropic_tool do
      :skip ->
        :skip

      tool ->
        case fetch_map(function, "parameters") do
          {:ok, schema} ->
            Map.put(tool, "input_schema", json_value(schema))

          :error ->
            # Try alternate key "input_schema" as well
            case fetch_map(function, "input_schema") do
              {:ok, schema} -> Map.put(tool, "input_schema", json_value(schema))
              :error -> tool
            end
        end
    end
  end

  # Already Anthropic-style tool with "name" and optionally "input_schema"
  defp map_tool(%{"name" => name} = tool) when is_binary(name) do
    anthropic_tool = %{"type" => "custom", "name" => name}

    anthropic_tool =
      case fetch_string(tool, "description") do
        {:ok, desc} -> Map.put(anthropic_tool, "description", desc)
        :error -> anthropic_tool
      end

    case fetch_map(tool, "input_schema") do
      {:ok, schema} -> Map.put(anthropic_tool, "input_schema", json_value(schema))
      :error -> anthropic_tool
    end
  end

  # Unknown tool shape — omit safely
  defp map_tool(_tool), do: :skip

  defp fetch_string(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_map(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # base_url resolution
  # ---------------------------------------------------------------------------

  defp resolve_base_url(options) when is_map(options) do
    base_url = option_value(options, :base_url) || option_value(options, "base_url")

    case base_url do
      nil ->
        {:error, {:missing_base_url, "base_url is required for Anthropic provider requests"}}

      value when not is_binary(value) ->
        {:error, {:invalid_base_url, "base_url must be a string"}}

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:missing_base_url, "base_url is required for Anthropic provider requests"}}
        else
          {:ok, value}
        end
    end
  end

  defp resolve_base_url(_options),
    do: {:error, {:missing_base_url, "base_url is required for Anthropic provider requests"}}

  # ---------------------------------------------------------------------------
  # URL construction — strip trailing slash, strip /v1, append /messages
  # ---------------------------------------------------------------------------

  defp build_url(base_url) do
    trimmed = String.trim_trailing(base_url, "/")
    url = trimmed <> endpoint_path()

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
  # Model validation
  # ---------------------------------------------------------------------------

  defp validate_model(nil),
    do: {:error, {:missing_model, "model is required for Anthropic provider requests"}}

  defp validate_model(""),
    do: {:error, {:missing_model, "model is required for Anthropic provider requests"}}

  defp validate_model(model) when is_binary(model), do: :ok

  defp validate_model(_model), do: {:error, {:missing_model, "model must be a non-empty string"}}

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

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, json_value(value))

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

  defp truncate(binary, max_length) when is_binary(binary) do
    if String.length(binary) > max_length do
      String.slice(binary, 0, max_length) <> "…"
    else
      binary
    end
  end

  defp redact_url(scheme), do: scheme <> "://[REDACTED]"
end
