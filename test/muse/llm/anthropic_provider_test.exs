defmodule Muse.LLM.AnthropicProviderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, Message, Request, ToolCall}
  alias Muse.LLM.AnthropicProvider

  # ---------------------------------------------------------------------------
  # complete/2
  # ---------------------------------------------------------------------------

  describe "complete/2" do
    test "calls injected post_fn with correct URL/body/headers without network" do
      parent = self()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request(%{post_fn: post_fn})

      assert {:ok, response} = AnthropicProvider.complete(request)

      assert response.id == "msg_test"
      assert response.content == "Hello from Anthropic"
      assert response.text == "Hello from Anthropic"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 10, completion_tokens: 5}
      assert response.tool_calls == []

      assert_receive {:post_called, url, options}
      assert url == "https://api.anthropic.test/v1/messages"
      assert options[:json]["model"] == "claude-sonnet-4-20250514"
      assert options[:json]["max_tokens"] == 1024
      assert [%{"role" => "user", "content" => "hello"}] = options[:json]["messages"]
      refute Map.has_key?(options[:json], "system")
    end

    test "builds expected URL with trailing slash stripped" do
      parent = self()

      post_fn = fn url, _options ->
        send(parent, {:url, url})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request(%{base_url: "https://api.anthropic.test/v1/", post_fn: post_fn})

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:url, "https://api.anthropic.test/v1/messages"}
    end

    test "builds expected URL with /v1 suffix stripped" do
      parent = self()

      post_fn = fn url, _options ->
        send(parent, {:url, url})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      # When base_url ends with /v1, the endpoint becomes /v1/messages
      request = request(%{base_url: "https://api.anthropic.test/v1", post_fn: post_fn})

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:url, "https://api.anthropic.test/v1/messages"}
    end

    test "model is required" do
      request = %Request{
        provider: :anthropic,
        model: nil,
        messages: [Message.user("hello")],
        options: %{base_url: "https://api.anthropic.test"}
      }

      assert {:error, {:missing_model, _message}} = AnthropicProvider.complete(request)
    end

    test "max_tokens defaults to 1024" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request(%{post_fn: post_fn})

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      assert json["max_tokens"] == 1024
    end

    test "max_tokens from request overrides default" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = %Request{
        request()
        | max_tokens: 2048,
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      assert json["max_tokens"] == 2048
    end

    test "system messages go into system field, not messages" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = %Request{
        request()
        | messages: [Message.system("You are helpful."), Message.user("hello")],
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      assert json["system"] == "You are helpful."
      # Only user messages in messages array
      assert [%{"role" => "user"}] = json["messages"]
    end

    test "multiple system messages are concatenated" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = %Request{
        request()
        | messages: [
            Message.system("Be concise."),
            Message.system("Be safe."),
            Message.user("hello")
          ],
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      assert json["system"] == "Be concise.\n\nBe safe."
    end

    test "only user and assistant messages go into messages array" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = %Request{
        request()
        | messages: [
            Message.system("system prompt"),
            Message.user("hello"),
            Message.assistant("hi"),
            Message.tool("result", "call_1")
          ],
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      assert length(json["messages"]) == 2
      assert [%{"role" => "user"}, %{"role" => "assistant"}] = json["messages"]
    end

    test "temperature is included when set" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = %Request{
        request()
        | temperature: 0.7,
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      assert json["temperature"] == 0.7
    end

    test "temperature is omitted when nil" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request(%{post_fn: post_fn})

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:json, json}
      refute Map.has_key?(json, "temperature")
    end
  end

  # ---------------------------------------------------------------------------
  # complete/2 — HTTP error handling
  # ---------------------------------------------------------------------------

  describe "complete/2 error handling" do
    test "non-2xx HTTP response returns redacted bounded error" do
      secret_body = String.duplicate("noisy ", 120) <> "Bearer sk-body-secret token=also-secret"

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 401, body: secret_body)}
      end

      req = request(%{post_fn: post_fn})

      assert {:error, {:provider_http_error, %{status: 401, body_summary: summary}}} =
               AnthropicProvider.complete(req)

      rendered = inspect(summary)
      refute rendered =~ "sk-body-secret"
      refute rendered =~ "Bearer sk"
      refute rendered =~ "token=also-secret"
      assert String.length(summary) <= 500
    end

    test "network/Req errors return redacted provider error" do
      post_fn = fn _url, _options ->
        {:error, RuntimeError.exception("boom Bearer sk-network-secret")}
      end

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               AnthropicProvider.complete(request(%{post_fn: post_fn}))

      rendered = inspect(reason)
      refute rendered =~ "sk-network-secret"
      refute rendered =~ "Bearer sk"
      assert rendered =~ "boom"
    end

    test "missing base_url returns error without calling post_fn" do
      post_fn = fn url, options ->
        send(self(), {:unexpected_post, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      assert {:error, {:missing_base_url, _message}} =
               AnthropicProvider.complete(%Request{
                 request()
                 | options: %{post_fn: post_fn}
               })

      refute_received {:unexpected_post, _url, _options}
    end

    test "invalid base_url returns error" do
      post_fn = fn url, options ->
        send(self(), {:unexpected_post, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      assert {:error, {:invalid_base_url, message}} =
               request(%{base_url: "ftp://files.example.test/v1", post_fn: post_fn})
               |> AnthropicProvider.complete()

      assert message =~ "http or https"
      refute_received {:unexpected_post, _url, _options}
    end

    test "malformed response returns safe error, no crash" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: "not json at all!!!")}
      end

      assert {:error, {:provider_decode_error, _reason}} =
               AnthropicProvider.complete(request(%{post_fn: post_fn}))
    end

    test "response with unknown content blocks does not crash" do
      body = %{
        "id" => "msg_unknown",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "unknown_block", "data" => "weird"}
        ],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
      }

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.content == "Hello"
      assert response.tool_calls == []
    end
  end

  # ---------------------------------------------------------------------------
  # complete/2 — Anthropic response decoding
  # ---------------------------------------------------------------------------

  describe "complete/2 response decoding" do
    test "decodes standard Anthropic text response" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.id == "msg_test"
      assert response.content == "Hello from Anthropic"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 10, completion_tokens: 5}
    end

    test "decodes tool_use response" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: tool_use_body())}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.content == "I will help with that."
      assert response.finish_reason == "tool_calls"

      assert [tool_call] = response.tool_calls
      assert %ToolCall{} = tool_call
      assert tool_call.id == "toolu_read"
      assert tool_call.name == "read_file"
      assert tool_call.arguments == %{"path" => "lib/muse.ex", "start_line" => 1}
    end

    test "normalizes stop_reason end_turn to stop" do
      body = %{
        "id" => "msg_endturn",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Done"}],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
      }

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.finish_reason == "stop"
    end

    test "normalizes stop_reason tool_use to tool_calls" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: tool_use_body())}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.finish_reason == "tool_calls"
    end

    test "normalizes stop_reason max_tokens to length" do
      body = %{
        "id" => "msg_maxtok",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Truncated"}],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "max_tokens",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 1024}
      }

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.finish_reason == "length"
    end

    test "response with no usage returns nil usage" do
      body = %{
        "id" => "msg_no_usage",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "No usage"}],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn"
      }

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.usage == nil
    end

    test "response with empty content returns nil text" do
      body = %{
        "id" => "msg_empty",
        "type" => "message",
        "role" => "assistant",
        "content" => [],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
      }

      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, response} = AnthropicProvider.complete(request(%{post_fn: post_fn}))
      assert response.content == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Auth header injection
  # ---------------------------------------------------------------------------

  describe "complete/2 auth" do
    test "injects x-api-key header from configured api_key auth" do
      parent = self()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_ANTHROPIC_API_KEY",
          auth_env: %{"MUSE_ANTHROPIC_API_KEY" => "sk-ant-provider-secret"},
          system_env?: false,
          post_fn: post_fn
        })

      assert {:ok, response} = AnthropicProvider.complete(request)
      assert response.content == "Hello from Anthropic"

      assert_receive {:post_called, _url, options}
      assert {"x-api-key", "sk-ant-provider-secret"} in options[:headers]
      assert {"anthropic-version", "2023-06-01"} in options[:headers]
    end

    test "explicit x-api-key header wins over resolver" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:post_called, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_ANTHROPIC_API_KEY",
          auth_env: %{"MUSE_ANTHROPIC_API_KEY" => "sk-ant-resolver-secret"},
          system_env?: false,
          headers: [{"x-api-key", "sk-ant-caller-secret"}],
          post_fn: post_fn
        })

      assert {:ok, _response} = AnthropicProvider.complete(request)

      assert_receive {:post_called, options}
      # Explicit header wins: only one x-api-key
      assert x_api_key_headers(options[:headers]) == ["sk-ant-caller-secret"]
    end

    test "auth :none allows request without x-api-key" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:post_called, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :none,
          post_fn: post_fn
        })

      assert {:ok, _response} = AnthropicProvider.complete(request)

      assert_receive {:post_called, options}
      assert x_api_key_headers(options[:headers]) == []
      # anthropic-version is still attached
      assert {"anthropic-version", "2023-06-01"} in options[:headers]
    end

    test "auth errors never leak api key in error message" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_ANTHROPIC_API_KEY",
          auth_env: %{"MUSE_ANTHROPIC_API_KEY" => "sk-ant-network-secret"},
          system_env?: false,
          post_fn: post_fn
        })

      # Make the post_fn return an error that might leak headers
      error_post_fn = fn _url, options ->
        {:error, {:transport_failed, options}}
      end

      request = %{request | options: Map.put(request.options, :post_fn, error_post_fn)}

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               AnthropicProvider.complete(request)

      rendered = inspect(reason)
      refute rendered =~ "sk-ant-network-secret"
      refute rendered =~ "Bearer sk-ant"
    end

    test "anthropic-version header is always attached" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:headers, options[:headers]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request(%{post_fn: post_fn})

      assert {:ok, _} = AnthropicProvider.complete(request)

      assert_receive {:headers, headers}
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    test "explicit anthropic-version header is not duplicated" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:headers, options[:headers]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          headers: [{"anthropic-version", "2024-01-01"}],
          post_fn: post_fn
        })

      assert {:ok, _} = AnthropicProvider.complete(request)

      assert_receive {:headers, headers}
      # Should have exactly one anthropic-version header, and it should be the caller's
      version_headers =
        Enum.filter(headers, fn {name, _} -> String.downcase(name) == "anthropic-version" end)

      assert length(version_headers) == 1
      assert {"anthropic-version", "2024-01-01"} in version_headers
    end
  end

  # ---------------------------------------------------------------------------
  # stream/2
  # ---------------------------------------------------------------------------

  describe "stream/2" do
    test "replays normalized events and returns response" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      req = request(%{post_fn: post_fn})

      emit = fn event ->
        send(self(), {:event, event})
        :ok
      end

      assert {:ok, response} = AnthropicProvider.stream(req, emit)
      assert response.content == "Hello from Anthropic"

      events = drain_events()

      assert Enum.map(events, & &1.type) == [
               :response_started,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]

      assert Enum.at(events, 1).text == "Hello from Anthropic"
      assert Enum.at(events, 2).text == "Hello from Anthropic"

      assert Enum.at(events, 3).usage == %{
               prompt_tokens: 10,
               completion_tokens: 5
             }
    end

    test "emits tool call events for a tool_use response" do
      post_fn = fn _url, _options ->
        {:ok, Req.Response.new(status: 200, body: tool_use_body())}
      end

      req = request(%{post_fn: post_fn})

      emit = fn event ->
        send(self(), {:event, event})
        :ok
      end

      assert {:ok, response} = AnthropicProvider.stream(req, emit)
      assert [%ToolCall{name: "read_file"}] = response.tool_calls

      events = drain_events()

      assert Enum.map(events, & &1.type) == [
               :response_started,
               :assistant_delta,
               :assistant_completed,
               :tool_call_started,
               :tool_call_completed,
               :response_completed
             ]
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

      assert {:error, reason} = AnthropicProvider.stream(req, emit)
      refute inspect(reason) =~ "sk-stream-secret"

      assert [%Event{type: :provider_error, error: event_reason}] = drain_events()
      refute inspect(event_reason) =~ "sk-stream-secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Tool schema mapping
  # ---------------------------------------------------------------------------

  describe "tool schema mapping" do
    test "maps OpenAI-style function tools to Anthropic tool entries" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "read_file",
            "description" => "Read a file",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "path" => %{"type" => "string", "description" => "File path"}
              },
              "required" => ["path"]
            }
          }
        }
      ]

      request = %Request{
        request()
        | tools: tools,
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)

      assert_receive {:json, json}
      assert [%{"type" => "custom", "name" => "read_file"}] = json["tools"]
      assert hd(json["tools"])["description"] == "Read a file"
      assert hd(json["tools"])["input_schema"]["type"] == "object"
    end

    test "tool presence does not crash even with ambiguous schemas" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      # Ambiguous/unusual tool schemas — should not crash
      tools = [
        %{"type" => "unknown_type", "data" => "weird"},
        %{"no_name_key" => true},
        %{"type" => "function", "function" => %{"no_name" => true}},
        %{"name" => "valid_tool"}
      ]

      request = %Request{
        request()
        | tools: tools,
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)

      assert_receive {:json, json}
      # Only valid tools should appear
      assert Enum.any?(json["tools"], fn t -> t["name"] == "valid_tool" end)
    end

    test "tools omitted when no valid tools can be mapped" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:json, options[:json]})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      tools = [
        %{"type" => "unknown_type", "data" => "weird"}
      ]

      request = %Request{
        request()
        | tools: tools,
          options: Map.put(request().options, :post_fn, post_fn)
      }

      assert {:ok, _} = AnthropicProvider.complete(request)

      assert_receive {:json, json}
      refute Map.has_key?(json, "tools")
    end
  end

  # ---------------------------------------------------------------------------
  # post_fn injection via opts and request.options
  # ---------------------------------------------------------------------------

  describe "post_fn injection" do
    test "post_fn from opts keyword list" do
      parent = self()

      post_fn = fn url, _options ->
        send(parent, {:post_called, url})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request()

      assert {:ok, _} = AnthropicProvider.complete(request, post_fn: post_fn)
      assert_receive {:post_called, _url}
    end

    test "http_post from request.options works as post_fn alias" do
      parent = self()

      http_post = fn url, _options ->
        send(parent, {:http_post_called, url})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request = request(%{http_post: http_post})

      assert {:ok, _} = AnthropicProvider.complete(request)
      assert_receive {:http_post_called, _url}
    end

    test "default HTTP path uses Req.post/2" do
      source = File.read!("lib/muse/llm/anthropic_provider.ex")
      assert source =~ "&Req.post/2"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp request(extra_options \\ %{}) do
    base_options = %{base_url: "https://api.anthropic.test/v1"}

    %Request{
      provider: :anthropic,
      model: "claude-sonnet-4-20250514",
      wire_api: nil,
      transport: :none,
      messages: [Message.user("hello")],
      stream: false,
      options: Map.merge(base_options, extra_options)
    }
  end

  defp text_body do
    %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => "Hello from Anthropic"}],
      "model" => "claude-sonnet-4-20250514",
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp tool_use_body do
    %{
      "id" => "msg_tools",
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "I will help with that."},
        %{
          "type" => "tool_use",
          "id" => "toolu_read",
          "name" => "read_file",
          "input" => %{"path" => "lib/muse.ex", "start_line" => 1}
        }
      ],
      "model" => "claude-sonnet-4-20250514",
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 15, "output_tokens" => 10}
    }
  end

  defp x_api_key_headers(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name) == "x-api-key" end)
    |> Enum.map(fn {_name, value} -> value end)
  end

  defp drain_events(acc \\ []) do
    receive do
      {:event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
