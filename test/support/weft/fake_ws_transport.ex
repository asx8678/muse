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
  def join_channel(topic, token \\ "test-token-16chars-ok", channel_module \\ nil) do
    {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => token})

    mod = channel_module || resolve_channel_module(topic)

    case subscribe_and_join(socket, mod, topic) do
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

  # -- Private ------------------------------------------------------------------

  # Resolve the Phoenix Channel module from a topic prefix.
  # New Weft channel types (mcp:, watch:, terminal:) are routed to
  # SessionChannel as placeholders until dedicated channel modules exist.
  defp resolve_channel_module("session:" <> _), do: MuseWeb.SessionChannel
  defp resolve_channel_module("mcp:" <> _), do: MuseWeb.SessionChannel
  defp resolve_channel_module("watch:" <> _), do: MuseWeb.SessionChannel
  defp resolve_channel_module("terminal:" <> _), do: MuseWeb.SessionChannel
  defp resolve_channel_module(_), do: MuseWeb.SessionChannel
end
