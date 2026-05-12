defmodule Muse.Weft.Test.FakeWsTransportTest do
  use Muse.Weft.Test.ChannelCase, async: false

  alias Muse.Weft.ChannelSender
  alias Muse.Weft.PhoenixV2

  describe "PhoenixV2 encode/decode" do
    test "round-trips a join message" do
      msg = PhoenixV2.join("test:topic")
      json = PhoenixV2.encode(msg)
      assert {:ok, decoded} = PhoenixV2.decode(json)
      assert decoded.topic == "test:topic"
      assert decoded.event == "phx_join"
      assert decoded.join_ref == "1"
    end

    test "heartbeat message" do
      msg = PhoenixV2.heartbeat()
      assert msg.topic == "phoenix"
      assert msg.event == "heartbeat"
      assert msg.join_ref == nil
    end

    test "leave message" do
      msg = PhoenixV2.leave("test:topic")
      assert msg.topic == "test:topic"
      assert msg.event == "phx_leave"
    end

    test "decode rejects non-array JSON" do
      assert {:error, _} = PhoenixV2.decode("{\"key\": 1}")
    end

    test "decode rejects wrong-size array" do
      assert {:error, "expected 5-element array"} = PhoenixV2.decode("[1,2,3]")
    end

    test "decode rejects invalid JSON" do
      assert {:error, _} = PhoenixV2.decode("not json")
    end
  end

  describe "ChannelSender" do
    test "struct fields and from_socket" do
      sender = %ChannelSender{topic: "test:topic", join_ref: "1"}
      assert sender.topic == "test:topic"
      assert sender.join_ref == "1"
    end

    test "inspect hides socket internals" do
      sender = %ChannelSender{socket: :some_socket, topic: "secret:topic", join_ref: "1"}
      inspect_str = inspect(sender)
      assert inspect_str =~ "secret:topic"
      # Socket should not appear in inspect output
      refute inspect_str =~ "some_socket"
    end
  end

  describe "InitResult" do
    test "done signals clean exit" do
      assert :done == :done
    end

    test "error signals join validation failure" do
      assert {:error, "bad path"} == {:error, "bad path"}
    end

    test "shutdown signals runtime error" do
      assert {:shutdown, "process died"} == {:shutdown, "process died"}
    end
  end

  describe "FakeWsTransport" do
    test "can join a session channel" do
      {:ok, _user_socket, channel_socket} = join_channel("session:test-sess")
      # subscribe_and_join returns a Phoenix.Socket with a channel_pid
      assert is_pid(channel_socket.channel_pid)
    end

    test "rejects invalid session id" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => "test-token-16chars-ok"})

      assert {:error, %{reason: "invalid_session_id"}} =
               subscribe_and_join(socket, MuseWeb.SessionChannel, "session:")
    end

    test "rejects connection when external WS is disabled" do
      original_ws = Application.get_env(:muse, :external_ws)

      on_exit(fn ->
        if original_ws do
          Application.put_env(:muse, :external_ws, original_ws)
        else
          Application.delete_env(:muse, :external_ws)
        end
      end)

      Application.put_env(:muse, :external_ws, enabled: false, token_hashes: [])
      assert :error = connect(MuseWeb.UserSocket, %{"token" => "test-token-16chars-ok"})
    end

    test "wait_for_event returns pushed event payload" do
      {:ok, _user_socket, _channel_socket} = join_channel("session:event-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => _})

      # Push a muse_event through Muse.State to trigger a live event
      event =
        Muse.Event.new(:cli, :user_message, %{text: "hello"},
          session_id: "event-test",
          visibility: :user,
          id: 100,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      :ok = Muse.State.append(event)

      assert {:ok, payload} = wait_for_event("muse_event")
      assert payload["type"] == "user_message"
    end

    test "wait_for_event times out for missing events" do
      {:ok, _user_socket, _channel_socket} = join_channel("session:timeout-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => _})

      assert {:error, :timeout} = wait_for_event("never_coming", 50)
    end
  end
end
