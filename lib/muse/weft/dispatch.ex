defmodule Muse.Weft.Dispatch do
  @moduledoc """
  Channel dispatch and InitResult reply helpers.

  Provides topic-based routing for `phx_join` messages and translates
  `Muse.Weft.InitResult` values into the appropriate Phoenix wire messages.

  ## Topic routing

  `dispatch_join/4` routes join requests by topic prefix to the matching
  channel module. The prefix is the segment before the first `:`:

      "mcp:session-123"  →  prefix "mcp"
      "watch:ref-1"      →  prefix "watch"
      "session:abc"      →  prefix "session"

  Unknown prefixes return `{:error, "unknown_topic"}`.

  ## InitResult translation

  `reply_init/2` maps each `InitResult` variant to its Phoenix wire message:

  - `:done`              → `phx_close` push (clean exit, client leaves)
  - `{:error, reason}`   → `{:error, %{reason: reason}}` (join rejection, client can retry)
  - `{:shutdown, reason}` → `phx_error` push (runtime error, client rejoin)
  """

  alias Muse.Weft.{ChannelSender, InitResult}

  @doc """
  Route a `phx_join` by topic prefix and initialize the channel.

  `channel_module_map` maps topic prefixes to channel modules implementing
  `Muse.Weft.Behaviour`. On match, the module's `init/3` is called with the
  topic, payload, and socket. On success, a `ChannelSender` is built from
  the resulting socket.

  ## Examples

      channel_map = %{
        "mcp"     => Muse.Weft.Channels.McpChannel,
        "watch"   => Muse.Weft.Channels.WatchChannel,
        "session" => MuseWeb.SessionChannel
      }

      {:ok, channel_socket, sender} =
        Dispatch.dispatch_join("mcp:session-123", %{}, socket, channel_map)

      {:error, "unknown_topic"} =
        Dispatch.dispatch_join("bogus:id", %{}, socket, channel_map)
  """
  @spec dispatch_join(String.t(), map(), Phoenix.Socket.t(), %{String.t() => module()}) ::
          {:ok, Phoenix.Socket.t(), ChannelSender.t()} | {:error, String.t()}
  def dispatch_join(topic, payload, socket, channel_module_map) do
    case resolve_module(topic, channel_module_map) do
      {:ok, module} ->
        case module.init(topic, payload, socket) do
          {:ok, channel_socket} ->
            sender = ChannelSender.from_socket(channel_socket)
            {:ok, channel_socket, sender}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Resolve a topic string to its channel module using the prefix map.

  Extracts the prefix (segment before the first `:`) and looks it up
  in `channel_module_map`. Returns `{:ok, module}` or
  `{:error, "unknown_topic"}`.

  ## Examples

      iex> Dispatch.resolve_module("mcp:abc", %{"mcp" => McpChannel})
      {:ok, McpChannel}

      iex> Dispatch.resolve_module("unknown:x", %{})
      {:error, "unknown_topic"}
  """
  @spec resolve_module(String.t(), %{String.t() => module()}) ::
          {:ok, module()} | {:error, String.t()}
  def resolve_module(topic, channel_module_map) when is_binary(topic) do
    case String.split(topic, ":", parts: 2) do
      [prefix, _rest] ->
        case Map.fetch(channel_module_map, prefix) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, "unknown_topic"}
        end

      _ ->
        {:error, "unknown_topic"}
    end
  end

  @doc """
  Translate an `InitResult` into the appropriate Phoenix wire message.

  - `:done`              → pushes `phx_close` (clean exit, client should leave)
  - `{:error, reason}`   → returns `{:error, %{reason: reason}}` (join failure, client can retry)
  - `{:shutdown, reason}` → pushes `phx_error` (runtime error, triggers client rejoin)

  For `:done` and `{:shutdown, _}`, the socket must be a joined channel
  socket (`socket.joined == true`) so that `Phoenix.Channel.push/3` can
  deliver the message.

  For `{:error, _}`, no socket is required — the error tuple is returned
  directly for the caller to use as the join callback return value.
  """
  @spec reply_init(Phoenix.Socket.t(), InitResult.t()) ::
          :ok | {:error, map()}
  def reply_init(socket, :done) do
    Phoenix.Channel.push(socket, "phx_close", %{})
  end

  def reply_init(_socket, {:error, reason}) do
    {:error, %{reason: reason}}
  end

  def reply_init(socket, {:shutdown, reason}) do
    Phoenix.Channel.push(socket, "phx_error", %{reason: reason})
  end
end
