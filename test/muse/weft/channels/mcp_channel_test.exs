defmodule Muse.Weft.Channels.McpChannelTest do
  use Muse.Weft.Test.ChannelCase, async: false

  alias Muse.Weft.ChannelSender
  alias Muse.Weft.Channels.McpChannel
  alias Muse.Weft.Test.FakeWsTransport

  setup do
    original_weft = Application.get_env(:muse, :weft)
    Application.put_env(:muse, :weft, enabled_channels: ["mcp"])
    McpChannel.ensure_tables()

    on_exit(fn ->
      if original_weft do
        Application.put_env(:muse, :weft, original_weft)
      else
        Application.delete_env(:muse, :weft)
      end
    end)

    :ok
  end

  describe "join/3" do
    test "joins successfully with valid mcp:<session_id> topic" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:valid-session-id")

      assert channel_socket.assigns.mcp_session_id == "valid-session-id"
      assert %ChannelSender{} = channel_socket.assigns.mcp_sender
    end

    test "rejects join with empty session id" do
      assert {:error, %{reason: "invalid_session_id"}} =
               FakeWsTransport.join_channel("mcp:")
    end

    test "rejects join with path traversal session id" do
      assert {:error, %{reason: "invalid_session_id"}} =
               FakeWsTransport.join_channel("mcp:../path")
    end

    test "rejects join when mcp channel is disabled" do
      Application.put_env(:muse, :weft, enabled_channels: [])

      assert {:error, %{reason: "mcp_channel_disabled"}} =
               FakeWsTransport.join_channel("mcp:disabled-test")
    end
  end

  describe "lookup_sender/1" do
    test "returns sender after join" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("mcp:lookup-test")

      assert {:ok, %ChannelSender{}} = McpChannel.lookup_sender("lookup-test")
    end

    test "returns error for unknown session" do
      assert {:error, :not_connected} = McpChannel.lookup_sender("unknown-session")
    end

    test "returns error when disabled" do
      Application.put_env(:muse, :weft, enabled_channels: [])
      assert {:error, :disabled} = McpChannel.lookup_sender("any-session")
    end
  end

  describe "handle_in mcp_message" do
    test "routes mcp_message with id to awaiting answer" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:msg-test")

      assert {:ok, ref} = McpChannel.register_awaiting_answer("msg-test", 42, self())

      FakeWsTransport.push(channel_socket, "mcp_message", %{"id" => 42, "result" => "ok"})

      assert_receive {:mcp_response, %{"id" => 42, "result" => "ok"}}, 500
      assert :error = McpChannel.consume_awaiting_answer("msg-test", 42)

      Process.demonitor(ref, [:flush])
    end

    test "ignores mcp_message without id" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:notify-test")

      FakeWsTransport.push(channel_socket, "mcp_message", %{"method" => "notify"})

      refute_receive {:mcp_response, _}, 100
    end

    test "ignores mcp_message with nil id" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:nil-id-test")

      FakeWsTransport.push(channel_socket, "mcp_message", %{"id" => nil, "method" => "notify"})

      refute_receive {:mcp_response, _}, 100
    end
  end

  describe "terminate/2" do
    test "cleans up session registry and errors pending answers" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("mcp:term-test")

      assert {:ok, ref} = McpChannel.register_awaiting_answer("term-test", 99, self())
      assert {:ok, %ChannelSender{}} = McpChannel.lookup_sender("term-test")

      Process.unlink(channel_socket.channel_pid)
      close(channel_socket)

      assert_receive {:mcp_error, "Browser disconnected"}, 500
      Process.demonitor(ref, [:flush])

      assert {:error, :not_connected} = McpChannel.lookup_sender("term-test")
      assert :error = McpChannel.consume_awaiting_answer("term-test", 99)
    end
  end

  describe "multiple browsers" do
    test "last join wins for the same session_id" do
      assert {:ok, _user_socket1, _channel_socket1} =
               FakeWsTransport.join_channel("mcp:multi-test")

      assert {:ok, _user_socket2, channel_socket2} =
               FakeWsTransport.join_channel("mcp:multi-test")

      assert {:ok, sender} = McpChannel.lookup_sender("multi-test")
      assert sender.socket.channel_pid == channel_socket2.channel_pid
    end
  end
end
