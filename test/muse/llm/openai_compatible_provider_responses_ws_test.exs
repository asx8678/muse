defmodule Muse.LLM.OpenAICompatibleProviderResponsesWSTest do
  @moduledoc """
  Tests for the Responses WebSocket streaming path of OpenAICompatibleProvider.stream/2.

  All tests use injected `ws_stream_fn` — no real network calls.

  Covers:
    - Success text stream via injected ws_stream_fn
    - response.completed carries previous_response_id in provider_state
    - Request previous_response_id appears in outgoing create frame
    - Explicit Authorization header wins; API key auth attaches outbound header only
    - Malformed JSON and transport errors are redacted; no completion events
    - Tool call streaming via Responses WS
    - Binary and decoded-map frame inputs both work
    - response.failed emits provider_error; no completion events after
    - Missing response.completed emits provider_error; no completion events
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request, Response}
  alias Muse.LLM.OpenAICompatibleProvider

  # ---------------------------------------------------------------------------
  # Text streaming — happy path
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS text response" do
    test "emits canonical events incrementally for a text WS stream" do
      ws_stream_fn = ws_stream_fn_for(text_ws_frames())
      req = ws_request(%{ws_stream_fn: ws_stream_fn})

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
      assert completed_event.usage == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    end

    test "returns assembled Response with full content, usage, and previous_response_id" do
      ws_stream_fn = ws_stream_fn_for(text_ws_frames())
      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, response} = stream_with_collector(req)

      assert %Response{} = response
      assert response.content == "Hello world"
      assert response.text == "Hello world"
      assert response.usage == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      assert response.tool_calls == []
      assert response.provider_state == %{previous_response_id: "resp_test_123"}
    end

    test "uses wss:// scheme for https base_url" do
      parent = self()

      ws_stream_fn = fn url, _ws_options, on_frame ->
        send(parent, {:ws_url, url})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_url, url}
      assert url == "wss://api.example.test/v1/responses"
    end

    test "uses ws:// scheme for http base_url" do
      parent = self()

      ws_stream_fn = fn url, _ws_options, on_frame ->
        send(parent, {:ws_url, url})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn, base_url: "http://localhost:8080/v1"})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_url, url}
      assert url == "ws://localhost:8080/v1/responses"
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call streaming
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS tool calls" do
    test "emits tool_call_started, tool_call_delta, and tool_call_completed" do
      ws_stream_fn = ws_stream_fn_for(tool_call_ws_frames())
      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      events = collect_stream_events(req)

      types = event_types(events)

      assert :tool_call_started in types
      assert :tool_call_delta in types
      assert :tool_call_completed in types

      started = Enum.find(events, &(&1.type == :tool_call_started))
      assert started.tool_call.name == "read_file"
    end

    test "returns Response with tool_calls and decoded arguments" do
      ws_stream_fn = ws_stream_fn_for(tool_call_ws_frames())
      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, response} = stream_with_collector(req)

      assert response.tool_calls != []
      assert length(response.tool_calls) == 1
      assert hd(response.tool_calls).name == "read_file"
      assert hd(response.tool_calls).arguments == %{"path" => "lib/muse.ex"}
    end
  end

  # ---------------------------------------------------------------------------
  # WS transport detection
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS transport detection" do
    test "uses WS path when wire_api is :responses and transport is :websocket" do
      parent = self()

      ws_stream_fn = fn _url, _ws_options, on_frame ->
        send(parent, :ws_path_called)
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: true,
        options: %{base_url: "https://api.example.test/v1", ws_stream_fn: ws_stream_fn}
      }

      assert {:ok, _response} = stream_with_collector(req)
      assert_receive :ws_path_called
    end

    test "uses WS path when transport is set via request.options" do
      parent = self()

      ws_stream_fn = fn _url, _ws_options, on_frame ->
        send(parent, :ws_options_path_called)
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: nil,
        messages: [Message.user("hello")],
        stream: true,
        options: %{
          base_url: "https://api.example.test/v1",
          ws_stream_fn: ws_stream_fn,
          transport: :websocket
        }
      }

      assert {:ok, _response} = stream_with_collector(req)
      assert_receive :ws_options_path_called
    end

    test "uses WS path when transport is set via string key in options" do
      parent = self()

      ws_stream_fn = fn _url, _ws_options, on_frame ->
        send(parent, :ws_string_key_path_called)
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: nil,
        messages: [Message.user("hello")],
        stream: true,
        options: %{
          "base_url" => "https://api.example.test/v1",
          "ws_stream_fn" => ws_stream_fn,
          "transport" => :websocket
        }
      }

      assert {:ok, _response} = stream_with_collector(req)
      assert_receive :ws_string_key_path_called
    end

    test "does not use WS path when wire_api is not :responses" do
      parent = self()

      post_fn = fn _url, _options ->
        send(parent, :non_ws_path_called)
        {:ok, %{status: 200, body: non_ws_body()}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :chat_completions,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: false,
        options: %{base_url: "https://api.example.test/v1", post_fn: post_fn}
      }

      assert {:ok, _response} = stream_with_collector(req)
      assert_receive :non_ws_path_called
    end
  end

  # ---------------------------------------------------------------------------
  # ws_stream_fn injection
  # ---------------------------------------------------------------------------

  describe "stream/2 WS stream function injection" do
    test "ws_stream_fn receives url, ws_options, and on_frame callback" do
      parent = self()

      ws_stream_fn = fn url, ws_options, on_frame ->
        send(parent, {:ws_fn_args, url, ws_options, is_function(on_frame, 1)})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_fn_args, url, ws_options, on_frame_is_fn1}
      assert url == "wss://api.example.test/v1/responses"
      assert is_map(ws_options)
      assert ws_options.headers != nil
      assert is_map(ws_options.create_frame)
      assert on_frame_is_fn1 == true
    end

    test "ws_options contains headers and create_frame" do
      parent = self()

      ws_stream_fn = fn _url, ws_options, on_frame ->
        send(parent, {:ws_options_received, ws_options})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_options_received, ws_options}
      assert is_list(ws_options.headers)
      assert is_map(ws_options.create_frame)
      assert ws_options.create_frame["type"] == "response.create"
      assert is_map(ws_options.create_frame["response"])
    end

    test "ws_options includes timeout/retry options when provided" do
      parent = self()

      ws_stream_fn = fn _url, ws_options, on_frame ->
        send(parent, {:ws_timeout_opts, ws_options})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn, timeout_ms: 5000, max_retries: 2})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_timeout_opts, ws_options}
      assert ws_options.timeout_ms == 5000
      assert ws_options.max_retries == 2
    end

    test "missing ws_stream_fn returns clear error" do
      req = ws_request(%{})

      result = stream_with_collector(req)
      assert {:error, reason} = result
      rendered = inspect(reason)
      assert rendered =~ "ws_stream_fn_required" or rendered =~ "ws_stream_fn"
    end

    test "invalid ws_stream_fn arity returns clear error" do
      req = ws_request(%{ws_stream_fn: fn _a, _b -> {:ok, %{}} end})

      result = stream_with_collector(req)
      assert {:error, reason} = result
      rendered = inspect(reason)
      assert rendered =~ "invalid_ws_stream_fn" or rendered =~ "three-arity"
    end
  end

  # ---------------------------------------------------------------------------
  # previous_response_id
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS previous_response_id" do
    test "response.completed carries previous_response_id in provider_state" do
      ws_stream_fn = ws_stream_fn_for(text_ws_frames())
      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, response} = stream_with_collector(req)
      assert response.provider_state == %{previous_response_id: "resp_test_123"}
    end

    test "request previous_response_id appears in outgoing create frame" do
      parent = self()

      ws_stream_fn = fn _url, ws_options, on_frame ->
        send(parent, {:ws_create_frame, ws_options.create_frame})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: true,
        previous_response_id: "resp_prev_999",
        options: %{base_url: "https://api.example.test/v1", ws_stream_fn: ws_stream_fn}
      }

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_create_frame, create_frame}
      assert create_frame["type"] == "response.create"
      assert create_frame["response"]["previous_response_id"] == "resp_prev_999"
    end

    test "previous_response_id is absent from create frame when not supplied" do
      parent = self()

      ws_stream_fn = fn _url, ws_options, on_frame ->
        send(parent, {:ws_create_frame_no_prev, ws_options.create_frame})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_create_frame_no_prev, create_frame}
      refute Map.has_key?(create_frame["response"], "previous_response_id")
    end
  end

  # ---------------------------------------------------------------------------
  # Auth integration
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS auth integration" do
    test "resolves auth and attaches Authorization header to WS handshake" do
      parent = self()

      ws_stream_fn = fn _url, ws_options, on_frame ->
        send(parent, {:ws_auth_headers, ws_options.headers})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: true,
        options: %{
          base_url: "https://api.example.test/v1",
          ws_stream_fn: ws_stream_fn,
          auth: :api_key,
          env_map: %{"MUSE_OPENAI_API_KEY" => "sk-ws-test-key"}
        }
      }

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_auth_headers, headers}
      assert headers != nil
      auth_header = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
      assert auth_header != nil
      assert elem(auth_header, 1) =~ "Bearer "
    end

    test "explicit Authorization header wins over resolved auth" do
      parent = self()

      ws_stream_fn = fn _url, ws_options, on_frame ->
        send(parent, {:ws_explicit_auth, ws_options.headers})
        text_ws_frames() |> Enum.each(&on_frame.(&1))
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: true,
        options: %{
          base_url: "https://api.example.test/v1",
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", "Bearer explicit-ws-token"}],
          auth: :api_key,
          env_map: %{"MUSE_OPENAI_API_KEY" => "sk-should-not-appear-ws"}
        }
      }

      assert {:ok, _response} = stream_with_collector(req)

      assert_receive {:ws_explicit_auth, headers}
      auth_header = Enum.find(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
      assert auth_header != nil
      assert elem(auth_header, 1) == "Bearer explicit-ws-token"
      refute elem(auth_header, 1) =~ "sk-should-not-appear-ws"
    end

    test "API key auth attaches only to outbound header; not in provider_state" do
      ws_stream_fn = ws_stream_fn_for(text_ws_frames())

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: true,
        options: %{
          base_url: "https://api.example.test/v1",
          ws_stream_fn: ws_stream_fn,
          auth: :api_key,
          env_map: %{"MUSE_OPENAI_API_KEY" => "sk-outbound-only"}
        }
      }

      assert {:ok, response} = stream_with_collector(req)
      # provider_state contains only previous_response_id; no API key leakage
      refute inspect(response.provider_state) =~ "sk-outbound-only"
    end
  end

  # ---------------------------------------------------------------------------
  # Binary frame input
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS binary frames" do
    test "accepts binary JSON frames (not just decoded maps)" do
      frames_as_binaries =
        text_ws_frames()
        |> Enum.map(&Jason.encode!/1)

      ws_stream_fn = fn _url, _ws_options, on_frame ->
        Enum.each(frames_as_binaries, &on_frame.(&1))
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      events = collect_stream_events(req)

      assert event_types(events) == [
               :response_started,
               :assistant_delta,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]

      assert {:ok, response} = stream_with_collector(ws_request(%{ws_stream_fn: ws_stream_fn}))
      assert response.content == "Hello world"
    end
  end

  # ---------------------------------------------------------------------------
  # Error scenarios
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS errors and redaction" do
    test "malformed JSON frame emits provider_error and returns error" do
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        on_frame.("this is not valid json{{{")
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      provider_errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(provider_errors) >= 1
      # No completion events after failure
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end

    test "transport error emits provider_error and returns error" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        {:error, :econnrefused}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
      # No completion events after failure
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end

    test "exception in ws_stream_fn is caught and emits provider_error" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        raise "unexpected WS crash"
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end

    test "throw in ws_stream_fn is caught" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        throw(:intentional_ws_throw)
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "response.failed emits provider_error; no completion events" do
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        on_frame.(%{
          "type" => "response.failed",
          "response" => %{"id" => "resp_fail_001", "status" => "failed"}
        })

        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      assert Enum.any?(events, &(&1.type == :provider_error))
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end

    test "missing response.completed emits provider_error; no completion events" do
      # Stream with valid deltas but no response.completed
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        on_frame.(%{
          "type" => "response.output_text.delta",
          "delta" => "partial text"
        })

        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)
      # We should see assistant_delta but NOT completion events
      assert Enum.any?(events, &(&1.type == :assistant_delta))
      assert Enum.any?(events, &(&1.type == :provider_error))
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end

    test "exactly one provider_error on malformed JSON (not multiple)" do
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        on_frame.("bad json 1{{{")
        on_frame.("bad json 2{{{")
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      events = collect_stream_events(req)
      provider_errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(provider_errors) == 1
    end

    test "exactly one provider_error on transport error (not multiple)" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        {:error, :timeout}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      events = collect_stream_events(req)
      provider_errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(provider_errors) == 1
    end

    test "provider_error events never contain raw Authorization value" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        {:error, {:connection_failed, "header had Bearer sk-ws-leak-check"}}
      end

      req =
        ws_request(%{
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", "Bearer sk-ws-secret-value"}]
        })

      events = collect_stream_events(req)

      Enum.each(events, fn event ->
        rendered = inspect(event)
        refute rendered =~ "sk-ws-secret-value"
        refute rendered =~ "sk-ws-leak-check"
      end)
    end

    test "error return never contains raw auth from headers" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        {:error, :econnrefused}
      end

      req =
        ws_request(%{
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", "Bearer sk-ws-err-secret"}]
        })

      assert {:error, reason} = stream_with_collector(req)
      rendered = inspect(reason)
      refute rendered =~ "sk-ws-err-secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Mid-stream failure
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS mid-stream failure" do
    test "valid deltas emitted before failure; no completed events after" do
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        # First: valid text delta
        on_frame.(%{
          "type" => "response.output_text.delta",
          "delta" => "Hello"
        })

        # Then: malformed JSON triggers failure
        on_frame.("not valid json{{{")
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

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

    test "valid deltas then response.failed; no completion events" do
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        on_frame.(%{"type" => "response.output_text.delta", "delta" => "Starting text"})
        on_frame.(%{"type" => "response.failed", "response" => %{"status" => "failed"}})
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:error, _reason} = stream_with_collector(req)

      events = collect_stream_events(req)

      deltas = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(deltas) == 1

      assert Enum.any?(events, &(&1.type == :provider_error))
      refute Enum.any?(events, &(&1.type == :assistant_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown WS events
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS unknown events" do
    test "unknown event types are ignored without crashing" do
      ws_stream_fn = fn _url, _ws_options, on_frame ->
        on_frame.(%{"type" => "response.created", "response" => %{"id" => "resp_ign_001"}})
        on_frame.(%{"type" => "some_unknown_event", "data" => "whatever"})
        on_frame.(%{"type" => "response.output_text.delta", "delta" => "ok"})
        on_frame.(%{"type" => "response.completed", "response" => %{"id" => "resp_ign_001"}})
        {:ok, %{}}
      end

      req = ws_request(%{ws_stream_fn: ws_stream_fn})

      assert {:ok, response} = stream_with_collector(req)
      assert response.content == "ok"
    end
  end

  # ---------------------------------------------------------------------------
  # Missing base_url
  # ---------------------------------------------------------------------------

  describe "stream/2 Responses WS missing base_url" do
    test "missing base_url returns error without calling ws_stream_fn" do
      called? = Agent.start_link(fn -> false end)

      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        Agent.update(elem(called?, 1), fn _ -> true end)
        {:ok, %{}}
      end

      req = %Request{
        provider: :openai_compatible,
        model: "gpt-4.1-mini",
        wire_api: :responses,
        transport: :websocket,
        messages: [Message.user("hello")],
        stream: true,
        options: %{ws_stream_fn: ws_stream_fn}
      }

      result = stream_with_collector(req)
      assert {:error, _reason} = result
      # The ws_stream_fn should NOT have been called since base_url was missing
      refute Agent.get(elem(called?, 1), & &1)
      Agent.stop(elem(called?, 1))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws_request(extra_options) do
    base = %{base_url: "https://api.example.test/v1"}

    merged = Map.merge(base, extra_options)

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :responses,
      transport: :websocket,
      messages: [Message.user("hello")],
      stream: true,
      options: merged
    }
  end

  defp text_ws_frames do
    [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_test_123", "status" => "in_progress"}
      },
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "message", "role" => "assistant"}
      },
      %{
        "type" => "response.content_part.added",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "text"}
      },
      %{
        "type" => "response.output_text.delta",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "Hello"
      },
      %{
        "type" => "response.output_text.delta",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => " world"
      },
      %{
        "type" => "response.output_text.done",
        "output_index" => 0,
        "content_index" => 0,
        "text" => "Hello world"
      },
      %{
        "type" => "response.content_part.done",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "text", "text" => "Hello world"}
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{"type" => "message", "role" => "assistant", "status" => "completed"}
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_test_123",
          "status" => "completed",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
        }
      }
    ]
  end

  defp tool_call_ws_frames do
    [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_tc_001", "status" => "in_progress"}
      },
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_001",
          "call_id" => "call_001",
          "name" => "read_file"
        }
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_001",
        "delta" => "{\"path\":"
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_001",
        "delta" => "\"lib/muse.ex\"}"
      },
      %{
        "type" => "response.function_call_arguments.done",
        "item_id" => "fc_001",
        "arguments" => "{\"path\":\"lib/muse.ex\"}"
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_001",
          "call_id" => "call_001",
          "name" => "read_file",
          "arguments" => "{\"path\":\"lib/muse.ex\"}"
        }
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_tc_001",
          "status" => "completed",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}
        }
      }
    ]
  end

  defp non_ws_body do
    %{
      "id" => "chatcmpl_nonws",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => "hi"},
          "finish_reason" => "stop"
        }
      ]
    }
  end

  defp ws_stream_fn_for(frames) do
    fn _url, _ws_options, on_frame ->
      Enum.each(frames, &on_frame.(&1))
      {:ok, %{}}
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
      send(test_pid, {:ws_stream_event, ref, event})
      :ok
    end

    result = OpenAICompatibleProvider.stream(req, emit_fn)
    events = drain_stream_events(ref)
    {result, events}
  end

  defp drain_stream_events(ref, acc \\ []) do
    receive do
      {:ws_stream_event, ^ref, event} -> drain_stream_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp event_types(events), do: Enum.map(events, & &1.type)
end
