defmodule Muse.LLM.OpenAICompatibleProviderSSETest do
  @moduledoc """
  Tests for the SSE streaming path of OpenAICompatibleProvider.stream/2.

  All tests use injected `sse_post_fn` — no real network calls.
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request, Response}
  alias Muse.LLM.OpenAICompatibleProvider

  # ---------------------------------------------------------------------------
  # SSE text streaming — happy path
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE text response" do
    test "emits canonical events incrementally for a text SSE stream" do
      sse_post_fn = sse_post_fn_for(text_sse_chunks())

      req = sse_request(%{sse_post_fn: sse_post_fn})

      events = collect_stream_events(req)

      assert event_types(events) == [
               :response_started,
               :assistant_delta,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]

      deltas = events |> Enum.filter(&(&1.type == :assistant_delta)) |> Enum.map(& &1.text)
      assert deltas == ["Hello", " world"]

      completed = Enum.find(events, &(&1.type == :assistant_completed))
      assert completed.text == "Hello world"

      completed_event = Enum.find(events, &(&1.type == :response_completed))
      assert completed_event.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
    end

    test "returns assembled Response with full content and usage" do
      sse_post_fn = sse_post_fn_for(text_sse_chunks())
      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)

      assert %Response{} = response
      assert response.content == "Hello world"
      assert response.text == "Hello world"
      assert response.finish_reason == "stop"
      assert response.usage == %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
      assert response.tool_calls == []
    end

    test "builds spec with stream: true in payload" do
      parent = self()

      sse_post_fn = fn url, req_options, on_chunk ->
        send(parent, {:sse_post_called, url, req_options})

        text_sse_chunks()
        |> Enum.each(&on_chunk.(&1))

        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_post_called, _url, req_options}
      assert req_options[:json]["stream"] == true
      assert req_options[:json]["model"] == "gpt-4.1-mini"
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call streaming
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE tool calls" do
    test "emits tool_call_started, tool_call_delta, and tool_call_completed" do
      sse_post_fn = sse_post_fn_for(tool_call_sse_chunks())

      req = sse_request(%{sse_post_fn: sse_post_fn})

      events = collect_stream_events(req)

      types = event_types(events)

      assert :tool_call_started in types
      assert :tool_call_delta in types
      assert :tool_call_completed in types

      started = Enum.find(events, &(&1.type == :tool_call_started))
      assert started.tool_call.name == "read_file"
    end

    test "returns Response with tool_calls" do
      sse_post_fn = sse_post_fn_for(tool_call_sse_chunks())
      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, response} = stream_with_collector(req)

      assert response.tool_calls != []
      assert length(response.tool_calls) == 1
      assert hd(response.tool_calls).name == "read_file"
      assert hd(response.tool_calls).arguments["path"] == "lib/muse.ex"
    end
  end

  # ---------------------------------------------------------------------------
  # SSE transport detection
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE transport detection" do
    test "uses SSE path when request.transport == :sse" do
      parent = self()

      sse_post_fn = fn _url, _opts, on_chunk ->
        send(parent, :sse_path_called)
        text_sse_chunks() |> Enum.each(&on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4",
        transport: :sse,
        wire_api: :chat_completions,
        messages: [Message.user("hello")],
        stream: true,
        options: %{base_url: "https://api.example.test/v1", sse_post_fn: sse_post_fn}
      }

      assert {:ok, _response} = stream_with_collector(req)
      assert_receive :sse_path_called
    end

    test "uses non-streaming path when request.transport != :sse" do
      parent = self()

      post_fn = fn _url, _opts ->
        send(parent, :non_streaming_path_called)

        {:ok,
         %{
           status: 200,
           body: %{
             "choices" => [
               %{
                 "message" => %{"content" => "hi", "role" => "assistant"},
                 "finish_reason" => "stop"
               }
             ]
           }
         }}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4",
        transport: :none,
        wire_api: :chat_completions,
        messages: [Message.user("hello")],
        stream: false,
        options: %{base_url: "https://api.example.test/v1", post_fn: post_fn}
      }

      assert {:ok, _response} = stream_with_collector(req)
      assert_receive :non_streaming_path_called
    end
  end

  # ---------------------------------------------------------------------------
  # sse_post_fn injection
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE post function injection" do
    test "invalid sse_post_fn arity returns clear error" do
      req = sse_request(%{sse_post_fn: fn _a, _b -> {:ok, %{status: 200}} end})

      result = stream_with_collector(req)
      assert {:error, reason} = result
      rendered = inspect(reason)
      assert rendered =~ "invalid_sse_post_fn" or rendered =~ "three-arity"
    end

    test "sse_post_fn receives url, req_options, and on_chunk callback" do
      parent = self()

      sse_post_fn = fn url, req_options, on_chunk ->
        send(parent, {:sse_fn_args, url, is_list(req_options), is_function(on_chunk, 1)})

        text_sse_chunks() |> Enum.each(&on_chunk.(&1))

        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_fn_args, url, req_options_is_list, on_chunk_is_fn1}
      assert url == "https://api.example.test/v1/chat/completions"
      assert req_options_is_list == true
      assert on_chunk_is_fn1 == true
    end
  end

  # ---------------------------------------------------------------------------
  # No raw tokens in events/errors
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE no raw token leakage" do
    test "provider_error events never contain raw Authorization value" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, {:connection_failed, "header had Bearer sk-leak-check"}}
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
        refute rendered =~ "sk-leak-check"
      end)
    end

    test "non-2xx response error never contains raw auth from headers" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 403}}
      end

      req =
        sse_request(%{
          sse_post_fn: sse_post_fn,
          headers: [{"Authorization", "Bearer sk-403-secret"}]
        })

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      refute rendered =~ "sk-403-secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Auth integration (PR13 wired into SSE path)
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE auth integration" do
    test "resolves auth and attaches Authorization header" do
      parent = self()

      sse_post_fn = fn _url, req_options, on_chunk ->
        send(parent, {:sse_auth_headers, req_options[:headers]})
        text_sse_chunks() |> Enum.each(&on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req =
        %Request{
          provider: :openai_compatible,
          model: "gpt-4",
          transport: :sse,
          wire_api: :chat_completions,
          messages: [Message.user("hello")],
          stream: true,
          options: %{
            base_url: "https://api.example.test/v1",
            sse_post_fn: sse_post_fn,
            auth: :api_key,
            env_map: %{"MUSE_OPENAI_API_KEY" => "sk-test-key"}
          }
        }

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_auth_headers, headers}
      assert headers != nil
      auth_header = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
      assert auth_header != nil
      assert elem(auth_header, 1) =~ "Bearer "
      refute elem(auth_header, 1) =~ "sk-leak"
    end

    test "explicit Authorization header wins over resolved auth" do
      parent = self()

      sse_post_fn = fn _url, req_options, on_chunk ->
        send(parent, {:sse_explicit_auth, req_options[:headers]})
        text_sse_chunks() |> Enum.each(&on_chunk.(&1))
        {:ok, %{status: 200}}
      end

      req =
        %Request{
          provider: :openai_compatible,
          model: "gpt-4",
          transport: :sse,
          wire_api: :chat_completions,
          messages: [Message.user("hello")],
          stream: true,
          options: %{
            base_url: "https://api.example.test/v1",
            sse_post_fn: sse_post_fn,
            headers: [{"Authorization", "Bearer explicit-token"}],
            auth: :api_key,
            env_map: %{"MUSE_OPENAI_API_KEY" => "sk-should-not-appear"}
          }
        }

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:sse_explicit_auth, headers}
      auth_header = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
      assert auth_header != nil
      assert elem(auth_header, 1) == "Bearer explicit-token"
      refute elem(auth_header, 1) =~ "sk-should-not-appear"
    end
  end

  # ---------------------------------------------------------------------------
  # Error scenarios
  # ---------------------------------------------------------------------------

  describe "stream/2 SSE errors and redaction" do
    test "non-2xx HTTP response returns provider_http_error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:ok, %{status: 401}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, reason} = stream_with_collector(req)
      # The error is redacted; verify it indicates an HTTP error
      rendered = inspect(reason)
      assert rendered =~ "provider_http_error" or rendered =~ "401"

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "transport errors emit provider_error and return error" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        {:error, :econnrefused}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "rescue/exception in sse_post_fn is caught" do
      sse_post_fn = fn _url, _req_options, _on_chunk ->
        raise "unexpected crash"
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "malformed SSE JSON emits provider_error and returns error" do
      sse_post_fn = fn _url, _req_options, on_chunk ->
        on_chunk.("data: {{invalid json}}\n\n")
        on_chunk.("data: [DONE]\n\n")
        {:ok, %{status: 200}}
      end

      req = sse_request(%{sse_post_fn: sse_post_fn})

      # Per PR14 acceptance: malformed JSON emits provider_error and returns error
      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      provider_errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(provider_errors) >= 1
      # No assistant_completed or response_completed after failure
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
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
      text_delta_chunk(%{"role" => "assistant", "content" => "Hello"}),
      text_delta_chunk(%{"content" => " world"}),
      "data: #{Jason.encode!(%{"id" => "chatcmpl-test", "model" => "gpt-4.1-mini", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}})}\n\n",
      "data: [DONE]\n\n"
    ]
  end

  defp text_delta_chunk(delta) do
    body = %{
      "id" => "chatcmpl-test",
      "model" => "gpt-4.1-mini",
      "choices" => [%{"index" => 0, "delta" => delta}]
    }

    "data: #{Jason.encode!(body)}\n\n"
  end

  defp tool_call_sse_chunks do
    [
      tool_init_chunk(),
      tool_args_chunk(~s({"path":)),
      tool_args_chunk(~s("lib/muse.ex"})),
      "data: #{Jason.encode!(%{"id" => "chatcmpl-tools", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}], "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 9, "total_tokens" => 20}})}\n\n",
      "data: [DONE]\n\n"
    ]
  end

  defp tool_init_chunk do
    body = %{
      "id" => "chatcmpl-tools",
      "model" => "gpt-4.1-mini",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call_read",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => ""}
              }
            ]
          }
        }
      ]
    }

    "data: #{Jason.encode!(body)}\n\n"
  end

  defp tool_args_chunk(args) do
    body = %{
      "id" => "chatcmpl-tools",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "function" => %{"arguments" => args}
              }
            ]
          }
        }
      ]
    }

    "data: #{Jason.encode!(body)}\n\n"
  end

  defp sse_post_fn_for(chunks) do
    fn _url, _req_options, on_chunk ->
      Enum.each(chunks, &on_chunk.(&1))
      {:ok, %{status: 200}}
    end
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
      send(test_pid, {:stream_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(req, emit_fn)

    events = drain_stream_events(ref)
    {result, events}
  end

  defp drain_stream_events(ref, acc \\ []) do
    receive do
      {:stream_event, ^ref, event} -> drain_stream_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp event_types(events), do: Enum.map(events, & &1.type)
end
