defmodule Muse.AgentRuntime do
  @moduledoc """
  Simple universal agent runtime state manager.

  Maintains connection state and broadcasts updates via PubSub.
  No websocket dependency — `connect/1` transitions state and
  returns a clear status. Real transport can be added later.
  """

  use GenServer

  @topic "muse:agent_runtime"
  @default_endpoint "ws://localhost:4000"

  @type status :: :disconnected | :connecting | :connected | :error
  @type health :: :inactive | :healthy | :warning | :error

  @type snapshot :: %{
          status: status(),
          endpoint: String.t(),
          last_attempt_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          health: health()
        }

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec snapshot() :: snapshot()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:error, :pubsub_unavailable}

      _pid ->
        Phoenix.PubSub.subscribe(Muse.PubSub, @topic)
    end
  end

  @spec set_endpoint(String.t()) :: :ok
  def set_endpoint(endpoint), do: GenServer.call(__MODULE__, {:set_endpoint, endpoint})

  @spec connect(String.t() | nil) :: {:ok, snapshot()} | {:error, String.t()}
  def connect(endpoint \\ nil) do
    GenServer.call(__MODULE__, {:connect, endpoint})
  end

  @spec retry() :: {:ok, snapshot()} | {:error, String.t()}
  def retry, do: GenServer.call(__MODULE__, :retry)

  @spec disconnect() :: {:ok, snapshot()}
  def disconnect, do: GenServer.call(__MODULE__, :disconnect)

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      status: :disconnected,
      endpoint: @default_endpoint,
      last_attempt_at: nil,
      last_error: nil,
      health: :inactive
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:set_endpoint, endpoint}, _from, state) do
    new_state = %{state | endpoint: normalize_endpoint(endpoint, state.endpoint)}
    broadcast_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:connect, endpoint}, _from, state) do
    endpoint = normalize_endpoint(endpoint, state.endpoint)
    now = DateTime.utc_now()

    # No real transport — transition to :error with clear message
    new_state = %{
      state
      | status: :error,
        endpoint: endpoint,
        last_attempt_at: now,
        last_error: "Runtime transport not configured",
        health: :error
    }

    broadcast_update(new_state)
    {:reply, {:error, "Runtime transport not configured"}, new_state}
  end

  @impl true
  def handle_call(:retry, _from, state) do
    now = DateTime.utc_now()

    new_state = %{
      state
      | status: :error,
        last_attempt_at: now,
        last_error: "Runtime transport not configured",
        health: :error
    }

    broadcast_update(new_state)
    {:reply, {:error, "Runtime transport not configured"}, new_state}
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    new_state = %{
      state
      | status: :disconnected,
        last_attempt_at: nil,
        last_error: nil,
        health: :inactive
    }

    broadcast_update(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  # -- Helpers -----------------------------------------------------------------

  @doc false
  @spec normalize_endpoint(term(), String.t()) :: String.t()
  def normalize_endpoint(nil, current), do: do_blank_fallback("", current)

  def normalize_endpoint(endpoint, current) when is_binary(endpoint) do
    trimmed = String.trim(endpoint)
    do_blank_fallback(trimmed, current)
  end

  def normalize_endpoint(endpoint, current),
    do: do_blank_fallback(safe_to_string(endpoint), current)

  defp safe_to_string(value) when is_binary(value), do: String.trim(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp do_blank_fallback(str, _current) when is_binary(str) and str != "", do: str
  defp do_blank_fallback(_str, current) when is_binary(current) and current != "", do: current
  defp do_blank_fallback(_str, _current), do: @default_endpoint

  defp broadcast_update(state) do
    case Process.whereis(Muse.PubSub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_agent_runtime_updated, state})
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
