defmodule Muse.LLM.OpenAICompatibleProvider do
  @moduledoc """
  OpenAI-compatible non-streaming provider adapter.

  This provider performs a single Chat Completions-compatible HTTP POST, decodes
  the complete response into Muse's normalized response struct, and can replay
  the result as canonical Muse LLM events for callers using `stream/2`.

  This adapter keeps auth resolution centralized in `Muse.Auth.Resolver`:

    * no SSE parser
    * no WebSocket client
    * fake provider remains the offline/default provider
    * configured auth modes resolve before any HTTP call

  Callers may pass explicit headers through `request.options[:headers]`; those
  headers are sent to the provider but are never included in returned/emitted
  error data. If an explicit `Authorization` header is present, it wins and the
  auth layer does not overwrite or duplicate it.
  """

  @behaviour Muse.LLM.Provider

  alias Muse.Auth.Resolver
  alias Muse.{EventPayloadRedactor, MetadataSanitizer}
  alias Muse.LLM.OpenAI.RequestBuilder
  alias Muse.LLM.{Event, Request, Response, ToolCall}

  @chat_completions_decoder Module.concat(Muse.LLM.OpenAI, ChatCompletionsDecoder)
  @max_summary_string_length 500

  @type post_fn :: (String.t(), keyword() -> {:ok, term()} | {:error, term()})

  @doc """
  Complete a request through an OpenAI-compatible Chat Completions endpoint.

  Tests and offline callers can inject `opts[:post_fn]`, a two-arity function
  with the same call shape as `Req.post/2`: `post_fn.(url, options)`.
  """
  @spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(request), do: complete(request, [])

  @impl true
  @spec complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request, opts) when is_list(opts) do
    with {:ok, spec} <- RequestBuilder.build_chat_completions(request),
         {:ok, spec} <- attach_auth(spec, request, opts),
         {:ok, post_fn} <- complete_post_fn(opts),
         {:ok, http_response} <- post(spec, post_fn) do
      decode_http_response(http_response)
    end
  end

  def complete(%Request{}, _opts), do: {:error, {:invalid_options, "opts must be a keyword list"}}

  @doc """
  Emit canonical Muse events by performing the same non-streaming HTTP call.

  Because the provider behaviour only passes `(request, emit_fn)` for streaming,
  offline tests may inject a post function via `request.options[:post_fn]` or
  `request.options[:http_post]`.
  """
  @impl true
  @spec stream(Request.t(), (Event.t() -> :ok)) :: {:ok, Response.t()} | {:error, term()}
  def stream(%Request{} = request, emit_fn) when is_function(emit_fn, 1) do
    opts = request_options(request)

    result =
      request
      |> RequestBuilder.build_chat_completions()
      |> with_auth(request, [])
      |> with_stream_post_fn(opts)
      |> complete_from_stream_spec()

    case result do
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

  defp with_auth({:ok, spec}, request, opts), do: attach_auth(spec, request, opts)
  defp with_auth({:error, reason}, _request, _opts), do: {:error, reason}

  defp attach_auth(%{headers: headers} = spec, request, opts)
       when is_list(headers) do
    if authorization_header?(headers) do
      {:ok, spec}
    else
      resolve_and_attach_auth(spec, request, opts)
    end
  end

  defp attach_auth(spec, request, opts), do: resolve_and_attach_auth(spec, request, opts)

  defp resolve_and_attach_auth(spec, request, opts) do
    case Resolver.resolve(request, opts) do
      {:ok, credential} ->
        {:ok, append_authorization_header(spec, credential)}

      :none ->
        {:ok, spec}

      {:error, reason} ->
        {:error, {:auth_error, safe_auth_reason(reason)}}
    end
  end

  defp authorization_header?(headers) do
    Enum.any?(headers, fn
      {name, _value} when is_binary(name) -> String.downcase(name) == "authorization"
      _other -> false
    end)
  end

  defp append_authorization_header(%{headers: headers} = spec, credential) do
    %{spec | headers: headers ++ [{"Authorization", "Bearer " <> credential.value}]}
  end

  defp safe_auth_reason(reason), do: EventPayloadRedactor.redact(reason)

  # ---------------------------------------------------------------------------
  # HTTP dispatch
  # ---------------------------------------------------------------------------

  defp complete_post_fn(opts) do
    case Keyword.fetch(opts, :post_fn) do
      {:ok, post_fn} -> normalize_post_fn(post_fn)
      :error -> {:ok, &Req.post/2}
    end
  end

  defp with_stream_post_fn({:ok, spec}, opts) do
    case option_value(opts, :post_fn) || option_value(opts, :http_post) do
      nil -> {:ok, spec, &Req.post/2}
      post_fn -> with {:ok, fun} <- normalize_post_fn(post_fn), do: {:ok, spec, fun}
    end
  end

  defp with_stream_post_fn({:error, reason}, _opts), do: {:error, reason}

  defp normalize_post_fn(post_fn) when is_function(post_fn, 2), do: {:ok, post_fn}

  defp normalize_post_fn(_post_fn) do
    {:error, {:invalid_post_fn, "post_fn must be a two-arity function"}}
  end

  defp complete_from_stream_spec({:ok, spec, post_fn}) do
    with {:ok, http_response} <- post(spec, post_fn) do
      decode_http_response(http_response)
    end
  end

  defp complete_from_stream_spec({:error, reason}), do: {:error, reason}

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
         {:ok, response} <- decode_chat_completions(decoded_body) do
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

  defp decode_chat_completions(body) do
    if Code.ensure_loaded?(@chat_completions_decoder) and
         function_exported?(@chat_completions_decoder, :decode, 1) do
      apply(@chat_completions_decoder, :decode, [body])
    else
      compat_decode_chat_completions(body)
    end
  end

  # ---------------------------------------------------------------------------
  # Event emission
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
  # Private compatibility decoder
  # ---------------------------------------------------------------------------

  defp compat_decode_chat_completions(body) when is_map(body) do
    with {:ok, choice} <- first_choice(body),
         {:ok, message} <- required_map(choice, "message", "choices[0].message"),
         {:ok, tool_calls} <- decode_tool_calls(message),
         {:ok, content} <- decode_content(message, tool_calls),
         {:ok, finish_reason} <- decode_finish_reason(choice),
         {:ok, id} <- optional_string(body, "id", "id"),
         {:ok, usage} <- decode_usage(body) do
      {:ok,
       Response.new(
         id: id,
         content: content,
         text: content,
         tool_calls: tool_calls,
         usage: usage,
         finish_reason: finish_reason,
         raw: body
       )}
    end
  end

  defp compat_decode_chat_completions(_body) do
    {:error, {:invalid_response, "expected Chat Completions response body to be a map"}}
  end

  defp first_choice(body) do
    case fetch_any(body, "choices") do
      {:ok, [choice | _]} when is_map(choice) -> {:ok, choice}
      {:ok, []} -> {:error, {:invalid_response, "choices must be a non-empty list"}}
      {:ok, _other} -> {:error, {:invalid_response, "choices must be a non-empty list"}}
      :error -> {:error, {:invalid_response, "missing required field choices"}}
    end
  end

  defp required_map(map, key, path) do
    case fetch_any(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_response, "#{path} must be a map"}}
      :error -> {:error, {:invalid_response, "missing required field #{path}"}}
    end
  end

  defp decode_content(message, tool_calls) do
    case fetch_any(message, "content") do
      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:ok, nil} when tool_calls != [] ->
        {:ok, nil}

      {:ok, nil} ->
        {:error, {:invalid_response, "choices[0].message.content must be a string"}}

      {:ok, _other} ->
        {:error, {:invalid_response, "choices[0].message.content must be a string or nil"}}

      :error when tool_calls != [] ->
        {:ok, nil}

      :error ->
        {:error, {:invalid_response, "missing required field choices[0].message.content"}}
    end
  end

  defp decode_finish_reason(choice) do
    case fetch_any(choice, "finish_reason") do
      {:ok, reason} when is_binary(reason) or is_nil(reason) ->
        {:ok, reason}

      {:ok, _other} ->
        {:error, {:invalid_response, "choices[0].finish_reason must be a string or nil"}}

      :error ->
        {:ok, nil}
    end
  end

  defp decode_usage(body) do
    case fetch_any(body, "usage") do
      {:ok, nil} -> {:ok, nil}
      {:ok, usage} when is_map(usage) -> {:ok, normalize_usage(usage)}
      {:ok, _other} -> {:error, {:invalid_response, "usage must be a map or nil"}}
      :error -> {:ok, nil}
    end
  end

  defp normalize_usage(usage) do
    usage
    |> Map.drop(["prompt_tokens", :prompt_tokens, "completion_tokens", :completion_tokens])
    |> Map.drop(["total_tokens", :total_tokens])
    |> Map.merge(optional_usage(usage, "prompt_tokens", :prompt_tokens))
    |> Map.merge(optional_usage(usage, "completion_tokens", :completion_tokens))
    |> Map.merge(optional_usage(usage, "total_tokens", :total_tokens))
  end

  defp optional_usage(usage, string_key, atom_key) do
    cond do
      Map.has_key?(usage, string_key) -> %{atom_key => Map.fetch!(usage, string_key)}
      Map.has_key?(usage, atom_key) -> %{atom_key => Map.fetch!(usage, atom_key)}
      true -> %{}
    end
  end

  defp decode_tool_calls(message) do
    case fetch_any(message, "tool_calls") do
      {:ok, nil} -> {:ok, []}
      {:ok, calls} when is_list(calls) -> decode_tool_call_list(calls)
      {:ok, _other} -> {:error, {:invalid_tool_call, "tool_calls must be a list or nil"}}
      :error -> {:ok, []}
    end
  end

  defp decode_tool_call_list(calls) do
    calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {call, index}, {:ok, acc} ->
      case decode_tool_call(call, index) do
        {:ok, tool_call} -> {:cont, {:ok, [tool_call | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tool_calls} -> {:ok, Enum.reverse(tool_calls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_tool_call(call, index) when is_map(call) do
    path = "choices[0].message.tool_calls[#{index}]"

    with {:ok, function} <- required_tool_function(call, path),
         {:ok, name} <- required_tool_name(function, path),
         {:ok, arguments} <- decode_tool_arguments(function, path),
         {:ok, id} <- optional_string(call, "id", "#{path}.id") do
      {:ok, ToolCall.new(name, arguments, id: id, raw: call)}
    end
  end

  defp decode_tool_call(_call, index) do
    {:error, {:invalid_tool_call, "choices[0].message.tool_calls[#{index}] must be a map"}}
  end

  defp required_tool_function(call, path) do
    case fetch_any(call, "function") do
      {:ok, function} when is_map(function) -> {:ok, function}
      {:ok, _other} -> {:error, {:invalid_tool_call, "#{path}.function must be a map"}}
      :error -> {:error, {:invalid_tool_call, "missing required field #{path}.function"}}
    end
  end

  defp required_tool_name(function, path) do
    case fetch_any(function, "name") do
      {:ok, name} when is_binary(name) -> {:ok, name}
      {:ok, _other} -> {:error, {:invalid_tool_call, "#{path}.function.name must be a string"}}
      :error -> {:error, {:invalid_tool_call, "missing required field #{path}.function.name"}}
    end
  end

  defp decode_tool_arguments(function, path) do
    case fetch_any(function, "arguments") do
      {:ok, arguments} -> decode_tool_arguments_value(arguments, path)
      :error -> {:ok, %{}}
    end
  end

  defp decode_tool_arguments_value(nil, _path), do: {:ok, %{}}
  defp decode_tool_arguments_value(arguments, _path) when is_map(arguments), do: {:ok, arguments}

  defp decode_tool_arguments_value(arguments, path) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> decode_tool_arguments_value(nil, path)
      json -> decode_tool_arguments_json(json, path)
    end
  end

  defp decode_tool_arguments_value(_arguments, path) do
    {:error,
     {:invalid_tool_call_arguments, "#{path}.function.arguments must be a JSON object string"}}
  end

  defp decode_tool_arguments_json(json, path) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error,
         {:invalid_tool_call_arguments, "#{path}.function.arguments must decode to a map"}}

      {:error, reason} ->
        {:error,
         {:invalid_tool_call_arguments,
          "invalid JSON in #{path}.function.arguments: #{Exception.message(reason)}"}}
    end
  end

  defp optional_string(map, key, path) do
    case fetch_any(map, key) do
      {:ok, value} when is_binary(value) or is_nil(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_response, "#{path} must be a string or nil"}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_any(map, key) when is_map(map) and is_binary(key) do
    atom_key = atom_key(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.fetch!(map, atom_key)}
      true -> :error
    end
  end

  defp atom_key("arguments"), do: :arguments
  defp atom_key("choices"), do: :choices
  defp atom_key("completion_tokens"), do: :completion_tokens
  defp atom_key("content"), do: :content
  defp atom_key("finish_reason"), do: :finish_reason
  defp atom_key("function"), do: :function
  defp atom_key("id"), do: :id
  defp atom_key("message"), do: :message
  defp atom_key("name"), do: :name
  defp atom_key("prompt_tokens"), do: :prompt_tokens
  defp atom_key("tool_calls"), do: :tool_calls
  defp atom_key("total_tokens"), do: :total_tokens
  defp atom_key("usage"), do: :usage

  # ---------------------------------------------------------------------------
  # Safe option access and redaction
  # ---------------------------------------------------------------------------

  defp request_options(%Request{options: options}) when is_map(options), do: options
  defp request_options(_request), do: %{}

  defp option_value(map, key) when is_map(map), do: Map.get(map, key)

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
