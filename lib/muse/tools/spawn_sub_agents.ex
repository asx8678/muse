defmodule Muse.Tools.SpawnSubAgents do
  @moduledoc """
  Tool for spawning worker sub-agents to perform tasks in parallel.

  The LLM calls this tool with a list of worker specifications. Each worker
  is spawned under the session's `Muse.SubAgentPool` and begins executing
  immediately. The tool returns instantly (non-blocking) with worker IDs;
  results arrive asynchronously via message passing to the SessionServer.

  ## Worker types

    * `coder` — checks out files via ActiveVFS, edits, commits back
    * `reviewer` — reads files for review (no lock needed)
    * `scout` — reads and searches files (no lock needed)

  ## Asynchronous result protocol

  The SessionServer receives these messages as workers complete:

    * `{:worker_completed, pid, type, result}` — success
    * `{:worker_failed, pid, type, reason}` — failure (includes :timeout)

  ## Arguments

    * `"workers"` — array of worker spec objects, each with:
      * `"type"` — `"coder"`, `"reviewer"`, or `"scout"` (required)
      * `"task_id"` — unique identifier for the worker (required)
      * `"instructions"` — detailed task description (required)
      * `"files"` — list of workspace-relative file paths (optional)
      * `"max_duration_ms"` — per-worker timeout in ms (optional, default 300_000)

  ## Context requirements

    * `:sub_agent_pool` — pid of the session-scoped SubAgentPool (preferred)
    * `:session_id` — used to look up pool by registered name (fallback)

  ## Output

      %{
        spawned_count: N,
        worker_ids: [%{task_id: "...", pid: "...", type: "..."}],
        errors: [%{task_id: "...", error: "..."}]
      }
  """

  alias Muse.SubAgentPool
  alias Muse.Tool.Result

  @valid_types ~w(coder reviewer scout)
  @type_map %{"coder" => :coder, "reviewer" => :reviewer, "scout" => :scout}
  @default_max_duration_ms 300_000

  @doc """
  Execute the spawn_sub_agents tool.

  Spawns each worker spec under the session's SubAgentPool and returns
  immediately with the spawned worker IDs. Workers that fail to spawn
  are reported in the `errors` list.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    pool_pid = resolve_pool(context)

    cond do
      is_nil(pool_pid) ->
        Result.error(
          "spawn_sub_agents",
          "sub_agent_pool not available (session may not have a pool)"
        )

      not Process.alive?(pool_pid) ->
        Result.error("spawn_sub_agents", "sub_agent_pool process is not alive")

      true ->
        do_spawn(args, pool_pid)
    end
  end

  # Try to resolve the SubAgentPool pid from context.
  # 1. Direct :sub_agent_pool key in context (preferred)
  # 2. Look up by registered name based on session_id
  defp resolve_pool(context) do
    case Map.get(context, :sub_agent_pool) do
      pid when is_pid(pid) -> pid
      _ -> pool_from_session_id(Map.get(context, :session_id))
    end
  end

  defp pool_from_session_id(nil), do: nil

  defp pool_from_session_id(session_id) when is_binary(session_id) do
    pool_name = :"muse_sub_agent_pool_#{session_id}"
    Process.whereis(pool_name)
  end

  defp do_spawn(args, pool_pid) do
    workers = Map.get(args, "workers", [])

    if not is_list(workers) do
      Result.error("spawn_sub_agents", "workers must be a list")
    else
      {spawned, errors} =
        workers
        |> Enum.reduce({[], []}, fn worker_spec, {spawned_acc, error_acc} ->
          spawn_single_worker(worker_spec, pool_pid, spawned_acc, error_acc)
        end)

      Result.ok("spawn_sub_agents", %{
        spawned_count: length(spawned),
        worker_ids: Enum.reverse(spawned),
        errors: Enum.reverse(errors)
      })
    end
  end

  defp spawn_single_worker(worker_spec, pool_pid, spawned_acc, error_acc) do
    task_id = Map.get(worker_spec, "task_id")
    type_str = Map.get(worker_spec, "type")
    instructions = Map.get(worker_spec, "instructions", "")

    cond do
      is_nil(task_id) or task_id == "" ->
        {spawned_acc,
         [%{task_id: task_id || "(missing)", error: "task_id is required"} | error_acc]}

      type_str not in @valid_types ->
        {spawned_acc,
         [
           %{
             task_id: task_id,
             error:
               "invalid type: #{inspect(type_str)}. Must be one of: #{Enum.join(@valid_types, ", ")}"
           }
           | error_acc
         ]}

      instructions == "" ->
        {spawned_acc, [%{task_id: task_id, error: "instructions is required"} | error_acc]}

      true ->
        type_atom = Map.fetch!(@type_map, type_str)
        files = Map.get(worker_spec, "files", [])
        _max_duration_ms = Map.get(worker_spec, "max_duration_ms", @default_max_duration_ms)

        task = %{
          task_id: task_id,
          instructions: instructions,
          files: files
        }

        case SubAgentPool.spawn_worker(pool_pid, type_atom, task) do
          {:ok, pid} ->
            # Send the execute message so the worker begins work
            send(pid, {:execute, task})

            entry = %{
              task_id: task_id,
              pid: pid_to_string(pid),
              type: type_str
            }

            {[entry | spawned_acc], error_acc}

          {:error, :pool_full} ->
            {spawned_acc, [%{task_id: task_id, error: "pool is full"} | error_acc]}

          {:error, :already_spawned} ->
            {spawned_acc,
             [%{task_id: task_id, error: "worker already spawned with this task_id"} | error_acc]}

          {:error, reason} ->
            {spawned_acc,
             [%{task_id: task_id, error: "spawn failed: #{inspect(reason)}"} | error_acc]}
        end
    end
  end

  defp pid_to_string(pid) when is_pid(pid), do: :erlang.pid_to_list(pid) |> to_string()
end
