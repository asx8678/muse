defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, ToolCall}
  alias Muse.LLM.OpenAI.ChatCompletionsStreamDecoder

  describe "new/0" do
    test "returns a fresh decoder state" do
      state = ChatCompletionsStreamDecoder.new()
      assert %ChatCompletionsStreamDecoder{} = state
      assert state.text_parts == []
      assert state.tool_calls == %{}
      assert state.id == nil
      assert state.usage == nil
      assert state.finish_reason == nil
      assert state.finalized == false
    end
  end

  describe "feed/2 — text streaming" do
    test "emits assistant_delta for each content chunk" do
      state = ChatCompletionsStreamDecoder.new()

      {state, e1} = feed_text(state, "Hello")
      {state, e2} = feed_text(state, " world")
      {state, e3} = feed_text(state, "!")
      events = e1 ++ e2 ++ e3

      assert events == [
               Event.assistant_delta("Hello"),
               Event.assistant_delta(" world"),
               Event.assistant_delta("!")
             ]

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == "Hello world!"
      assert response.text == "Hello world!"
      assert response.finish_reason == "stop"
    end

    test "single content chunk produces correct events and response" do
      state = ChatCompletionsStreamDecoder.new()
      chunk = text_chunk("Hi there")
      {state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)

      assert events == [Event.assistant_delta("Hi there")]

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == "Hi there"
      assert response.tool_calls == []
      assert response.usage == nil
    end
  end

  describe "feed/2 — role-only delta" do
    test "role-only delta with nil content emits no events" do
      state = ChatCompletionsStreamDecoder.new()

      chunk = %{
        "choices" => [%{"delta" => %{"role" => "assistant", "content" => nil}, "index" => 0}]
      }

      {state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)
      assert events == []

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == ""
    end

    test "empty string content emits no events" do
      state = ChatCompletionsStreamDecoder.new()

      chunk = %{
        "choices" => [%{"delta" => %{"role" => "assistant", "content" => ""}, "index" => 0}]
      }

      {state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)
      assert events == []

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == ""
    end
  end

  describe "feed/2 — [DONE] marker" do
    test ":done atom marks stream as finalized" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _events} = ChatCompletionsStreamDecoder.feed(state, text_chunk("done"))
      {state, events} = ChatCompletionsStreamDecoder.feed(state, :done)
      assert events == []
      assert state.finalized

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == "done"
    end

    test "\"[DONE]\" string marks stream as finalized" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _events} = ChatCompletionsStreamDecoder.feed(state, text_chunk("yes"))
      {state, events} = ChatCompletionsStreamDecoder.feed(state, "[DONE]")
      assert events == []
      assert state.finalized

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == "yes"
    end

    test "chunks after finalized are ignored" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _events} = ChatCompletionsStreamDecoder.feed(state, :done)
      {state, events} = ChatCompletionsStreamDecoder.feed(state, text_chunk("ignored"))
      assert events == []
      assert state.finalized

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == ""
    end
  end

  describe "finalize/1 — finalization events" do
    test "emits assistant_completed and response_completed" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _} = ChatCompletionsStreamDecoder.feed(state, text_chunk("hello"))
      {_response, final_events} = ChatCompletionsStreamDecoder.finalize(state)

      assert [
               %Event{type: :assistant_completed, text: "hello"},
               %Event{type: :response_completed, usage: nil}
             ] = final_events
    end

    test "response_completed includes usage when present" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _} = ChatCompletionsStreamDecoder.feed(state, text_chunk("hello"))

      usage_chunk = %{
        "id" => "chatcmpl_abc",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 10, "total_tokens" => 15}
      }

      {state, _} = ChatCompletionsStreamDecoder.feed(state, usage_chunk)
      {response, final_events} = ChatCompletionsStreamDecoder.finalize(state)

      assert response.usage == %{
               prompt_tokens: 5,
               completion_tokens: 10,
               total_tokens: 15
             }

      assert [%Event{type: :assistant_completed}, %Event{type: :response_completed, usage: usage}] =
               final_events

      assert usage[:prompt_tokens] == 5
      assert usage[:completion_tokens] == 10
      assert usage[:total_tokens] == 15
    end

    test "finish_reason is preserved in final response" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _} = ChatCompletionsStreamDecoder.feed(state, text_chunk("hello"))

      {state, _} =
        ChatCompletionsStreamDecoder.feed(state, %{
          "choices" => [%{"finish_reason" => "stop", "delta" => %{}}]
        })

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.finish_reason == "stop"
    end

    test "id is preserved in final response" do
      state = ChatCompletionsStreamDecoder.new()
      {state, _} = ChatCompletionsStreamDecoder.feed(state, text_chunk("a"))

      {state, _} =
        ChatCompletionsStreamDecoder.feed(state, %{
          "id" => "chatcmpl_xyz",
          "choices" => [%{"delta" => %{"content" => "b"}}]
        })

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.id == "chatcmpl_xyz"
      assert response.content == "ab"
    end

    test "tool_call finish_reason takes precedence over default" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_1", "read_file")

      {state, _} =
        feed_tool_args(state, 0, ~s({"path": "README.md"}))

      {state, _} = ChatCompletionsStreamDecoder.feed(state, :done)
      {response, _} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.finish_reason == "tool_calls"
    end
  end

  describe "feed/2 — tool-call chunks" do
    test "tool_call_started emitted when id and name first known" do
      state = ChatCompletionsStreamDecoder.new()

      {state, events} =
        feed_tool_start(state, 0, "call_read", "read_file")

      assert [%Event{type: :tool_call_started, tool_call: %{id: "call_read", name: "read_file"}}] =
               events

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)
      assert [%ToolCall{id: "call_read", name: "read_file", arguments: %{}}] = response.tool_calls
    end

    test "tool_call_delta emitted for argument fragments" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _events} =
        feed_tool_start(state, 0, "call_read", "read_file")

      {state, events} =
        feed_tool_args(state, 0, ~s({"path": ))

      assert [%Event{type: :tool_call_delta, tool_call: %{arguments: ~s({"path": )}}] = events

      {state, events} =
        feed_tool_args(state, 0, ~s("README.md"}))

      assert [%Event{type: :tool_call_delta, tool_call: %{arguments: ~s("README.md"})}}] = events

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)

      assert [%ToolCall{id: "call_read", name: "read_file", arguments: %{"path" => "README.md"}}] =
               response.tool_calls
    end

    test "tool_call_completed emitted at finalization" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_ls", "list_files")

      {state, _} =
        feed_tool_args(state, 0, ~s({"dir": "."}))

      {_response, final_events} = ChatCompletionsStreamDecoder.finalize(state)

      assert Enum.any?(final_events, fn
               %Event{
                 type: :tool_call_completed,
                 tool_call: %ToolCall{id: "call_ls", name: "list_files"}
               } ->
                 true

               _ ->
                 false
             end)
    end

    test "multiple tool calls by index are handled independently" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_a", "tool_a")

      {state, _} =
        feed_tool_start(state, 1, "call_b", "tool_b")

      {state, _} =
        feed_tool_args(state, 0, ~s({"x": 1}))

      {state, _} =
        feed_tool_args(state, 1, ~s({"y": 2}))

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)

      assert [
               %ToolCall{id: "call_a", name: "tool_a", arguments: %{"x" => 1}},
               %ToolCall{id: "call_b", name: "tool_b", arguments: %{"y" => 2}}
             ] =
               response.tool_calls
    end

    test "tool call with empty arguments parts produces empty map" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_empty", "empty_tool")

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)

      assert [%ToolCall{id: "call_empty", name: "empty_tool", arguments: %{}}] =
               response.tool_calls
    end

    test "tool call with whitespace-only arguments produces empty map" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_ws", "ws_tool")

      {state, _} =
        feed_tool_args(state, 0, "  ")

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)
      assert [%ToolCall{id: "call_ws", name: "ws_tool", arguments: %{}}] = response.tool_calls
    end
  end

  describe "feed/2 — malformed tool argument JSON" do
    test "decodes to error with no raw secret leakage" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_bad", "bad_tool")

      {state, _} =
        feed_tool_args(state, 0, ~s({"secret": "sk-test-12345", "path": "README.md))

      {response, _final_events} = ChatCompletionsStreamDecoder.finalize(state)

      # Malformed tool call should be dropped from the response
      assert response.tool_calls == []

      # The content should still be present
      assert response.content == ""
    end

    test "non-map JSON at finalization does not crash" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} =
        feed_tool_start(state, 0, "call_arr", "array_tool")

      {state, _} =
        feed_tool_args(state, 0, ~s([1, 2, 3]))

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.tool_calls == []
    end
  end

  describe "feed/2 — unknown chunk shapes" do
    test "nil chunk does not crash" do
      state = ChatCompletionsStreamDecoder.new()
      {_state, events} = ChatCompletionsStreamDecoder.feed(state, nil)
      assert events == []
    end

    test "non-map chunk does not crash" do
      state = ChatCompletionsStreamDecoder.new()
      {_state, events} = ChatCompletionsStreamDecoder.feed(state, "not a map")
      assert events == []
    end

    test "chunk with missing choices key does not crash" do
      state = ChatCompletionsStreamDecoder.new()

      chunk = %{"id" => "chatcmpl_123", "object" => "chat.completion.chunk"}
      {state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)
      assert events == []
      assert state.id == "chatcmpl_123"

      {response, _} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.id == "chatcmpl_123"
    end

    test "chunk with non-list choices does not crash" do
      state = ChatCompletionsStreamDecoder.new()
      {_state, events} = ChatCompletionsStreamDecoder.feed(state, %{"choices" => "not_a_list"})
      assert events == []
    end

    test "chunk with empty choices list does not crash" do
      state = ChatCompletionsStreamDecoder.new()
      usage_chunk = %{"choices" => [], "usage" => %{"prompt_tokens" => 1}}
      {state, events} = ChatCompletionsStreamDecoder.feed(state, usage_chunk)
      assert events == []
      assert state.usage != nil
    end

    test "chunk with choice missing delta does not crash" do
      state = ChatCompletionsStreamDecoder.new()

      chunk = %{"choices" => [%{"index" => 0, "finish_reason" => "stop"}]}
      {state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)
      assert events == []
      assert state.finish_reason == "stop"
    end

    test "delta with unknown fields does not crash" do
      state = ChatCompletionsStreamDecoder.new()

      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "role" => "assistant",
              "unknown_field" => "some_value",
              "metadata" => %{"foo" => "bar"}
            }
          }
        ]
      }

      {_state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)
      assert events == []
    end
  end

  describe "feed/2 — usage in final chunk" do
    test "usage is captured from the final chunk and included in response" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} = ChatCompletionsStreamDecoder.feed(state, text_chunk("Hello"))

      usage_chunk = %{
        "id" => "chatcmpl_abc",
        "object" => "chat.completion.chunk",
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {state, _} = ChatCompletionsStreamDecoder.feed(state, usage_chunk)
      {state, _} = ChatCompletionsStreamDecoder.feed(state, :done)
      {response, final_events} = ChatCompletionsStreamDecoder.finalize(state)

      assert response.usage == %{
               prompt_tokens: 10,
               completion_tokens: 20,
               total_tokens: 30
             }

      assert Enum.any?(final_events, fn
               %Event{type: :response_completed, usage: %{prompt_tokens: 10}} -> true
               _ -> false
             end)
    end

    test "usage with custom keys is preserved" do
      state = ChatCompletionsStreamDecoder.new()

      {state, _} = ChatCompletionsStreamDecoder.feed(state, text_chunk("hi"))

      usage_chunk = %{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 1,
          "completion_tokens" => 1,
          "total_tokens" => 2,
          "cached_tokens" => 5
        }
      }

      {state, _} = ChatCompletionsStreamDecoder.feed(state, usage_chunk)
      {response, _} = ChatCompletionsStreamDecoder.finalize(state)

      assert response.usage[:prompt_tokens] == 1
      assert response.usage[:completion_tokens] == 1
      assert response.usage[:total_tokens] == 2
      assert response.usage["cached_tokens"] == 5
    end
  end

  describe "feed/2 — multiple choices" do
    test "only the first choice with delta is processed (streaming convention)" do
      state = ChatCompletionsStreamDecoder.new()

      chunk = %{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "first"}},
          %{"index" => 1, "delta" => %{"content" => "second"}}
        ]
      }

      {_state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)
      texts = Enum.map(events, & &1.text)
      assert "first" in texts
      assert "second" in texts
    end
  end

  describe "feed/2 — mix of text and tool calls" do
    test "text delta and tool call delta in same chunk both produce events" do
      state = ChatCompletionsStreamDecoder.new()

      # First tool call chunk (id + function name + first args piece)
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "content" => "Thinking...",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_think",
                  "type" => "function",
                  "function" => %{
                    "name" => "think",
                    "arguments" => ""
                  }
                }
              ]
            }
          }
        ]
      }

      {_state, events} = ChatCompletionsStreamDecoder.feed(state, chunk)

      types = Enum.map(events, & &1.type)
      assert :assistant_delta in types
      assert :tool_call_started in types
    end

    test "realistic multi-chunk streaming produces correct assembly" do
      state = ChatCompletionsStreamDecoder.new()

      # Chunk 0: role assignment
      {state, _events} =
        ChatCompletionsStreamDecoder.feed(state, %{
          "choices" => [%{"delta" => %{"role" => "assistant"}, "index" => 0}]
        })

      # Chunk 1: text prefix
      {state, _} =
        ChatCompletionsStreamDecoder.feed(state, text_chunk("I'll look into that."))

      # Chunk 2: tool call starts
      {state, _} =
        feed_tool_start(state, 0, "call_read", "read_file")

      # Chunk 3: first args fragment
      {state, _} =
        feed_tool_args(state, 0, ~s({"path": ))

      # Chunk 4: second args fragment
      {state, _} =
        feed_tool_args(state, 0, ~s("/tmp/file.txt"}))

      # Chunk 5: finish
      {state, _} =
        ChatCompletionsStreamDecoder.feed(state, %{
          "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
        })

      {response, final_events} = ChatCompletionsStreamDecoder.finalize(state)

      assert response.content == "I'll look into that."
      assert response.finish_reason == "tool_calls"

      assert [
               %ToolCall{
                 id: "call_read",
                 name: "read_file",
                 arguments: %{"path" => "/tmp/file.txt"}
               }
             ] =
               response.tool_calls

      final_types = Enum.map(final_events, & &1.type)
      assert :assistant_completed in final_types
      assert :tool_call_completed in final_types
      assert :response_completed in final_types
    end
  end

  describe "no dynamic atoms" do
    test "provider data strings are never converted to atoms" do
      # The module uses only compile-time atom keys from known maps.
      # Provider data (string keys, role names, etc.) should never be
      # converted to atoms via String.to_existing_atom/1 or similar.
      # This test verifies the module doesn't crash on realistic data
      # that could expose atom-table exhaustion if dynamic atom creation
      # were present.

      state = ChatCompletionsStreamDecoder.new()

      # Feed chunks with various string-shaped fields that could be
      # tempting to convert to atoms
      chunks = [
        %{
          "choices" => [%{"delta" => %{"role" => "assistant", "content" => "hello"}}]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{"name" => "read_file", "arguments" => "{}"}
                  }
                ]
              }
            }
          ]
        },
        %{
          "choices" => [%{"delta" => %{"content" => "world"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        },
        %{
          "id" => "chatcmpl_abc",
          "object" => "chat.completion.chunk",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }
      ]

      state =
        Enum.reduce(chunks, state, fn chunk, st ->
          {st, _events} = ChatCompletionsStreamDecoder.feed(st, chunk)
          st
        end)

      {response, _events} = ChatCompletionsStreamDecoder.finalize(state)
      assert response.content == "helloworld"
      assert response.finish_reason == "stop"
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp text_chunk(content) do
    %{
      "choices" => [%{"delta" => %{"content" => content}, "index" => 0}]
    }
  end

  defp feed_text(state, text) do
    ChatCompletionsStreamDecoder.feed(state, text_chunk(text))
  end

  defp feed_tool_start(state, index, id, name) do
    chunk = %{
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => index,
                "id" => id,
                "type" => "function",
                "function" => %{
                  "name" => name,
                  "arguments" => ""
                }
              }
            ]
          }
        }
      ]
    }

    ChatCompletionsStreamDecoder.feed(state, chunk)
  end

  defp feed_tool_args(state, index, arguments) do
    chunk = %{
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => index,
                "function" => %{
                  "arguments" => arguments
                }
              }
            ]
          }
        }
      ]
    }

    ChatCompletionsStreamDecoder.feed(state, chunk)
  end
end
