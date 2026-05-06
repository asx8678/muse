defmodule Muse.LLM.AnthropicProvider do
  @moduledoc """
  Anthropic Messages API provider adapter implementing `Muse.LLM.Provider`.

  Performs a single Messages API HTTP POST and decodes the complete response
  into Muse's normalized response struct. `stream/2` currently performs a
  non-streaming POST and replays normalized events (full-response replay).

  ## Auth

  Auth resolution is centralized in `Muse.Auth.Resolver`. For `:api_key` auth,
  the Anthropic-specific header `x-api-key: <secret>` and
  `anthropic-version: 2023-06-01` are attached. If an explicit `x-api-key`
  header is already present in `request.options[:headers]`, it wins and the
  auth layer does not overwrite or duplicate it. `auth: :none` allows requests
  without `x-api-key` (for tests/local proxies).

  Raw API keys never appear in returned errors or emitted events.

  ## Function injection

  Callers can inject `post_fn` via `opts[:post_fn]` or
  `request.options[:post_fn]` / `request.options[:http_post]` to avoid
  network calls in tests. The shape matches `Req.post/2`:

      post_fn = fn url, options ->
        {:ok, Req.Response.new(status: 200, body: %{...})}
      end

  ## Error handling

  HTTP non-2xx returns `{:error, safe_reason}` and emits `:provider_error`
  from `stream/2`. Decode errors are safe/redacted. Raw request bodies,
  API keys, Authorization/x-api-key headers, and large provider payloads
  are never included in errors.
  """

  @behaviour Muse.LLM.Provider

  alias Muse.Auth.Resolver
  alias Muse.{EventPayloadRedactor, MetadataSanitizer}

  alias Muse.LLM.Anthropic.RequestBuilder
  alias Muse.LLM.{Event, Request, Response, ToolCall}

  @anthropic_version "2023-06-01"
  @max_summary_string_length 500

  @type post_fn :: (String.t(), keyword() -> {:ok, term()} | {:error, term()})

  # ---------------------------------------------------------------------------
  # Provider behaviour: complete/2
  # ---------------------------------------------------------------------------

  @doc """
  Complete a request through the Anthropic Messages API.

  Tests and offline callers can inject `opts[:post_fn]`, a two-arity function
  with the same call shape as `Req.post/2`: `post_fn.(url, options)`.
  """
  @spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(request), do: complete(request, [])

  @impl true
  @spec complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request, opts) when is_list(opts) do
    with {:ok, spec} <- RequestBuilder.build(request),
         {:ok, spec} <- attach_auth(spec, request, opts),
         {:ok, post_fn} <- resolve_post_fn(opts, request.options),
         {:ok, http_response} <- post(spec, post_fn) do
      decode_http_response(http_response)
    end
  end

  def complete(%Request{}, _opts), do: {:error, {:invalid_options, "opts must be a keyword list"}}

  # ---------------------------------------------------------------------------
  # Provider behaviour: stream/2
  # ---------------------------------------------------------------------------

  @impl true
  @spec stream(Request.t(), (Event.t() -> :ok)) :: {:ok, Response.t()} | {:error, term()}
  def stream(%Request{} = request, emit_fn) when is_function(emit_fn, 1) do
    case complete(request) do
      {:ok, %Response{} = response} ->
        emit_response_events(response, emit_fn)
        {:ok, response}

      {:error, reason} ->
        redacted = redact_error(reason)
        emit_fn.(Event.provider_error(redacted))
        {:error, redacted}
    end
  end

  # ---------------------------------------------------------------------------
  # Auth header attachment
  # ---------------------------------------------------------------------------

  defp attach_auth(%{headers: headers} = spec, request, opts) when is_list(headers) do
    if x_api_key_header?(headers) do
      # Explicit x-api-key header wins — attach version header if not present
      {:ok, ensure_version_header(spec)}
    else
      resolve_and_attach_auth(spec, request, opts)
    end
  end

  defp attach_auth(spec, request, opts), do: resolve_and_attach_auth(spec, request, opts)

  defp resolve_and_attach_auth(spec, request, opts) do
    case Resolver.resolve(request, opts) do
      {:ok, credential} ->
        spec
        |> append_x_api_key_header(credential)
        |> ensure_version_header()
        |> then(&{:ok, &1})

      :none ->
        # auth: :none or no auth configured — attach version header only
        {:ok, ensure_version_header(spec)}

      {:error, reason} ->
        {:error, {:auth_error, safe_auth_reason(reason)}}
    end
  end

  defp x_api_key_header?(headers) do
    Enum.any?(headers, fn
      {name, _value} when is_binary(name) -> String.downcase(name) == "x-api-key"
      _other -> false
    end)
  end

  defp append_x_api_key_header(%{headers: headers} = spec, credential) do
    %{spec | headers: headers ++ [{"x-api-key", credential.value}]}
  end

  defp ensure_version_header(%{headers: headers} = spec) do
    if has_header?(headers, "anthropic-version") do
      spec
    else
      %{spec | headers: headers ++ [{"anthropic-version", @anthropic_version}]}
    end
  end

  defp has_header?(headers, wanted_name) do
    Enum.any?(headers, fn {name, _value} -> String.downcase(name) == wanted_name end)
  end

  defp safe_auth_reason(reason), do: EventPayloadRedactor.redact(reason)

  # ---------------------------------------------------------------------------
  # Post function resolution
  # ---------------------------------------------------------------------------

  defp resolve_post_fn(opts, request_options) do
    case Keyword.fetch(opts, :post_fn) do
      {:ok, post_fn} ->
        normalize_post_fn(post_fn)

      :error ->
        # Also check request.options for :post_fn or :http_post
        case option_value(request_options, :post_fn) || option_value(request_options, "post_fn") ||
               option_value(request_options, :http_post) ||
               option_value(request_options, "http_post") do
          nil -> {:ok, &Req.post/2}
          post_fn -> normalize_post_fn(post_fn)
        end
    end
  end

  defp normalize_post_fn(post_fn) when is_function(post_fn, 2), do: {:ok, post_fn}

  defp normalize_post_fn(_post_fn) do
    {:error, {:invalid_post_fn, "post_fn must be a two-arity function"}}
  end

  # ---------------------------------------------------------------------------
  # HTTP dispatch
  # ---------------------------------------------------------------------------

  defp post(spec, post_fn) do
    request_options = [json: spec.payload, headers: spec.headers] ++ spec.req_options

    case safe_post(post_fn, spec.url, request_options) do
      {:ok, %{status: status} = response} when is_integer(status) ->
        {:ok, response}

      {:ok, other} ->
        {:error,
         {:provider_network_error, %{reason: safe_summary({:unexpected_response, other})}}}

      {:error, reason} ->
        {:error, {:provider_network_error, %{reason: safe_summary(reason)}}}
    end
  end

  defp safe_post(post_fn, url, request_options) do
    post_fn.(url, request_options)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # ---------------------------------------------------------------------------
  # HTTP response handling
  # ---------------------------------------------------------------------------

  defp decode_http_response(%{status: status, body: body})
       when is_integer(status) and status >= 200 and status <= 299 do
    decode_success_body(body)
  end

  defp decode_http_response(%{status: status, body: body}) when is_integer(status) do
    {:error,
     {:provider_http_error,
      %{
        status: status,
        body_summary: safe_summary(body)
      }}}
  end

  defp decode_http_response(response) do
    {:error, {:provider_network_error, %{reason: safe_summary({:unexpected_response, response})}}}
  end

  defp decode_success_body(body) do
    with {:ok, decoded_body} <- decode_json_body(body),
         {:ok, response} <- decode_anthropic_messages(decoded_body) do
      {:ok, response}
    else
      {:error, {:provider_decode_error, _reason} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, {:provider_decode_error, safe_summary(reason)}}
    end
  end

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json_response, Exception.message(reason)}}
    end
  end

  defp decode_json_body(body), do: {:ok, body}

  # ---------------------------------------------------------------------------
  # Anthropic Messages response decoding
  # ---------------------------------------------------------------------------

  defp decode_anthropic_messages(body) when is_map(body) do
    with {:ok, id} <- optional_string(body, "id"),
         {:ok, content_blocks} <- decode_content_blocks(body),
         {:ok, text} <- extract_text(content_blocks),
         {:ok, tool_calls} <- extract_tool_calls(content_blocks),
         {:ok, stop_reason} <- decode_stop_reason(body),
         {:ok, usage} <- decode_usage(body) do
      {:ok,
       Response.new(
         id: id,
         content: text,
         text: text,
         tool_calls: tool_calls,
         usage: usage,
         finish_reason: normalize_stop_reason(stop_reason),
         raw: bounded_raw(body)
       )}
    end
  end

  defp decode_anthropic_messages(_body) do
    {:error, {:invalid_response, "expected Anthropic Messages response body to be a map"}}
  end

  defp decode_content_blocks(body) do
    case fetch_any(body, "content") do
      {:ok, blocks} when is_list(blocks) -> {:ok, blocks}
      {:ok, _other} -> {:ok, []}
      :error -> {:ok, []}
    end
  end

  defp extract_text(content_blocks) do
    text_parts =
      content_blocks
      |> Enum.filter(fn
        %{"type" => "text"} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %{"text" => text} when is_binary(text) -> text
        _ -> ""
      end)

    case text_parts do
      [] -> {:ok, nil}
      parts -> {:ok, Enum.join(parts, "\n")}
    end
  end

  defp extract_tool_calls(content_blocks) do
    tool_calls =
      content_blocks
      |> Enum.filter(fn
        %{"type" => "tool_use"} -> true
        _ -> false
      end)
      |> Enum.map(&decode_tool_use_block/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, tc} -> tc end)

    {:ok, tool_calls}
  end

  defp decode_tool_use_block(%{"id" => id, "name" => name, "input" => input})
       when is_binary(name) do
    arguments = if is_map(input), do: input, else: %{}
    {:ok, ToolCall.new(name, arguments, id: id)}
  end

  defp decode_tool_use_block(_block), do: :skip

  defp decode_stop_reason(body) do
    case fetch_any(body, "stop_reason") do
      {:ok, reason} when is_binary(reason) or is_nil(reason) -> {:ok, reason}
      {:ok, _other} -> {:ok, nil}
      :error -> {:ok, nil}
    end
  end

  defp normalize_stop_reason("end_turn"), do: "stop"
  defp normalize_stop_reason("tool_use"), do: "tool_calls"
  defp normalize_stop_reason("max_tokens"), do: "length"
  defp normalize_stop_reason("stop_sequence"), do: "stop"
  defp normalize_stop_reason(other) when is_binary(other), do: other
  defp normalize_stop_reason(nil), do: nil

  defp decode_usage(body) do
    case fetch_any(body, "usage") do
      {:ok, nil} -> {:ok, nil}
      {:ok, usage} when is_map(usage) -> {:ok, normalize_usage(usage)}
      {:ok, _other} -> {:ok, nil}
      :error -> {:ok, nil}
    end
  end

  defp normalize_usage(usage) do
    normalized = %{}

    normalized =
      case fetch_any(usage, "input_tokens") do
        {:ok, n} when is_integer(n) -> Map.put(normalized, :prompt_tokens, n)
        _ -> normalized
      end

    normalized =
      case fetch_any(usage, "output_tokens") do
        {:ok, n} when is_integer(n) -> Map.put(normalized, :completion_tokens, n)
        _ -> normalized
      end

    if normalized == %{}, do: nil, else: normalized
  end

  # Bound the raw payload to avoid storing unbounded provider responses
  defp bounded_raw(body) when is_map(body) do
    MetadataSanitizer.sanitize(body,
      max_depth: 4,
      max_map_keys: 20,
      max_list_length: 10,
      max_string_len: @max_summary_string_length
    )
  end

  defp bounded_raw(body), do: safe_summary(body)

  # ---------------------------------------------------------------------------
  # Event emission (non-streaming replay)
  # ---------------------------------------------------------------------------

  defp emit_response_events(%Response{} = response, emit_fn) do
    emit_fn.(Event.response_started())

    response
    |> response_text()
    |> maybe_emit_assistant_events(emit_fn)

    response.tool_calls
    |> List.wrap()
    |> Enum.each(fn tool_call ->
      emit_fn.(Event.tool_call_started(tool_call))
      emit_fn.(Event.tool_call_completed(tool_call))
    end)

    emit_fn.(Event.response_completed(response.usage))
  end

  defp maybe_emit_assistant_events(nil, _emit_fn), do: :ok
  defp maybe_emit_assistant_events("", _emit_fn), do: :ok

  defp maybe_emit_assistant_events(text, emit_fn) when is_binary(text) do
    emit_fn.(Event.assistant_delta(text))
    emit_fn.(Event.assistant_completed(text))
  end

  defp response_text(%Response{content: content}) when is_binary(content), do: content
  defp response_text(%Response{text: text}) when is_binary(text), do: text
  defp response_text(_response), do: nil

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_any(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:ok, Map.fetch!(map, String.to_atom(key))}
      true -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp optional_string(map, key) do
    case fetch_any(map, key) do
      {:ok, value} when is_binary(value) or is_nil(value) -> {:ok, value}
      {:ok, _other} -> {:ok, nil}
      :error -> {:ok, nil}
    end
  end

  defp option_value(map, key) when is_map(map), do: Map.get(map, key)
  defp option_value(_map, _key), do: nil

  defp redact_error(reason), do: safe_summary(reason)

  defp safe_summary(term) when is_binary(term) do
    term
    |> EventPayloadRedactor.redact_string()
    |> String.slice(0, @max_summary_string_length)
  end

  defp safe_summary(term) do
    term
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize(
      max_depth: 4,
      max_map_keys: 20,
      max_list_length: 10,
      max_string_len: @max_summary_string_length
    )
  rescue
    _exception ->
      term
      |> inspect(limit: 10, printable_limit: @max_summary_string_length)
      |> EventPayloadRedactor.redact_string()
      |> String.slice(0, @max_summary_string_length)
  end
end
