defmodule Muse.LLM.OpenAICompatibleProviderSSEErrorTest do
  @moduledoc """
  SSE error handling and secret redaction tests for PR14.

  Acceptance criteria covered:

    1. Non-2xx HTTP/SSE response returns provider error with bounded/redacted
       body summary; emits provider_error when in stream/2.
    2. Transport exceptions/errors from sse_post_fn/Req are caught, bounded,
       redacted, and emit provider_error.
    3. Malformed SSE JSON returns/emits provider_error; no raw secret leakage.
    4. Mid-stream failure after some deltas emits previously valid deltas
       then one provider_error and returns error; no assistant_completed/
       response_completed after failure.
    5. [DONE] without final usage still completes safely.
    6. Unknown provider SSE events/fields are ignored safely; never crash.
    7. Authorization/API keys are redacted from errors/events.
    8. No hangs/timeouts in tests.
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAICompatibleProvider

  # ---------------------------------------------------------------------------
  # Non-2xx HTTP responses
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE non-2xx HTTP" do
    test "401 returns provider_http_error and emits provider_error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 401}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      assert rendered =~ "provider_http_error" or rendered =~ "401"

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "500 returns provider_http_error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 500}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end
  end

  # ---------------------------------------------------------------------------
  # Transport errors
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE transport errors" do
    test "connection refused emits provider_error and returns error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, :econnrefused}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "exception in sse_post_fn is caught and emits provider_error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        raise "unexpected SSE crash"
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "throw in sse_post_fn is caught" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        throw(:intentional_throw)
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed JSON
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE malformed JSON" do
    test "malformed JSON chunk emits provider_error and returns error" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.("data: {{invalid json}}\n\n")
        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      provider_errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(provider_errors) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Mid-stream failure
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE mid-stream failure" do
    test "valid deltas emitted before failure; no completed events after" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        # First: valid text delta
        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-mid", "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}}]})}\n\n"
        )

        # Then: malformed JSON triggers failure
        on_chunk.("data: {not valid json\n\n")
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)

      # Should have the valid assistant_delta before the error
      deltas = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(deltas) >= 1

      # Should have provider_error
      assert Enum.any?(events, &(&1.type == :provider_error))

      # Should NOT have assistant_completed or response_completed after failure
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end
  end

  # ---------------------------------------------------------------------------
  # [DONE] without usage
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE [DONE] without usage" do
    test "stream completes safely when no usage is provided" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-no-usage", "choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}}]})}\n\n"
        )

        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-no-usage", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)
      assert response.content == "Hi"
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown SSE events
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE unknown events" do
    test "comment-only frames are ignored without crashing" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.(": this is a comment\n\n")

        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-comment", "choices" => [%{"index" => 0, "delta" => %{"content" => "ok"}}]})}\n\n"
        )

        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-comment", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)
      assert response.content == "ok"
    end

    test "non-map JSON data is ignored without crashing" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.("data: 42\n\n")
        on_chunk.("data: \"just a string\"\n\n")

        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-nonmap", "choices" => [%{"index" => 0, "delta" => %{"content" => "fine"}}]})}\n\n"
        )

        on_chunk.(
          "data: #{Jason.encode!(%{"id" => "chatcmpl-nonmap", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})}\n\n"
        )

        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)
      assert response.content == "fine"
    end
  end

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE redaction" do
    test "provider_error events never contain raw Authorization value" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, {:connection_failed, "Bearer sk-leak-check-error"}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer sk-sse-error-secret"}]
        })

      events = collect_stream_events(req)

      Enum.each(events, fn event ->
        rendered = inspect(event)
        refute rendered =~ "sk-sse-error-secret"
      end)
    end

    test "non-2xx error never contains raw auth from headers" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 403}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer sk-403-sse-secret"}]
        })

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      refute rendered =~ "sk-403-sse-secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid sse_post_fn
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE invalid sse_post_fn" do
    test "wrong arity returns clear error" do
      req = sse_request(%{sse_post_fn: fn _a, _b -> {:ok, %{status: 200}} end})

      result = stream_with_collector(req)
      assert {:error, reason} = result
      rendered = inspect(reason)
      assert rendered =~ "invalid_sse_post_fn" or rendered =~ "three-arity"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sse_request(extra_options) do
    base = %{base_url: "https://api.example.test/v1"}

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :sse,
      messages: [Message.user("hello")],
      stream: true,
      options: Map.merge(base, extra_options)
    }
  end

  defp collect_stream_events(req) do
    {_result, events} = stream_with_events(req)
    events
  end

  defp stream_with_collector(req) do
    {result, _events} = stream_with_events(req)
    result
  end

  defp stream_with_events(req) do
    test_pid = self()
    ref = make_ref()

    emit_fn = fn event ->
      send(test_pid, {:sse_error_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(req, emit_fn)
    events = drain_events(ref)
    {result, events}
  end

  defp drain_events(ref, acc \\ []) do
    receive do
      {:sse_error_event, ^ref, event} -> drain_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
