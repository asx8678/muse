defmodule Muse.Weft.DispatchTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Muse.Weft.{ChannelSender, Dispatch, PhoenixV2}

  # -- Mock channel modules for testing ----------------------------------------

  defmodule OkChannel do
    @behaviour Muse.Weft.Behaviour

    @impl true
    def init(topic, _payload, socket) do
      {:ok, Phoenix.Socket.assign(socket, :resolved_topic, topic)}
    end

    @impl true
    def handle_in(_event, _payload, socket), do: {:noreply, socket}

    @impl true
    def terminate(_reason, _socket), do: :ok
  end

  defmodule FailChannel do
    @behaviour Muse.Weft.Behaviour

    @impl true
    def init(_topic, _payload, _socket), do: {:error, "init_failed"}

    @impl true
    def handle_in(_event, _payload, socket), do: {:noreply, socket}

    @impl true
    def terminate(_reason, _socket), do: :ok
  end

  defmodule PayloadChannel do
    @behaviour Muse.Weft.Behaviour

    @impl true
    def init(_topic, payload, socket) do
      {:ok, Phoenix.Socket.assign(socket, :join_payload, payload)}
    end

    @impl true
    def handle_in(_event, _payload, socket), do: {:noreply, socket}

    @impl true
    def terminate(_reason, _socket), do: :ok
  end

  # -- resolve_module/2 --------------------------------------------------------

  describe "resolve_module/2" do
    test "routes known prefix to correct module" do
      channel_map = %{"mcp" => OkChannel, "watch" => FailChannel}

      assert {:ok, OkChannel} = Dispatch.resolve_module("mcp:session-123", channel_map)
      assert {:ok, FailChannel} = Dispatch.resolve_module("watch:ref-1", channel_map)
    end

    test "routes session prefix" do
      channel_map = %{"session" => OkChannel}

      assert {:ok, OkChannel} = Dispatch.resolve_module("session:abc-123", channel_map)
    end

    test "routes terminal prefix" do
      channel_map = %{"terminal" => OkChannel}

      assert {:ok, OkChannel} = Dispatch.resolve_module("terminal:ref-1", channel_map)
    end

    test "returns error for unknown prefix" do
      channel_map = %{"mcp" => OkChannel}

      assert {:error, "unknown_topic"} = Dispatch.resolve_module("unknown:topic", channel_map)
    end

    test "returns error for topic without colon" do
      channel_map = %{"mcp" => OkChannel}

      assert {:error, "unknown_topic"} = Dispatch.resolve_module("notopic", channel_map)
    end

    test "returns error for empty topic" do
      channel_map = %{"mcp" => OkChannel}

      assert {:error, "unknown_topic"} = Dispatch.resolve_module("", channel_map)
    end

    test "handles topic with multiple colons" do
      channel_map = %{"mcp" => OkChannel}

      # "mcp:session:extra" → prefix "mcp", rest "session:extra"
      assert {:ok, OkChannel} = Dispatch.resolve_module("mcp:session:extra", channel_map)
    end

    test "empty map returns error for any topic" do
      assert {:error, "unknown_topic"} = Dispatch.resolve_module("mcp:x", %{})
    end
  end

  # -- dispatch_join/4 ---------------------------------------------------------

  describe "dispatch_join/4" do
    test "successful join returns socket and sender" do
      channel_map = %{"mcp" => OkChannel}

      socket = %Phoenix.Socket{
        topic: "mcp:session-123",
        joined: false
      }

      assert {:ok, channel_socket, sender} =
               Dispatch.dispatch_join("mcp:session-123", %{}, socket, channel_map)

      # Channel socket has assigns from init
      assert channel_socket.assigns.resolved_topic == "mcp:session-123"

      # Sender is built from the channel socket
      assert %ChannelSender{} = sender
      assert sender.topic == "mcp:session-123"
    end

    test "failed init returns error" do
      channel_map = %{"mcp" => FailChannel}

      socket = %Phoenix.Socket{
        topic: "mcp:session-123",
        joined: false
      }

      assert {:error, "init_failed"} =
               Dispatch.dispatch_join("mcp:session-123", %{}, socket, channel_map)
    end

    test "unknown topic returns error" do
      channel_map = %{"mcp" => OkChannel}

      socket = %Phoenix.Socket{
        topic: "bogus:id",
        joined: false
      }

      assert {:error, "unknown_topic"} =
               Dispatch.dispatch_join("bogus:id", %{}, socket, channel_map)
    end

    test "passes payload to init callback" do
      channel_map = %{"watch" => PayloadChannel}

      socket = %Phoenix.Socket{topic: "watch:ref-1", joined: false}

      payload = %{"cursor" => 42, "filter" => "active"}

      assert {:ok, channel_socket, _sender} =
               Dispatch.dispatch_join("watch:ref-1", payload, socket, channel_map)

      assert channel_socket.assigns.join_payload == payload
    end
  end

  # -- reply_init/2 (pure unit tests) ------------------------------------------

  describe "reply_init/2" do
    test "error returns error map with reason" do
      socket = %Phoenix.Socket{}

      assert {:error, %{reason: "validation_failed"}} =
               Dispatch.reply_init(socket, {:error, "validation_failed"})
    end

    test "error with empty reason string" do
      socket = %Phoenix.Socket{}

      assert {:error, %{reason: ""}} = Dispatch.reply_init(socket, {:error, ""})
    end
  end

  # -- Behaviour callback types ------------------------------------------------

  describe "Behaviour" do
    test "OkChannel implements all callbacks" do
      assert function_exported?(OkChannel, :init, 3)
      assert function_exported?(OkChannel, :handle_in, 3)
      assert function_exported?(OkChannel, :terminate, 2)
    end

    test "terminate is optional" do
      defmodule MinimalChannel do
        @behaviour Muse.Weft.Behaviour

        @impl true
        def init(_topic, _payload, socket), do: {:ok, socket}

        @impl true
        def handle_in(_event, _payload, socket), do: {:noreply, socket}
      end

      # Should not raise — terminate is @optional_callbacks
      assert function_exported?(MinimalChannel, :init, 3)
      assert function_exported?(MinimalChannel, :handle_in, 3)
      refute function_exported?(MinimalChannel, :terminate, 2)
    end
  end
end

defmodule Muse.Weft.DispatchIntegrationTest do
  @moduledoc """
  Integration tests for Dispatch that require a live Phoenix channel.
  """
  use Muse.Weft.Test.ChannelCase, async: false

  alias Muse.Weft.{Dispatch, PhoenixV2}
  import Muse.Weft.Test.FakeWsTransport

  # -- reply_init/2 with live channel ------------------------------------------

  describe "reply_init/2 integration" do
    test "done pushes phx_close to client" do
      {:ok, _user_socket, channel_socket} = join_channel("session:init-done-test")

      # Consume the replay push
      assert_push("muse_event", %{})

      assert :ok = Dispatch.reply_init(channel_socket, :done)

      assert_push("phx_close", %{})
    end

    test "shutdown pushes phx_error with reason" do
      {:ok, _user_socket, channel_socket} = join_channel("session:init-shutdown-test")

      # Consume the replay push
      assert_push("muse_event", %{})

      assert :ok = Dispatch.reply_init(channel_socket, {:shutdown, "process died"})

      assert_push("phx_error", %{reason: "process died"})
    end
  end

  # -- FakeWsTransport send_phoenix_msg / recv_phoenix_msg ---------------------

  describe "FakeWsTransport phoenix msg helpers" do
    test "send_phoenix_msg pushes event and returns reference" do
      {:ok, _user_socket, channel_socket} = join_channel("session:phoenix-msg-test")

      # Consume the replay push
      assert_push("muse_event", %{})

      msg = PhoenixV2.join("session:phoenix-msg-test", "99", %{action: "test"})
      ref = send_phoenix_msg(channel_socket, msg)

      # The push returns a reference for matching replies
      assert is_reference(ref)
    end

    test "recv_phoenix_msg returns pushed message as PhoenixV2 struct" do
      {:ok, _user_socket, _channel_socket} = join_channel("session:phoenix-msg-recv-test")

      # Consume the replay push via recv_phoenix_msg
      assert {:ok, replay_msg} = recv_phoenix_msg(500)
      assert %PhoenixV2{} = replay_msg
      assert replay_msg.topic == "session:phoenix-msg-recv-test"
      assert replay_msg.event == "muse_event"
    end

    test "recv_phoenix_msg times out when no messages" do
      assert {:error, :timeout} = recv_phoenix_msg(10)
    end
  end
end
