defmodule Muse.SubAgentPool do
  @moduledoc """
  DynamicSupervisor that manages ephemeral SubAgent workers.

  The SubAgentPool is responsible for spawning, tracking, and terminating
  temporary worker processes (`:coder`, `:reviewer`, `:scout`) on behalf of
  a session. Workers are `:temporary` — they do not restart on crash.

  ## Concurrency

  The pool enforces a `max_workers` cap (default 10). Attempts to spawn
  beyond the limit return `{:error, :pool_full}`.

  ## Duplicate prevention

  Spawning a worker with a `task_id` that already exists in the pool returns
  `{:error, :already_spawned}`.

  ## Usage

      {:ok, pool} = Muse.SubAgentPool.start_link(max_workers: 5)
      {:ok, pid} = Muse.SubAgentPool.spawn_worker(pool, :coder, %{task_id: "t1", ...})
      :ok = Muse.SubAgentPool.terminate_worker(pool, pid)
  """

  use DynamicSupervisor

  @default_max_workers 10
  @config_table :sub_agent_pool_config

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Starts the SubAgentPool DynamicSupervisor.

  ## Options

    * `:name` — supervisor name (default `__MODULE__`)
    * `:max_workers` — maximum concurrent workers (default 10)

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max_workers = Keyword.get(opts, :max_workers, @default_max_workers)

    DynamicSupervisor.start_link(__MODULE__, max_workers, name: name)
  end

  @doc """
  Spawns a new SubAgent worker under the pool.

  The worker is started with `restart: :temporary` — it will not be
  restarted if it crashes.

  ## Parameters

    * `pool` — pid or name of the SubAgentPool
    * `worker_type` — `:coder`, `:reviewer`, or `:scout`
    * `task` — map describing the work. Must include `:task_id`.

  ## Returns

    * `{:ok, pid}` — worker spawned successfully
    * `{:error, :pool_full}` — max_workers limit reached
    * `{:error, :already_spawned}` — a worker with the same task_id exists
    * `{:error, reason}` — child start failed

  """
  @spec spawn_worker(GenServer.server(), atom(), map()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_worker(pool, worker_type, task) when is_map(task) do
    task_id = Map.get(task, :task_id)
    max = get_max_workers(pool)

    # Check pool capacity
    if worker_count(pool) >= max do
      {:error, :pool_full}
    else
      # Check for duplicate task_id
      if task_id && task_id_already_exists?(pool, task_id) do
        {:error, :already_spawned}
      else
        parent_pid = self()

        child_spec =
          {Muse.SubAgent,
           %{
             type: worker_type,
             task: task,
             parent_pid: parent_pid,
             pool_pid: pool
           }}

        case DynamicSupervisor.start_child(pool, child_spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:error, {:already_started, pid}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Returns the number of currently running workers in the pool.
  """
  @spec worker_count(GenServer.server()) :: non_neg_integer()
  def worker_count(pool) do
    DynamicSupervisor.count_children(pool).active
  end

  @doc """
  Lists all workers in the pool as `[{pid, worker_type}]`.
  """
  @spec list_workers(GenServer.server()) :: [{pid(), atom()}]
  def list_workers(pool) do
    DynamicSupervisor.which_children(pool)
    |> Enum.flat_map(fn {_, pid, :worker, _modules} ->
      if is_pid(pid) do
        case Muse.SubAgent.get_info(pid) do
          %{type: type} -> [{pid, type}]
          _ -> []
        end
      else
        []
      end
    end)
  end

  @doc """
  Terminates a specific worker by pid.

  Returns `:ok` on success, `{:error, :not_found}` if the pid is not
  a child of this pool.
  """
  @spec terminate_worker(GenServer.server(), pid()) :: :ok | {:error, :not_found}
  def terminate_worker(pool, worker_pid) when is_pid(worker_pid) do
    case DynamicSupervisor.terminate_child(pool, worker_pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Terminates all workers in the pool.
  """
  @spec terminate_all(GenServer.server()) :: :ok
  def terminate_all(pool) do
    DynamicSupervisor.which_children(pool)
    |> Enum.each(fn {_, pid, :worker, _} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(pool, pid)
    end)

    :ok
  end

  # ── DynamicSupervisor callback ─────────────────────────────────────

  @impl true
  def init(max_workers) do
    ensure_config_table()
    :ets.insert(@config_table, {self(), max_workers})

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp ensure_config_table do
    case :ets.whereis(@config_table) do
      :undefined ->
        :ets.new(@config_table, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  end

  defp get_max_workers(pool) do
    pool_pid =
      case pool do
        pid when is_pid(pid) -> pid
        name -> GenServer.whereis(name)
      end

    case :ets.lookup(@config_table, pool_pid) do
      [{^pool_pid, max}] -> max
      [] -> @default_max_workers
    end
  rescue
    _ -> @default_max_workers
  end

  defp task_id_already_exists?(pool, task_id) do
    list_workers(pool)
    |> Enum.any?(fn {pid, _type} ->
      case Muse.SubAgent.get_info(pid) do
        %{task_id: ^task_id} -> true
        _ -> false
      end
    end)
  end
end
