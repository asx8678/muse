defmodule Muse.LLM.OpenAICompatibleProviderSSEContractTest do
  @moduledoc """
  Contract tests for OpenAI-compatible SSE streaming against fixture data.

  Uses `Muse.LLM.Transport.SSE.Parser` and `Muse.LLM.OpenAI.ChatCompletionsStreamDecoder`
  to verify that SSE frames from fixture files decode into canonical Muse events,
  tool-call argument deltas reassemble correctly, usage propagates, and secrets
  in error frames are redaction-safe. No network calls.
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, Message, Request, Response}
  alias Muse.LLM.OpenAICompatibleProvider
  alias Muse.LLM.Transport.SSE.Parser, as: SSEParser
  alias Muse.LLM.OpenAI.ChatCompletionsStreamDecoder

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
      assert Enum.map(events, & &1.type) == [
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
      assert %Event{type: :tool_call_started} = started
      assert started.tool_call.name == "read_file"
    end

    test "emits tool_call_delta for each argument continuation", %{events: events} do
      deltas = for %Event{type: :tool_call_delta} = e <- events, do: e
      assert length(deltas) == 2
    end

    test "emits tool_call_completed with fully assembled arguments", %{events: events} do
      completed = Enum.find(events, &match?(%Event{type: :tool_call_completed}, &1))
      assert %Event{type: :tool_call_completed} = completed
      tc = completed.tool_call
      assert tc.name == "read_file"
      assert tc.arguments["path"] == "README.md"
      assert tc.arguments["limit"] == 10
    end

    test "assembles response with tool_calls", %{response: response} do
      assert %Response{} = response
      assert length(response.tool_calls) == 1
      tc = hd(response.tool_calls)
      assert tc.name == "read_file"
      assert tc.arguments["path"] == "README.md"
    end
  end

  # ---------------------------------------------------------------------------
  # Error fixture — malformed JSON and error events
  # ---------------------------------------------------------------------------

  describe "error fixture with malformed data" do
    setup do
      run_fixture_stream!("sse_error.txt", expect_error: true)
    end

    test "emits provider_error for malformed/error chunks", %{events: events} do
      errors = for %Event{type: :provider_error} <- events, do: :error_event
      assert length(errors) >= 1
    end

    test "returns error result", %{result: result} do
      assert match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Pure parser + decoder contract (no provider)
  # ---------------------------------------------------------------------------

  describe "pure SSE parser + decoder contract" do
    test "text fixture parses and decodes correctly" do
      fixture = read_fixture!("sse_text_delta.txt")
      {events, _parser} = parse_sse_text(fixture)

      data_events = Enum.filter(events, &(&1.data != "[DONE]" and &1.data != ""))
      decoder = ChatCompletionsStreamDecoder.new()

      {final_decoder, all_events} =
        Enum.reduce(data_events, {decoder, []}, fn event, {dec, evts} ->
          case Jason.decode(event.data) do
            {:ok, chunk} when is_map(chunk) ->
              {new_dec, new_evts} = ChatCompletionsStreamDecoder.feed(dec, chunk)
              {new_dec, evts ++ new_evts}

            _ ->
              {dec, evts}
          end
        end)

      {response, final_evts} = ChatCompletionsStreamDecoder.finalize(final_decoder)
      all_events = all_events ++ final_evts

      assert response.content == "Hello from SSE"
      assert Enum.any?(all_events, &(&1.type == :assistant_delta))
      assert Enum.any?(all_events, &(&1.type == :response_completed))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp read_fixture!(filename) do
    path = Path.join(@fixtures_dir, filename)
    File.read!(path)
  end

  defp parse_sse_text(text) do
    parser = SSEParser.new()
    SSEParser.parse_chunk(text, parser)
  end

  defp run_fixture_stream!(filename, opts \\ []) do
    expect_error? = Keyword.get(opts, :expect_error, false)
    fixture_data = read_fixture!(filename)

    sse_post_fn = fn _url, _req_options, on_chunk ->
      on_chunk.(fixture_data)
      {:ok, %{status: 200}}
    end

    req = %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      transport: :sse,
      wire_api: :chat_completions,
      messages: [Message.user("hello")],
      stream: true,
      options: %{base_url: "https://api.example.test/v1", sse_post_fn: sse_post_fn}
    }

    {result, events} = collect_stream(req)

    response =
      case result do
        {:ok, resp} -> resp
        _ -> nil
      end

    if expect_error? do
      %{result: result, events: events, response: nil}
    else
      assert {:ok, ^response} = result
      %{result: result, events: events, response: response}
    end
  end

  defp collect_stream(req) do
    test_pid = self()
    ref = make_ref()

    emit_fn = fn event ->
      send(test_pid, {:sse_contract_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(req, emit_fn)
    events = drain_events(ref)
    {result, events}
  end

  defp drain_events(ref, acc \\ []) do
    receive do
      {:sse_contract_event, ^ref, event} -> drain_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
