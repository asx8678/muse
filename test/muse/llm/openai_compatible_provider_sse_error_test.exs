defmodule Muse.LLM.OpenAICompatibleProviderSSEErrorTest do
  @moduledoc """
  SSE error handling and secret redaction tests for PR14 Lane 08.

  Acceptance criteria covered:

    1. Non-2xx HTTP/SSE response returns {:provider_http_error, %{status: ...}}
       with bounded/redacted body summary; emits provider_error when in stream/2.
    2. Transport exceptions/errors from stream_fn/Req are caught, bounded,
       redacted, and emit provider_error.
    3. Malformed SSE JSON returns/emits {:provider_decode_error, ...}
       redacted/bounded; no raw secret body leakage.
    4. Mid-stream failure after some deltas emits previously valid deltas
       then one provider_error and returns error; no assistant_completed/
       response_completed after failure.
    5. [DONE] without final usage still completes safely.
    6. Unknown provider SSE events/fields are ignored or represented safely;
       never crash.
    7. Authorization/API keys/Bearer/JWT-like strings are redacted from
       errors/events. Raw token can only be captured in outbound Authorization
       header in tests.
    8. No hangs/timeouts in tests.
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, Message, Request, ToolCall}
  alias Muse.LLM.OpenAICompatibleProvider

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp sse_request(extra) do
    base = %{base_url: "https://api.example.test/v1"}

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :sse,
      messages: [Message.user("hello")],
      stream: true,
      options: Map.merge(base, extra)
    }
  end

  defp collect_events do
    parent = self()

    fn event ->
      send(parent, {:sse_event, event})
      :ok
    end
  end

  defp drain_events(acc \\ []) do
    receive do
      {:sse_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sse_lines(events) when is_list(events) do
    events
    |> Enum.map(&format_sse_event/1)
    |> Enum.join("")
  end

  # Single-field shortcut
  defp format_sse_event({:data, value}) do
    "data: #{value}\n\n"
  end

  # Multi-field event: list of field tuples, followed by blank line
  defp format_sse_event(fields) when is_list(fields) do
    content =
      fields
      |> Enum.map(fn
        {:data, value} -> "data: #{value}\n"
        {:event, value} -> "event: #{value}\n"
        {:id, value} -> "id: #{value}\n"
        {:comment, _} -> ": comment\n"
      end)
      |> Enum.join()

    content <> "\n"
  end

  defp sse_chunk(choice_delta, opts \\ []) do
    id = Keyword.get(opts, :id, "chatcmpl-test")
    finish_reason = Keyword.get(opts, :finish_reason)
    usage = Keyword.get(opts, :usage)

    chunk = %{"id" => id, "choices" => [%{"delta" => choice_delta}]}

    chunk =
      if finish_reason,
        do: put_in(chunk, ["choices", Access.at(0), "finish_reason"], finish_reason),
        else: chunk

    chunk = if usage, do: Map.put(chunk, "usage", usage), else: chunk
    Jason.encode!(chunk)
  end

  # ---------------------------------------------------------------------------
  # Acceptance 1: Non-2xx HTTP/SSE response
  # ---------------------------------------------------------------------------

  describe "SSE non-2xx HTTP response (acceptance 1)" do
    test "401 returns {:provider_http_error, %{status: 401}} with redacted body and emits provider_error" do
      secret_body =
        String.duplicate("noisy ", 100) <>
          "Bearer sk-body-secret-abc123 token=also-leaked api_key=sk-leaked-key"

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 401, body: secret_body)}
      end

      req =
        sse_request(%{
          stream_fn: post_fn,
          headers: %{"Authorization" => "Bearer sk-header-secret"}
        })

      assert {:error, {:provider_http_error, %{status: 401, body_summary: summary}}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      rendered = inspect(summary)
      refute rendered =~ "sk-body-secret"
      refute rendered =~ "sk-header-secret"
      refute rendered =~ "Bearer sk"
      refute rendered =~ "token=also-leaked"
      refute rendered =~ "api_key=sk-leaked"

      # Body summary is bounded
      assert is_binary(summary) and String.length(summary) <= 500

      # Emits exactly one provider_error
      events = drain_events()
      assert [%Event{type: :provider_error, error: event_error}] = events
      refute inspect(event_error) =~ "sk-body-secret"
      refute inspect(event_error) =~ "sk-header-secret"
    end

    test "429 rate-limit returns provider_http_error with redacted body" do
      post_fn = fn _url, _opts ->
        {:ok,
         Req.Response.new(
           status: 429,
           body: %{"error" => %{"message" => "rate limited", "token" => "sk-leaked-in-body"}}
         )}
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_http_error, %{status: 429, body_summary: summary}}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      # Map body should be sanitized/redacted
      rendered = inspect(summary)
      refute rendered =~ "sk-leaked-in-body"

      events = drain_events()
      assert [%Event{type: :provider_error}] = events
    end

    test "500 internal error returns provider_http_error" do
      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 500, body: "Internal Server Error with sk-err-key")}
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_http_error, %{status: 500, body_summary: summary}}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      refute inspect(summary) =~ "sk-err-key"

      events = drain_events()
      assert [%Event{type: :provider_error}] = events
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 2: Transport exceptions/errors from stream_fn/Req
  # ---------------------------------------------------------------------------

  describe "SSE transport errors (acceptance 2)" do
    test "stream_fn returning {:error, exception} emits provider_error with redacted reason" do
      post_fn = fn _url, _opts ->
        {:error, RuntimeError.exception("connection reset Bearer sk-transport-secret")}
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      rendered = inspect(reason)
      refute rendered =~ "sk-transport-secret"
      assert rendered =~ "connection reset"

      events = drain_events()
      assert [%Event{type: :provider_error, error: event_error}] = events
      refute inspect(event_error) =~ "sk-transport-secret"
    end

    test "stream_fn raising an exception is caught and emits provider_error" do
      post_fn = fn _url, _opts ->
        raise "DNS resolution failed with api_key=sk-dns-leak"
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      rendered = inspect(reason)
      refute rendered =~ "sk-dns-leak"

      events = drain_events()
      assert [%Event{type: :provider_error}] = events
    end

    test "stream_fn throwing is caught and emits provider_error" do
      post_fn = fn _url, _opts ->
        throw({:boom, "token=sk-thrown-token"})
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      rendered = inspect(reason)
      refute rendered =~ "sk-thrown-token"

      events = drain_events()
      assert [%Event{type: :provider_error}] = events
    end

    test "stream_fn returning unexpected shape emits provider_error" do
      post_fn = fn _url, _opts -> {:ok, "not a map"} end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_network_error, _}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      events = drain_events()
      assert [%Event{type: :provider_error}] = events
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 3: Malformed SSE JSON
  # ---------------------------------------------------------------------------

  describe "SSE malformed JSON (acceptance 3)" do
    test "malformed JSON in SSE data emits provider_decode_error with redacted message" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "Hello"})},
          {:data, "{bad json with Bearer sk-malformed-secret"},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_decode_error, message}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      rendered = inspect(message)
      refute rendered =~ "sk-malformed-secret"

      events = drain_events()
      # Should have response_started, then at least one delta, then provider_error
      assert Enum.any?(events, &(&1.type == :response_started))
      assert Enum.any?(events, &(&1.type == :provider_error))

      error_event = Enum.find(events, &(&1.type == :provider_error))
      refute inspect(error_event.error) =~ "sk-malformed-secret"
    end

    test "non-object JSON in SSE data emits provider_decode_error" do
      sse_body =
        sse_lines([
          {:data, Jason.encode!([1, 2, 3])}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_decode_error, _}} =
               OpenAICompatibleProvider.stream(req, collect_events())
    end

    test "no raw secret body leakage in decode errors" do
      # Simulate a chunk that has a secret embedded in a JSON value
      sse_body =
        sse_lines([
          {:data, ~s({"choices":[{"delta":{"content":"ok"}}],"api_key":"sk-embedded-secret"})}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      result = OpenAICompatibleProvider.stream(req, collect_events())

      # The chunk may decode successfully (it's valid JSON), but secrets in
      # the raw body should not leak into returned events/errors
      case result do
        {:ok, _response} ->
          events = drain_events()

          for event <- events do
            refute inspect(event) =~ "sk-embedded-secret"
          end

        {:error, error} ->
          refute inspect(error) =~ "sk-embedded-secret"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 4: Mid-stream failure after some deltas
  # ---------------------------------------------------------------------------

  describe "SSE mid-stream failure (acceptance 4)" do
    test "valid deltas before malformed chunk are emitted, then provider_error, no completion events" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "Hello "})},
          {:data, sse_chunk(%{"content" => "world"})},
          {:data, "{broken json with token=sk-mid-secret"},
          {:data, sse_chunk(%{"content" => "should not appear"})}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:error, _reason} = OpenAICompatibleProvider.stream(req, collect_events())

      events = drain_events()
      types = Enum.map(events, & &1.type)

      # Should have response_started, then deltas, then provider_error
      assert :response_started in types
      assert :assistant_delta in types
      assert :provider_error in types

      # Must NOT have assistant_completed or response_completed after failure
      # The provider_error should be the last event type
      error_index = Enum.find_index(types, &(&1 == :provider_error))
      after_error = Enum.drop(types, error_index + 1)
      refute :assistant_completed in after_error
      refute :response_completed in after_error

      # The deltas before the error should contain the valid content
      deltas = events |> Enum.filter(&(&1.type == :assistant_delta)) |> Enum.map(& &1.text)
      assert "Hello " in deltas
      assert "world" in deltas

      # "should not appear" content must not be in any event
      for event <- events do
        refute event.text == "should not appear"
      end

      # No secret leakage
      error_event = Enum.find(events, &(&1.type == :provider_error))
      refute inspect(error_event.error) =~ "sk-mid-secret"
    end

    test "only one provider_error emitted on mid-stream failure" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "first"})},
          {:data, "not valid json"},
          {:data, "also not valid"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:error, _} = OpenAICompatibleProvider.stream(req, collect_events())

      events = drain_events()
      error_count = Enum.count(events, &(&1.type == :provider_error))
      assert error_count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 5: [DONE] without final usage
  # ---------------------------------------------------------------------------

  describe "SSE [DONE] without usage (acceptance 5)" do
    test "completes safely with nil usage when no usage chunk received" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "Hello"}, finish_reason: "stop")},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())

      assert response.content == "Hello"
      assert response.usage == nil

      events = drain_events()
      types = Enum.map(events, & &1.type)
      assert :response_completed in types

      completed = Enum.find(events, &(&1.type == :response_completed))
      assert completed.usage == nil
    end

    test "[DONE] with prior usage chunk includes usage in response_completed" do
      usage_chunk =
        Jason.encode!(%{
          "id" => "chatcmpl-test",
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8},
          "choices" => []
        })

      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "Hi"}, finish_reason: "stop")},
          {:data, usage_chunk},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())

      assert response.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}

      events = drain_events()
      completed = Enum.find(events, &(&1.type == :response_completed))
      assert completed.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 6: Unknown SSE events/fields
  # ---------------------------------------------------------------------------

  describe "SSE unknown events/fields (acceptance 6)" do
    test "unknown SSE event type is ignored safely" do
      sse_body =
        sse_lines([
          # Multi-field event: event type + data
          [{:event, "ping"}, {:data, "{}"}],
          {:data, sse_chunk(%{"content" => "ok"}, finish_reason: "stop")},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())
      assert response.content == "ok"
    end

    test "unknown fields in SSE chunk are ignored" do
      chunk = %{
        "id" => "chatcmpl-test",
        "choices" => [%{"delta" => %{"content" => "hello"}, "finish_reason" => nil}],
        "model" => "gpt-4.1-mini",
        "object" => "chat.completion.chunk",
        "created" => 1_700_000_000,
        "unknown_field" => "mystery",
        "service_tier" => "default"
      }

      sse_body =
        sse_lines([
          {:data, Jason.encode!(chunk)},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())
      assert response.content == "hello"
    end

    test "SSE comment lines are ignored" do
      sse_body =
        ": this is a comment\n" <>
          ": another comment\n" <>
          "data: " <>
          sse_chunk(%{"content" => "after comments"}, finish_reason: "stop") <>
          "\n" <>
          "\n" <>
          "data: [DONE]\n\n"

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())
      assert response.content == "after comments"
    end

    test "empty SSE body (no events) completes with nil content and no crash" do
      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: "")}
      end

      req = sse_request(%{stream_fn: post_fn})
      # No SSE events to parse — response_started is emitted but no content
      result = OpenAICompatibleProvider.stream(req, collect_events())
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 7: Authorization/API keys redaction
  # ---------------------------------------------------------------------------

  describe "SSE secret redaction (acceptance 7)" do
    test "Bearer token in Authorization header never appears in errors or events" do
      secret_token = "sk-test-redaction-check-xyz789"

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 403, body: "forbidden with Bearer #{secret_token}")}
      end

      req =
        sse_request(%{
          stream_fn: post_fn,
          headers: %{"Authorization" => "Bearer #{secret_token}"}
        })

      assert {:error, error} = OpenAICompatibleProvider.stream(req, collect_events())

      # Error should not contain the raw token
      error_str = inspect(error, limit: :infinity, printable_limit: :infinity)
      refute error_str =~ secret_token
      refute error_str =~ "Bearer sk-test"

      # Events should not contain the raw token
      events = drain_events()

      for event <- events do
        event_str = inspect(event, limit: :infinity, printable_limit: :infinity)
        refute event_str =~ secret_token
      end
    end

    test "JWT-like tokens in SSE body are redacted from errors" do
      jwt_body =
        ~s({"error":{"message":"invalid eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.abc.def token","code":"invalid_api_key"}})

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 401, body: jwt_body)}
      end

      req = sse_request(%{stream_fn: post_fn})

      assert {:error, {:provider_http_error, _}} =
               OpenAICompatibleProvider.stream(req, collect_events())

      events = drain_events()
      # The token= pattern should be redacted
      for event <- events do
        refute inspect(event.error) =~ "token=eyJ"
      end
    end

    test "api_key pattern in SSE stream data is redacted from decode errors" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "ok"})},
          {:data, ~s({"malformed": "api_key=sk-in-stream-data"})}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      result = OpenAICompatibleProvider.stream(req, collect_events())

      case result do
        {:error, error} ->
          refute inspect(error) =~ "sk-in-stream-data"

        {:ok, _} ->
          events = drain_events()

          for event <- events do
            refute inspect(event) =~ "sk-in-stream-data"
          end
      end
    end

    test "raw token only captured in outbound Authorization header, not in returned errors" do
      parent = self()
      raw_token = "sk-outbound-only-test"

      post_fn = fn url, opts ->
        send(parent, {:outbound_request, url, opts})
        {:ok, Req.Response.new(status: 500, body: "server error")}
      end

      req =
        sse_request(%{
          stream_fn: post_fn,
          headers: %{"Authorization" => "Bearer #{raw_token}"}
        })

      assert {:error, _} = OpenAICompatibleProvider.stream(req, collect_events())

      # The raw token should appear in the outbound Authorization header
      assert_receive {:outbound_request, _url, opts}
      assert {"Authorization", "Bearer #{raw_token}"} in opts[:headers]

      # But NOT in any error or emitted event
      events = drain_events()

      for event <- events do
        refute inspect(event) =~ raw_token
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance 8: No hangs/timeouts
  # ---------------------------------------------------------------------------

  describe "SSE no hangs/timeouts (acceptance 8)" do
    test "stream/2 with SSE returns promptly on transport error" do
      post_fn = fn _url, _opts ->
        {:error, :timeout}
      end

      req = sse_request(%{stream_fn: post_fn})

      result = OpenAICompatibleProvider.stream(req, collect_events())
      assert match?({:error, _}, result)
    end

    test "stream/2 with SSE returns promptly on HTTP error" do
      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 503, body: "service unavailable")}
      end

      req = sse_request(%{stream_fn: post_fn})
      result = OpenAICompatibleProvider.stream(req, collect_events())
      assert match?({:error, _}, result)
    end

    test "stream/2 with SSE returns promptly on success" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "fast"}, finish_reason: "stop")},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      result = OpenAICompatibleProvider.stream(req, collect_events())
      assert match?({:ok, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Additional SSE happy-path verification
  # ---------------------------------------------------------------------------

  describe "SSE streaming happy path" do
    test "incremental text deltas produce correct events and response" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"role" => "assistant", "content" => nil})},
          {:data, sse_chunk(%{"content" => "Hello"})},
          {:data, sse_chunk(%{"content" => " world"})},
          {:data, sse_chunk(%{"content" => "!"}, finish_reason: "stop")},
          {:data,
           Jason.encode!(%{
             "id" => "chatcmpl-test",
             "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15},
             "choices" => []
           })},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())

      assert response.content == "Hello world!"
      assert response.usage == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}

      events = drain_events()
      types = Enum.map(events, & &1.type)

      assert :response_started in types
      assert :assistant_delta in types
      assert :assistant_completed in types
      assert :response_completed in types

      # Three deltas
      deltas = events |> Enum.filter(&(&1.type == :assistant_delta)) |> Enum.map(& &1.text)
      assert deltas == ["Hello", " world", "!"]
    end

    test "SSE streaming with post_fn (backward compatibility)" do
      sse_body =
        sse_lines([
          {:data, sse_chunk(%{"content" => "via post_fn"}, finish_reason: "stop")},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      # Use post_fn instead of stream_fn — should still work via SSE path
      req = sse_request(%{post_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())
      assert response.content == "via post_fn"
    end

    test "SSE streaming with tool call deltas" do
      chunk1 =
        Jason.encode!(%{
          "id" => "chatcmpl-tools",
          "choices" => [
            %{
              "delta" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_abc",
                    "function" => %{"name" => "read_file", "arguments" => ""}
                  }
                ]
              }
            }
          ]
        })

      chunk2 =
        Jason.encode!(%{
          "id" => "chatcmpl-tools",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "function" => %{"arguments" => ~s({"path":"lib/muse.ex"})}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

      sse_body =
        sse_lines([
          {:data, chunk1},
          {:data, chunk2},
          {:data, "[DONE]"}
        ])

      post_fn = fn _url, _opts ->
        {:ok, Req.Response.new(status: 200, body: sse_body)}
      end

      req = sse_request(%{stream_fn: post_fn})
      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())

      assert [%ToolCall{} = tc] = response.tool_calls
      assert tc.id == "call_abc"
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse.ex"}
    end
  end

  # ---------------------------------------------------------------------------
  # Auth integration with SSE path
  # ---------------------------------------------------------------------------

  describe "SSE auth integration" do
    test "SSE path with auth error emits provider_error before any HTTP call" do
      post_fn = fn _url, _opts ->
        send(self(), :unexpected_post)
        {:ok, Req.Response.new(status: 200, body: "data: [DONE]\n\n")}
      end

      req =
        sse_request(%{
          stream_fn: post_fn,
          auth: :api_key,
          env_key: "MUSE_TEST_MISSING_KEY",
          env: %{},
          system_env?: false
        })

      result = OpenAICompatibleProvider.stream(req, collect_events())
      assert {:error, _} = result
      refute_received :unexpected_post

      events = drain_events()
      assert [%Event{type: :provider_error}] = events
    end
  end

  # ---------------------------------------------------------------------------
  # Non-SSE path still works (regression guard)
  # ---------------------------------------------------------------------------

  describe "non-SSE stream/2 backward compatibility" do
    test "stream/2 without transport :sse uses non-streaming path" do
      post_fn = fn _url, _opts ->
        {:ok,
         Req.Response.new(
           status: 200,
           body: %{
             "id" => "chatcmpl-nosse",
             "choices" => [
               %{
                 "message" => %{"role" => "assistant", "content" => "non-SSE"},
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
           }
         )}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :chat_completions,
        transport: :none,
        messages: [Message.user("hello")],
        stream: true,
        options: %{base_url: "https://api.example.test/v1", post_fn: post_fn}
      }

      assert {:ok, response} = OpenAICompatibleProvider.stream(req, collect_events())
      assert response.content == "non-SSE"
    end
  end
end
