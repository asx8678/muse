defmodule Muse.LLM.OpenAICompatibleProviderResponsesWSAuthTest do
  @moduledoc """
  Security-focused auth tests for the draft Responses WebSocket provider path.
  """

  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAICompatibleProvider
  alias Muse.LLM.{Message, Request}

  @secret "sk-test-pr15-secret"

  describe "stream/2 Responses WebSocket auth" do
    test "resolves auth and attaches Authorization only to the outbound handshake options" do
      parent = self()

      ws_stream_fn = fn websocket_url, ws_options, on_frame ->
        send(parent, {:ws_handshake, websocket_url, ws_options})
        emit_success_frames(on_frame, "resp_ws_auth")
        {:ok, :closed}
      end

      request =
        ws_request(%{
          ws_stream_fn: ws_stream_fn,
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          auth_env: %{"MUSE_TEST_API_KEY" => @secret},
          system_env?: false
        })

      assert {:ok, response, events} = stream_with_events(request)

      assert_receive {:ws_handshake, "wss://api.example.test/v1/responses", ws_options}
      assert authorization_headers(ws_options[:headers]) == ["Bearer " <> @secret]
      assert ws_options[:frame]["type"] == "response.create"

      assert response.content == "Hello over WS"
      assert response.raw == nil
      assert response.provider_state == %{previous_response_id: "resp_ws_auth"}
      assert_no_secret(response)
      assert_no_secret(events)
    end

    test "explicit Authorization header wins and is not duplicated" do
      parent = self()
      explicit = "Bearer caller-pr15-token"

      ws_stream_fn = fn _websocket_url, ws_options, on_frame ->
        send(parent, {:ws_headers, ws_options[:headers]})
        emit_success_frames(on_frame, "resp_ws_explicit_auth")
        {:ok, :closed}
      end

      request =
        ws_request(%{
          ws_stream_fn: ws_stream_fn,
          headers: [{"Authorization", explicit}, {"X-Test", "ok"}],
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          auth_env: %{"MUSE_TEST_API_KEY" => @secret},
          system_env?: false
        })

      assert {:ok, response, events} = stream_with_events(request)

      assert_receive {:ws_headers, headers}
      assert authorization_headers(headers) == [explicit]
      assert {"X-Test", "ok"} in headers

      assert response.raw == nil
      assert_no_secret(response)
      assert_no_secret(events)
    end

    test "missing configured auth returns before ws_stream_fn is called" do
      parent = self()

      ws_stream_fn = fn _websocket_url, _ws_options, _on_frame ->
        send(parent, :unexpected_ws_call)
        {:ok, :closed}
      end

      request =
        ws_request(%{
          ws_stream_fn: ws_stream_fn,
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          auth_env: %{},
          system_env?: false
        })

      assert {:error, reason, events} = stream_with_events(request)
      refute_received :unexpected_ws_call
      assert Enum.any?(events, &(&1.type == :provider_error))
      assert_no_secret(reason)
      assert_no_secret(events)
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

  defp emit_success_frames(on_frame, response_id) do
    on_frame.(%{
      "type" => "response.output_text.delta",
      "response_id" => response_id,
      "delta" => "Hello over WS"
    })

    on_frame.(%{
      "type" => "response.completed",
      "response" => %{
        "id" => response_id,
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4, "total_tokens" => 7}
      }
    })
  end

  defp stream_with_events(request) do
    test_pid = self()
    ref = make_ref()

    emit_fn = fn event ->
      send(test_pid, {:responses_ws_auth_event, ref, event})
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
      {:responses_ws_auth_event, ^ref, event} -> drain_events(ref, [event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp authorization_headers(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name) == "authorization" end)
    |> Enum.map(fn {_name, value} -> value end)
  end

  defp assert_no_secret(term) do
    rendered = inspect(term)
    refute rendered =~ @secret
    refute rendered =~ "Bearer " <> @secret
    refute rendered =~ "token=leak"
  end
end
