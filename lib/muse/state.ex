defmodule Muse.State do
  @moduledoc """
  Globally-named GenServer that holds the ordered event log and broadcasts
  every new event on `Muse.PubSub`.

  The topic string is an implementation detail — consumers call `subscribe/0`
  and receive `{:muse_event, %Muse.Event{}}` messages.

  ## Bounded storage

  Events are stored internally newest-first for O(1) prepend.  The public
  API (`events/0`, `get/0`) transparently reverses so consumers always see
  oldest-first order.  The event count is capped at `:max_events` (default
  `1_000`) — the oldest events are dropped when the cap
  is exceeded.
  """

  use GenServer

  @topic "muse:events"
  @default_max_events 1_000

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: %{events: [Muse.Event.t()]}
  def get, do: GenServer.call(__MODULE__, :get)

  @spec events() :: [Muse.Event.t()]
  def events, do: GenServer.call(__MODULE__, :events)

  @spec max_events() :: non_neg_integer()
  def max_events, do: GenServer.call(__MODULE__, :max_events)

  @spec append(Muse.Event.t()) :: :ok
  def append(event), do: GenServer.call(__MODULE__, {:append, event})

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    case Phoenix.PubSub.subscribe(Muse.PubSub, @topic) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    max_events = Keyword.get(opts, :max_events, @default_max_events)
    {:ok, %{events: [], max_events: max_events}}
  end

  @impl true
  def handle_call(:get, _from, %{events: events} = state) do
    {:reply, %{events: Enum.reverse(events)}, state}
  end

  @impl true
  def handle_call(:events, _from, %{events: events} = state) do
    {:reply, Enum.reverse(events), state}
  end

  @impl true
  def handle_call(:max_events, _from, %{max_events: max_events} = state) do
    {:reply, max_events, state}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    # Prepend for O(1), then trim to max_events (drops oldest when over cap)
    updated = [event | state.events] |> Enum.take(state.max_events)
    Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_event, event})
    {:reply, :ok, %{state | events: updated}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_events_cleared})
    {:reply, :ok, %{state | events: []}}
  end
end
