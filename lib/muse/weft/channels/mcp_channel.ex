defmodule Muse.Weft.Channels.McpChannel do
  @moduledoc """
  MCP WebSocket channel handler.

  Implements `Muse.Weft.Behaviour` and the `Phoenix.Channel` contract
  (without `use Phoenix.Channel`) to route JSON-RPC messages between a
  browser (MCP client) and the Muse HTTP bridge.

  ## Topic format

      mcp:<session_id>

  ## Session registry

  Uses two named public ETS tables:

    * `:mcp_channel_sessions` — stores `{session_id, ChannelSender.t()}`
    * `:mcp_awaiting_answers` — stores `{{session_id, request_id}, {monitor_ref, from_pid}}`

  The channel is opt-in via config:

      config :muse, :weft, enabled_channels: ["mcp"]
  """

  @behaviour Muse.Weft.Behaviour

  alias Muse.Weft.ChannelSender
  alias MuseWeb.ExternalEventFilter

  @sessions_table :mcp_channel_sessions
  @awaiting_table :mcp_awaiting_answers

  # -- Phoenix.Channel contract ------------------------------------------------

  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      shutdown: 5000,
      restart: :temporary
    }
  end

  def start_link(triplet) do
    GenServer.start_link(Phoenix.Channel.Server, triplet, hibernate_after: 15_000)
  end

  def __intercepts__, do: []

  def __socket__(:private) do
    %{log_join: :info, log_handle_in: :debug}
  end

  # -- Config ------------------------------------------------------------------

  defp mcp_enabled? do
    Application.get_env(:muse, :weft, [])
    |> Keyword.get(:enabled_channels, [])
    |> Enum.member?("mcp")
  end

  # -- ETS tables --------------------------------------------------------------

  @doc """
  Create the :ets tables used by this channel if they don't already exist.
  """
  def ensure_tables do
    if :ets.whereis(@sessions_table) == :undefined do
      :ets.new(@sessions_table, [:named_table, :public, :set, read_concurrency: true])
    end

    if :ets.whereis(@awaiting_table) == :undefined do
      :ets.new(@awaiting_table, [:named_table, :public, :set])
    end

    :ok
  end

  # -- Phoenix.Channel join ----------------------------------------------------

  def join("mcp:" <> _ = topic, payload, socket) do
    case init(topic, payload, socket) do
      {:ok, socket} ->
        # Ensure the stored sender has joined: true so server-side
        # pushes (e.g. from the HTTP handler) work correctly.
        sender = ChannelSender.from_socket(%{socket | joined: true})
        session_id = socket.assigns.mcp_session_id
        :ets.insert(@sessions_table, {session_id, sender})
        socket = Phoenix.Socket.assign(socket, :mcp_sender, sender)
        {:ok, socket}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  # -- Muse.Weft.Behaviour init ------------------------------------------------

  @impl Muse.Weft.Behaviour
  def init(topic, _payload, socket) do
    if not mcp_enabled?() do
      {:error, "mcp_channel_disabled"}
    else
      ensure_tables()

      case String.split(topic, ":", parts: 2) do
        ["mcp", session_id] ->
          if ExternalEventFilter.valid_session_id?(session_id) do
            sender = ChannelSender.from_socket(socket)
            :ets.insert(@sessions_table, {session_id, sender})

            socket =
              socket
              |> Phoenix.Socket.assign(:mcp_session_id, session_id)
              |> Phoenix.Socket.assign(:mcp_sender, sender)

            {:ok, socket}
          else
            {:error, "invalid_session_id"}
          end

        _ ->
          {:error, "invalid_topic"}
      end
    end
  end

  # -- Muse.Weft.Behaviour handle_in ------------------------------------------

  @impl Muse.Weft.Behaviour
  def handle_in("mcp_message", %{"id" => nil}, socket) do
    {:noreply, socket}
  end

  def handle_in("mcp_message", %{"id" => request_id} = payload, socket)
      when not is_nil(request_id) do
    if not mcp_enabled?() do
      {:noreply, socket}
    else
      session_id = socket.assigns.mcp_session_id

      case consume_awaiting_answer(session_id, request_id) do
        {:ok, {_ref, pid}} ->
          send(pid, {:mcp_response, payload})
          {:noreply, socket}

        :error ->
          {:noreply, socket}
      end
    end
  end

  def handle_in("mcp_message", _payload, socket) do
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  # -- Muse.Weft.Behaviour terminate -------------------------------------------

  @impl Muse.Weft.Behaviour
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :mcp_session_id) do
      nil ->
        :ok

      session_id ->
        :ets.delete(@sessions_table, session_id)
        error_pending_answers(session_id, "Browser disconnected")
        :ok
    end
  end

  # -- Public API (HTTP bridge) ------------------------------------------------

  @doc """
  Look up the `ChannelSender` for a connected session.
  """
  @spec lookup_sender(String.t()) ::
          {:ok, ChannelSender.t()} | {:error, :not_connected | :disabled}
  def lookup_sender(session_id) when is_binary(session_id) do
    if mcp_enabled?() do
      ensure_tables()

      case :ets.lookup(@sessions_table, session_id) do
        [{^session_id, sender}] -> {:ok, sender}
        [] -> {:error, :not_connected}
      end
    else
      {:error, :disabled}
    end
  end

  @doc """
  Register a one-shot awaiting answer.

  Monitors the channel process for the given session and stores
  `{{session_id, request_id}, {monitor_ref, from_pid}}` in ETS.
  """
  @spec register_awaiting_answer(String.t(), term(), pid()) ::
          {:ok, reference()} | {:error, :not_connected | :disabled}
  def register_awaiting_answer(session_id, request_id, from_pid)
      when is_binary(session_id) and is_pid(from_pid) do
    if mcp_enabled?() do
      ensure_tables()

      case lookup_sender(session_id) do
        {:ok, %ChannelSender{socket: socket}} ->
          channel_pid = socket.channel_pid
          ref = Process.monitor(channel_pid)
          :ets.insert(@awaiting_table, {{session_id, request_id}, {ref, from_pid}})
          {:ok, ref}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :disabled}
    end
  end

  @doc """
  Atomically get-and-delete a pending awaiting-answer registration.
  """
  @spec consume_awaiting_answer(String.t(), term()) ::
          {:ok, {reference(), pid()}} | :error | {:error, :disabled}
  def consume_awaiting_answer(session_id, request_id) when is_binary(session_id) do
    if mcp_enabled?() do
      ensure_tables()

      case :ets.take(@awaiting_table, {session_id, request_id}) do
        [{{^session_id, ^request_id}, value}] -> {:ok, value}
        [] -> :error
      end
    else
      {:error, :disabled}
    end
  end

  @doc """
  Error all pending awaiting answers for a session and remove them.
  """
  @spec error_pending_answers(String.t(), String.t()) :: :ok | {:error, :disabled}
  def error_pending_answers(session_id, reason) when is_binary(session_id) do
    if mcp_enabled?() do
      ensure_tables()

      entries = :ets.match_object(@awaiting_table, {{session_id, :_}, :_})

      Enum.each(entries, fn {{^session_id, _request_id}, {_ref, pid}} ->
        send(pid, {:mcp_error, reason})
      end)

      :ets.match_delete(@awaiting_table, {{session_id, :_}, :_})
      :ok
    else
      {:error, :disabled}
    end
  end
end
