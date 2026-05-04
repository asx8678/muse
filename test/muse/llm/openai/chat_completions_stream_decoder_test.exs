defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAI.ChatCompletionsStreamDecoder
  alias Muse.LLM.{Event}

  describe "text streaming" do
    test "accumulates content deltas and finalizes" do
      acc = ChatCompletionsStreamDecoder.new()

      chunk1 = %{
        "id" => "chatcmpl-test",
        "choices" => [%{"delta" => %{"role" => "assistant", "content" => "Hello"}}]
      }

      chunk2 = %{
        "id" => "chatcmpl-test",
        "choices" => [%{"delta" => %{"content" => " world"}}]
      }

      chunk3 = %{
        "id" => "chatcmpl-test",
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      }

      {events1, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk1, acc)
      assert :response_started in Enum.map(events1, & &1.type)
      assert :assistant_delta in Enum.map(events1, & &1.type)

      {events2, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk2, acc)
      assert [%Event{type: :assistant_delta, text: " world"}] = events2

      {events3, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk3, acc)
      assert events3 == []

      {final_events, response} = ChatCompletionsStreamDecoder.finalize(acc)

      assert %Event{type: :assistant_completed, text: "Hello world"} in final_events
      assert Enum.any?(final_events, &(&1.type == :response_completed))

      usage_event = Enum.find(final_events, &(&1.type == :response_completed))
      assert usage_event.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}

      assert response.content == "Hello world"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
    end
  end

  describe "tool call streaming" do
    test "accumulates tool call deltas and finalizes" do
      acc = ChatCompletionsStreamDecoder.new()

      chunk1 = %{
        "id" => "chatcmpl-tools",
        "choices" => [
          %{
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => ""}
                }
              ]
            }
          }
        ]
      }

      chunk2 = %{
        "id" => "chatcmpl-tools",
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}
              ]
            }
          }
        ]
      }

      chunk3 = %{
        "id" => "chatcmpl-tools",
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "\"lib/muse.ex\"}"}}
              ]
            }
          }
        ]
      }

      chunk4 = %{
        "id" => "chatcmpl-tools",
        "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      {events1, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk1, acc)
      assert :response_started in Enum.map(events1, & &1.type)
      assert :tool_call_started in Enum.map(events1, & &1.type)

      {events2, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk2, acc)
      assert :tool_call_delta in Enum.map(events2, & &1.type)

      {_events3, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk3, acc)
      {_events4, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk4, acc)

      {final_events, response} = ChatCompletionsStreamDecoder.finalize(acc)

      # Should have tool_call_completed and response_completed
      assert Enum.any?(final_events, &(&1.type == :tool_call_completed))
      assert Enum.any?(final_events, &(&1.type == :response_completed))

      assert length(response.tool_calls) == 1
      [tc] = response.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse.ex"}
      assert response.finish_reason == "tool_calls"
    end
  end

  describe "edge cases" do
    test "handles empty content delta" do
      acc = ChatCompletionsStreamDecoder.new()

      chunk = %{
        "id" => "t",
        "choices" => [%{"delta" => %{"role" => "assistant"}}]
      }

      {events, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk, acc)

      # Only response_started — no assistant_delta for role-only delta
      assert Enum.map(events, & &1.type) == [:response_started]
      {_final_events, _response} = ChatCompletionsStreamDecoder.finalize(acc)
    end

    test "handles chunk without choices (usage-only)" do
      acc = ChatCompletionsStreamDecoder.new()

      # First, start the stream
      {_, acc} =
        ChatCompletionsStreamDecoder.decode_chunk(
          %{"id" => "t", "choices" => [%{"delta" => %{"content" => "ok"}}]},
          acc
        )

      # Usage-only chunk (no choices)
      chunk = %{
        "id" => "t",
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      {events, acc} = ChatCompletionsStreamDecoder.decode_chunk(chunk, acc)

      assert events == []

      {_final_events, response} = ChatCompletionsStreamDecoder.finalize(acc)
      assert response.usage == %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
    end
  end
end
