defmodule Muse.Execution.TargetRegistry do
  @moduledoc """
  ETS-based registry for execution target descriptors.

  Stores `Muse.Execution.Target` structs keyed by target id. Never
  stores or emits credentials — only opaque `credential_ref` values
  are stored alongside the target descriptor.

  ## Safety properties

    * ETS table is `:protected` — only the registry GenServer (owner) can write;
      callers can still read via `fetch/1`, `get/1`, `get!/1`, `list/0`.
    * Events emitted by this registry use `Target.safe_payload/1` —
      never include `user`, `credential_ref`, or `connection_opts`.
    * No `String.to_atom/1` — all target/protocol lookups use explicit
      maps with pre-defined keys.
    * API returns `%Target{}` structs, not raw ETS tuples.

  ## Events

  When `Muse.State` is running, emits:

    * `:target_registered` — on register
    * `:target_updated` — on update
    * `:target_removed` — on remove

  All events use `Target.safe_payload/1` for their data payload.

  ## Usage

      {:ok, target} = Muse.Execution.Target.new("tgt_staging", protocol: :fake, host: "staging.io")
      :ok = Muse.Execution.TargetRegistry.register(target)
      {:ok, fetched} = Muse.Execution.TargetRegistry.fetch("tgt_staging")
  """

  use GenServer

  alias Muse.Execution.Target

  @table __MODULE__
  @registry_name __MODULE__

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @registry_name))
  end

  @doc """
  Register a target in the registry.

  Returns `:ok` on success, `{:error, reason}` on failure.
  Emits `:target_registered` event if `Muse.State` is running.
  """
  @spec register(Target.t()) :: :ok | {:error, String.t()}
  def register(%Target{} = target) do
    GenServer.call(@registry_name, {:register, target})
  end

  @doc """
  Fetch a target by id.

  Returns `{:ok, %Target{}}` if found, `{:error, :not_found}` otherwise.
  """
  @spec fetch(String.t()) :: {:ok, Target.t()} | {:error, :not_found}
  def fetch(target_id) when is_binary(target_id) do
    case :ets.lookup(@table, target_id) do
      [{^target_id, %Target{} = target}] -> {:ok, target}
      _ -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Get a target by id, returning nil if not found.
  """
  @spec get(String.t()) :: Target.t() | nil
  def get(target_id) when is_binary(target_id) do
    case fetch(target_id) do
      {:ok, target} -> target
      {:error, :not_found} -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Get a target by id, raising if not found.
  """
  @spec get!(String.t()) :: Target.t()
  def get!(target_id) when is_binary(target_id) do
    case fetch(target_id) do
      {:ok, target} -> target
      {:error, :not_found} -> raise ArgumentError, "target not found: #{target_id}"
    end
  end

  @doc """
  List all registered targets.
  """
  @spec list() :: [Target.t()]
  def list do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, target} -> target end)
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Update an existing target in the registry.

  Returns `:ok` on success, `{:error, :not_found}` if target doesn't exist.
  Emits `:target_updated` event if `Muse.State` is running.
  """
  @spec update(Target.t()) :: :ok | {:error, :not_found}
  def update(%Target{} = target) do
    GenServer.call(@registry_name, {:update, target})
  end

  @doc """
  Remove a target by id.

  Returns `:ok` on success, `{:error, :not_found}` if target doesn't exist.
  Emits `:target_removed` event if `Muse.State` is running.
  """
  @spec remove(String.t()) :: :ok | {:error, :not_found}
  def remove(target_id) when is_binary(target_id) do
    GenServer.call(@registry_name, {:remove, target_id})
  end

  @doc """
  Clear all targets from the registry.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(@registry_name, :clear)
  end

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, %{table: table, name: Keyword.get(opts, :name, @registry_name)}}
  end

  @impl true
  def handle_call({:register, %Target{} = target}, _from, state) do
    :ets.insert(@table, {target.id, target})
    emit_event(:target_registered, target)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, %Target{} = target}, _from, state) do
    case :ets.lookup(@table, target.id) do
      [{_, _existing}] ->
        updated = %{target | updated_at: DateTime.utc_now()}
        :ets.insert(@table, {target.id, updated})
        emit_event(:target_updated, updated)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:remove, target_id}, _from, state) do
    case :ets.lookup(@table, target_id) do
      [{_, %Target{} = target}] ->
        :ets.delete(@table, target_id)
        emit_event(:target_removed, target)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # -- Event emission -----------------------------------------------------------

  defp emit_event(event_type, %Target{} = target) do
    # Only emit if Muse.State is running
    if state_running?() do
      safe_data = Target.safe_payload(target)
      event = Muse.Event.new(:target_registry, event_type, safe_data, visibility: :internal)
      Muse.State.append(event)
    end

    :ok
  rescue
    # Never crash the registry if event emission fails
    _ -> :ok
  end

  defp state_running? do
    case Process.whereis(Muse.State) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  rescue
    _ -> false
  end
end
