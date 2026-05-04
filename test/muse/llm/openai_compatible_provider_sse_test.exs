defmodule Muse.LLM.OpenAICompatibleProviderSSETest do
  @moduledoc """
  Tests for the SSE streaming path of OpenAICompatibleProvider.stream/2.

  All tests use injected `sse_post_fn` — no real network calls.
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request, Response, ToolCall}
  alias Muse.LLM.OpenAICompatibleProvider

  # ---------------------------------------------------------------------------
  # SSE text streaming — happy path
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE text response" do
    test "emits canonical events incrementally for a text SSE stream" do
      sse_post_fn = sse_post_fn_for(text_sse_chunks())

      req = sse_request(%{sse_post_fn: sse_post_fn})

      events = collect_stream_events(req)

      assert event_types(events) == [
               :response_started,
               :assistant_delta,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]

      # Deltas come incrementally
      deltas = events |> Enum.filter(&(&1.type == :assistant_delta)) |> Enum.map(& &1.text)
      assert deltas == ["Hello", " world"]

      # Completed has full text
      completed = Enum.find(events, &(&1.type == :assistant_completed))
      assert completed.text == "Hello world"

      # Usage on response_completed
      completed_event = Enum.find(events, &(&1.type == :response_completed))
      assert completed_event.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
    end

    test "returns assembled Response with full content and usage" do
      sse_post_fn = sse_post_fn_for(text_sse_chunks())
      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)

      assert %Response{} = response
      assert response.content == "Hello world"
      assert response.text == "Hello world"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
      assert response.tool_calls == []
    end

    test "builds spec with stream: true in payload" do
      parent = self()

      sse_post_fn = fn url, req_options, on_chunk ->
        send(parent, {:sse_post_called, url, req_options})

        # Feed chunks
        text_sse_chunks()
        |> Enum.each(&on_chunk.(&1))

        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_post_called, _url, req_options}
      assert req_options[:json]["stream"] == true
      assert req_options[:json]["model"] == "gpt-4.1-mini"
    end
  end

  # ---------------------------------------------------------------------------
  # SSE tool call streaming
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE tool call response" do
    test "emits tool_call_started, tool_call_delta, tool_call_completed events" do
      sse_post_fn = sse_post_fn_for(tool_call_sse_chunks())

      req = sse_request(%{sse_post_fn: sse_post_fn})
      events = collect_stream_events(req)

      types = event_types(events)

      assert :response_started in types
      assert :tool_call_started in types
      assert :tool_call_delta in types
      assert :tool_call_completed in types
      assert :response_completed in types

      # Tool call started should have id and name
      started = Enum.find(events, &(&1.type == :tool_call_started))
      assert started.tool_call.id == "call_read"
      assert started.tool_call.name == "read_file"

      # Completed should have full tool call
      completed_tc = Enum.find(events, &(&1.type == :tool_call_completed))
      assert completed_tc.tool_call.name == "read_file"
      assert completed_tc.tool_call.arguments == %{"path" => "lib/muse.ex", "start_line" => 1}
    end

    test "returns Response with assembled tool calls" do
      sse_post_fn = sse_post_fn_for(tool_call_sse_chunks())
      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)

      assert [%ToolCall{} = tc] = response.tool_calls
      assert tc.id == "call_read"
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse.ex", "start_line" => 1}
      assert response.finish_reason == "tool_calls"
    end
  end

  # ---------------------------------------------------------------------------
  # SSE with partial chunks (buffering)
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE partial chunk buffering" do
    test "handles partial SSE events across chunks" do
      # Simulate partial data across chunk boundaries.
      # Note: real SSE streams have single-line JSON data; no newlines inside data values.
      # Build complete SSE text and split at arbitrary byte boundaries.
      sse_text =
        "data: {\"id\":\"t1\",\"choices\":[{\"delta\":{\"content\":\"He\"}}]}\n\n" <>
          "data: {\"id\":\"t2\",\"choices\":[{\"delta\":{\"content\":\"llo\"}}]}\n\n" <>
          "data: {\"id\":\"t3\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" <>
          "data: [DONE]\n\n"

      # Split at a point that breaks mid-event (after 60 chars)
      {chunk1, rest} = String.split_at(sse_text, 60)
      {chunk2, rest2} = String.split_at(rest, 40)
      {chunk3, chunk4} = String.split_at(rest2, 40)
      chunks = [chunk1, chunk2, chunk3, chunk4]

      sse_post_fn = fn _url, _req_options, on_chunk ->
        Enum.each(chunks, &on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)
      assert response.content == "Hello"
      assert response.finish_reason == "stop"
    end
  end

  # ---------------------------------------------------------------------------
  # SSE with auth
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE auth integration" do
    test "injects Authorization header from auth resolver into SSE request" do
      parent = self()

      sse_post_fn = fn _url, req_options, on_chunk ->
        send(parent, {:sse_headers, req_options[:headers]})

        # Feed a minimal text stream
        on_chunk.("data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")

        on_chunk.(
          "data: {\"id\":\"t\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")

        {:ok, %{status: 200}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          auth: :api_key,
          env_key: "MUSE_SSE_TEST_KEY",
          auth_env: %{"MUSE_SSE_TEST_KEY" => "sk-sse-secret"},
          system_env?: false
        })

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_headers, headers}
      assert {"Authorization", "Bearer sk-sse-secret"} in headers
    end

    test "explicit Authorization header wins over auth resolver for SSE" do
      parent = self()

      sse_post_fn = fn _url, req_options, on_chunk ->
        send(parent, {:sse_headers, req_options[:headers]})

        on_chunk.("data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")

        on_chunk.(
          "data: {\"id\":\"t\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")

        {:ok, %{status: 200}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          auth: :api_key,
          env_key: "MUSE_SSE_TEST_KEY",
          auth_env: %{"MUSE_SSE_TEST_KEY" => "sk-resolver-secret"},
          system_env?: false,
          headers: [{"Authorization", "Bearer caller-sse-secret"}]
        })

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_headers, headers}

      auth_headers =
        Enum.filter(headers, fn {name, _} -> String.downcase(name) == "authorization" end)

      assert auth_headers == [{"Authorization", "Bearer caller-sse-secret"}]
    end

    test "auth error before SSE post is called" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        send(self(), {:unexpected_sse_post, true})
        {:ok, %{status: 200}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          auth: :api_key,
          env_key: "MUSE_SSE_MISSING_KEY",
          env: %{},
          system_env?: false
        })

      result = stream_with_collector(req)
      assert {:error, reason} = result
      # Auth errors may be redacted; check the structure is correct
      rendered = inspect(reason)
      assert rendered =~ "auth_error" or rendered =~ "missing"
      refute_received {:unexpected_sse_post, _}
    end
  end

  # ---------------------------------------------------------------------------
  # SSE error handling
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE error handling" do
    test "non-2xx HTTP status emits provider_error and returns error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 429}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})
      events = collect_stream_events(req)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) >= 1

      error = hd(error_events)
      assert error.type == :provider_error
    end

    test "transport error emits redacted provider_error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, {:connection_failed, "Bearer sk-sse-error-secret"}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      refute rendered =~ "sk-sse-error-secret"
      refute rendered =~ "Bearer sk"
    end

    test "exception in sse_post_fn emits redacted provider_error, no hang" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        raise "boom Bearer sk-sse-exception-secret"
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      refute rendered =~ "sk-sse-exception-secret"
    end

    test "invalid JSON in SSE chunk emits provider_error but continues" do
      chunks = [
        "data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n",
        "data: not-valid-json\n\n",
        "data: {\"id\":\"t\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n"
      ]

      sse_post_fn = fn _url, _req_options, on_chunk ->
        Enum.each(chunks, &on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      events = collect_stream_events(req)

      # Should still have the valid events plus a provider_error
      types = event_types(events)
      assert :response_started in types
      assert :assistant_delta in types
      assert :provider_error in types
      assert :response_completed in types
    end
  end

  # ---------------------------------------------------------------------------
  # Non-SSE transport preserved
  # ---------------------------------------------------------------------------

  describe "stream/2 non-SSE preserved behavior" do
    test "transport :none still uses non-streaming replay" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      req = request(%{post_fn: post_fn, transport: :none})

      events = collect_stream_events(req)

      # Non-streaming replay emits: response_started, assistant_delta, assistant_completed, response_completed
      assert event_types(events) == [
               :response_started,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]
    end

    test "default transport (nil) still uses non-streaming replay" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :chat_completions,
        transport: nil,
        messages: [Message.user("hello")],
        stream: true,
        options: %{base_url: "https://api.example.test/v1", post_fn: post_fn}
      }

      events = collect_stream_events(req)

      assert event_types(events) == [
               :response_started,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Transport selection
  # ---------------------------------------------------------------------------

  describe "stream/2 transport selection" do
    test "request.transport == :sse activates SSE path" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.("data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")

        on_chunk.(
          "data: {\"id\":\"t\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        transport: :sse,
        messages: [Message.user("hello")],
        options: %{base_url: "https://api.example.test/v1", sse_post_fn: sse_post_fn}
      }

      events = collect_stream_events(req)
      assert :response_started in event_types(events)
      assert :assistant_delta in event_types(events)
    end

    test "request.options[:transport] == :sse activates SSE path" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.("data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")

        on_chunk.(
          "data: {\"id\":\"t\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        transport: nil,
        messages: [Message.user("hello")],
        options: %{
          base_url: "https://api.example.test/v1",
          sse_post_fn: sse_post_fn,
          transport: :sse
        }
      }

      events = collect_stream_events(req)
      assert :response_started in event_types(events)
      assert :assistant_delta in event_types(events)
    end
  end

  # ---------------------------------------------------------------------------
  # SSE post_fn shape documentation test
  # ---------------------------------------------------------------------------

  describe "sse_post_fn shape" do
    test "default sse_post_fn references Req.post in source" do
      source = File.read!("lib/muse/llm/openai_compatible_provider.ex")
      assert source =~ "default_sse_post"
      assert source =~ "Req.post"
    end

    test "invalid sse_post_fn arity returns clear error" do
      # 2-arity function instead of 3-arity
      sse_post_fn = fn _a, _b -> {:ok, %{status: 200}} end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      result = stream_with_collector(req)
      assert {:error, reason} = result
      rendered = inspect(reason)
      assert rendered =~ "invalid_sse_post_fn" or rendered =~ "three-arity"
    end

    test "sse_post_fn receives url, req_options, and on_chunk callback" do
      parent = self()

      sse_post_fn = fn url, req_options, on_chunk ->
        send(parent, {:sse_fn_args, url, is_list(req_options), is_function(on_chunk, 1)})

        on_chunk.("data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")

        on_chunk.(
          "data: {\"id\":\"t\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")

        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_fn_args, url, req_options_is_list, on_chunk_is_fn1}
      assert url == "https://api.example.test/v1/chat/completions"
      assert req_options_is_list == true
      assert on_chunk_is_fn1 == true
    end
  end

  # ---------------------------------------------------------------------------
  # No raw tokens in events/errors
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE no raw token leakage" do
    test "provider_error events never contain raw Authorization value" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, {:connection_failed, "header had Bearer sk-leak-check"}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer sk-sse-leak-test"}]
        })

      events = collect_stream_events(req)

      Enum.each(events, fn event ->
        rendered = inspect(event)
        refute rendered =~ "sk-sse-leak-test"
        refute rendered =~ "sk-leak-check"
      end)
    end

    test "non-2xx response error never contains raw auth from headers" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 403}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer sk-403-secret"}]
        })

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      refute rendered =~ "sk-403-secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sse_request(extra_options) do
    base = %{base_url: "https://api.example.test/v1"}
    options = Map.merge(base, extra_options)

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :sse,
      messages: [Message.user("hello")],
      stream: true,
      options: options
    }
  end

  defp request(extra_options) do
    base = %{base_url: "https://api.example.test/v1"}
    options = Map.merge(base, extra_options)

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :none,
      messages: [Message.user("hello")],
      stream: true,
      options: options
    }
  end

  defp text_body do
    %{
      "id" => "chatcmpl_text",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => "hello from chat completions"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
    }
  end

  # SSE chunk generators — produce lists of raw SSE text chunks

  defp text_sse_chunks do
    [
      "data: {\"id\":\"chatcmpl-test\",\"model\":\"gpt-4.1-mini\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"}}]}\n\n",
      "data: {\"id\":\"chatcmpl-test\",\"model\":\"gpt-4.1-mini\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" world\"}}]}\n\n",
      "data: {\"id\":\"chatcmpl-test\",\"model\":\"gpt-4.1-mini\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3,\"total_tokens\":8}}\n\n",
      "data: [DONE]\n\n"
    ]
  end

  defp tool_call_sse_chunks do
    [
      # First tool call delta — includes id, type, function.name
      "data: {\"id\":\"chatcmpl-tools\",\"model\":\"gpt-4.1-mini\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_read\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}\n\n",
      # Second delta — argument fragments
      "data: {\"id\":\"chatcmpl-tools\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n",
      "data: {\"id\":\"chatcmpl-tools\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"lib/muse.ex\\\",\\\"start_line\\\":1}\"}}]}}]}\n\n",
      # Final chunk with finish_reason
      "data: {\"id\":\"chatcmpl-tools\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":9,\"total_tokens\":20}}\n\n",
      "data: [DONE]\n\n"
    ]
  end

  defp sse_post_fn_for(chunks) do
    fn _url, _req_options, on_chunk ->
      Enum.each(chunks, &on_chunk.(&1))
      {:ok, %{status: 200}}
    end
  end

  defp collect_stream_events(req) do
    {result, events} = stream_with_events(req)
    _ = result
    events
  end

  defp stream_with_collector(req) do
    {result, _events} = stream_with_events(req)
    result
  end

  defp stream_with_events(req) do
    test_pid = self()
    ref = make_ref()

    emit_fn = fn event ->
      send(test_pid, {:stream_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(req, emit_fn)

    events = drain_stream_events(ref)
    {result, events}
  end

  defp drain_stream_events(ref, acc \\ []) do
    receive do
      {:stream_event, ^ref, event} -> drain_stream_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp event_types(events), do: Enum.map(events, & &1.type)
end
