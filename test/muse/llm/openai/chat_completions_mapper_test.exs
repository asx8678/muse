defmodule Muse.LLM.OpenAI.ChatCompletionsMapperTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAI.ChatCompletionsMapper

  # ---------------------------------------------------------------------------
  # endpoint_path/0
  # ---------------------------------------------------------------------------

  describe "endpoint_path/0" do
    test "returns /chat/completions" do
      assert ChatCompletionsMapper.endpoint_path() == "/chat/completions"
    end
  end

  # ---------------------------------------------------------------------------
  # to_payload/1 — messages
  # ---------------------------------------------------------------------------

  describe "to_payload/1 — messages" do
    test "includes required model field" do
      payload = build_payload(model: "gpt-4.1")
      assert payload["model"] == "gpt-4.1"
    end

    test "maps system message" do
      payload = build_payload(messages: [Message.system("be helpful")])
      assert [msg] = payload["messages"]
      assert msg["role"] == "system"
      assert msg["content"] == "be helpful"
    end

    test "maps user message" do
      payload = build_payload(messages: [Message.user("hello")])
      assert [msg] = payload["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "hello"
    end

    test "maps assistant message" do
      payload = build_payload(messages: [Message.assistant("ok")])
      assert [msg] = payload["messages"]
      assert msg["role"] == "assistant"
      assert msg["content"] == "ok"
    end

    test "maps assistant message with nil content" do
      payload = build_payload(messages: [Message.assistant(nil)])
      assert [msg] = payload["messages"]
      assert msg["role"] == "assistant"
      assert msg["content"] == nil
    end

    test "maps tool message with tool_call_id" do
      payload = build_payload(messages: [Message.tool("file contents", "call_abc123")])
      assert [msg] = payload["messages"]
      assert msg["role"] == "tool"
      assert msg["content"] == "file contents"
      assert msg["tool_call_id"] == "call_abc123"
    end

    test "omits tool_call_id from non-tool messages" do
      payload = build_payload(messages: [Message.user("hello")])
      assert [msg] = payload["messages"]
      refute Map.has_key?(msg, "tool_call_id")
    end

    test "includes name on message when present" do
      msg = %Message{role: :user, content: "hello", name: "Alice"}
      payload = build_payload(messages: [msg])
      assert [m] = payload["messages"]
      assert m["name"] == "Alice"
    end

    test "omits name when nil" do
      payload = build_payload(messages: [Message.user("hello")])
      assert [m] = payload["messages"]
      refute Map.has_key?(m, "name")
    end

    test "maps multiple messages in order" do
      payload =
        build_payload(
          messages: [
            Message.system("be helpful"),
            Message.user("hello"),
            Message.assistant("hi there"),
            Message.tool("result", "call_1")
          ]
        )

      msgs = payload["messages"]
      assert length(msgs) == 4
      assert Enum.map(msgs, & &1["role"]) == ["system", "user", "assistant", "tool"]
    end

    test "handles nil messages" do
      payload = build_payload(messages: nil)
      assert payload["messages"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # to_payload/1 — tools
  # ---------------------------------------------------------------------------

  describe "to_payload/1 — tools" do
    test "maps tools and strips debug atom keys" do
      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "read_file",
            "description" => "Read a file",
            "parameters" => %{"type" => "object"}
          },
          :name => "read_file"
        }
      ]

      payload = build_payload(tools: tools)
      assert [tool] = payload["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read_file"
      refute Map.has_key?(tool, :name)
    end

    test "omits tools block when tools is nil" do
      payload = build_payload(tools: nil)
      refute Map.has_key?(payload, "tools")
    end

    test "omits tools block when tools is empty" do
      payload = build_payload(tools: [])
      refute Map.has_key?(payload, "tools")
    end
  end

  # ---------------------------------------------------------------------------
  # to_payload/1 — tool_choice
  # ---------------------------------------------------------------------------

  describe "to_payload/1 — tool_choice" do
    defp tools_with_one,
      do: [%{"type" => "function", "function" => %{"name" => "read_file", "parameters" => %{}}}]

    test "defaults to auto when tools present and choice is nil" do
      payload = build_payload(tools: tools_with_one(), tool_choice: nil)
      assert payload["tool_choice"] == "auto"
    end

    test "maps :auto" do
      payload = build_payload(tools: tools_with_one(), tool_choice: :auto)
      assert payload["tool_choice"] == "auto"
    end

    test "maps :none" do
      payload = build_payload(tools: tools_with_one(), tool_choice: :none)
      assert payload["tool_choice"] == "none"
    end

    test "maps :required" do
      payload = build_payload(tools: tools_with_one(), tool_choice: :required)
      assert payload["tool_choice"] == "required"
    end

    test "maps {:function, name}" do
      payload = build_payload(tools: tools_with_one(), tool_choice: {:function, "read_file"})

      assert payload["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "read_file"}
             }
    end

    test "omits tool_choice when no tools present" do
      payload = build_payload(tools: nil, tool_choice: :auto)
      refute Map.has_key?(payload, "tool_choice")
    end

    test "omits tool_choice when tools is empty" do
      payload = build_payload(tools: [], tool_choice: :auto)
      refute Map.has_key?(payload, "tool_choice")
    end
  end

  # ---------------------------------------------------------------------------
  # to_payload/1 — optional fields
  # ---------------------------------------------------------------------------

  describe "to_payload/1 — optional fields" do
    test "includes stream when true" do
      payload = build_payload(stream: true)
      assert payload["stream"] == true
    end

    test "includes stream when false" do
      payload = build_payload(stream: false)
      assert payload["stream"] == false
    end

    test "includes temperature when set" do
      payload = build_payload(temperature: 0.7)
      assert payload["temperature"] == 0.7
    end

    test "omits temperature when nil" do
      payload = build_payload(temperature: nil)
      refute Map.has_key?(payload, "temperature")
    end

    test "includes max_tokens when set" do
      payload = build_payload(max_tokens: 100)
      assert payload["max_tokens"] == 100
    end

    test "omits max_tokens when nil" do
      payload = build_payload(max_tokens: nil)
      refute Map.has_key?(payload, "max_tokens")
    end

    test "includes response_format when set" do
      rf = %{type: "json_schema", json_schema: %{name: "test", schema: %{type: "object"}}}
      payload = build_payload(response_format: rf)
      assert payload["response_format"] == rf
    end

    test "omits response_format when nil" do
      payload = build_payload(response_format: nil)
      refute Map.has_key?(payload, "response_format")
    end

    test "omits all optional nil fields" do
      payload =
        build_payload(
          tools: nil,
          temperature: nil,
          max_tokens: nil,
          response_format: nil
        )

      refute Map.has_key?(payload, "tools")
      refute Map.has_key?(payload, "tool_choice")
      refute Map.has_key?(payload, "temperature")
      refute Map.has_key?(payload, "max_tokens")
      refute Map.has_key?(payload, "response_format")
      assert payload["stream"] == true
    end
  end

  # ---------------------------------------------------------------------------
  # to_payload/1 — JSON encodability
  # ---------------------------------------------------------------------------

  describe "to_payload/1 — JSON encodability" do
    test "payload with full options is encodable and decodes correctly" do
      rf = %{type: "json_schema", json_schema: %{name: "test", schema: %{type: "object"}}}

      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "read_file",
            "description" => "Read a file",
            "parameters" => %{"type" => "object"}
          },
          :name => "read_file"
        }
      ]

      payload =
        build_payload(
          model: "gpt-4.1",
          messages: [
            Message.system("be helpful"),
            Message.user("hello")
          ],
          tools: tools,
          tool_choice: :auto,
          temperature: 0.5,
          max_tokens: 2000,
          response_format: rf,
          stream: true
        )

      json = Jason.encode!(payload)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["model"] == "gpt-4.1"
      assert length(decoded["messages"]) == 2
      assert decoded["tool_choice"] == "auto"
      assert decoded["temperature"] == 0.5
      assert decoded["max_tokens"] == 2000
      assert decoded["stream"] == true

      # response_format atom keys are stringified by Jason
      assert decoded["response_format"]["type"] == "json_schema"

      # tools contain only JSON-compatible keys (no :name)
      assert [tool] = decoded["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read_file"
    end

    test "minimal payload is encodable" do
      payload = build_payload(model: "gpt-4.1-mini", messages: [Message.user("hi")])
      json = Jason.encode!(payload)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["model"] == "gpt-4.1-mini"
      assert [msg] = decoded["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "hi"
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp build_payload(opts) do
    model = Keyword.get(opts, :model, "gpt-4.1")
    messages = Keyword.get(opts, :messages, [Message.user("hi")])
    tools = Keyword.get(opts, :tools)
    tool_choice = Keyword.get(opts, :tool_choice)
    stream = Keyword.get(opts, :stream, true)
    temperature = Keyword.get(opts, :temperature)
    max_tokens = Keyword.get(opts, :max_tokens)
    response_format = Keyword.get(opts, :response_format)

    req = %Request{
      model: model,
      messages: messages,
      tools: tools,
      tool_choice: tool_choice,
      stream: stream,
      temperature: temperature,
      max_tokens: max_tokens,
      response_format: response_format
    }

    ChatCompletionsMapper.to_payload(req)
  end
end
