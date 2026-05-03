defmodule Muse.AgentRegistry do
  @moduledoc """
  GenServer that tracks Muse registrations and broadcasts changes over PubSub.

  This is a foundation API — no real external Muse runtime is wired in yet.
  The UI can call `snapshot/0` to get current Muse state and `subscribe/0`
  to receive `{:muse_agent_registry_updated, snapshot}` broadcasts.

  Muse records are plain maps with the following fields:

    * `:id`          — unique identifier (string or atom)
    * `:name`        — display name
    * `:kind`        — atom categorising the Muse (e.g. `:coder`, `:reviewer`)
    * `:parent_id`   — optional parent Muse id
    * `:status`      — `:idle`, `:busy`, `:error`, `:unavailable`
    * `:progress`    — float 0.0–1.0 or nil
    * `:current_tool`— string or nil
    * `:current_file`— string or nil
    * `:task`        — string description or nil
    * `:updated_at`  — `DateTime.t()`

  ## Test-friendly options

    * `:name` — GenServer name (default `__MODULE__`)
  """

  use GenServer

  @pubsub_topic "muse:agent_registry"

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot() :: %{agents: [map()]}
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Muse.PubSub, @pubsub_topic)
  end

  @spec register_agent(map()) :: :ok
  def register_agent(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  @spec update_agent(term(), map()) :: :ok | {:error, :not_found}
  def update_agent(id, updates) when is_map(updates) do
    GenServer.call(__MODULE__, {:update, id, updates})
  end

  @spec unregister_agent(term()) :: :ok
  def unregister_agent(id) do
    GenServer.call(__MODULE__, {:unregister, id})
  end

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{agents: %{}}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{agents: Map.values(state.agents)}, state}
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    id = Map.fetch!(attrs, :id)
    now = DateTime.utc_now()

    agent =
      %{
        id: id,
        name: Map.get(attrs, :name, to_string(id)),
        kind: Map.get(attrs, :kind, :unknown),
        parent_id: Map.get(attrs, :parent_id),
        status: Map.get(attrs, :status, :idle),
        progress: Map.get(attrs, :progress),
        current_tool: Map.get(attrs, :current_tool),
        current_file: Map.get(attrs, :current_file),
        task: Map.get(attrs, :task),
        updated_at: now
      }

    new_state = put_in(state.agents[id], agent)
    broadcast_snapshot(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:update, id, updates}, _from, state) do
    case Map.get(state.agents, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      agent ->
        updated =
          agent
          |> Map.merge(updates)
          |> Map.put(:updated_at, DateTime.utc_now())

        new_state = put_in(state.agents[id], updated)
        broadcast_snapshot(new_state)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:unregister, id}, _from, state) do
    new_state = %{state | agents: Map.delete(state.agents, id)}
    broadcast_snapshot(new_state)
    {:reply, :ok, new_state}
  end

  # -- Private ------------------------------------------------------------------

  defp broadcast_snapshot(state) do
    snapshot = %{agents: Map.values(state.agents)}
    Phoenix.PubSub.broadcast(Muse.PubSub, @pubsub_topic, {:muse_agent_registry_updated, snapshot})
  end
end
