defmodule Muse.LLM.OpenAI.ResponsesStreamDecoderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAI.ResponsesStreamDecoder
  alias Muse.LLM.Event

  describe "new/0" do
    test "creates a fresh decoder state" do
      state = ResponsesStreamDecoder.new()
      assert state.text == ""
      assert state.tool_calls == []
      assert state.pending_tool_calls == %{}
      assert state.response_id == nil
      assert state.usage == nil
      assert state.failed? == false
    end
  end

  describe "feed/2 — text deltas" do
    test "emits assistant_delta for response.output_text.delta" do
      state = ResponsesStreamDecoder.new()

      {new_state, events} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Hello"
        })

      assert [%Event{type: :assistant_delta, text: "Hello"}] = events
      assert new_state.text == "Hello"
    end

    test "accumulates text across multiple deltas" do
      state = ResponsesStreamDecoder.new()

      {state, e1} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Hi"
        })

      {state, e2} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => " there"
        })

      assert [%Event{type: :assistant_delta, text: "Hi"}] = e1
      assert [%Event{type: :assistant_delta, text: " there"}] = e2
      assert state.text == "Hi there"
    end

    test "response.output_text.done is acknowledged with no events" do
      state = ResponsesStreamDecoder.new()

      {state, []} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.done",
          "text" => "Hello"
        })

      assert state.text == ""
    end

    test "text delta with missing delta field is ignored" do
      state = ResponsesStreamDecoder.new()
      {^state, []} = ResponsesStreamDecoder.feed(state, %{"type" => "response.output_text.delta"})
    end
  end

  describe "feed/2 — lifecycle events" do
    test "response.created is acknowledged with no events" do
      state = ResponsesStreamDecoder.new()
      {^state, []} = ResponsesStreamDecoder.feed(state, %{"type" => "response.created"})
    end

    test "response.in_progress is acknowledged with no events" do
      state = ResponsesStreamDecoder.new()
      {^state, []} = ResponsesStreamDecoder.feed(state, %{"type" => "response.in_progress"})
    end
  end

  describe "feed/2 — tool calls" do
    test "emits tool_call_started for function_call output_item.added" do
      state = ResponsesStreamDecoder.new()

      frame = %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "call_1",
          "call_id" => "call_1",
          "name" => "read_file"
        }
      }

      {state, events} = ResponsesStreamDecoder.feed(state, frame)
      assert [%Event{type: :tool_call_started}] = events
      assert state.pending_tool_calls |> Map.has_key?("call_1")
    end

    test "emits tool_call_delta for function_call_arguments.delta" do
      state = ResponsesStreamDecoder.new()

      ResponsesStreamDecoder.feed(state, %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "call_1",
          "call_id" => "call_1",
          "name" => "read_file"
        }
      })
      |> then(fn {state, _} ->
        {_state, events} =
          ResponsesStreamDecoder.feed(state, %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "call_1",
            "delta" => "{\"path\":"
          })

        assert [%Event{type: :tool_call_delta}] = events
      end)
    end

    test "emits tool_call_completed for function_call output_item.done" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "id" => "call_1",
            "call_id" => "call_1",
            "name" => "read_file"
          }
        })

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "call_1",
          "delta" => "{\"path\":"
        })

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.function_call_arguments.done",
          "item_id" => "call_1",
          "arguments" => "{\"path\":\"/tmp\"}"
        })

      {state, events} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "id" => "call_1",
            "call_id" => "call_1",
            "name" => "read_file",
            "arguments" => "{\"path\":\"/tmp\"}"
          }
        })

      assert [%Event{type: :tool_call_completed}] = events
      assert length(state.tool_calls) == 1
      tc = hd(state.tool_calls)
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/tmp"}
    end

    test "non-function_call output_item.added is ignored" do
      state = ResponsesStreamDecoder.new()

      {^state, []} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_item.added",
          "item" => %{"type" => "message"}
        })
    end

    test "non-function_call output_item.done is ignored" do
      state = ResponsesStreamDecoder.new()

      {^state, []} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_item.done",
          "item" => %{"type" => "message"}
        })
    end
  end

  describe "feed/2 — response.completed" do
    test "captures response_id and usage from response.completed" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Hello"
        })

      {state, events} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_123",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
          }
        })

      assert state.response_id == "resp_123"
      assert state.usage == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      # No events from feed for response.completed — those come from finalize
      assert events == []
    end
  end

  describe "feed/2 — failure events" do
    test "response.failed marks stream as failed and emits provider_error" do
      state = ResponsesStreamDecoder.new()
      {state, [event]} = ResponsesStreamDecoder.feed(state, %{"type" => "response.failed"})
      assert state.failed? == true
      assert event.type == :provider_error
    end

    test "error event marks stream as failed and emits provider_error" do
      state = ResponsesStreamDecoder.new()
      {state, [event]} = ResponsesStreamDecoder.feed(state, %{"type" => "error"})
      assert state.failed? == true
      assert event.type == :provider_error
    end

    test "after failure, further frames are ignored" do
      state = ResponsesStreamDecoder.new()
      {state, _} = ResponsesStreamDecoder.feed(state, %{"type" => "response.failed"})

      {_state, events} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Should be ignored"
        })

      assert events == []
    end
  end

  describe "feed/2 — unknown events" do
    test "unknown event types are safely ignored" do
      state = ResponsesStreamDecoder.new()
      {^state, []} = ResponsesStreamDecoder.feed(state, %{"type" => "some_future_event"})
    end

    test "non-map frames are safely ignored" do
      state = ResponsesStreamDecoder.new()
      {^state, []} = ResponsesStreamDecoder.feed(state, "not a map")
      {^state, []} = ResponsesStreamDecoder.feed(state, nil)
    end
  end

  describe "finalize/1" do
    test "returns response with provider_state containing previous_response_id" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Hi"
        })

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_abc"}
        })

      {response, events} = ResponsesStreamDecoder.finalize(state)
      assert response.id == "resp_abc"
      assert response.content == "Hi"
      assert response.provider_state == %{previous_response_id: "resp_abc"}
      assert response.finish_reason == "stop"

      types = Enum.map(events, & &1.type)
      assert :response_completed in types
    end

    test "after failure, finalize returns error response with no completion events" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Partial"
        })

      {state, _} = ResponsesStreamDecoder.feed(state, %{"type" => "response.failed"})

      {response, events} = ResponsesStreamDecoder.finalize(state)
      assert response.finish_reason == "error"
      assert response.content == nil
      assert events == []
      assert response.provider_state == %{previous_response_id: nil}
    end

    test "finalize with no text produces nil content" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_empty"}
        })

      {response, _events} = ResponsesStreamDecoder.finalize(state)
      assert response.content == nil
      assert response.text == nil
    end
  end

  describe "usage normalization" do
    test "maps input_tokens to prompt_tokens" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_usage",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 20, "total_tokens" => 30}
          }
        })

      assert state.usage == %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}
    end

    test "handles nil usage gracefully" do
      state = ResponsesStreamDecoder.new()

      {state, _} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_no_usage"}
        })

      assert state.usage == nil
    end
  end

  describe "full text streaming flow" do
    test "text streaming produces canonical event sequence" do
      state = ResponsesStreamDecoder.new()

      {state, []} = ResponsesStreamDecoder.feed(state, %{"type" => "response.created"})
      {state, []} = ResponsesStreamDecoder.feed(state, %{"type" => "response.in_progress"})

      {state, e1} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => "Hello"
        })

      {state, e2} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.delta",
          "delta" => " world"
        })

      {state, []} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.output_text.done",
          "text" => "Hello world"
        })

      {state, []} =
        ResponsesStreamDecoder.feed(state, %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_text",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
          }
        })

      # Deltas are emitted immediately; completion events come from finalize
      stream_events = e1 ++ e2
      assert Enum.map(stream_events, & &1.type) == [:assistant_delta, :assistant_delta]

      {response, finalize_events} = ResponsesStreamDecoder.finalize(state)
      finalize_types = Enum.map(finalize_events, & &1.type)
      assert :assistant_completed in finalize_types
      assert :response_completed in finalize_types
      assert response.content == "Hello world"
      assert response.provider_state == %{previous_response_id: "resp_text"}
    end
  end
end
