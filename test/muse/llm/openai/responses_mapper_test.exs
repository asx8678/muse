defmodule Muse.LLM.OpenAI.ResponsesMapperTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAI.ResponsesMapper
  alias Muse.LLM.{Message, Request}

  describe "endpoint_path/0" do
    test "returns the Responses API path" do
      assert ResponsesMapper.endpoint_path() == "/responses"
    end
  end

  describe "to_payload/1 messages" do
    test "maps system messages to instructions and non-system text messages to typed input" do
      request = %Request{
        model: "gpt-4.1-mini",
        messages: [
          Message.system("Be concise."),
          Message.user("Add a /version command."),
          Message.system("Use read-only tools before planning."),
          Message.assistant("I'll inspect the CLI routing first.")
        ]
      }

      payload = ResponsesMapper.to_payload(request)

      assert payload["model"] == "gpt-4.1-mini"
      assert payload["instructions"] == "Be concise.\n\nUse read-only tools before planning."

      assert payload["input"] == [
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_text", "text" => "Add a /version command."}
                 ]
               },
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "input_text", "text" => "I'll inspect the CLI routing first."}
                 ]
               }
             ]

      refute Enum.any?(payload["input"], &(&1["role"] == "system"))
      assert payload["stream"] == true
      assert payload["store"] == false
      assert_string_keys!(payload)
    end

    test "maps tool result messages without losing role, content, or tool_call_id" do
      content = Jason.encode!(%{"result" => "5 files"})

      request = %Request{
        model: "gpt-4.1-mini",
        messages: [Message.tool(content, "call_123")]
      }

      payload = ResponsesMapper.to_payload(request)
      [tool_result] = payload["input"]

      assert tool_result["type"] == "function_call_output"
      assert tool_result["role"] == "tool"
      assert tool_result["content"] == content
      assert tool_result["tool_call_id"] == "call_123"
      assert tool_result["call_id"] == "call_123"
      assert tool_result["output"] == content
      assert_string_keys!(payload)
    end
  end

  describe "to_payload/1 tools" do
    test "flattens OpenAI function schemas and strips debug atom keys" do
      tool = %{
        :name => "debug-preview-name",
        :debug => true,
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          :description => "Read a file from the workspace.",
          :debug => :do_not_emit,
          "parameters" => %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Workspace-relative path"
              }
            },
            required: ["path"],
            additionalProperties: false
          }
        }
      }

      request = %Request{
        model: "gpt-4.1-mini",
        messages: [Message.user("Read mix.exs")],
        tools: [tool]
      }

      payload = ResponsesMapper.to_payload(request)

      assert payload["tools"] == [
               %{
                 "type" => "function",
                 "name" => "read_file",
                 "description" => "Read a file from the workspace.",
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{
                     "path" => %{
                       "type" => "string",
                       "description" => "Workspace-relative path"
                     }
                   },
                   "required" => ["path"],
                   "additionalProperties" => false
                 }
               }
             ]

      [mapped_tool] = payload["tools"]
      refute Map.has_key?(mapped_tool, :name)
      refute Map.has_key?(mapped_tool, :debug)
      refute Map.has_key?(mapped_tool, "function")
      refute inspect(payload) =~ "debug-preview-name"
      refute inspect(payload) =~ "do_not_emit"
      assert_string_keys!(payload)
    end
  end

  describe "to_payload/1 state and streaming flags" do
    test "includes previous_response_id, stream, and store with nil store defaulting false" do
      default_store_payload =
        ResponsesMapper.to_payload(%Request{
          model: "gpt-4.1-mini",
          messages: [Message.user("hello")]
        })

      assert default_store_payload["store"] == false

      payload =
        ResponsesMapper.to_payload(%Request{
          model: "gpt-4.1-mini",
          messages: [Message.user("continue")],
          previous_response_id: "resp_abc123",
          stream: false,
          store: true
        })

      assert payload["previous_response_id"] == "resp_abc123"
      assert payload["stream"] == false
      assert payload["store"] == true
      assert_string_keys!(payload)
    end
  end

  describe "to_payload/1 optional generation fields" do
    test "includes temperature, max_output_tokens, and Responses structured output format only when present" do
      response_format = %{
        type: "json_schema",
        name: "plan",
        strict: true,
        schema: %{
          type: "object",
          properties: %{
            title: %{type: "string"}
          },
          required: ["title"],
          additionalProperties: false
        }
      }

      payload =
        ResponsesMapper.to_payload(%Request{
          model: "gpt-4.1-mini",
          messages: [Message.user("Return a plan as JSON")],
          temperature: 0.2,
          max_tokens: 1024,
          response_format: response_format
        })

      assert payload["temperature"] == 0.2
      assert payload["max_output_tokens"] == 1024

      assert payload["text"] == %{
               "format" => %{
                 "type" => "json_schema",
                 "name" => "plan",
                 "strict" => true,
                 "schema" => %{
                   "type" => "object",
                   "properties" => %{
                     "title" => %{"type" => "string"}
                   },
                   "required" => ["title"],
                   "additionalProperties" => false
                 }
               }
             }

      refute Map.has_key?(payload, "response_format")
      assert_string_keys!(payload)
    end

    test "omits optional generation fields when absent" do
      payload =
        ResponsesMapper.to_payload(%Request{
          model: "gpt-4.1-mini",
          messages: [Message.user("hello")]
        })

      refute Map.has_key?(payload, "temperature")
      refute Map.has_key?(payload, "max_output_tokens")
      refute Map.has_key?(payload, "text")
      refute Map.has_key?(payload, "response_format")
    end
  end

  describe "JSON compatibility" do
    test "produces payloads Jason can encode" do
      payload =
        ResponsesMapper.to_payload(%Request{
          model: "gpt-4.1-mini",
          messages: [
            Message.system("Be safe."),
            Message.user("Use a tool."),
            Message.tool("done", "call_done")
          ],
          tools: [
            %{
              "type" => "function",
              "function" => %{
                "name" => "list_files",
                "description" => "List files.",
                "parameters" => %{type: "object", properties: %{}}
              },
              :name => "list_files"
            }
          ],
          previous_response_id: "resp_previous",
          stream: true,
          store: nil,
          temperature: 1.0,
          max_tokens: 256,
          response_format: %{type: "json_object"}
        })

      assert_string_keys!(payload)
      assert Jason.encode!(payload) =~ "gpt-4.1-mini"
    end
  end

  defp assert_string_keys!(value) when is_list(value) do
    Enum.each(value, &assert_string_keys!/1)
  end

  defp assert_string_keys!(value) when is_map(value) do
    Enum.each(value, fn {key, nested_value} ->
      assert is_binary(key), "expected string key, got #{inspect(key)} in #{inspect(value)}"
      assert_string_keys!(nested_value)
    end)
  end

  defp assert_string_keys!(_value), do: :ok
end
