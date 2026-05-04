defmodule Muse.LLM.OpenAICompatibleProviderSSEContractTest do
  @moduledoc """
  Contract tests for OpenAI-compatible SSE streaming parsing.

  Exercises `Muse.LLM.OpenAI.SSEStreamParser` with fixture data — no network
  calls. Verifies that SSE frames decode into canonical Muse events, tool-call
  argument deltas reassemble correctly, usage propagates, and secrets in error
  frames are redaction-safe.
  """
  use ExUnit.Case, async: true

  alias Muse.EventPayloadRedactor
  alias Muse.LLM.{Event, Response, ToolCall}
  alias Muse.LLM.OpenAI.SSEStreamParser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "chat_completions"])

  # ---------------------------------------------------------------------------
  # Text deltas + usage
  # ---------------------------------------------------------------------------

  describe "text deltas with usage fixture" do
    setup do
      run_fixture_stream!("sse_text_delta.txt")
    end

    test "emits response_started as first event", %{events: events} do
      assert [%Event{type: :response_started} | _] = events
    end

    test "emits assistant_delta for each content chunk", %{events: events} do
      deltas = for %Event{type: :assistant_delta, text: text} <- events, do: text
      assert deltas == ["Hello", " from", " SSE"]
    end

    test "emits assistant_completed with full assembled text", %{events: events} do
      completed = Enum.find(events, &match?(%Event{type: :assistant_completed}, &1))
      assert completed.text == "Hello from SSE"
    end

    test "emits response_completed with usage", %{events: events} do
      completed = Enum.find(events, &match?(%Event{type: :response_completed}, &1))
      assert completed.usage == %{prompt_tokens: 10, completion_tokens: 6, total_tokens: 16}
    end

    test "assembles response with content, usage, and finish_reason", %{response: response} do
      assert %Response{} = response
      assert response.id == "chatcmpl-sse-text"
      assert response.content == "Hello from SSE"
      assert response.text == "Hello from SSE"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 10, completion_tokens: 6, total_tokens: 16}
      assert response.tool_calls == []
    end

    test "event type sequence matches canonical provider contract", %{events: events} do
      assert Enum.map(events, & &1.type) ==
               [
                 :response_started,
                 :assistant_delta,
                 :assistant_delta,
                 :assistant_delta,
                 :assistant_completed,
                 :response_completed
               ]
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call argument deltas
  # ---------------------------------------------------------------------------

  describe "tool call deltas fixture" do
    setup do
      run_fixture_stream!("sse_tool_call.txt")
    end

    test "emits tool_call_started when first tool chunk arrives", %{events: events} do
      started = Enum.find(events, &match?(%Event{type: :tool_call_started}, &1))
      assert %Event{type: :tool_call_started, tool_call: %ToolCall{}} = started
      assert started.tool_call.id == "call_sse_read"
      assert started.tool_call.name == "read_file"
    end

    test "emits tool_call_delta for each argument continuation", %{events: events} do
      deltas = for %Event{type: :tool_call_delta} = e <- events, do: e
      assert length(deltas) == 2

      assert deltas |> Enum.at(0) |> Map.get(:tool_call) |> Map.get(:arguments_delta) ==
               ~s({\"path\":)

      assert deltas |> Enum.at(1) |> Map.get(:tool_call) |> Map.get(:arguments_delta) ==
               ~s(\"README.md\",\"limit\":10})
    end

    test "emits tool_call_completed with fully assembled arguments", %{events: events} do
      completed = Enum.find(events, &match?(%Event{type: :tool_call_completed}, &1))
      assert %Event{type: :tool_call_completed, tool_call: %ToolCall{}} = completed
      assert completed.tool_call.id == "call_sse_read"
      assert completed.tool_call.name == "read_file"
      assert completed.tool_call.arguments == %{"path" => "README.md", "limit" => 10}
    end

    test "response has assembled tool calls and usage", %{response: response} do
      assert [%ToolCall{} = tc] = response.tool_calls
      assert tc.id == "call_sse_read"
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "README.md", "limit" => 10}
      assert response.finish_reason == "tool_calls"
      assert response.usage == %{prompt_tokens: 20, completion_tokens: 15, total_tokens: 35}
    end

    test "no assistant_delta or assistant_completed events for tool-call-only stream", %{
      events: events
    } do
      refute Enum.any?(events, &match?(%Event{type: :assistant_delta}, &1))
      refute Enum.any?(events, &match?(%Event{type: :assistant_completed}, &1))
    end

    test "event type sequence matches canonical tool-call contract", %{events: events} do
      assert Enum.map(events, & &1.type) == [
               :response_started,
               :tool_call_started,
               :tool_call_delta,
               :tool_call_delta,
               :tool_call_completed,
               :response_completed
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed / error frames with secrets
  # ---------------------------------------------------------------------------

  describe "malformed fixture with secret" do
    setup do
      run_fixture_stream!("sse_error.txt")
    end

    test "parses the valid content delta before the error", %{events: events} do
      deltas = for %Event{type: :assistant_delta, text: text} <- events, do: text
      assert deltas == ["Partial"]
    end

    test "emits provider_error for SSE error frame", %{events: events} do
      error_events = for %Event{type: :provider_error} = e <- events, do: e
      assert length(error_events) >= 1

      # The SSE error frame carries the raw provider error map
      error_event =
        Enum.find(error_events, fn e ->
          is_map(e.error) and Map.has_key?(e.error, "message")
        end)

      assert error_event != nil
      assert error_event.error["code"] == "429"
    end

    test "emits provider_error for malformed JSON line", %{events: events} do
      error_events = for %Event{type: :provider_error} = e <- events, do: e

      json_error =
        Enum.find(error_events, fn e ->
          match?({:invalid_sse_json, _}, e.error) or match?({:invalid_sse_data, _}, e.error)
        end)

      assert json_error != nil
    end

    test "raw error data in events is redaction-safe via EventPayloadRedactor", %{events: events} do
      error_events = for %Event{type: :provider_error} = e <- events, do: e

      for event <- error_events do
        redacted = EventPayloadRedactor.redact(event.error)

        inspected = inspect(redacted)

        refute inspected =~ "sk-fake-secret-key-abc123",
               "secret leaked through redaction: #{inspected}"
      end
    end

    test "assembled response has partial content despite errors", %{response: response} do
      assert response.content == "Partial"
    end

    test "parse_stream indicates error when error frames present" do
      raw = File.read!(Path.join(@fixtures_dir, "sse_error.txt"))
      {_events, result} = SSEStreamParser.parse_stream(raw)
      assert result == {:error, :provider_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Incremental chunk feeding (simulates network chunk delivery)
  # ---------------------------------------------------------------------------

  describe "incremental chunk feeding" do
    test "processing frame-sized chunks matches single-chunk parsing" do
      batch = run_fixture_stream!("sse_text_delta.txt", stream_fn: &single_chunk_stream/1)
      streamed = run_fixture_stream!("sse_text_delta.txt")

      assert Enum.map(batch.events, & &1.type) == Enum.map(streamed.events, & &1.type)
      assert batch.response.content == streamed.response.content
      assert batch.response.usage == streamed.response.usage
    end

    test "injected stream function + chunk callback can split stream and still assemble tool calls" do
      split_stream_fn = fn raw ->
        raw
        |> String.split("\n\n", trim: true)
        |> split_frame_chunks(2)
      end

      stream_result =
        run_fixture_stream!("sse_tool_call.txt",
          stream_fn: split_stream_fn,
          on_chunk: fn chunk -> send(self(), {:fixture_chunk, chunk}) end
        )

      assert_receive {:fixture_chunk, _chunk}
      assert_receive {:fixture_chunk, _chunk}

      completed = Enum.find(stream_result.events, &match?(%Event{type: :tool_call_completed}, &1))
      assert completed.tool_call.arguments == %{"path" => "README.md", "limit" => 10}
      assert stream_result.response.finish_reason == "tool_calls"
    end
  end

  defp run_fixture_stream!(fixture_name, opts \\ []) do
    raw = File.read!(Path.join(@fixtures_dir, fixture_name))
    stream_fn = Keyword.get(opts, :stream_fn, &default_frame_stream/1)
    on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)

    {stream_events, acc} =
      stream_fn.(raw)
      |> Enum.reduce({[], SSEStreamParser.new_accumulator()}, fn chunk, {events, acc} ->
        on_chunk.(chunk)

        {chunk_events, acc} =
          chunk
          |> SSEStreamParser.parse_frames()
          |> SSEStreamParser.process_frames(acc)

        {events ++ chunk_events, acc}
      end)

    {final_events, response} = SSEStreamParser.finalize(acc)

    %{events: stream_events ++ final_events, response: response}
  end

  defp default_frame_stream(raw) do
    raw
    |> String.split("\n\n", trim: true)
    |> Enum.map(&(&1 <> "\n\n"))
  end

  defp single_chunk_stream(raw), do: [raw]

  defp split_frame_chunks(frames, chunk_count) when chunk_count >= 1 do
    chunk_size = max(1, ceil(length(frames) / chunk_count))

    frames
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn frame_group -> Enum.join(frame_group, "\n\n") <> "\n\n" end)
  end
end
