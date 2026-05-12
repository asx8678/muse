defmodule Muse.Weft.Channels.TerminalChannelTest do
  use Muse.Weft.Test.ChannelCase, async: false

  alias Muse.Weft.Test.{FakePort, FakeWsTransport}

  setup do
    original_weft = Application.get_env(:muse, :weft)
    Application.put_env(:muse, :weft, enabled_channels: ["terminal"])
    Application.put_env(:muse, :weft_terminal_port_module, FakePort)

    on_exit(fn ->
      if original_weft do
        Application.put_env(:muse, :weft, original_weft)
      else
        Application.delete_env(:muse, :weft)
      end

      Application.delete_env(:muse, :weft_terminal_port_module)
    end)

    :ok
  end

  describe "join/3" do
    test "joins successfully with valid terminal:test-ref topic" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("terminal:test-ref")

      assert channel_socket.assigns.terminal_ref == "test-ref"
      assert channel_socket.assigns.terminal_port != nil
    end

    test "rejects join with empty ref" do
      assert {:error, %{reason: "invalid_ref"}} =
               FakeWsTransport.join_channel("terminal:")
    end

    test "rejects join with path traversal ref" do
      assert {:error, %{reason: "invalid_ref"}} =
               FakeWsTransport.join_channel("terminal:../escape")
    end

    test "rejects join when terminal channel is disabled" do
      Application.put_env(:muse, :weft, enabled_channels: [])

      assert {:error, %{reason: "terminal_channel_disabled"}} =
               FakeWsTransport.join_channel("terminal:disabled-test")
    end
  end

  describe "handle_in input" do
    test "send input and receive output" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("terminal:io-test")

      FakeWsTransport.push(channel_socket, "input", %{"data" => "hello\n"})

      assert_push("output", %{data: "hello\n"})
    end
  end

  describe "handle_in resize" do
    test "resize is accepted" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("terminal:resize-test")

      ref = FakeWsTransport.push(channel_socket, "resize", %{"cols" => 80, "rows" => 24})
      assert_reply(ref, :ok, %{ok: true})
    end
  end

  describe "terminate/2" do
    test "closes the port on channel exit" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("terminal:term-test")

      port = channel_socket.assigns.terminal_port

      Process.unlink(channel_socket.channel_pid)
      close(channel_socket)

      Process.sleep(100)

      refute Process.alive?(port)
    end
  end
end
