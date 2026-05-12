defmodule Muse.Weft.ChannelSender do
  @moduledoc """
  Lightweight handle for pushing messages to a channel's client.

  Wraps a `Phoenix.Socket` with topic and join_ref so channel handlers
  can push events without constructing full pushes every time.

  ## Usage

  Build from a channel's `socket` in `join/3` or `handle_in/3`:

      sender = ChannelSender.from_socket(socket)
      ChannelSender.push(sender, "my_event", %{key: "value"})

  ## Async replies

  For async replies, capture a `socket_ref` and pass it along with
  the sender:

      ref = Phoenix.Channel.socket_ref(socket)
      ChannelSender.reply(sender, ref, :ok, %{result: "done"})
  """

  @derive {Inspect, only: [:topic, :join_ref]}
  defstruct [:socket, :topic, :join_ref]

  @type t :: %__MODULE__{
          socket: Phoenix.Socket.t(),
          topic: String.t(),
          join_ref: String.t() | nil
        }

  @doc """
  Build a `ChannelSender` from a joined channel socket.
  """
  @spec from_socket(Phoenix.Socket.t()) :: t()
  def from_socket(%Phoenix.Socket{} = socket) do
    %__MODULE__{
      socket: socket,
      topic: socket.topic,
      join_ref: socket.join_ref
    }
  end

  @doc """
  Push an event to the client with the given payload.

  Returns `:ok` on success. The message is sent to the channel's
  transport process for serialization and delivery.
  """
  @spec push(t(), String.t(), map()) :: :ok
  def push(%__MODULE__{socket: socket}, event, payload) when is_binary(event) do
    Phoenix.Channel.push(socket, event, payload)
  end

  @doc """
  Reply to a specific message with a status and response.

  `ref` must be a `socket_ref` obtained via `Phoenix.Channel.socket_ref/1`.
  This enables async replies from outside the `handle_in/3` callback.
  """
  @spec reply(t(), Phoenix.Channel.socket_ref(), atom(), map()) :: :ok
  def reply(%__MODULE__{topic: topic, join_ref: join_ref}, socket_ref, status, response)
      when is_atom(status) do
    # socket_ref is {transport_pid, serializer, topic, ref, join_ref}
    # We use our own topic/join_ref for consistency
    case socket_ref do
      {transport_pid, serializer, _ref_topic, ref, _ref_join} ->
        Phoenix.Channel.reply(
          {transport_pid, serializer, topic, ref, join_ref},
          {status, response}
        )

      ref when is_reference(ref) ->
        # Legacy path: bare ref from push/3
        # This won't work without the full socket_ref — caller must use
        # Phoenix.Channel.socket_ref/1 to obtain a valid ref.
        raise ArgumentError,
              "ChannelSender.reply/4 requires a socket_ref tuple, " <>
                "not a bare reference. Use Phoenix.Channel.socket_ref/1 " <>
                "to obtain one from the channel socket."
    end
  end
end
