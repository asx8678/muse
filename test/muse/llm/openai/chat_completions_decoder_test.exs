defmodule Muse.LLM.OpenAI.ChatCompletionsDecoderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Response, ToolCall}
  alias Muse.LLM.OpenAI.ChatCompletionsDecoder

  describe "decode/1" do
    test "simple assistant response decodes" do
      body = chat_completion_body(content: "Hello from the assistant.")

      assert {:ok, %Response{} = response} = ChatCompletionsDecoder.decode(body)
      assert response.id == "chatcmpl_123"
      assert response.content == "Hello from the assistant."
      assert response.text == "Hello from the assistant."
      assert response.tool_calls == []
      assert response.finish_reason == "stop"
      assert response.raw == body
    end

    test "usage is normalized to atom keys for known fields" do
      body =
        chat_completion_body(
          usage: %{
            "prompt_tokens" => 3,
            "completion_tokens" => 5,
            "total_tokens" => 8,
            "cached_tokens" => 2
          }
        )

      assert {:ok, response} = ChatCompletionsDecoder.decode(body)

      assert response.usage == %{
               "cached_tokens" => 2,
               prompt_tokens: 3,
               completion_tokens: 5,
               total_tokens: 8
             }

      refute Map.has_key?(response.usage, "prompt_tokens")
      refute Map.has_key?(response.usage, "completion_tokens")
      refute Map.has_key?(response.usage, "total_tokens")
      assert response.raw == body
    end

    test "tool_calls decode from JSON string arguments" do
      tool_call =
        tool_call_body(
          id: "call_read_file",
          name: "read_file",
          arguments: ~s({"path":"README.md","limit":5})
        )

      body = tool_call_completion_body(tool_calls: [tool_call])

      assert {:ok, response} = ChatCompletionsDecoder.decode(body)
      assert [%ToolCall{} = decoded] = response.tool_calls
      assert decoded.id == "call_read_file"
      assert decoded.name == "read_file"
      assert decoded.arguments == %{"path" => "README.md", "limit" => 5}
      assert decoded.raw == tool_call
    end

    test "tool_calls decode from map, empty string, and nil arguments" do
      map_call =
        tool_call_body(id: "call_map", name: "map_args", arguments: %{"path" => "mix.exs"})

      empty_call = tool_call_body(id: "call_empty", name: "empty_args", arguments: "")
      nil_call = tool_call_body(id: "call_nil", name: "nil_args", arguments: nil)

      body = tool_call_completion_body(tool_calls: [map_call, empty_call, nil_call])

      assert {:ok, response} = ChatCompletionsDecoder.decode(body)

      assert [decoded_map, decoded_empty, decoded_nil] = response.tool_calls
      assert decoded_map.arguments == %{"path" => "mix.exs"}
      assert decoded_empty.arguments == %{}
      assert decoded_nil.arguments == %{}
    end

    test "invalid tool-call JSON returns an error without raising" do
      tool_call = tool_call_body(name: "read_file", arguments: ~s({"path":"README.md"))
      body = tool_call_completion_body(tool_calls: [tool_call])

      assert {:error, reason} = ChatCompletionsDecoder.decode(body)

      inspected = inspect(reason)
      assert inspected =~ "invalid_tool_call_arguments"
      assert inspected =~ "invalid JSON"
      assert inspected =~ "choices[0].message.tool_calls[0].function.arguments"
      refute inspected =~ ~s({"path":"README.md")
    end

    test "missing choices, message, function, and function name return clear errors" do
      cases = [
        {
          "choices",
          Map.delete(chat_completion_body(), "choices"),
          "missing required field choices"
        },
        {
          "message",
          %{
            "id" => "chatcmpl_123",
            "choices" => [%{"finish_reason" => "stop"}],
            "usage" => usage_body()
          },
          "missing required field choices[0].message"
        },
        {
          "function",
          tool_call_completion_body(tool_calls: [%{"id" => "call_missing_function"}]),
          "missing required field choices[0].message.tool_calls[0].function"
        },
        {
          "function.name",
          tool_call_completion_body(
            tool_calls: [
              %{
                "id" => "call_missing_name",
                "type" => "function",
                "function" => %{"arguments" => "{}"}
              }
            ]
          ),
          "missing required field choices[0].message.tool_calls[0].function.name"
        }
      ]

      for {label, body, expected} <- cases do
        assert {:error, reason} = ChatCompletionsDecoder.decode(body), label
        assert inspect(reason) =~ expected, label
      end
    end

    test "tool-call-only response with nil content succeeds" do
      tool_call = tool_call_body(name: "list_files", arguments: nil)
      body = tool_call_completion_body(content: nil, tool_calls: [tool_call])

      assert {:ok, response} = ChatCompletionsDecoder.decode(body)
      assert response.content == nil
      assert response.text == nil
      assert response.finish_reason == "tool_calls"
      assert [%ToolCall{name: "list_files", arguments: %{}}] = response.tool_calls
    end

    test "decoder errors are redaction-safe when malformed raw body contains secrets" do
      body = %{
        "id" => "chatcmpl_secret",
        "authorization" => "Bearer super-secret-token",
        "api_key" => "sk-test-12345",
        "choices" => "not-a-list",
        "headers" => %{"Authorization" => "Bearer another-secret-token"}
      }

      assert {:error, reason} = ChatCompletionsDecoder.decode(body)

      inspected = inspect(reason)
      assert inspected =~ "malformed choices"
      refute inspected =~ "sk-test-12345"
      refute inspected =~ "super-secret-token"
      refute inspected =~ "another-secret-token"
      refute inspected =~ "Bearer super-secret-token"
      refute inspected =~ "Bearer another-secret-token"
    end
  end

  defp chat_completion_body(opts \\ []) do
    content = Keyword.get(opts, :content, "Hello")
    finish_reason = Keyword.get(opts, :finish_reason, "stop")
    usage = Keyword.get(opts, :usage, usage_body())

    %{
      "id" => Keyword.get(opts, :id, "chatcmpl_123"),
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => finish_reason
        }
      ],
      "usage" => usage
    }
  end

  defp tool_call_completion_body(opts) do
    content = Keyword.get(opts, :content, nil)
    tool_calls = Keyword.fetch!(opts, :tool_calls)

    %{
      "id" => Keyword.get(opts, :id, "chatcmpl_tools"),
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content,
            "tool_calls" => tool_calls
          },
          "finish_reason" => Keyword.get(opts, :finish_reason, "tool_calls")
        }
      ],
      "usage" => usage_body()
    }
  end

  defp tool_call_body(opts) do
    %{
      "id" => Keyword.get(opts, :id, "call_123"),
      "type" => "function",
      "function" => %{
        "name" => Keyword.fetch!(opts, :name),
        "arguments" => Keyword.get(opts, :arguments, "{}")
      }
    }
  end

  defp usage_body do
    %{
      "prompt_tokens" => 10,
      "completion_tokens" => 20,
      "total_tokens" => 30
    }
  end
end
