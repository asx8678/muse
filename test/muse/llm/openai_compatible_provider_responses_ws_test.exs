defmodule Muse.LLM.OpenAICompatibleProviderResponsesWSTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAICompatibleProvider
  alias Muse.LLM.Request

  defp ws_request(overrides) do
    defaults = [
      provider: :openai,
      model: "gpt-4.1",
      wire_api: :responses,
      transport: :websocket,
      messages: [],
      options: %{
        base_url: "https://api.openai.com/v1",
        ws_stream_fn: fn _url, _opts, _on_frame -> {:ok, %{}} end
      }
    ]

    struct(Request, Keyword.merge(defaults, overrides))
  end

  defp collect_events(request) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    emit_fn = fn event ->
      Agent.update(agent, fn events -> events ++ [event] end)
      :ok
    end

    result =
      try do
        OpenAICompatibleProvider.stream(request, emit_fn)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    events = Agent.get(agent, & &1)
    Agent.stop(agent, :normal, 5000)
    {result, events}
  end

  defp event_types(events), do: Enum.map(events, & &1.type)

  defp assert_single_provider_error_without_completion(events) do
    types = event_types(events)

    assert Enum.count(types, &(&1 == :provider_error)) == 1
    refute :assistant_completed in types
    refute :response_completed in types
  end

  describe "Responses WebSocket transport detection" do
    test "dispatches to WS path when wire_api=:responses and transport=:websocket" do
      ws_fn = fn _url, _opts, _on_frame -> {:ok, %{close_code: 1000}} end
      request = ws_request(options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: ws_fn})
      {result, _events} = collect_events(request)
      # Will fail because no frames delivered, but should attempt WS path
      assert match?({:error, _}, result)
    end

    test "dispatches to WS path via options map transport" do
      ws_fn = fn _url, _opts, _on_frame -> {:ok, %{close_code: 1000}} end

      request = %Request{
        provider: :openai,
        model: "gpt-4.1",
        wire_api: :responses,
        messages: [],
        options: %{
          base_url: "https://api.openai.com/v1",
          transport: :websocket,
          ws_stream_fn: ws_fn
        }
      }

      {result, _events} = collect_events(request)
      assert match?({:error, _}, result)
    end
  end

  describe "Responses WebSocket text streaming" do
    test "full text flow emits canonical events" do
      frames = [
        Jason.encode!(%{"type" => "response.created"}),
        Jason.encode!(%{"type" => "response.in_progress"}),
        Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Hello"}),
        Jason.encode!(%{"type" => "response.output_text.delta", "delta" => " world"}),
        Jason.encode!(%{"type" => "response.output_text.done", "text" => "Hello world"}),
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_ws_1",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
          }
        })
      ]

      ws_fn = fn _url, _opts, on_frame ->
        Enum.each(frames, &on_frame.(&1))
        {:ok, %{close_code: 1000}}
      end

      request = ws_request(options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: ws_fn})
      {{:ok, response}, events} = collect_events(request)

      assert response.content == "Hello world"
      assert response.id == "resp_ws_1"
      assert response.provider_state == %{previous_response_id: "resp_ws_1"}
      assert response.finish_reason == "stop"

      types = Enum.map(events, & &1.type)
      assert :response_started in types
      assert :assistant_delta in types
      assert :assistant_completed in types
      assert :response_completed in types
    end
  end

  describe "Responses WebSocket tool call streaming" do
    test "full tool call flow emits canonical events" do
      frames = [
        Jason.encode!(%{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "id" => "call_1",
            "call_id" => "call_1",
            "name" => "read_file"
          }
        }),
        Jason.encode!(%{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "call_1",
          "delta" => "{\"path\":"
        }),
        Jason.encode!(%{
          "type" => "response.function_call_arguments.done",
          "item_id" => "call_1",
          "arguments" => "{\"path\":\"/tmp\"}"
        }),
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "id" => "call_1",
            "call_id" => "call_1",
            "name" => "read_file",
            "arguments" => "{\"path\":\"/tmp\"}"
          }
        }),
        Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_tool_1"}})
      ]

      ws_fn = fn _url, _opts, on_frame ->
        Enum.each(frames, &on_frame.(&1))
        {:ok, %{close_code: 1000}}
      end

      request = ws_request(options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: ws_fn})
      {{:ok, response}, events} = collect_events(request)

      assert length(response.tool_calls) == 1
      tc = hd(response.tool_calls)
      assert tc.name == "read_file"

      types = Enum.map(events, & &1.type)
      assert :tool_call_started in types
      assert :tool_call_delta in types
      assert :tool_call_completed in types
    end
  end

  describe "Responses WebSocket error handling" do
    test "response.failed emits provider_error and no completion events" do
      frames = [
        Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Partial"}),
        Jason.encode!(%{"type" => "response.failed"})
      ]

      ws_fn = fn _url, _opts, on_frame ->
        Enum.each(frames, &on_frame.(&1))
        {:ok, %{close_code: 1000}}
      end

      request = ws_request(options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: ws_fn})
      {{:error, _}, events} = collect_events(request)

      assert_single_provider_error_without_completion(events)
    end

    test "error frame emits provider_error" do
      frames = [
        Jason.encode!(%{"type" => "error", "message" => "rate_limit_exceeded"})
      ]

      ws_fn = fn _url, _opts, on_frame ->
        Enum.each(frames, &on_frame.(&1))
        {:ok, %{close_code: 1000}}
      end

      request = ws_request(options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: ws_fn})
      {{:error, _}, events} = collect_events(request)
      assert_single_provider_error_without_completion(events)
    end

    test "malformed JSON emits provider_error" do
      ws_fn = fn _url, _opts, on_frame ->
        on_frame.("not valid json{{{")
        {:ok, %{close_code: 1000}}
      end

      request = ws_request(options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: ws_fn})
      {{:error, _}, events} = collect_events(request)
      assert_single_provider_error_without_completion(events)
    end

    test "transport error emits provider_error" do
      ws_fn = fn _url, _opts, _on_frame -> {:error, :connection_refused} end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            fallback_transport: nil
          }
        )

      {{:error, _}, events} = collect_events(request)
      assert_single_provider_error_without_completion(events)
    end

    test "ws_stream_fn throwing emits provider_error" do
      ws_fn = fn _url, _opts, _on_frame -> throw(:boom) end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            fallback_transport: nil
          }
        )

      {{:error, _}, events} = collect_events(request)
      assert_single_provider_error_without_completion(events)
    end
  end

  describe "Responses WebSocket SSE fallback" do
    test "falls back to SSE when fallback_transport is :sse and setup fails before any frame" do
      parent = self()
      ws_fn = fn _url, _opts, _on_frame -> {:error, :connection_refused} end

      sse_fn = fn _url, _req_options, on_chunk ->
        send(parent, :sse_called)

        on_chunk.(
          "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Fallback\"}\n\n"
        )

        on_chunk.(
          "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_sse_fallback\"}}\n\n"
        )

        {:ok, %{status: 200}}
      end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            sse_post_fn: sse_fn,
            fallback_transport: :sse
          }
        )

      {{:ok, response}, events} = collect_events(request)
      assert response.content == "Fallback"
      assert response.id == "resp_sse_fallback"
      types = event_types(events)
      assert :assistant_delta in types
      assert_received :sse_called
    end

    test "does not fall back to SSE when transport errors after an inbound frame" do
      parent = self()

      ws_fn = fn _url, _opts, on_frame ->
        on_frame.(Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Partial"}))
        {:error, :connection_lost}
      end

      sse_fn = fn _url, _req_options, _on_chunk ->
        send(parent, :sse_called)
        {:ok, %{status: 200}}
      end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            sse_post_fn: sse_fn,
            fallback_transport: :sse
          }
        )

      {{:error, _}, events} = collect_events(request)

      assert_single_provider_error_without_completion(events)
      assert :assistant_delta in event_types(events)
      refute_received :sse_called
    end

    test "does not fall back to SSE when close arrives after a delta without response.completed" do
      parent = self()

      ws_fn = fn _url, _opts, on_frame ->
        on_frame.(Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Partial"}))
        {:ok, %{close_code: 1000}}
      end

      sse_fn = fn _url, _req_options, _on_chunk ->
        send(parent, :sse_called)
        {:ok, %{status: 200}}
      end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            sse_post_fn: sse_fn,
            fallback_transport: :sse
          }
        )

      {{:error, _}, events} = collect_events(request)

      assert_single_provider_error_without_completion(events)
      assert :assistant_delta in event_types(events)
      refute_received :sse_called
    end

    test "falls back to SSE when fallback_to_sse is true" do
      ws_fn = fn _url, _opts, _on_frame -> {:error, :connection_refused} end

      sse_fn = fn _url, _req_options, on_chunk ->
        on_chunk.(
          "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fallback2\"}}\n\n"
        )

        {:ok, %{status: 200}}
      end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            sse_post_fn: sse_fn,
            fallback_to_sse: true
          }
        )

      {{:ok, response}, _events} = collect_events(request)
      assert response.id == "resp_fallback2"
    end
  end

  describe "Responses WebSocket security" do
    test "auth tokens never appear in events or errors" do
      ws_fn = fn _url, _opts, on_frame ->
        on_frame.(
          Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_secure"}})
        )

        {:ok, %{close_code: 1000}}
      end

      request =
        ws_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            ws_stream_fn: ws_fn,
            headers: [{"Authorization", "Bearer sk-secret-token-12345"}]
          }
        )

      {{:ok, _response}, events} = collect_events(request)

      Enum.each(events, fn event ->
        refute inspect(event) =~ "sk-secret-token-12345"
      end)
    end
  end

  describe "Responses WebSocket ws_stream_fn validation" do
    test "rejects missing ws_stream_fn" do
      request = ws_request(options: %{base_url: "https://api.openai.com/v1"})
      {{:error, _}, events} = collect_events(request)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "rejects non-function ws_stream_fn" do
      request =
        ws_request(
          options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: "not a function"}
        )

      {{:error, _}, events} = collect_events(request)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "rejects wrong-arity ws_stream_fn" do
      request =
        ws_request(
          options: %{base_url: "https://api.openai.com/v1", ws_stream_fn: fn _a, _b -> :ok end}
        )

      {{:error, _}, events} = collect_events(request)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end
  end
end
