defmodule Muse.Weft.Endpoints.McpClientHandlerTest do
  @moduledoc """
  Tests for the MCP HTTP POST handler.

  Tests the plug in isolation using `Plug.Test`, but relies on
  `Muse.Weft.Test.ChannelCase` for the Phoenix infrastructure
  (PubSub, Endpoint, fake transport) needed to exercise the full
  `McpChannel` round-trip.
  """

  use Muse.Weft.Test.ChannelCase, async: false

  import Plug.Test

  alias Muse.Weft.Channels.McpChannel
  alias Muse.Weft.Endpoints.McpClientHandler
  alias Muse.Weft.Test.FakeWsTransport

  setup do
    original_weft = Application.get_env(:muse, :weft)
    Application.put_env(:muse, :weft, enabled_channels: ["mcp"])
    McpChannel.ensure_tables()

    # Clear tables for isolation between tests
    :ets.delete_all_objects(:mcp_channel_sessions)
    :ets.delete_all_objects(:mcp_awaiting_answers)

    on_exit(fn ->
      if original_weft do
        Application.put_env(:muse, :weft, original_weft)
      else
        Application.delete_env(:muse, :weft)
      end
    end)

    :ok
  end

  describe "POST /socket/mcp-remote-client" do
    test "valid session with request id returns response from browser" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:handler-valid-session")

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})

      Task.start(fn ->
        Process.sleep(50)

        FakeWsTransport.push(channel_socket, "mcp_message", %{
          "id" => 1,
          "result" => "ok",
          "jsonrpc" => "2.0"
        })
      end)

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=handler-valid-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"id" => 1, "result" => "ok", "jsonrpc" => "2.0"}
    end

    test "missing session returns 404" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=missing-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 404
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["error"]["message"] == "Browser is not connected"
    end

    test "no auth token returns 401" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=any-session",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end

    test "notification (no id) returns 202 and pushes to browser" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("mcp:handler-notify-session")

      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=handler-notify-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 202
      assert conn.resp_body == ""

      assert {:ok, %{"method" => "notify"}} =
               FakeWsTransport.wait_for_event("mcp_message", 500)
    end

    test "malformed JSON returns 400" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("mcp:handler-json-session")

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=handler-json-session&token=test-token-16chars-ok",
          "not json"
        )
        |> McpClientHandler.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["error"]["message"] == "Parse error"
    end

    test "missing jsonrpc field returns 400" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("mcp:handler-rpc-session")

      body = Jason.encode!(%{"id" => 1, "method" => "test"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=handler-rpc-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["error"]["message"] == "Invalid Request"
    end

    test "disabled MCP returns 503" do
      Application.put_env(:muse, :weft, enabled_channels: [])

      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=disabled-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "MCP channel disabled"}
    end

    test "timeout on response returns 504" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("mcp:handler-timeout-session")

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "method" => "test"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=handler-timeout-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call(timeout: 100)

      assert conn.status == 504
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 99
      assert resp["error"]["message"] == "Timeout waiting for browser response"
    end

    test "channel process dies returns 500" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:handler-die-session")

      # Unlink test process so it survives the channel kill
      Process.unlink(channel_socket.channel_pid)

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 88, "method" => "test"})

      Task.start(fn ->
        Process.sleep(50)
        Process.exit(channel_socket.channel_pid, :kill)
      end)

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=handler-die-session&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call(timeout: 5_000)

      assert conn.status == 500
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 88
      assert resp["error"]["message"] =~ "Internal error"
    end

    test "invalid session id returns 400" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?sessionId=../bad&token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["error"]["message"] =~ "invalid sessionId"
    end

    test "missing sessionId returns 400" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify"})

      conn =
        conn(
          :post,
          "/socket/mcp-remote-client?token=test-token-16chars-ok",
          body
        )
        |> McpClientHandler.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["jsonrpc"] == "2.0"
      assert resp["error"]["message"] =~ "missing sessionId"
    end
  end
end
