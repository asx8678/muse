defmodule Muse.LLM.OpenAICompatibleProviderSSEAuthTest do
  @moduledoc """
  SSE streaming auth integration tests for PR14.

  Covers:
    - Auth resolution and Authorization header attachment for SSE stream path
    - Explicit Authorization header wins over resolved auth in SSE path
    - Missing auth returns auth_error before sse_post_fn is called
    - Network errors in SSE path do not leak API keys or Bearer tokens
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAICompatibleProvider

  # ---------------------------------------------------------------------------
  # Auth resolution
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE auth resolution" do
    test "resolves auth and attaches Authorization header to SSE request" do
      parent = self()

      sse_post_fn = fn _url, req_options, on_chunk ->
        send(parent, {:sse_auth_headers, req_options[:headers]})
        text_sse_chunks() |> Enum.each(&on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          auth: :api_key,
          env_map: %{"MUSE_OPENAI_API_KEY" => "sk-test-key-sse"}
        })

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_auth_headers, headers}
      assert headers != nil
      auth_header = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
      assert auth_header != nil
      assert elem(auth_header, 1) =~ "Bearer "
    end

    test "explicit Authorization header wins over resolved auth in SSE path" do
      parent = self()

      sse_post_fn = fn _url, req_options, on_chunk ->
        send(parent, {:sse_explicit_auth, req_options[:headers]})
        text_sse_chunks() |> Enum.each(&on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer explicit-sse-token"}],
          auth: :api_key,
          env_map: %{"MUSE_OPENAI_API_KEY" => "sk-should-not-appear"}
        })

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_explicit_auth, headers}
      auth_header = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
      assert auth_header != nil
      assert elem(auth_header, 1) == "Bearer explicit-sse-token"
      refute elem(auth_header, 1) =~ "sk-should-not-appear"
    end
  end

  # ---------------------------------------------------------------------------
  # Auth error
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE auth error" do
    test "missing configured auth returns error before sse_post_fn is called" do
      called? = Agent.start_link(fn -> false end)

      sse_post_fn = fn _url, _req_options, _on_chunk ->
        Agent.update(elem(called?, 1), fn _ -> true end)
        {:ok, %{status: 200}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          auth: :api_key,
          env_map: %{}
        })

      result = stream_with_collector(req)
      assert {:error, _reason} = result
      # The sse_post_fn should NOT have been called since auth failed first
      refute Agent.get(elem(called?, 1), & &1)
      Agent.stop(elem(called?, 1))
    end
  end

  # ---------------------------------------------------------------------------
  # No key leakage
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE no auth leakage" do
    test "provider_error events from transport error never contain raw auth value" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, {:connection_failed, "header had Bearer sk-leak-check-sse"}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer sk-sse-leak-test"}]
        })

      events = collect_stream_events(req)

      Enum.each(events, fn event ->
        rendered = inspect(event)
        refute rendered =~ "sk-sse-leak-test"
        refute rendered =~ "sk-leak-check-sse"
      end)
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

  defp text_sse_chunks do
    [
      "data: #{Jason.encode!(%{"id" => "chatcmpl-sse-auth", "model" => "gpt-4.1-mini", "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "Hello"}}]})}\n\n",
      "data: #{Jason.encode!(%{"id" => "chatcmpl-sse-auth", "model" => "gpt-4.1-mini", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}})}\n\n",
      "data: [DONE]\n\n"
    ]
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
      send(test_pid, {:sse_auth_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(req, emit_fn)
    events = drain_events(ref)
    {result, events}
  end

  defp drain_events(ref, acc \\ []) do
    receive do
      {:sse_auth_event, ^ref, event} -> drain_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
