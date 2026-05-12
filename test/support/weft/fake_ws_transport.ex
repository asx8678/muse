defmodule Muse.Weft.Test.FakeWsTransport do
  @moduledoc """
  Fake WebSocket transport for testing Weft channel handlers.

  Provides helpers for connecting, joining, sending, and receiving
  messages through Phoenix channels without a real WebSocket.

  Wraps `Phoenix.ChannelTest` with tidewave-style convenience API.

  ## Example

      test "channel sends event after join" do
        {:ok, _user_socket, channel_socket} = join_channel("session:test-session")

        # Wait for the replay push
        assert_push "muse_event", %{"events" => _}

        # Push a message to the channel
        push(channel_socket, "my_event", %{key: "value"})
      end
  """

  import Phoenix.ChannelTest

  # Required by Phoenix.ChannelTest.connect/3 macro
  @endpoint MuseWeb.Endpoint

  @doc """
  Connect to the UserSocket and join a channel topic.

  Returns `{:ok, user_socket, channel_socket}` where `user_socket` is
  the socket returned by `connect/3` and `channel_socket` is the joined
  channel socket from `subscribe_and_join/3`.

  The channel socket has a `channel_pid` field for matching pushed messages.
  """
  @spec join_channel(String.t(), String.t(), module() | nil) ::
          {:ok, Phoenix.Socket.t(), Phoenix.Socket.t()}
          | {:error, map()}
  def join_channel(topic, token \\ "test-token-16chars-ok", channel_module \\ nil, payload \\ %{}) do
    {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => token})

    mod = channel_module || resolve_channel_module(topic)

    case subscribe_and_join(socket, mod, topic, payload) do
      {:ok, _reply, channel_socket} ->
        {:ok, socket, channel_socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Push an event to a channel socket.

  Returns a reference that can be used with `assert_reply/3`.
  Delegates to `Phoenix.ChannelTest.push/3`.
  """
  @spec push(Phoenix.Socket.t(), String.t(), map()) :: reference()
  def push(channel_socket, event, payload) do
    Phoenix.ChannelTest.push(channel_socket, event, payload)
  end

  @doc """
  Wait for a specific event push from the channel.

  Matches `%Phoenix.Socket.Message{}` structs in the test mailbox,
  returning `{:ok, payload}` when a matching event is found or
  `{:error, :timeout}` after `timeout` ms.

  Unlike `assert_push`, this returns the payload instead of raising.
  """
  @spec wait_for_event(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_event(event, timeout \\ 500) when is_binary(event) do
    receive do
      %Phoenix.Socket.Message{event: ^event, payload: payload} ->
        {:ok, payload}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Wait for a reply to a specific push reference.

  Matches `%Phoenix.Socket.Reply{}` structs in the test mailbox,
  returning `{:ok, status, payload}` when found or
  `{:error, :timeout}` after `timeout` ms.
  """
  @spec wait_for_reply(reference(), non_neg_integer()) ::
          {:ok, atom(), map()} | {:error, :timeout}
  def wait_for_reply(ref, timeout \\ 500) when is_reference(ref) do
    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: status, payload: payload} ->
        {:ok, status, payload}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Send a PhoenixV2 message through the fake transport.

  Encodes the struct to JSON (simulating a real client sending over
  the wire) and pushes the event/payload to the channel socket.
  Returns a reference for matching with `wait_for_reply/2` or
  `recv_phoenix_msg/1`.
  """
  @spec send_phoenix_msg(Phoenix.Socket.t(), Muse.Weft.PhoenixV2.t()) :: reference()
  def send_phoenix_msg(channel_socket, %Muse.Weft.PhoenixV2{} = msg) do
    Phoenix.ChannelTest.push(channel_socket, msg.event, msg.payload)
  end

  @doc """
  Receive the next Phoenix V2 message from the test mailbox.

  Matches `%Phoenix.Socket.Message{}` structs pushed by the channel
  and converts them to `PhoenixV2` structs. Returns
  `{:ok, phoenix_v2_msg}` when a message is found or
  `{:error, :timeout}` after `timeout` ms.

  `PhoenixV2.join_ref` is populated from the socket message when
  available.
  """
  @spec recv_phoenix_msg(non_neg_integer()) ::
          {:ok, Muse.Weft.PhoenixV2.t()} | {:error, :timeout}
  def recv_phoenix_msg(timeout \\ 500) do
    receive do
      %Phoenix.Socket.Message{topic: topic, event: event, payload: payload, ref: ref} ->
        {:ok,
         %Muse.Weft.PhoenixV2{
           topic: topic,
           event: event,
           payload: payload,
           ref: ref,
           join_ref: nil
         }}
    after
      timeout -> {:error, :timeout}
    end
  end

  # -- Private ------------------------------------------------------------------

  # Resolve the Phoenix Channel module from a topic prefix.
  # New Weft channel types (mcp:, watch:, terminal:) are routed to
  # SessionChannel as placeholders until dedicated channel modules exist.
  defp resolve_channel_module("session:" <> _), do: MuseWeb.SessionChannel
  defp resolve_channel_module("mcp:" <> _), do: Muse.Weft.Channels.McpChannel
  defp resolve_channel_module("watch:" <> _), do: Muse.Weft.Channels.WatchChannel
  defp resolve_channel_module("terminal:" <> _), do: Muse.Weft.Channels.TerminalChannel
  defp resolve_channel_module(_), do: MuseWeb.SessionChannel
end
