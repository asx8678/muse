defmodule Muse.LLM.OpenAI.ResponsesWebsocket.Stream do
  @moduledoc """
  Draft Responses WebSocket stream executor for the OpenAI-compatible provider.

  A concrete WebSocket client is not wired in yet. Callers/tests inject
  `request.options[:ws_stream_fn]`, which receives the redacted-safe connection
  spec and drives provider frames through the supplied callback:

      ws_stream_fn = fn websocket_url, ws_options, on_frame ->
        on_frame.(%{"type" => "response.completed", "response" => %{"id" => "resp_1"}})
        {:ok, :closed}
      end

  `ws_options[:headers]` is the only place resolved Authorization credentials
  are exposed. All returned errors and emitted provider errors are redacted.
  """

  alias Muse.Auth.Resolver
  alias Muse.{EventPayloadRedactor, MetadataSanitizer}
  alias Muse.LLM.Event
  alias Muse.LLM.OpenAI.ResponsesWebsocket.{EventDecoder, RequestBuilder}
  alias Muse.LLM.Request

  @max_summary_string_length 500

  @type ws_stream_fn :: (String.t(), keyword(), (term() -> :ok) ->
                           {:ok, term()} | {:error, term()})

  @doc """
  Stream a Responses WebSocket request through an injected `ws_stream_fn`.
  """
  @spec stream(Request.t(), (Event.t() -> :ok)) :: {:ok, Muse.LLM.Response.t()} | {:error, term()}
  def stream(%Request{} = request, emit_fn) when is_function(emit_fn, 1) do
    with {:ok, spec} <- RequestBuilder.build(request),
         {:ok, spec} <- attach_auth(spec, request),
         {:ok, ws_stream_fn} <- resolve_ws_stream_fn(request.options) do
      stream_with_spec(spec, ws_stream_fn, emit_fn)
    else
      {:error, reason} -> emit_and_return_error(emit_fn, reason)
    end
  end

  defp stream_with_spec(spec, ws_stream_fn, emit_fn) do
    case Agent.start_link(fn -> EventDecoder.new() end) do
      {:ok, agent} ->
        try do
          on_frame = on_frame(agent, emit_fn)
          emit_fn.(Event.response_started())

          case safe_ws_stream(
                 ws_stream_fn,
                 spec.websocket_url,
                 ws_request_options(spec),
                 on_frame
               ) do
            {:ok, _result} ->
              finish_stream(agent, emit_fn)

            {:error, reason} ->
              fail_unless_already_failed(agent, emit_fn, {:ws_transport_error, reason})

            :invalid_return ->
              fail_unless_already_failed(
                agent,
                emit_fn,
                {:invalid_ws_stream_result,
                 "ws_stream_fn must return {:ok, term} or {:error, term}"}
              )
          end
        after
          stop_agent(agent)
        end

      {:error, reason} ->
        emit_and_return_error(emit_fn, {:ws_decoder_state_error, reason})
    end
  end

  defp on_frame(agent, emit_fn) do
    fn frame ->
      events =
        Agent.get_and_update(agent, fn state ->
          {events, new_state} = EventDecoder.feed(state, frame)
          {events, new_state}
        end)

      Enum.each(events, &emit_fn.(&1))
      :ok
    end
  end

  defp finish_stream(agent, emit_fn) do
    state = Agent.get(agent, & &1)

    if EventDecoder.failed?(state) do
      {:error, EventDecoder.error_reason(state)}
    else
      case EventDecoder.finalize(state) do
        {:ok, response, events} ->
          Enum.each(events, &emit_fn.(&1))
          {:ok, response}

        {:error, reason} ->
          emit_and_return_error(emit_fn, reason)
      end
    end
  end

  defp fail_unless_already_failed(agent, emit_fn, reason) do
    state = Agent.get(agent, & &1)

    if EventDecoder.failed?(state) do
      {:error, EventDecoder.error_reason(state)}
    else
      emit_and_return_error(emit_fn, reason)
    end
  end

  defp stop_agent(agent) do
    Agent.stop(agent, :normal, 5000)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_ws_stream(ws_stream_fn, websocket_url, ws_options, on_frame) do
    case ws_stream_fn.(websocket_url, ws_options, on_frame) do
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
      _other -> :invalid_return
    end
  rescue
    exception -> {:error, {:ws_stream_exception, exception}}
  catch
    kind, reason -> {:error, {:ws_stream_caught, kind, reason}}
  end

  defp ws_request_options(spec) do
    [
      headers: spec.headers,
      frame: spec.frame,
      connect_options: spec.connect_options,
      req_options: spec.req_options
    ]
  end

  defp resolve_ws_stream_fn(options) when is_map(options) do
    case option_value(options, :ws_stream_fn) || option_value(options, "ws_stream_fn") do
      ws_stream_fn when is_function(ws_stream_fn, 3) ->
        {:ok, ws_stream_fn}

      nil ->
        {:error,
         {:missing_ws_stream_fn,
          "ws_stream_fn is required until a Responses WebSocket transport is configured"}}

      _other ->
        {:error, {:invalid_ws_stream_fn, "ws_stream_fn must be a three-arity function"}}
    end
  end

  defp resolve_ws_stream_fn(_options) do
    {:error,
     {:missing_ws_stream_fn,
      "ws_stream_fn is required until a Responses WebSocket transport is configured"}}
  end

  defp attach_auth(%{headers: headers} = spec, request) when is_list(headers) do
    if authorization_header?(headers) do
      {:ok, spec}
    else
      resolve_and_attach_auth(spec, request)
    end
  end

  defp attach_auth(spec, request), do: resolve_and_attach_auth(spec, request)

  defp resolve_and_attach_auth(spec, request) do
    case Resolver.resolve(request, []) do
      {:ok, %{value: value}} when is_binary(value) ->
        {:ok, append_authorization_header(spec, value)}

      {:ok, _credential} ->
        {:error, {:auth_error, "auth resolver returned an invalid credential"}}

      :none ->
        {:ok, spec}

      {:error, reason} ->
        {:error, {:auth_error, safe_summary(reason)}}
    end
  end

  defp authorization_header?(headers) do
    Enum.any?(headers, fn
      {name, _value} when is_binary(name) -> String.downcase(name) == "authorization"
      _other -> false
    end)
  end

  defp append_authorization_header(%{headers: headers} = spec, credential_value) do
    %{spec | headers: headers ++ [{"Authorization", "Bearer " <> credential_value}]}
  end

  defp emit_and_return_error(emit_fn, reason) do
    redacted = safe_summary(reason)
    emit_fn.(Event.provider_error(redacted))
    {:error, redacted}
  end

  defp option_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

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
