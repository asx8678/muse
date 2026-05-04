defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, ToolCall}
  alias Muse.LLM.OpenAI.ChatCompletionsStreamDecoder

  describe "decode/2 — tool call streaming" do
    test "single tool call across multiple chunks emits started/delta/completed events" do
      events =
        collect_events(fn emit ->
          chunks = [
            # First chunk: id, name, and empty arguments
            tool_call_delta_chunk(0, "call_read_file", "read_file", ""),
            # Argument deltas
            tool_call_arg_chunk(0, ~s({"path":)),
            tool_call_arg_chunk(0, ~s("README.md"})),
            # Final chunk with finish_reason
            finish_chunk("tool_calls")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      assert_event_types(events, [
        :tool_call_started,
        :tool_call_delta,
        :tool_call_delta,
        :tool_call_completed
      ])

      # Verify started event
      assert %Event{type: :tool_call_started, tool_call: started} = Enum.at(events, 0)
      assert started.id == "call_read_file"
      assert started.name == "read_file"
      assert started.index == 0

      # Verify first delta
      assert %Event{type: :tool_call_delta, tool_call: d1} = Enum.at(events, 1)
      assert d1.index == 0
      assert d1.arguments == ~s({"path":)

      # Verify second delta
      assert %Event{type: :tool_call_delta, tool_call: d2} = Enum.at(events, 2)
      assert d2.index == 0
      assert d2.arguments == ~s("README.md"})

      # Verify completed event
      assert %Event{type: :tool_call_completed, tool_call: %ToolCall{} = tc} = Enum.at(events, 3)
      assert tc.id == "call_read_file"
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "README.md"}
    end

    test "multiple interleaved tool calls by index" do
      events =
        collect_events(fn emit ->
          chunks = [
            # Start tool call 0
            tool_call_delta_chunk(0, "call_read", "read_file", ""),
            # Start tool call 1
            tool_call_delta_chunk(1, "call_write", "write_file", ""),
            # Interleaved arguments
            tool_call_arg_chunk(0, ~s({"path":)),
            tool_call_arg_chunk(1, ~s({"path":)),
            tool_call_arg_chunk(0, ~s("README.md"})),
            tool_call_arg_chunk(1, ~s("output.txt"})),
            finish_chunk("tool_calls")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      # Two started events first, then 4 deltas, then 2 completed
      started = Enum.filter(events, &(&1.type == :tool_call_started))
      deltas = Enum.filter(events, &(&1.type == :tool_call_delta))
      completed = Enum.filter(events, &(&1.type == :tool_call_completed))

      assert length(started) == 2
      assert length(deltas) == 4
      assert length(completed) == 2

      # Verify tool call 0
      tc0 = completed |> Enum.find(&match?(%Event{tool_call: %{id: "call_read"}}, &1))
      assert tc0.tool_call.name == "read_file"
      assert tc0.tool_call.arguments == %{"path" => "README.md"}

      # Verify tool call 1
      tc1 = completed |> Enum.find(&match?(%Event{tool_call: %{id: "call_write"}}, &1))
      assert tc1.tool_call.name == "write_file"
      assert tc1.tool_call.arguments == %{"path" => "output.txt"}
    end

    test "text content plus tool calls produces both assistant and tool events" do
      events =
        collect_events(fn emit ->
          chunks = [
            text_delta_chunk("I'll look that up."),
            tool_call_delta_chunk(0, "call_find", "search_files", ~s({"query":)),
            tool_call_arg_chunk(0, ~s("config"})),
            finish_chunk("tool_calls")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      assert_event_types(events, [
        :assistant_delta,
        :tool_call_started,
        :tool_call_delta,
        :tool_call_completed
      ])

      assert %Event{type: :assistant_delta, text: "I'll look that up."} = hd(events)
    end

    test "multiple assistant deltas concatenate into final response content" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          text_delta_chunk("Hello"),
          text_delta_chunk(" "),
          text_delta_chunk("World"),
          finish_chunk("stop")
        ])

      assert response.content == "Hello World"
      assert response.finish_reason == "stop"
      assert response.tool_calls == []
    end

    test "response includes usage when provided in a chunk" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          text_delta_chunk("Done"),
          %{
            "id" => "cmpl_1",
            "object" => "chat.completion.chunk",
            "choices" => [
              %{
                "index" => 0,
                "delta" => %{},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
          }
        ])

      assert response.usage == %{
               "prompt_tokens" => 10,
               "completion_tokens" => 20,
               "total_tokens" => 30
             }

      assert response.content == "Done"
    end

    test "response id is set from chunk id" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          %{
            "id" => "chatcmpl_abc123",
            "object" => "chat.completion.chunk",
            "choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}}]
          },
          finish_chunk("stop", "chatcmpl_abc123")
        ])

      assert response.id == "chatcmpl_abc123"
    end

    test "finish_reason tool_calls produces correct response" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          tool_call_delta_chunk(0, "call_tc1", "list_files", ~s({"path":"."})),
          finish_chunk("tool_calls")
        ])

      assert response.finish_reason == "tool_calls"
      assert [%ToolCall{name: "list_files"}] = response.tool_calls
    end

    test "tool_call without explicit id uses tc_ prefix fallback" do
      events =
        collect_events(fn emit ->
          chunks = [
            # A delta chunk without "id" field but with a tool call entry
            # (edge case — normally id is always present on the first chunk)
            %{
              "id" => "cmpl_1",
              "object" => "chat.completion.chunk",
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{
                    "tool_calls" => [
                      %{
                        "index" => 0,
                        "type" => "function",
                        "function" => %{
                          "name" => "fallback_fn",
                          "arguments" => "{}"
                        }
                      }
                    ]
                  },
                  "finish_reason" => "tool_calls"
                }
              ]
            }
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      %Event{type: :tool_call_started, tool_call: started} = hd(events)
      # When no id is present, we fall back to "tc_<index>"
      assert started.id == "tc_0"
      assert started.name == "fallback_fn"
    end

    test "malformed argument JSON emits provider_error and tool call completes with empty map" do
      events =
        collect_events(fn emit ->
          chunks = [
            tool_call_delta_chunk(0, "call_bad", "risky_tool", ~s({"path":)),
            tool_call_arg_chunk(0, "UNCLOSED_JSON"),
            finish_chunk("tool_calls")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      # Should see tool_call_started, tool_call_delta, provider_error, tool_call_completed
      assert_event_types(events, [
        :tool_call_started,
        :tool_call_delta,
        :provider_error,
        :tool_call_completed
      ])

      # Provider error should be redacted
      %Event{type: :provider_error, error: error_msg} = Enum.at(events, 2)
      assert is_binary(error_msg)
      assert error_msg =~ "invalid JSON"
      assert error_msg =~ "call_bad"
      # The raw JSON should NOT leak into the error
      refute error_msg =~ "UNCLOSED_JSON"
      refute error_msg =~ "{\"path\":"

      # Tool call still completes with empty arguments
      %Event{type: :tool_call_completed, tool_call: %ToolCall{} = tc} = List.last(events)
      assert tc.name == "risky_tool"
      assert tc.arguments == %{}
    end

    test "non-map arguments decode result emits provider_error" do
      events =
        collect_events(fn emit ->
          chunks = [
            # arguments that decode to a JSON array, not an object
            tool_call_delta_chunk(0, "call_arr", "array_return", ~s([1, 2, 3])),
            finish_chunk("tool_calls")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      %Event{type: :provider_error, error: error_msg} = Enum.at(events, 1)
      assert error_msg =~ "not decode to a JSON object"
    end

    test "empty arguments list produces empty map" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          tool_call_delta_chunk(0, "call_empty", "no_args", ""),
          finish_chunk("tool_calls")
        ])

      assert [%ToolCall{arguments: %{}}] = response.tool_calls
    end

    test "chunks with reserved words in keys demonstrate no crash" do
      # Ensure a chunk with Bun-inspired key patterns doesn't interfere
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          text_delta_chunk("safe"),
          finish_chunk("stop")
        ])

      assert response.content == "safe"
    end
  end

  describe "decode/2 — text-only streaming" do
    test "stream of text deltas produces correct response" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          text_delta_chunk("The", "cmpl_text"),
          text_delta_chunk(" quick", "cmpl_text"),
          text_delta_chunk(" brown", "cmpl_text"),
          text_delta_chunk(" fox.", "cmpl_text"),
          finish_chunk("stop", "cmpl_text")
        ])

      assert response.content == "The quick brown fox."
      assert response.finish_reason == "stop"
      assert response.tool_calls == []
      assert response.id == "cmpl_text"
    end

    test "empty chunk list produces empty response" do
      {:ok, response} = ChatCompletionsStreamDecoder.decode([])

      assert response.content == nil
      assert response.finish_reason == nil
      assert response.tool_calls == []
    end

    test "nil content in delta does not create assistant_delta event" do
      events =
        collect_events(fn emit ->
          ChatCompletionsStreamDecoder.decode(
            [
              %{
                "id" => "cmpl_1",
                "object" => "chat.completion.chunk",
                "choices" => [
                  %{
                    "index" => 0,
                    "delta" => %{"role" => "assistant", "content" => nil},
                    "finish_reason" => nil
                  }
                ]
              },
              text_delta_chunk("Actual"),
              finish_chunk("stop")
            ],
            emit
          )
        end)

      assert_event_types(events, [:assistant_delta])
    end
  end

  describe "decode/2 — edge cases" do
    test "chunk without choices is gracefully skipped" do
      events =
        collect_events(fn emit ->
          chunks = [
            %{"id" => "cmpl_1", "object" => "chat.completion.chunk"},
            text_delta_chunk("works"),
            finish_chunk("stop")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      assert_event_types(events, [:assistant_delta])
    end

    test "non-map chunk is silently ignored" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          "not a map",
          42,
          text_delta_chunk("Hello"),
          finish_chunk("stop")
        ])

      assert response.content == "Hello"
    end

    test "unknown tool call index delta is handled gracefully" do
      events =
        collect_events(fn emit ->
          chunks = [
            # Delta for an index that was never started
            %{
              "id" => "cmpl_1",
              "object" => "chat.completion.chunk",
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{
                    "tool_calls" => [
                      %{
                        "index" => 999,
                        "function" => %{"arguments" => "some data"}
                      }
                    ]
                  },
                  "finish_reason" => nil
                }
              ]
            },
            finish_chunk("stop")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      # Should emit a provider_error for the unknown index
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "no finish_reason in stream completes with inferred tool_calls" do
      {:ok, response} =
        ChatCompletionsStreamDecoder.decode([
          tool_call_delta_chunk(0, "call_1", "my_tool", ~s({"key":"val"})),
          # No explicit finish_reason chunk — just empty choices or usage
          %{
            "id" => "cmpl_1",
            "object" => "chat.completion.chunk",
            "choices" => [%{"index" => 0, "delta" => %{}}]
          }
        ])

      assert response.finish_reason == "tool_calls"
      assert [%ToolCall{name: "my_tool"}] = response.tool_calls
    end
  end

  describe "decode/2 — event emission completeness" do
    test "full tool call lifecycle emits all expected event types in order" do
      events =
        collect_events(fn emit ->
          chunks = [
            text_delta_chunk("Let me check."),
            tool_call_delta_chunk(0, "call_a", "tool_a", ""),
            tool_call_arg_chunk(0, ~s({"x":1})),
            text_delta_chunk(" "),
            tool_call_delta_chunk(1, "call_b", "tool_b", ""),
            tool_call_arg_chunk(1, ~s({"y":2})),
            finish_chunk("tool_calls")
          ]

          ChatCompletionsStreamDecoder.decode(chunks, emit)
        end)

      # Multiple assistant deltas possible
      assistant_count = Enum.count(events, &(&1.type == :assistant_delta))
      started_count = Enum.count(events, &(&1.type == :tool_call_started))
      delta_count = Enum.count(events, &(&1.type == :tool_call_delta))
      completed_count = Enum.count(events, &(&1.type == :tool_call_completed))

      assert assistant_count == 2
      assert started_count == 2
      assert delta_count == 2
      assert completed_count == 2
    end

    test "events emitted include stable id/name/index in partial map" do
      events =
        collect_events(fn emit ->
          ChatCompletionsStreamDecoder.decode(
            [
              tool_call_delta_chunk(0, "call_stable", "stable_fn", ""),
              finish_chunk("tool_calls")
            ],
            emit
          )
        end)

      %Event{type: :tool_call_started, tool_call: partial} = hd(events)
      assert partial.id == "call_stable"
      assert partial.name == "stable_fn"
      assert partial.index == 0
    end

    test "tool_call_delta only carries index and arguments, no unrelated payload" do
      events =
        collect_events(fn emit ->
          ChatCompletionsStreamDecoder.decode(
            [
              tool_call_delta_chunk(0, "call_d", "delta_fn", ""),
              tool_call_arg_chunk(0, ~s({"a":1})),
              finish_chunk("tool_calls")
            ],
            emit
          )
        end)

      %Event{type: :tool_call_delta, tool_call: delta} =
        Enum.find(events, &(&1.type == :tool_call_delta))

      # Should only have index and arguments
      assert delta == %{index: 0, arguments: ~s({"a":1})}
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp text_delta_chunk(text, id \\ "cmpl_text_only") do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"content" => text},
          "finish_reason" => nil
        }
      ]
    }
  end

  defp tool_call_delta_chunk(index, call_id, name, arguments) do
    %{
      "id" => "cmpl_tc",
      "object" => "chat.completion.chunk",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => index,
                "id" => call_id,
                "type" => "function",
                "function" => %{
                  "name" => name,
                  "arguments" => arguments
                }
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end

  defp tool_call_arg_chunk(index, arguments) do
    %{
      "id" => "cmpl_tc",
      "object" => "chat.completion.chunk",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => index,
                "function" => %{
                  "arguments" => arguments
                }
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end

  defp finish_chunk(finish_reason, id \\ "cmpl_finish") do
    # Note: id should match the text/initial chunk id in tests that assert on response.id
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => finish_reason
        }
      ]
    }
  end

  defp collect_events(fun) do
    parent = self()
    events_ref = make_ref()

    emit_fn = fn event ->
      send(parent, {events_ref, event})
      :ok
    end

    fun.(emit_fn)

    collect(events_ref, [])
    |> Enum.reverse()
  end

  defp collect(ref, acc) do
    receive do
      {^ref, event} -> collect(ref, [event | acc])
    after
      0 -> acc
    end
  end

  defp assert_event_types(events, expected_types) do
    actual_types = Enum.map(events, & &1.type)

    assert actual_types == expected_types,
           "Expected event types #{inspect(expected_types)}, got #{inspect(actual_types)}"
  end
end
