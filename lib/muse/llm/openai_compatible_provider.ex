defmodule Muse.LLM.OpenAICompatibleProvider do
  @moduledoc """
  OpenAI-compatible provider adapter with SSE and Responses WebSocket streaming.

  This provider performs a single Chat Completions-compatible HTTP POST and
  decodes the complete response into Muse's normalized response struct.
  When the caller selects SSE transport (`request.transport == :sse` or
  `request.options[:transport] == :sse`), `stream/2` opens an HTTP stream
  and emits canonical events incrementally as chunks arrive.

  ## Transport selection

    * `wire_api == :responses` and `transport == :websocket` (on request
      struct or `request.options[:transport]`): Responses WebSocket streaming
      using the `response.create` / event frame protocol.
    * `wire_api == :responses` and `transport == :sse` (on request
      struct or `request.options[:transport]`): Responses HTTP SSE streaming
      using the shared `ResponsesStreamDecoder`.
    * `transport == :sse` (on request struct or `request.options[:transport]`):
      streaming Chat Completions with `"stream" => true`, real SSE parsing,
      incremental event emission.
    * Otherwise (default): non-streaming POST with full-response replay.

  ## Auth

  Auth resolution is centralized in `Muse.Auth.Resolver`. Callers may pass
  explicit headers through `request.options[:headers]`; those headers are sent
  to the provider but are never included in returned/emitted error data. If an
  explicit `Authorization` header is present, it wins and the auth layer does
  not overwrite or duplicate it. Raw tokens appear only in the outbound
  Authorization header.

  ## SSE function injection

  For SSE streaming, callers can inject an `sse_post_fn` via
  `request.options[:sse_post_fn]` to avoid network calls in tests. The shape
  is:

      sse_post_fn = fn url, req_options, on_chunk ->
        on_chunk.(raw_sse_chunk)
        {:ok, %{status: 200}}
      end

  `on_chunk` is a one-arity function receiving raw SSE text (possibly partial).
  The injected function must call `on_chunk` zero or more times and return
  `{:ok, %{status: integer}}` or `{:error, reason}`.

  The default `sse_post_fn` uses `Muse.LLM.Transport.SSE.ReqStream.request/2`.
  Tests that want to exercise the default provider path without a network call
  may pass `request.options[:post_stream_fn]`, which is forwarded to ReqStream.

  ## Responses WebSocket function injection

  For Responses WebSocket streaming, callers **must** inject a `ws_stream_fn`
  via `request.options[:ws_stream_fn]` (or `"ws_stream_fn"`). The shape is:

      ws_stream_fn = fn url, ws_options, on_frame ->
        # url:          WebSocket URL (wss://...)
        # ws_options:   keyword list with :headers, :create_frame, optional timeouts
        # on_frame:     one-arity callback receiving JSON binary frames
        on_frame.(frame)
        {:ok, %{}}
      end

  `ws_options` contains `:headers` (Authorization, etc.), `:create_frame`
  (the `response.create` frame to send), and optional `:timeout_ms`,
  `:receive_timeout`, `:max_retries`. The injected function must call
  `on_frame` zero or more times and return `{:ok, result}` or
  `{:error, reason}`.

  ## SSE Fallback

  When WebSocket setup fails before any inbound provider frame is received,
  callers can enable SSE fallback via `request.options[:fallback_transport]`
  set to `:sse`, or `request.options[:fallback_to_sse]` set to `true`.
  Fallback is NOT attempted after midstream failure (after any inbound
  frame/delta). On midstream failure, a redacted `:provider_error` is emitted
  with no completed events.

  ## Error handling

  On malformed JSON, midstream failure, transport error, `response.failed`,
  or missing `response.completed`, the provider emits exactly one
  `:provider_error` event and returns an error. No `:assistant_completed` or
  `:response_completed` events are emitted after a failure. All error data is
  redacted — raw tokens, request bodies, and full response payloads never
  leak through.
  """

  @behaviour Muse.LLM.Provider

  alias Muse.Auth.Resolver
  alias Muse.{EventPayloadRedactor, MetadataSanitizer}

  alias Muse.LLM.OpenAI.{
    ChatCompletionsStreamDecoder,
    RequestBuilder,
    ResponsesMapper,
    ResponsesStreamDecoder,
    ResponsesWebSocket
  }

  alias Muse.LLM.Transport.SSE.Parser, as: SSEParser
  alias Muse.LLM.Transport.SSE.ReqStream
  alias Muse.LLM.{Event, Request, Response, ToolCall}

  @chat_completions_decoder Module.concat(Muse.LLM.OpenAI, ChatCompletionsDecoder)
  @max_summary_string_length 500

  @type post_fn :: (String.t(), keyword() -> {:ok, term()} | {:error, term()})
  @type sse_post_fn ::
          (String.t(), keyword(), (String.t() -> :ok) ->
             {:ok, %{status: integer()}} | {:error, term()})
  @type ws_stream_fn ::
          (String.t(), keyword(), (binary() -> :ok) ->
             {:ok, term()} | {:error, term()})

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
  Stream a request, emitting canonical Muse events incrementally.

  ## Transport dispatch

    * When `request.transport == :sse` or `request.options[:transport] == :sse`,
      opens an SSE streaming connection and emits events incrementally.
    * Otherwise, performs a non-streaming POST and replays the full response
      as events.

  ## Injection

  Non-SSE path: inject `post_fn` or `http_post` in `request.options`.
  SSE path: inject `sse_post_fn` in `request.options`.
  """
  @impl true
  @spec stream(Request.t(), (Event.t() -> :ok)) :: {:ok, Response.t()} | {:error, term()}
  def stream(%Request{} = request, emit_fn) when is_function(emit_fn, 1) do
    cond do
      responses_ws_transport?(request) -> stream_responses_ws(request, emit_fn)
      responses_sse_transport?(request) -> stream_responses_sse(request, emit_fn)
      sse_transport?(request) -> stream_sse(request, emit_fn)
      true -> stream_non_streaming(request, emit_fn)
    end
  end

  # ---------------------------------------------------------------------------
  # SSE streaming path
  # ---------------------------------------------------------------------------

  defp sse_transport?(%Request{transport: :sse}), do: true
  defp sse_transport?(%Request{options: %{transport: :sse}}), do: true
  defp sse_transport?(%Request{options: %{"transport" => :sse}}), do: true
  defp sse_transport?(_request), do: false

  defp responses_ws_transport?(%Request{wire_api: :responses, transport: :websocket}), do: true

  defp responses_ws_transport?(%Request{wire_api: :responses, options: %{transport: :websocket}}),
    do: true

  defp responses_ws_transport?(%Request{
         wire_api: :responses,
         options: %{"transport" => :websocket}
       }),
       do: true

  defp responses_ws_transport?(_request), do: false

  defp responses_sse_transport?(%Request{wire_api: :responses, transport: :sse}), do: true

  defp responses_sse_transport?(%Request{wire_api: :responses, options: %{transport: :sse}}),
    do: true

  defp responses_sse_transport?(%Request{wire_api: :responses, options: %{"transport" => :sse}}),
    do: true

  defp responses_sse_transport?(_request), do: false

  # ---------------------------------------------------------------------------
  # Responses SSE streaming path
  # ---------------------------------------------------------------------------

  defp stream_responses_sse(request, emit_fn) do
    with {:ok, spec} <- build_responses_sse_spec(request),
         {:ok, spec} <- attach_auth(spec, request, []),
         {:ok, sse_post_fn} <- resolve_sse_post_fn(request.options) do
      {:ok, agent} =
        Agent.start_link(fn ->
          {SSEParser.new(), ResponsesStreamDecoder.new(), false}
        end)

      on_chunk = fn raw_chunk when is_binary(raw_chunk) ->
        pending_events =
          Agent.get_and_update(agent, fn {parser_state, decoder_state, failed?} ->
            if failed? do
              {[], {parser_state, decoder_state, true}}
            else
              {sse_events, new_parser} = SSEParser.parse_chunk(raw_chunk, parser_state)

              {events, new_decoder, now_failed?} =
                process_responses_sse_events(sse_events, decoder_state, failed?)

              {events, {new_parser, new_decoder, now_failed?}}
            end
          end)

        Enum.each(pending_events, &emit_fn.(&1))
        :ok
      end

      try do
        emit_fn.(Event.response_started())

        case safe_sse_post(
               sse_post_fn,
               spec.url,
               sse_request_options(spec, request.options),
               on_chunk
             ) do
          {:ok, %{status: status}} when is_integer(status) and status >= 200 and status <= 299 ->
            {parser_state, decoder_state, failed?} = Agent.get(agent, & &1)

            if failed? do
              {:error, {:provider_sse_error, "stream failed mid-flight"}}
            else
              {remaining_events, _final_parser} = SSEParser.flush(parser_state)

              {flush_events, final_decoder, flush_failed?} =
                process_responses_sse_events(remaining_events, decoder_state, false)

              Enum.each(flush_events, &emit_fn.(&1))

              if flush_failed? do
                {:error, {:provider_sse_error, "malformed data in final flush"}}
              else
                {response, final_events} = ResponsesStreamDecoder.finalize(final_decoder)
                Enum.each(final_events, &emit_fn.(&1))
                {:ok, response}
              end
            end

          {:ok, %{status: status}} when is_integer(status) ->
            redacted = redact_error({:provider_http_error, %{status: status}})
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}

          {:ok, other} ->
            redacted = redact_error({:unexpected_sse_response, other})
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}

          {:error, reason} ->
            redacted = redact_error({:sse_transport_error, reason})
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}
        end
      after
        Agent.stop(agent, :normal, 5000)
      end
    else
      {:error, reason} ->
        redacted = redact_error(reason)
        emit_fn.(Event.provider_error(redacted))
        {:error, redacted}
    end
  end

  defp build_responses_sse_spec(request) do
    case resolve_base_url(request.options) do
      {:ok, base_url} ->
        trimmed = String.trim_trailing(base_url, "/")
        url = trimmed <> ResponsesMapper.endpoint_path()
        payload = ResponsesMapper.to_payload(request) |> Map.put("stream", true)
        headers = resolve_headers_from_options(request.options)
        headers = ensure_sse_accept_header(headers)
        req_options = resolve_req_options(request.options)

        {:ok,
         %{
           url: url,
           endpoint_path: ResponsesMapper.endpoint_path(),
           payload: payload,
           headers: headers,
           req_options: req_options
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_responses_sse_events(sse_events, decoder_state, failed?) do
    Enum.reduce(sse_events, {[], decoder_state, failed?}, fn sse_event, {acc_events, ds, f?} ->
      if f? do
        {acc_events, ds, true}
      else
        process_one_responses_sse_event(sse_event, ds, acc_events)
      end
    end)
  end

  defp process_one_responses_sse_event(%{done?: true}, decoder_state, acc_events) do
    {acc_events, decoder_state, false}
  end

  defp process_one_responses_sse_event(%{data: data}, decoder_state, acc_events) do
    case Jason.decode(data) do
      {:ok, chunk_map} when is_map(chunk_map) ->
        {new_decoder, events} = ResponsesStreamDecoder.feed(decoder_state, chunk_map)
        {acc_events ++ events, new_decoder, false}

      {:ok, _other} ->
        {acc_events, decoder_state, false}

      {:error, _reason} ->
        error_event = Event.provider_error(redact_error({:sse_decode_error, "malformed JSON"}))
        {acc_events ++ [error_event], decoder_state, true}
    end
  end

  defp process_one_responses_sse_event(_sse_event, decoder_state, acc_events) do
    {acc_events, decoder_state, false}
  end

  # ---------------------------------------------------------------------------
  # Responses WebSocket streaming path
  # ---------------------------------------------------------------------------

  defp stream_responses_ws(request, emit_fn) do
    with {:ok, spec} <- ResponsesWebSocket.RequestBuilder.build(request),
         {:ok, spec} <- attach_auth(spec, request, []),
         {:ok, ws_stream_fn} <- resolve_ws_stream_fn(request.options) do
      {:ok, agent} = Agent.start_link(fn -> {ResponsesStreamDecoder.new(), false, false} end)

      on_frame = fn frame ->
        pending_events =
          Agent.get_and_update(agent, fn {decoder_state, failed?, _received_frame?} ->
            cond do
              failed? ->
                {[], {decoder_state, true, true}}

              true ->
                case decode_ws_frame(frame) do
                  {:ok, frame_map} when is_map(frame_map) ->
                    {new_state, events} = ResponsesStreamDecoder.feed(decoder_state, frame_map)
                    {events, {new_state, new_state.failed?, true}}

                  {:error, _reason} ->
                    error_event =
                      Event.provider_error(redact_error({:ws_decode_error, "malformed JSON"}))

                    {[error_event], {decoder_state, true, true}}
                end
            end
          end)

        Enum.each(pending_events, &emit_fn.(&1))
        :ok
      end

      try do
        emit_fn.(Event.response_started())

        ws_options = build_ws_options(spec)

        case safe_ws_stream(ws_stream_fn, spec.websocket_url, ws_options, on_frame) do
          {:ok, _result} ->
            {decoder_state, failed?, received_frame?} = Agent.get(agent, & &1)

            cond do
              failed? ->
                {:error, {:provider_ws_error, "stream failed mid-flight"}}

              decoder_state.response_id == nil and not decoder_state.failed? ->
                if not received_frame? and ws_fallback_to_sse?(request) do
                  fallback_to_responses_sse(request, emit_fn)
                else
                  redacted =
                    redact_error({:ws_missing_completion, "response.completed not received"})

                  emit_fn.(Event.provider_error(redacted))
                  {:error, redacted}
                end

              true ->
                {response, final_events} = ResponsesStreamDecoder.finalize(decoder_state)
                Enum.each(final_events, &emit_fn.(&1))
                {:ok, response}
            end

          {:error, reason} ->
            {_decoder_state, failed?, received_frame?} = Agent.get(agent, & &1)

            cond do
              failed? ->
                {:error, {:provider_ws_error, "stream failed mid-flight"}}

              ws_should_fallback_to_sse?(request, received_frame?, reason) ->
                fallback_to_responses_sse(request, emit_fn)

              true ->
                redacted = redact_error({:ws_transport_error, reason})
                emit_fn.(Event.provider_error(redacted))
                {:error, redacted}
            end
        end
      after
        Agent.stop(agent, :normal, 5000)
      end
    else
      {:error, reason} ->
        redacted = redact_error(reason)
        emit_fn.(Event.provider_error(redacted))
        {:error, redacted}
    end
  end

  defp ws_fallback_to_sse?(request) do
    request.options[:fallback_transport] == :sse or
      request.options["fallback_transport"] == :sse or
      request.options[:fallback_to_sse] == true or
      request.options["fallback_to_sse"] == true
  end

  defp ws_should_fallback_to_sse?(request, false, reason) do
    ws_fallback_to_sse?(request) and ws_safe_setup_error?(reason)
  end

  defp ws_should_fallback_to_sse?(_request, _received_frame?, _reason), do: false

  defp ws_safe_setup_error?(reason)
       when reason in [
              :connection_refused,
              :econnrefused,
              :websocket_client_not_configured,
              :no_websocket_client
            ] do
    true
  end

  defp ws_safe_setup_error?({:transport_error, reason}), do: ws_safe_setup_error?(reason)

  defp ws_safe_setup_error?({phase, _reason})
       when phase in [:connect_failed, :setup_failed, :websocket_client_not_configured] do
    true
  end

  defp ws_safe_setup_error?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    Enum.any?(
      [
        "connect_failed",
        "connection_refused",
        "econnrefused",
        "websocket_client_not_configured",
        "client_not_configured",
        "no_websocket_client"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp ws_safe_setup_error?(_reason), do: false

  defp fallback_to_responses_sse(request, emit_fn) do
    stream_responses_sse(request, emit_fn)
  end

  defp build_ws_options(spec) do
    opts = [
      headers: spec.headers,
      create_frame: spec.frame
    ]

    opts =
      if spec.req_options[:timeout_ms],
        do: Keyword.put(opts, :timeout_ms, spec.req_options[:timeout_ms]),
        else: opts

    opts =
      if spec.req_options[:receive_timeout],
        do: Keyword.put(opts, :receive_timeout, spec.req_options[:receive_timeout]),
        else: opts

    opts =
      if spec.req_options[:max_retries],
        do: Keyword.put(opts, :max_retries, spec.req_options[:max_retries]),
        else: opts

    opts
  end

  defp resolve_ws_stream_fn(opts) when is_map(opts) do
    case Map.get(opts, :ws_stream_fn) || Map.get(opts, "ws_stream_fn") do
      nil ->
        {:error,
         {:ws_stream_fn_required, "WebSocket streaming requires a ws_stream_fn to be provided"}}

      ws_stream_fn when is_function(ws_stream_fn, 3) ->
        {:ok, ws_stream_fn}

      _other ->
        {:error, {:invalid_ws_stream_fn, "ws_stream_fn must be a three-arity function"}}
    end
  end

  defp resolve_ws_stream_fn(_opts),
    do:
      {:error,
       {:ws_stream_fn_required, "WebSocket streaming requires a ws_stream_fn to be provided"}}

  defp safe_ws_stream(ws_stream_fn, url, ws_options, on_frame) do
    ws_stream_fn.(url, ws_options, on_frame)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp decode_ws_frame(frame) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, :not_a_map}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_ws_frame(frame) when is_map(frame), do: {:ok, frame}
  defp decode_ws_frame(_), do: {:error, :invalid_frame}

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

  defp resolve_headers_from_options(options) when is_map(options) do
    case option_value(options, :headers) || option_value(options, "headers") do
      nil -> []
      headers when is_map(headers) -> normalize_provider_headers(headers)
      headers when is_list(headers) -> normalize_provider_headers(headers)
      _ -> []
    end
  end

  defp resolve_headers_from_options(_options), do: []

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

  defp normalize_provider_headers(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp normalize_provider_headers(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp ensure_sse_accept_header(headers) do
    if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "accept" end) do
      headers
    else
      headers ++ [{"Accept", "text/event-stream"}]
    end
  end

  # ---------------------------------------------------------------------------
  # Chat Completions SSE streaming path
  # ---------------------------------------------------------------------------

  defp stream_sse(request, emit_fn) do
    with {:ok, spec} <- RequestBuilder.build_chat_completions_stream(request),
         {:ok, spec} <- attach_auth(spec, request, []),
         {:ok, sse_post_fn} <- resolve_sse_post_fn(request.options) do
      {:ok, agent} =
        Agent.start_link(fn ->
          {SSEParser.new(), ChatCompletionsStreamDecoder.new(), false}
        end)

      on_chunk = fn raw_chunk when is_binary(raw_chunk) ->
        pending_events =
          Agent.get_and_update(agent, fn {parser_state, decoder_state, failed?} ->
            if failed? do
              {[], {parser_state, decoder_state, true}}
            else
              {sse_events, new_parser} = SSEParser.parse_chunk(raw_chunk, parser_state)

              {events, new_decoder, now_failed?} =
                process_sse_events(sse_events, decoder_state, failed?)

              {events, {new_parser, new_decoder, now_failed?}}
            end
          end)

        Enum.each(pending_events, &emit_fn.(&1))
        :ok
      end

      try do
        emit_fn.(Event.response_started())

        case safe_sse_post(
               sse_post_fn,
               spec.url,
               sse_request_options(spec, request.options),
               on_chunk
             ) do
          {:ok, %{status: status}} when is_integer(status) and status >= 200 and status <= 299 ->
            {parser_state, decoder_state, failed?} = Agent.get(agent, & &1)

            if failed? do
              {:error, {:provider_sse_error, "stream failed mid-flight"}}
            else
              # Flush any remaining buffered SSE events
              {remaining_events, _final_parser} = SSEParser.flush(parser_state)

              {flush_events, final_decoder, flush_failed?} =
                process_sse_events(remaining_events, decoder_state, false)

              Enum.each(flush_events, &emit_fn.(&1))

              if flush_failed? do
                {:error, {:provider_sse_error, "malformed data in final flush"}}
              else
                {response, final_events} = ChatCompletionsStreamDecoder.finalize(final_decoder)
                Enum.each(final_events, &emit_fn.(&1))
                {:ok, response}
              end
            end

          {:ok, %{status: status}} when is_integer(status) ->
            redacted = redact_error({:provider_http_error, %{status: status}})
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}

          {:ok, other} ->
            redacted = redact_error({:unexpected_sse_response, other})
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}

          {:error, reason} ->
            redacted = redact_error({:sse_transport_error, reason})
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}
        end
      after
        Agent.stop(agent, :normal, 5000)
      end
    else
      {:error, reason} ->
        redacted = redact_error(reason)
        emit_fn.(Event.provider_error(redacted))
        {:error, redacted}
    end
  end

  defp process_sse_events(sse_events, decoder_state, failed?) do
    Enum.reduce(sse_events, {[], decoder_state, failed?}, fn sse_event, {acc_events, ds, f?} ->
      if f? do
        {acc_events, ds, true}
      else
        process_one_sse_event(sse_event, ds, acc_events)
      end
    end)
  end

  defp process_one_sse_event(%{done?: true}, decoder_state, acc_events) do
    {acc_events, decoder_state, false}
  end

  defp process_one_sse_event(%{data: data}, decoder_state, acc_events) do
    case Jason.decode(data) do
      {:ok, chunk_map} when is_map(chunk_map) ->
        {new_decoder, events} = ChatCompletionsStreamDecoder.feed(decoder_state, chunk_map)
        {acc_events ++ events, new_decoder, false}

      {:ok, _other} ->
        # Decoded but not a map — ignore
        {acc_events, decoder_state, false}

      {:error, _reason} ->
        # Malformed JSON in a chunk — emit provider_error, mark failed
        error_event = Event.provider_error(redact_error({:sse_decode_error, "malformed JSON"}))
        {acc_events ++ [error_event], decoder_state, true}
    end
  end

  defp process_one_sse_event(_sse_event, decoder_state, acc_events) do
    # Unknown/empty SSE events — ignore
    {acc_events, decoder_state, false}
  end

  defp resolve_sse_post_fn(opts) when is_map(opts) do
    case Map.get(opts, :sse_post_fn) do
      nil ->
        {:ok, &default_sse_post/3}

      sse_post_fn when is_function(sse_post_fn, 3) ->
        {:ok, sse_post_fn}

      _other ->
        {:error, {:invalid_sse_post_fn, "sse_post_fn must be a three-arity function"}}
    end
  end

  defp resolve_sse_post_fn(_opts), do: {:ok, &default_sse_post/3}

  @doc false
  defp default_sse_post(url, req_options, on_chunk) do
    body = Keyword.get(req_options, :json, %{})
    headers = Keyword.get(req_options, :headers, [])

    stream_opts =
      [url: url, body: body, headers: headers] ++ Keyword.drop(req_options, [:json, :headers])

    case ReqStream.request(stream_opts, on_chunk) do
      {:ok, %{status: _status} = result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_sse_post(sse_post_fn, url, req_options, on_chunk) do
    sse_post_fn.(url, req_options, on_chunk)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp sse_request_options(spec, request_options) do
    [json: spec.payload, headers: spec.headers] ++
      spec.req_options ++ req_stream_adapter_options(request_options)
  end

  defp req_stream_adapter_options(options) when is_map(options) do
    case option_value(options, :post_stream_fn) || option_value(options, "post_stream_fn") do
      post_stream_fn when is_function(post_stream_fn, 3) -> [post_stream_fn: post_stream_fn]
      _other -> []
    end
  end

  defp req_stream_adapter_options(_options), do: []

  # ---------------------------------------------------------------------------
  # Non-streaming replay path
  # ---------------------------------------------------------------------------

  defp stream_non_streaming(request, emit_fn) do
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
