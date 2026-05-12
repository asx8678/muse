defmodule Muse.Weft.Behaviour do
  @moduledoc """
  Behaviour for Weft channel handlers.

  Defines the contract for channel modules that participate in
  `Muse.Weft.Dispatch` routing. Each channel type (mcp, watch, terminal)
  implements these callbacks to handle its topic lifecycle.

  ## Integration with Dispatch

  `dispatch_join/4` calls `init/3` on the resolved channel module.
  `handle_in/3` is called for incoming client pushes after join.
  `terminate/3` is called on channel shutdown.

  ## Example

      defmodule Muse.Weft.Channels.McpChannel do
        @behaviour Muse.Weft.Behaviour

        @impl true
        def init(topic, _payload, socket) do
          {:ok, Phoenix.Socket.assign(socket, :topic, topic)}
        end

        @impl true
        def handle_in("tool_call", payload, socket) do
          # Process tool call...
          {:reply, %{result: "ok"}, socket}
        end

        @impl true
        def terminate(_reason, _socket), do: :ok
      end
  """

  @doc """
  Initialize a channel after topic routing resolves to this module.

  Called by `Muse.Weft.Dispatch.dispatch_join/4` when a `phx_join`
  matches this module's topic prefix. Return `{:ok, socket}` to
  accept the join, or `{:error, reason}` to reject it.
  """
  @callback init(topic :: String.t(), payload :: map(), socket :: Phoenix.Socket.t()) ::
              {:ok, Phoenix.Socket.t()} | {:error, String.t()}

  @doc """
  Handle an incoming client push event.

  Return values:
  - `{:noreply, socket}` — no reply, continue
  - `{:reply, payload, socket}` — reply to the push with the given payload
  - `{:stop, reason, socket}` — stop the channel
  """
  @callback handle_in(event :: String.t(), payload :: map(), socket :: Phoenix.Socket.t()) ::
              {:noreply, Phoenix.Socket.t()}
              | {:reply, map(), Phoenix.Socket.t()}
              | {:stop, reason :: term(), Phoenix.Socket.t()}

  @doc """
  Called when the channel is about to terminate.

  Use for cleanup — unsubscribe from pubsub, close resources, etc.
  """
  @callback terminate(reason :: term(), socket :: Phoenix.Socket.t()) :: :ok

  @optional_callbacks terminate: 2
end
