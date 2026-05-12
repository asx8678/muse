defmodule Muse.Weft.Connection do
  @moduledoc """
  Weft WebSocket connection routing.

  Defines the canonical channel module map used by `Muse.Weft.Dispatch`
  and provides a convenience wrapper for `dispatch_join/4`.

  ## Channel map

      "mcp"      => Muse.Weft.Channels.McpChannel
      "watch"    => Muse.Weft.Channels.WatchChannel
      "terminal" => Muse.Weft.Channels.TerminalChannel
      "session"  => MuseWeb.SessionChannel
  """

  alias Muse.Weft.ChannelSender

  @doc """
  Returns the channel module map for all Weft topics.
  """
  @spec channel_module_map() :: %{String.t() => module()}
  def channel_module_map do
    %{
      "mcp" => Muse.Weft.Channels.McpChannel,
      "watch" => Muse.Weft.Channels.WatchChannel,
      "terminal" => Muse.Weft.Channels.TerminalChannel,
      "session" => MuseWeb.SessionChannel
    }
  end

  @doc """
  Dispatch a `phx_join` to the appropriate channel module.

  Convenience wrapper around `Muse.Weft.Dispatch.dispatch_join/4` that
  uses the canonical `channel_module_map`.
  """
  @spec dispatch_join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t(), ChannelSender.t()} | {:error, String.t()}
  def dispatch_join(topic, payload, socket) do
    Muse.Weft.Dispatch.dispatch_join(topic, payload, socket, channel_module_map())
  end
end
