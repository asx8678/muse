defmodule Muse.SubAgent do
  @moduledoc """
  Ephemeral worker GenServer for performing specialized tasks.

  SubAgents are spawned by `Muse.SubAgentPool` on behalf of a session
  to perform work (`:coder`, `:reviewer`, `:scout`) concurrently without
  blocking the main session process.

  ## Lifecycle

  1. **Spawned** — started under the SubAgentPool DynamicSupervisor
  2. **Started** — sends `{:worker_started, pid, type, task_id}` to parent
  3. **Execute** — parent sends `{:execute, task}` to begin work
  4. **Running** — worker performs its task, sending progress via
     `{:worker_log, pid, type, message}`
  5. **Completed** — sends `{:worker_completed, pid, type, result}` to parent
  6. **Terminated** — worker stops itself after completion or failure

  On failure: sends `{:worker_failed, pid, type, reason}` to parent.

  ## Timeout

  Workers that run longer than `max_duration` (default 300s) are killed
  by a timeout timer. The parent receives a `{:worker_failed, ...}`
  message with reason `:timeout`.

  ## Parent monitoring

  Workers monitor their parent process. If the parent dies, the worker
  auto-terminates (preventing orphans).

  ## VFS integration

    * `:coder` — checks out files via `ActiveVFS.checkout/2`, edits, and
      commits back via `ActiveVFS.commit/4`. Releases all locks on
      completion or termination.
    * `:scout` — reads files via `ActiveVFS.read/1` (no lock needed).
    * `:reviewer` — reads files for review (no lock needed).

  ## Communication protocol

  Parent → Worker:

    * `{:execute, task}` — begin work
    * `{:cancel}` — cancel work (worker exits with reason `:killed`)

  Worker → Parent (via `send/2`):

    * `{:worker_started, pid, type, task_id}`
    * `{:worker_log, pid, type, message}`
    * `{:worker_completed, pid, type, result}`
    * `{:worker_failed, pid, type, reason}`
  """

  use GenServer, restart: :temporary

  require Logger

  alias Muse.ActiveVFS

  @default_max_duration_ms 300_000

  # ── Types ───────────────────────────────────────────────────────────

  @type worker_type :: :coder | :reviewer | :scout
  @type status :: :initialized | :running | :completed | :failed

  @type state :: %{
          id: String.t(),
          type: worker_type(),
          task_id: String.t(),
          parent_pid: pid(),
          pool_pid: pid(),
          task: map(),
          status: status(),
          result: term(),
          started_at: DateTime.t(),
          max_duration_ms: non_neg_integer(),
          checked_out_files: [String.t()],
          vfs_pid: pid() | nil
        }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Starts a SubAgent worker.

  Called by `Muse.SubAgentPool.spawn_worker/3` — not typically called directly.

  ## Init map keys

    * `:type` — `:coder`, `:reviewer`, or `:scout` (required)
    * `:task` — task description map (required)
    * `:parent_pid` — the session/agent that spawned this (required)
    * `:pool_pid` — the DynamicSupervisor managing this (required)
    * `:vfs_pid` — the ActiveVFS pid (optional, defaults to ActiveVFS)
    * `:max_duration_ms` — timeout in ms (optional, default 300_000)

  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(init_map) when is_map(init_map) do
    GenServer.start_link(__MODULE__, init_map)
  end

  @doc """
  Returns a summary of the worker's current state.

  Used by `SubAgentPool.list_workers/1` to enumerate workers.
  """
  @spec get_info(pid()) :: map() | nil
  def get_info(pid) when is_pid(pid) do
    GenServer.call(pid, :get_info)
  catch
    :exit, _ -> nil
  end

  @doc """
  Returns the worker's status atom.
  """
  @spec status(pid()) :: status() | nil
  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  catch
    :exit, _ -> nil
  end

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def init(init_map) do
    type = Map.fetch!(init_map, :type)
    task = Map.fetch!(init_map, :task)
    parent_pid = Map.fetch!(init_map, :parent_pid)
    pool_pid = Map.fetch!(init_map, :pool_pid)

    task_id =
      Map.get(task, :task_id) ||
        "#{type}-#{:erlang.unique_integer([:positive, :monotonic])}"

    max_duration_ms = Map.get(init_map, :max_duration_ms, @default_max_duration_ms)
    vfs_pid = Map.get(init_map, :vfs_pid)

    state = %{
      id: "sub-agent-#{:erlang.unique_integer([:positive, :monotonic])}",
      type: type,
      task_id: task_id,
      parent_pid: parent_pid,
      pool_pid: pool_pid,
      task: task,
      status: :initialized,
      result: nil,
      started_at: DateTime.utc_now(),
      max_duration_ms: max_duration_ms,
      checked_out_files: [],
      vfs_pid: vfs_pid
    }

    # Monitor parent — if it dies, we auto-terminate
    Process.monitor(parent_pid)

    # Notify parent that worker has started
    send(parent_pid, {:worker_started, self(), type, task_id})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.id,
      type: state.type,
      task_id: state.task_id,
      status: state.status
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({:execute, task}, state) do
    # Start timeout timer
    timer_ref = Process.send_after(self(), :timeout, state.max_duration_ms)

    # Update state
    state = %{state | status: :running, task: Map.merge(state.task, task)}

    # Store timer ref in process dictionary for cancellation
    Process.put(:timeout_timer, timer_ref)

    # Dispatch based on type
    result = execute_for_type(state)

    case result do
      {:ok, value} ->
        complete(state, value)

      {:error, reason} ->
        fail(state, reason)
    end

    {:noreply, %{state | status: :completed, result: result}}
  end

  @impl true
  def handle_info({:cancel}, state) do
    # Release any VFS locks before exiting
    release_vfs_locks(state)
    send(state.parent_pid, {:worker_failed, self(), state.type, :cancelled})
    :erlang.exit(self(), :killed)
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning(
      "SubAgent #{state.id} (#{state.type}) timed out after #{state.max_duration_ms}ms"
    )

    release_vfs_locks(state)
    send(state.parent_pid, {:worker_failed, self(), state.type, :timeout})
    {:stop, {:shutdown, :timeout}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, parent_pid, reason}, %{parent_pid: parent_pid} = state) do
    # Parent died — clean up and terminate
    Logger.debug("SubAgent #{state.id}: parent died (#{inspect(reason)}), terminating")
    release_vfs_locks(state)
    {:stop, {:shutdown, :parent_died}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Monitored process other than parent died — ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("SubAgent #{state.id} terminating: #{inspect(reason)}")

    # Always release VFS locks on termination
    release_vfs_locks(state)

    # Cancel timeout timer if still running
    case Process.get(:timeout_timer) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    # Notify parent if we haven't already (crash case)
    if state.status == :running do
      send(state.parent_pid, {:worker_failed, self(), state.type, reason})
    end

    :ok
  end

  # ── Type-specific execution ────────────────────────────────────────

  defp execute_for_type(%{type: :coder} = state) do
    files = Map.get(state.task, :files, [])
    instructions = Map.get(state.task, :instructions, "")
    _vfs = state.vfs_pid

    checked_out =
      files
      |> Enum.reduce({[], []}, fn path, {ok_acc, err_acc} ->
        case ActiveVFS.checkout(path, agent_id: state.id) do
          {:ok, _version} ->
            send(state.parent_pid, {:worker_log, self(), :coder, "Checked out #{path}"})
            {[path | ok_acc], err_acc}

          {:error, reason} ->
            send(
              state.parent_pid,
              {:worker_log, self(), :coder, "Checkout failed for #{path}: #{inspect(reason)}"}
            )

            {ok_acc, [{path, reason} | err_acc]}
        end
      end)
      |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)

    # Store checked-out files in state for release on termination
    # (We update via process dictionary since handle_info can't return new state)
    {checked_out_files, failed_checkouts} = checked_out
    Process.put(:checked_out_files, checked_out_files)

    if failed_checkouts != [] do
      {:error, {:checkout_failed, failed_checkouts}}
    else
      # For now, return the checkout info as the result.
      # Real implementation would call an LLM here.
      send(state.parent_pid, {:worker_log, self(), :coder, "Executing: #{instructions}"})

      {:ok,
       %{
         files_checked_out: checked_out_files,
         instructions: instructions,
         message: "Coder task placeholder — real LLM integration pending"
       }}
    end
  end

  defp execute_for_type(%{type: :scout} = state) do
    files = Map.get(state.task, :files, [])
    query = Map.get(state.task, :query, "")

    results =
      files
      |> Enum.reduce([], fn path, acc ->
        case ActiveVFS.read(path) do
          {:ok, content} ->
            send(state.parent_pid, {:worker_log, self(), :scout, "Read #{path}"})
            summary = summarize_for_scout(path, content, query)
            [{path, summary} | acc]

          {:error, reason} ->
            send(
              state.parent_pid,
              {:worker_log, self(), :scout, "Read failed for #{path}: #{inspect(reason)}"}
            )

            acc
        end
      end)
      |> Enum.reverse()

    {:ok,
     %{
       query: query,
       files_searched: length(files),
       results: results,
       message: "Scout task placeholder — real search integration pending"
     }}
  end

  defp execute_for_type(%{type: :reviewer} = state) do
    target = Map.get(state.task, :review_target, Map.get(state.task, :files, []))

    reviewed =
      target
      |> Enum.reduce([], fn path, acc ->
        case ActiveVFS.read(path) do
          {:ok, content} ->
            send(state.parent_pid, {:worker_log, self(), :reviewer, "Reviewing #{path}"})
            review = review_file_content(path, content)
            [{path, review} | acc]

          {:error, reason} ->
            send(
              state.parent_pid,
              {:worker_log, self(), :reviewer, "Read failed for #{path}: #{inspect(reason)}"}
            )

            acc
        end
      end)
      |> Enum.reverse()

    {:ok,
     %{
       review_target: target,
       reviews: reviewed,
       message: "Reviewer task placeholder — real review integration pending"
     }}
  end

  # ── Completion / failure helpers ────────────────────────────────────

  defp complete(state, result) do
    # Release VFS locks
    release_vfs_locks(state)

    # Cancel timeout timer
    case Process.get(:timeout_timer) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    send(state.parent_pid, {:worker_completed, self(), state.type, result})
  end

  defp fail(state, reason) do
    # Release VFS locks
    release_vfs_locks(state)

    # Cancel timeout timer
    case Process.get(:timeout_timer) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    send(state.parent_pid, {:worker_failed, self(), state.type, reason})
  end

  # ── VFS lock management ────────────────────────────────────────────

  defp release_vfs_locks(state) do
    # Release any files checked out by this coder
    checked_out = Process.get(:checked_out_files) || state.checked_out_files

    if state.type == :coder and checked_out != [] do
      ActiveVFS.release_all_for_agent(state.id)
      Process.delete(:checked_out_files)
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── Placeholder helpers (real LLM integration pending) ────────────

  defp summarize_for_scout(path, content, _query) do
    line_count = content |> String.split("\n") |> length()
    byte_size = byte_size(content)
    "File #{path}: #{line_count} lines, #{byte_size} bytes"
  end

  defp review_file_content(path, content) do
    line_count = content |> String.split("\n") |> length()
    "File #{path}: #{line_count} lines — review placeholder"
  end
end
