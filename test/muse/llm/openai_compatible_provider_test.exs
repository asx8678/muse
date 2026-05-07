defmodule Muse.LLM.OpenAICompatibleProviderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, Message, Request, ToolCall}
  alias Muse.LLM.OpenAICompatibleProvider

  describe "complete/2" do
    test "calls injected post_fn with correct URL/json/options and decodes assistant response" do
      parent = self()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          headers: %{
            "Authorization" => "Bearer sk-test-secret",
            "X-Custom" => "value"
          },
          timeout_ms: 12_345,
          max_retries: 0
        })

      assert {:ok, response} = OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      assert response.id == "chatcmpl_text"
      assert response.content == "hello from chat completions"
      assert response.text == "hello from chat completions"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 7, completion_tokens: 5, total_tokens: 12}
      assert response.tool_calls == []

      assert_receive {:post_called, url, options}
      assert url == "https://api.example.test/v1/chat/completions"
      assert options[:json]["stream"] == false
      assert options[:json]["model"] == "gpt-4.1-mini"
      assert [%{"role" => "user", "content" => "hello"}] = options[:json]["messages"]
      assert {"Authorization", "Bearer sk-test-secret"} in options[:headers]
      assert {"X-Custom", "value"} in options[:headers]
      assert options[:timeout_ms] == 12_345
      assert options[:max_retries] == 0
    end

    test "decodes tool calls" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: tool_call_body())}
      end

      assert {:ok, response} = OpenAICompatibleProvider.complete(request(), post_fn: post_fn)
      assert response.content == nil
      assert response.finish_reason == "tool_calls"
      assert response.usage == %{prompt_tokens: 11, completion_tokens: 9, total_tokens: 20}

      assert [tool_call] = response.tool_calls
      assert %ToolCall{} = tool_call
      assert tool_call.id == "call_read"
      assert tool_call.name == "read_file"
      assert tool_call.arguments == %{"path" => "lib/muse.ex", "start_line" => 1}
    end

    test "non-2xx HTTP response returns redacted bounded error" do
      secret_body = String.duplicate("noisy ", 120) <> "Bearer sk-body-secret token=also-secret"

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 401, body: secret_body)}
      end

      req = request(%{headers: %{"Authorization" => "Bearer sk-header-secret"}})

      assert {:error, {:provider_http_error, %{status: 401, body_summary: summary}}} =
               OpenAICompatibleProvider.complete(req, post_fn: post_fn)

      rendered = inspect(summary)
      refute rendered =~ "sk-body-secret"
      refute rendered =~ "sk-header-secret"
      refute rendered =~ "Bearer sk"
      refute rendered =~ "token=also-secret"
      assert String.length(summary) <= 500
    end

    test "network/Req errors return redacted provider error" do
      post_fn = fn _url, _options ->
        {:error, RuntimeError.exception("boom Bearer sk-network-secret")}
      end

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               OpenAICompatibleProvider.complete(request(), post_fn: post_fn)

      rendered = inspect(reason)
      refute rendered =~ "sk-network-secret"
      refute rendered =~ "Bearer sk"
      assert rendered =~ "boom"
    end

    test "missing and invalid base_url return errors without calling post_fn" do
      post_fn = fn url, options ->
        send(self(), {:unexpected_post, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      assert {:error, {:missing_base_url, _message}} =
               OpenAICompatibleProvider.complete(%Request{request() | options: %{}},
                 post_fn: post_fn
               )

      refute_received {:unexpected_post, _url, _options}

      assert {:error, {:invalid_base_url, message}} =
               request(%{base_url: "ftp://files.example.test/v1"})
               |> OpenAICompatibleProvider.complete(post_fn: post_fn)

      assert message =~ "http or https"
      refute_received {:unexpected_post, _url, _options}
    end

    test "unsupported wire_api :responses errors clearly without calling post_fn" do
      post_fn = fn url, options ->
        send(self(), {:unexpected_post, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      req = %Request{request() | wire_api: :responses}

      assert {:error, {:unsupported_wire_api, :responses}} =
               OpenAICompatibleProvider.complete(req, post_fn: post_fn)

      refute_received {:unexpected_post, _url, _options}
    end
  end

  describe "stream/2" do
    test "emits canonical events for a text response" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      req = request(%{post_fn: post_fn})

      emit = fn event ->
        send(self(), {:event, event})
        :ok
      end

      assert {:ok, response} = OpenAICompatibleProvider.stream(req, emit)
      assert response.content == "hello from chat completions"

      events = drain_events()

      assert Enum.map(events, & &1.type) == [
               :response_started,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]

      assert Enum.at(events, 1).text == "hello from chat completions"
      assert Enum.at(events, 2).text == "hello from chat completions"

      assert Enum.at(events, 3).usage == %{
               prompt_tokens: 7,
               completion_tokens: 5,
               total_tokens: 12
             }
    end

    test "emits tool call events for a tool-call response" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: tool_call_body())}
      end

      req = request(%{http_post: post_fn})

      emit = fn event ->
        send(self(), {:event, event})
        :ok
      end

      assert {:ok, response} = OpenAICompatibleProvider.stream(req, emit)
      assert [%ToolCall{name: "read_file"}] = response.tool_calls

      events = drain_events()

      assert Enum.map(events, & &1.type) == [
               :response_started,
               :tool_call_started,
               :tool_call_completed,
               :response_completed
             ]

      assert %Event{tool_call: %ToolCall{id: "call_read", name: "read_file"}} = Enum.at(events, 1)
      assert %Event{tool_call: %ToolCall{id: "call_read", name: "read_file"}} = Enum.at(events, 2)

      assert Enum.at(events, 3).usage == %{
               prompt_tokens: 11,
               completion_tokens: 9,
               total_tokens: 20
             }
    end

    test "emits provider_error with redacted reason on error" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 500, body: %{"error" => "Bearer sk-stream-secret"})}
      end

      req = request(%{post_fn: post_fn})

      emit = fn event ->
        send(self(), {:event, event})
        :ok
      end

      assert {:error, reason} = OpenAICompatibleProvider.stream(req, emit)
      refute inspect(reason) =~ "sk-stream-secret"

      assert [%Event{type: :provider_error, error: event_reason}] = drain_events()
      refute inspect(event_reason) =~ "sk-stream-secret"
    end
  end

  test "default HTTP path is Req.post/2 while tests inject post_fn to avoid network" do
    source = File.read!("lib/muse/llm/openai_compatible_provider.ex")

    assert source =~ "&Req.post/2"
  end

  defp request(extra_options \\ %{}) do
    base_options = %{base_url: "https://api.example.test/v1"}

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :none,
      messages: [Message.user("hello")],
      stream: true,
      options: Map.merge(base_options, extra_options)
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

  defp tool_call_body do
    %{
      "id" => "chatcmpl_tools",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_read",
                "type" => "function",
                "function" => %{
                  "name" => "read_file",
                  "arguments" => ~s({"path":"lib/muse.ex","start_line":1})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 9, "total_tokens" => 20}
    }
  end

  defp drain_events(acc \\ []) do
    receive do
      {:event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "complete/2 — empty response validation" do
    test "returns error when response content is empty with no tool_calls" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: empty_body())}
      end

      request = request(%{})

      assert {:error, reason} = OpenAICompatibleProvider.complete(request, post_fn: post_fn)
      inspected = inspect(reason)
      # Empty content without reasoning_content returns an invalid_response error
      # from the decoder layer; with reasoning_content returns provider_empty_response
      assert inspected =~ "invalid_response" or inspected =~ "provider_empty_response"
    end

    test "returns error when response has reasoning_content but empty content" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: reasoning_only_body())}
      end

      request = request(%{})

      assert {:error, reason} = OpenAICompatibleProvider.complete(request, post_fn: post_fn)
      inspected = inspect(reason)
      assert inspected =~ "provider_empty_response"
      assert inspected =~ "reasoning"
    end

    test "returns success when response has tool_calls even with empty content" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: tool_call_body())}
      end

      request = request(%{})

      assert {:ok, %Muse.LLM.Response{}} =
               OpenAICompatibleProvider.complete(request, post_fn: post_fn)
    end
  end

  describe "stream/2 — empty response validation (SSE)" do
    test "SSE stream with reasoning-only returns provider_empty_response error" do
      # Simulate GLM-5.1 style: role-only init, reasoning, stop, no content
      sse_chunks =
        [
          "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":null}}]}\n\n",
          "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Thinking...\"}}]}\n\n",
          "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null},\"finish_reason\":\"stop\"}]}\n\n",
          "data: [DONE]\n\n"
        ]
        |> Enum.join("")

      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.(sse_chunks)
        {:ok, %{status: 200}}
      end

      request = request(%{transport: :sse, sse_post_fn: sse_post_fn})

      events = collect_stream_events(request)

      # Should contain a provider_error event, not a blank assistant message
      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) >= 1
    end

    test "SSE stream with reasoning then content returns success" do
      sse_chunks =
        [
          "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":null}}]}\n\n",
          "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Thinking...\"}}]}\n\n",
          "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null,\"content\":\"OK\"}}]}\n\n",
          "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null},\"finish_reason\":\"stop\"}]}\n\n",
          "data: [DONE]\n\n"
        ]
        |> Enum.join("")

      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.(sse_chunks)
        {:ok, %{status: 200}}
      end

      request = request(%{transport: :sse, sse_post_fn: sse_post_fn})

      events = collect_stream_events(request)

      # Should contain assistant_delta with "OK", not a provider_error
      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert error_events == []

      delta_events = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(delta_events) >= 1
      assert Enum.at(delta_events, 0).text == "OK"
    end
  end

  defp collect_stream_events(request) do
    {:ok, pid} = Agent.start_link(fn -> [] end)

    emit_fn = fn event ->
      Agent.update(pid, fn events -> events ++ [event] end)
      :ok
    end

    OpenAICompatibleProvider.stream(request, emit_fn)

    events = Agent.get(pid, & &1)
    Agent.stop(pid)
    events
  end

  defp empty_body do
    %{
      "id" => "chatcmpl_empty",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => ""},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end

  defp reasoning_only_body do
    %{
      "id" => "chatcmpl_reasoning",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "reasoning_content" => "I thought about this but ran out of tokens."
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 50, "total_tokens" => 60}
    }
  end
end
