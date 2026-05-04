defmodule Muse.LLM.Transport.WebSocket.StreamTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.Transport.WebSocket.Stream

  @url "wss://api.test.example/v1/responses"

  describe "request/2" do
    test "returns configured placeholder error without a real WebSocket client" do
      assert {:error, {:transport_error, :websocket_client_not_configured}} =
               Stream.request(
                 [url: @url, create_frame: "response.create"],
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      refute_received {:unexpected_frame, _frame}
    end

    test "returns redacted connect failure without leaking headers or create frame" do
      parent = self()

      connect_fn = fn url, client_options ->
        send(parent, {:connect, url, client_options})
        {:error, {:econnrefused, "Bearer sk-connect-secret token=connect-secret"}}
      end

      result =
        Stream.request(
          [
            url: @url,
            headers: [{"Authorization", "Bearer sk-header-secret"}],
            create_frame: "response.create prompt=do-not-leak",
            connect_fn: connect_fn
          ],
          fn frame -> send(parent, {:unexpected_frame, frame}) end
        )

      assert {:error, {:transport_error, summary}} = result
      assert is_binary(summary)
      assert summary =~ "connect_failed"
      assert summary =~ "[REDACTED]"
      refute summary =~ "Bearer"
      refute summary =~ "sk-connect-secret"
      refute summary =~ "token=connect-secret"
      refute summary =~ "sk-header-secret"
      refute summary =~ "response.create"
      refute summary =~ "do-not-leak"

      assert_receive {:connect, @url, client_options}
      assert client_options[:headers] == [{"Authorization", "Bearer sk-header-secret"}]
      refute Keyword.has_key?(client_options, :create_frame)
      refute_received {:unexpected_frame, _frame}
    end

    test "sends create frame once after connect and stops before receive on send failure" do
      parent = self()

      connect_fn = fn _url, _client_options ->
        send(parent, :connected)
        {:ok, :conn}
      end

      create_frame = fn ->
        send(parent, :create_frame_built)
        "response.create prompt=do-not-leak"
      end

      send_fn = fn conn, frame, client_options ->
        send(parent, {:sent, conn, frame, client_options})
        {:error, {:send_refused, frame}}
      end

      recv_fn = fn _conn, _client_options ->
        send(parent, :recv_called)
        {:error, :should_not_receive}
      end

      result =
        Stream.request(
          [
            url: @url,
            create_frame: create_frame,
            connect_fn: connect_fn,
            send_fn: send_fn,
            recv_fn: recv_fn
          ],
          fn frame -> send(parent, {:unexpected_frame, frame}) end
        )

      assert {:error, {:transport_error, summary}} = result
      assert is_binary(summary)
      assert summary =~ "send_failed"
      refute summary =~ "response.create"
      refute summary =~ "do-not-leak"

      assert_receive :connected
      assert_receive :create_frame_built
      assert_receive {:sent, :conn, "response.create prompt=do-not-leak", client_options}
      refute Keyword.has_key?(client_options, :create_frame)
      refute_receive :recv_called, 10
      refute_received {:unexpected_frame, _frame}
    end

    test "invokes callback for inbound binary frames and returns close status" do
      parent = self()

      recv_fn =
        recv_sequence([{:text, "first"}, {:binary, "second"}, "third", {:close, 1000, "done"}])

      result =
        Stream.request(
          [
            url: @url,
            create_frame: "response.create",
            connect_fn: ok_connect_fn(parent),
            send_fn: ok_send_fn(parent),
            recv_fn: recv_fn
          ],
          fn frame -> send(parent, {:frame, frame}) end
        )

      assert {:ok, %{close_code: 1000, close_reason: "done"}} = result
      assert_received {:connected, @url, _client_options}
      assert_received {:sent, :conn, "response.create", _client_options}
      assert_received {:frame, "first"}
      assert_received {:frame, "second"}
      assert_received {:frame, "third"}
    end

    test "ignores non-binary inbound events without invoking callback" do
      parent = self()

      recv_fn =
        recv_sequence([
          {:ping, "keepalive"},
          {:text, 123},
          {:binary, 456},
          :pong,
          {:message, "only binary message"},
          {:closed, 1001, "going away"}
        ])

      result =
        Stream.request(
          [
            url: @url,
            create_frame: "response.create",
            connect_fn: ok_connect_fn(parent),
            send_fn: ok_send_fn(parent),
            recv_fn: recv_fn
          ],
          fn frame -> send(parent, {:frame, frame}) end
        )

      assert {:ok, %{close_code: 1001, close_reason: "going away"}} = result
      assert_received {:frame, "only binary message"}
      refute_received {:frame, {:ping, "keepalive"}}
      refute_received {:frame, 123}
      refute_received {:frame, 456}
      refute_received {:frame, :pong}
    end

    test "forwards timeout and retry options to injectable 3-arity stream function" do
      parent = self()

      ws_stream_fn = fn url, ws_options, on_frame ->
        send(parent, {:stream_called, url, ws_options})
        on_frame.({:text, "frame via wrapper"})
        on_frame.({:ping, "ignored"})
        {:ok, %{close_code: 1000, close_reason: "normal"}}
      end

      create_frame = %{"type" => "response.create"}

      result =
        Stream.request(
          %{
            url: @url,
            headers: %{"Authorization" => "Bearer test-token", "OpenAI-Beta" => "realtime=v1"},
            create_frame: create_frame,
            timeout_ms: 10_000,
            receive_timeout: 30_000,
            max_retries: 2,
            ws_stream_fn: ws_stream_fn
          },
          fn frame -> send(parent, {:frame, frame}) end
        )

      assert {:ok, %{close_code: 1000, close_reason: "normal"}} = result
      assert_receive {:stream_called, @url, ws_options}
      assert {"Authorization", "Bearer test-token"} in ws_options[:headers]
      assert {"OpenAI-Beta", "realtime=v1"} in ws_options[:headers]
      assert ws_options[:create_frame] == create_frame
      assert ws_options[:timeout_ms] == 10_000
      assert ws_options[:receive_timeout] == 30_000
      assert ws_options[:max_retries] == 2
      assert ws_options[:connect_options] == [timeout: 10_000]
      assert_received {:frame, "frame via wrapper"}
      refute_received {:frame, {:ping, "ignored"}}
    end

    test "redacts Bearer sk-style tokens and token assignments in transport errors" do
      ws_stream_fn = fn _url, _ws_options, _on_frame ->
        {:error, {:connection_failed, "Bearer sk-redaction-secret token=top-secret"}}
      end

      assert {:error, {:transport_error, summary}} =
               Stream.request(
                 [url: @url, create_frame: "response.create", ws_stream_fn: ws_stream_fn],
                 fn _frame -> :ok end
               )

      assert is_binary(summary)
      assert summary =~ "[REDACTED]"
      refute summary =~ "Bearer"
      refute summary =~ "sk-redaction-secret"
      refute summary =~ "token=top-secret"
    end

    test "rejects lower-level websocket URL with query without leaking it" do
      assert {:error, {:transport_error, summary}} =
               Stream.request(
                 [
                   url: "wss://api.test.example/v1/responses?api_key=sk-secret",
                   create_frame: "response.create"
                 ],
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      assert summary =~ "websocket_url_contains_query"
      refute summary =~ "sk-secret"
      refute summary =~ "api_key"
      refute_received {:unexpected_frame, _frame}
    end

    test "rejects lower-level websocket URL with fragment without leaking it" do
      assert {:error, {:transport_error, summary}} =
               Stream.request(
                 [
                   url: "wss://api.test.example/v1/responses#token=sk-secret",
                   create_frame: "response.create"
                 ],
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      assert summary =~ "websocket_url_contains_fragment"
      refute summary =~ "sk-secret"
      refute summary =~ "token"
      refute_received {:unexpected_frame, _frame}
    end

    test "rejects lower-level websocket URL with control characters without leaking it" do
      assert {:error, {:transport_error, summary}} =
               Stream.request(
                 [
                   url: "wss://api.test.example/v1/responses\r\nAuthorization: Bearer sk-secret",
                   create_frame: "response.create"
                 ],
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      assert summary =~ "websocket_url_contains_control_characters"
      refute summary =~ "sk-secret"
      refute summary =~ "Authorization"
      refute_received {:unexpected_frame, _frame}
    end
  end

  defp ok_connect_fn(parent) do
    fn url, client_options ->
      send(parent, {:connected, url, client_options})
      {:ok, :conn}
    end
  end

  defp ok_send_fn(parent) do
    fn conn, frame, client_options ->
      send(parent, {:sent, conn, frame, client_options})
      {:ok, conn}
    end
  end

  defp recv_sequence(events) do
    {:ok, agent} = Agent.start_link(fn -> events end)

    fn conn, _client_options ->
      Agent.get_and_update(agent, fn
        [event | rest] -> {{:ok, event, conn}, rest}
        [] -> {{:error, :empty_recv_sequence}, []}
      end)
    end
  end
end
