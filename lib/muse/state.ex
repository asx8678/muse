defmodule Muse.State do
  @moduledoc """
  Globally-named GenServer that holds the ordered event log and broadcasts
  every new event on `Muse.PubSub`.

  The topic string is an implementation detail — consumers call `subscribe/0`
  or `subscribe/1` and receive `{:muse_event, %Muse.Event{}}` messages.

  ## Session-scoped topics

  Events can be broadcast on both a global topic (`"muse:events"`) for
  backward compatibility and a session-scoped topic
  (`"muse:events:<session_id>"`) so individual LiveView tabs only receive
  events for their own session.  Call `subscribe/1` with a session ID to
  listen on a scoped topic; `subscribe/0` subscribes to the `"default"`
  session topic.

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

  @spec append(Muse.Event.t(), String.t()) :: :ok
  def append(event, session_id \\ "default") do
    GenServer.call(__MODULE__, {:append, event, session_id})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: subscribe("default")

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session_id) do
    case Phoenix.PubSub.subscribe(Muse.PubSub, "muse:events:#{session_id}") do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(session_id) do
    Phoenix.PubSub.unsubscribe(Muse.PubSub, "muse:events:#{session_id}")
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
  def handle_call({:append, event, session_id}, _from, state) do
    # Prepend for O(1), then trim to max_events (drops oldest when over cap)
    updated = [event | state.events] |> Enum.take(state.max_events)
    # Broadcast on global topic for backward compat with existing consumers
    Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_event, event})
    # Broadcast on session-scoped topic so tab-scoped LiveViews receive events
    Phoenix.PubSub.broadcast(
      Muse.PubSub,
      "muse:events:#{session_id}",
      {:muse_event, event}
    )

    {:reply, :ok, %{state | events: updated}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_events_cleared})
    Phoenix.PubSub.broadcast(Muse.PubSub, "muse:events:default", {:muse_events_cleared})
    {:reply, :ok, %{state | events: []}}
  end
end
