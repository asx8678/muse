defmodule Muse.LLM.OpenAICompatibleProviderResponsesWSErrorTest do
  @moduledoc """
  Security-focused error/redaction tests for Responses WebSocket streaming.
  """

  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAICompatibleProvider
  alias Muse.LLM.{Message, Request}

  @secret "sk-test-pr15-secret"
  @bearer "Bearer sk-test-pr15-secret"

  describe "stream/2 Responses WebSocket ws_stream_fn failures" do
    test "ws_stream_fn exceptions are caught and redacted" do
      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        raise "boom #{@bearer} token=leak"
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:error, reason, events} = stream_with_events(request)
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "ws_stream_fn throws are caught and redacted" do
      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        throw({:bad_ws, "#{@bearer} token=leak"})
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:error, reason, events} = stream_with_events(request)
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "ws_stream_fn error tuples are redacted" do
      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        {:error, {:closed, "#{@bearer} token=leak"}}
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:error, reason, events} = stream_with_events(request)
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "invalid ws_stream_fn arity returns a safe error before any transport call" do
      request =
        ws_request(%{
          ws_stream_fn: fn _one, _two -> {:ok, :wrong_arity} end,
          headers: [{"Authorization", @bearer}]
        })

      assert {:error, reason, events} = stream_with_events(request)
      rendered = inspect(reason)
      assert rendered =~ "invalid_ws_stream_fn" or rendered =~ "three-arity"
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "invalid ws_stream_fn return shape does not echo returned terms" do
      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        {:unexpected, "#{@bearer} token=leak"}
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:error, reason, events} = stream_with_events(request)
      rendered = inspect(reason)
      assert rendered =~ "invalid_ws_stream_result"
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end
  end

  describe "stream/2 Responses WebSocket provider frame redaction" do
    test "malformed JSON provider frames are redacted in provider_error and returned reason" do
      ws_stream_fn = fn _websocket_url, _ws_options, on_frame ->
        on_frame.(~s({"type":"response.output_text.delta","delta":"bad #{@bearer} token=leak"))
        {:ok, :closed}
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:error, reason, events} = stream_with_events(request)
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "provider error frames redact fake secrets" do
      ws_stream_fn = fn _websocket_url, _ws_options, on_frame ->
        on_frame.(%{
          "type" => "response.error",
          "error" => %{"message" => "provider saw #{@bearer} token=leak"}
        })

        {:ok, :closed}
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:error, reason, events} = stream_with_events(request)
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "unknown provider event strings are ignored safely and never become debug events" do
      unknown_type = "provider.unknown.pr15.#{System.unique_integer([:positive])}"

      ws_stream_fn = fn _websocket_url, _ws_options, on_frame ->
        on_frame.(%{"type" => unknown_type, "message" => "ignored #{@bearer} token=leak"})
        on_frame.(%{"type" => "response.output_text.delta", "delta" => "safe text"})
        on_frame.(%{"type" => "response.completed", "response" => %{"id" => "resp_ws_unknown"}})
        {:ok, :closed}
      end

      request = ws_request(%{ws_stream_fn: ws_stream_fn, headers: [{"Authorization", @bearer}]})

      assert {:ok, response, events} = stream_with_events(request)
      assert response.content == "safe text"
      refute Enum.any?(events, &(&1.type == :debug))
      assert_redacted(response)
      assert_redacted(events)
    end
  end

  describe "Responses WebSocket URL safety" do
    test "websocket_url userinfo credentials are rejected and redacted" do
      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        send(self(), :unexpected_ws_call)
        {:ok, :closed}
      end

      request =
        ws_request(%{
          websocket_url: "wss://user:#{@secret}@api.example.test/v1/responses",
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", @bearer}]
        })

      assert {:error, reason, events} = stream_with_events(request)
      rendered = inspect(reason)
      assert rendered =~ "userinfo"
      refute_received :unexpected_ws_call
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "base_url userinfo credentials are rejected and redacted" do
      request =
        ws_request(%{
          base_url: "https://user:#{@secret}@api.example.test/v1",
          ws_stream_fn: fn _websocket_url, _ws_options, _on_frame -> {:ok, :closed} end,
          headers: [{"Authorization", @bearer}]
        })

      assert {:error, reason, events} = stream_with_events(request)
      assert inspect(reason) =~ "userinfo"
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "malformed websocket_url authority credentials are rejected and redacted" do
      parent = self()

      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        send(parent, :unexpected_ws_call)
        {:ok, :closed}
      end

      request =
        ws_request(%{
          websocket_url: "wss://api.example.test:#{@secret}/v1/responses",
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", @bearer}]
        })

      assert {:error, reason, events} = stream_with_events(request)
      refute_received :unexpected_ws_call
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "malformed base_url authority credentials are rejected and redacted" do
      parent = self()

      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        send(parent, :unexpected_ws_call)
        {:ok, :closed}
      end

      request =
        ws_request(%{
          base_url: "https://api.example.test:#{@secret}/v1",
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", @bearer}]
        })

      assert {:error, reason, events} = stream_with_events(request)
      refute_received :unexpected_ws_call
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end

    test "control-character websocket_url credentials are rejected and redacted" do
      parent = self()

      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        send(parent, :unexpected_ws_call)
        {:ok, :closed}
      end

      request =
        ws_request(%{
          websocket_url: "wss://api.example.test\r\nAuthorization: #{@bearer}/v1/responses",
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", @bearer}]
        })

      assert {:error, reason, events} = stream_with_events(request)
      refute_received :unexpected_ws_call
      assert_provider_error(events)
      assert_redacted(reason)
      assert_redacted(events)
    end
  end

  defp ws_request(extra_options) do
    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :responses,
      transport: :websocket,
      messages: [Message.user("hello")],
      stream: true,
      options: Map.merge(%{base_url: "https://api.example.test/v1"}, extra_options)
    }
  end

  defp stream_with_events(request) do
    test_pid = self()
    ref = make_ref()

    emit_fn = fn event ->
      send(test_pid, {:responses_ws_error_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(request, emit_fn)
    events = drain_events(ref)

    case result do
      {:ok, response} -> {:ok, response, events}
      {:error, reason} -> {:error, reason, events}
    end
  end

  defp drain_events(ref, acc \\ []) do
    receive do
      {:responses_ws_error_event, ^ref, event} -> drain_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp assert_provider_error(events) do
    assert Enum.any?(events, &(&1.type == :provider_error))
  end

  defp assert_redacted(term) do
    rendered = inspect(term)
    refute rendered =~ @secret
    refute rendered =~ @bearer
    refute rendered =~ "token=leak"
  end
end
