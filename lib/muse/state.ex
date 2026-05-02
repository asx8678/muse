defmodule Muse.State do
  @moduledoc """
  Globally-named GenServer that holds the ordered event log and broadcasts
  every new event on `Muse.PubSub`.

  The topic string is an implementation detail — consumers call `subscribe/0`
  and receive `{:muse_event, %Muse.Event{}}` messages.
  """

  use GenServer

  @topic "muse:events"

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: %{events: [Muse.Event.t()]}
  def get, do: GenServer.call(__MODULE__, :get)

  @spec events() :: [Muse.Event.t()]
  def events, do: GenServer.call(__MODULE__, :events)

  @spec append(Muse.Event.t()) :: :ok
  def append(event), do: GenServer.call(__MODULE__, {:append, event})

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    case Phoenix.PubSub.subscribe(Muse.PubSub, @topic) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{events: []}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:events, _from, state) do
    {:reply, state.events, state}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    new_state = %{state | events: state.events ++ [event]}
    Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_event, event})
    {:reply, :ok, new_state}
  end
end
