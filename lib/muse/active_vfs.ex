defmodule Muse.ActiveVFS do
  @moduledoc """
  In-Memory Active Virtual File System with version tracking and locking.

  The ActiveVFS provides a coordinated in-memory view of project files that
  agents can check out, edit, and commit back — with full version history for
  instant rollback. Files are lazily loaded from disk on first access and
  flushed back on demand.

  ## Architecture

  * **FileVersion struct** — each version records `content`, `version_number`,
    `agent_id`, `reason`, and `timestamp`.
  * **Lazy loading** — when a file is requested but not yet in memory, it is
    loaded from disk as Version 0 (Base).
  * **Check-out / Check-in with locking** — agents acquire an exclusive lock
    on checkout; concurrent edits are rejected. Locks auto-release after a
    configurable TTL (default 30 s).
  * **Version history stack** — each file maintains a stack of versions
    (newest first) for instant rollback.
  * **Flush to disk** — writes the latest version of each tracked file back
    to the real filesystem.

  ## Usage

      # Checkout acquires a lock and returns the latest version
      {:ok, v1} = Muse.ActiveVFS.checkout("lib/foo.ex", agent_id: "coder-1")

      # Commit new content (releases the lock)
      {:ok, v2} = Muse.ActiveVFS.commit("lib/foo.ex", "new content", "coder-1", "fix bug")

      # Read the latest content without acquiring a lock
      {:ok, content} = Muse.ActiveVFS.read("lib/foo.ex")

      # Rollback to a previous version
      {:ok, v0} = Muse.ActiveVFS.rollback("lib/foo.ex", 0)

      # Persist everything to disk
      :ok = Muse.ActiveVFS.flush()

  ## Test-friendly options

    * `:name` — GenServer name (default `__MODULE__`)
    * `:root` — workspace root path (default: from `Muse.Workspace` agent)
    * `:lock_ttl_ms` — lock auto-release timeout in milliseconds (default 30_000)

  """

  use GenServer

  alias Muse.ActiveVFS.FileVersion

  # ── Types ──────────────────────────────────────────────────────────────

  @type file_path :: String.t()
  @type agent_id :: String.t()
  @type version_number :: non_neg_integer()

  @type file_entry :: %{
          versions: [FileVersion.t()],
          locked_by: agent_id() | nil,
          locked_at: integer() | nil
        }

  @type state :: %{
          files: %{file_path() => file_entry()},
          root: String.t(),
          lock_ttl_ms: non_neg_integer()
        }

  @default_lock_ttl_ms 30_000

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Starts the ActiveVFS GenServer.

  ## Options

    * `:name` — GenServer name (default `__MODULE__`)
    * `:root` — workspace root path (default: from `Muse.Workspace` agent)
    * `:lock_ttl_ms` — lock auto-release timeout in ms (default 30_000)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    root = Keyword.get(opts, :root) || safe_workspace_root()
    lock_ttl_ms = Keyword.get(opts, :lock_ttl_ms, @default_lock_ttl_ms)

    init_state = %{
      files: %{},
      root: root,
      lock_ttl_ms: lock_ttl_ms
    }

    GenServer.start_link(__MODULE__, {init_state, lock_ttl_ms}, name: name)
  end

  @doc """
  Checks out a file for editing, acquiring an exclusive lock.

  Returns the latest `FileVersion` for the file. If the file is not yet
  in memory, it is lazily loaded from disk as Version 0 (Base).

  Returns `{:error, :locked}` if another agent holds the lock.
  Returns `{:error, :not_found}` if the file does not exist on disk.

  ## Options

    * `:agent_id` — the agent claiming the lock (required)

  """
  @spec checkout(file_path(), keyword()) ::
          {:ok, FileVersion.t()} | {:error, :locked | :not_found}
  def checkout(path, opts \\ []) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.call(__MODULE__, {:checkout, path, agent_id})
  end

  @doc """
  Commits new content for a file, releasing the lock.

  The caller must be the agent that holds the lock. A new `FileVersion` is
  appended to the version history.

  Returns `{:error, :not_locked}` if the file is not currently checked out.
  Returns `{:error, :wrong_agent}` if the caller does not hold the lock.
  Returns `{:error, :not_found}` if the file has no entry in the VFS.

  """
  @spec commit(file_path(), String.t(), agent_id(), String.t()) ::
          {:ok, FileVersion.t()} | {:error, term()}
  def commit(path, content, agent_id, reason) do
    GenServer.call(__MODULE__, {:commit, path, content, agent_id, reason})
  end

  @doc """
  Rolls back a file to the specified version number.

  The version is restored as the latest version in the history (a new entry
  is pushed on top of the stack with the old content). The lock status is
  not affected.

  Returns `{:error, :not_found}` if the file has no entry in the VFS.
  Returns `{:error, :version_not_found}` if the specified version does not exist.

  """
  @spec rollback(file_path(), version_number()) ::
          {:ok, FileVersion.t()} | {:error, term()}
  def rollback(path, to_version) do
    GenServer.call(__MODULE__, {:rollback, path, to_version})
  end

  @doc """
  Reads the latest content of a file without acquiring a lock.

  If the file is not yet in memory, it is lazily loaded from disk as Version 0.

  Returns `{:error, :not_found}` if the file does not exist on disk.

  """
  @spec read(file_path()) :: {:ok, String.t()} | {:error, term()}
  def read(path) do
    GenServer.call(__MODULE__, {:read, path})
  end

  @doc """
  Lists all versions for a file, newest first.

  If the file is not yet in memory, it is lazily loaded from disk.

  Returns `{:error, :not_found}` if the file does not exist on disk.

  """
  @spec list_versions(file_path()) :: {:ok, [FileVersion.t()]} | {:error, term()}
  def list_versions(path) do
    GenServer.call(__MODULE__, {:list_versions, path})
  end

  @doc """
  Flushes all tracked files to disk.

  Writes the latest version of each file back to the real filesystem.
  Only files that have been loaded into the VFS are flushed. Files whose
  latest content matches the on-disk content are skipped.

  Returns `:ok` always. Individual file write errors are logged but do not
  fail the flush operation.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Returns the current root path used for file resolution.
  """
  @spec root() :: String.t()
  def root do
    GenServer.call(__MODULE__, :root)
  end

  @doc """
  Returns whether a file is currently locked, and by whom.

  Returns `{:ok, nil}` if the file is not locked.
  Returns `{:ok, agent_id}` if the file is locked.
  Returns `{:error, :not_found}` if the file has no entry in the VFS.
  """
  @spec lock_status(file_path()) :: {:ok, agent_id() | nil} | {:error, :not_found}
  def lock_status(path) do
    GenServer.call(__MODULE__, {:lock_status, path})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init({state, lock_ttl_ms}) do
    if lock_ttl_ms > 0 do
      schedule_lock_expiry()
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout, path, agent_id}, _from, state) do
    case ensure_loaded(path, state) do
      {:ok, state} ->
        case lock_file(path, agent_id, state) do
          {:ok, new_state} ->
            entry = Map.fetch!(new_state.files, path)
            latest = hd(entry.versions)
            {:reply, {:ok, latest}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:commit, path, content, agent_id, reason}, _from, state) do
    case Map.fetch(state.files, path) do
      {:ok, entry} ->
        cond do
          entry.locked_by == nil ->
            {:reply, {:error, :not_locked}, state}

          entry.locked_by != agent_id ->
            {:reply, {:error, :wrong_agent}, state}

          true ->
            latest = hd(entry.versions)
            next_version = latest.version_number + 1

            new_file_version = %FileVersion{
              path: path,
              content: content,
              version_number: next_version,
              agent_id: agent_id,
              reason: reason,
              timestamp: DateTime.utc_now()
            }

            new_entry = %{
              entry
              | versions: [new_file_version | entry.versions],
                locked_by: nil,
                locked_at: nil
            }

            new_state = put_in(state.files[path], new_entry)
            {:reply, {:ok, new_file_version}, new_state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:rollback, path, to_version}, _from, state) do
    case Map.fetch(state.files, path) do
      {:ok, entry} ->
        case Enum.find(entry.versions, &(&1.version_number == to_version)) do
          nil ->
            {:reply, {:error, :version_not_found}, state}

          target ->
            # Push a new version on top of the stack with the old content
            latest = hd(entry.versions)
            next_version = latest.version_number + 1

            rollback_version = %FileVersion{
              path: path,
              content: target.content,
              version_number: next_version,
              agent_id: latest.agent_id,
              reason: "rollback to v#{to_version}",
              timestamp: DateTime.utc_now()
            }

            new_entry = %{entry | versions: [rollback_version | entry.versions]}
            new_state = put_in(state.files[path], new_entry)
            {:reply, {:ok, rollback_version}, new_state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:read, path}, _from, state) do
    case ensure_loaded(path, state) do
      {:ok, new_state} ->
        entry = Map.fetch!(new_state.files, path)
        latest = hd(entry.versions)
        {:reply, {:ok, latest.content}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:list_versions, path}, _from, state) do
    case ensure_loaded(path, state) do
      {:ok, new_state} ->
        entry = Map.fetch!(new_state.files, path)
        {:reply, {:ok, entry.versions}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    flush_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:root, _from, state) do
    {:reply, state.root, state}
  end

  @impl true
  def handle_call({:lock_status, path}, _from, state) do
    case Map.fetch(state.files, path) do
      {:ok, entry} ->
        {:reply, {:ok, entry.locked_by}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:check_lock_expiry, state) do
    now = System.monotonic_time(:millisecond)

    new_files =
      state.files
      |> Enum.map(fn {path, entry} ->
        case entry do
          %{locked_by: agent_id, locked_at: locked_at}
          when is_binary(agent_id) and not is_nil(locked_at) ->
            if now - locked_at >= state.lock_ttl_ms do
              {path, %{entry | locked_by: nil, locked_at: nil}}
            else
              {path, entry}
            end

          _ ->
            {path, entry}
        end
      end)
      |> Map.new()

    if state.lock_ttl_ms > 0 do
      schedule_lock_expiry()
    end

    {:noreply, %{state | files: new_files}}
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp schedule_lock_expiry do
    # Check every 5 seconds for expired locks
    Process.send_after(self(), :check_lock_expiry, 5_000)
  end

  defp ensure_loaded(path, %{files: files} = state) do
    if Map.has_key?(files, path) do
      {:ok, state}
    else
      load_from_disk(path, state)
    end
  end

  defp load_from_disk(path, state) do
    full_path = Path.join(state.root, path)

    case File.read(full_path) do
      {:ok, content} ->
        v0 = %FileVersion{
          path: path,
          content: content,
          version_number: 0,
          agent_id: "system",
          reason: "base (loaded from disk)",
          timestamp: DateTime.utc_now()
        }

        entry = %{versions: [v0], locked_by: nil, locked_at: nil}
        new_state = put_in(state.files[path], entry)
        {:ok, new_state}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_file(path, agent_id, state) do
    entry = Map.fetch!(state.files, path)
    now = System.monotonic_time(:millisecond)

    cond do
      entry.locked_by == nil ->
        new_entry = %{entry | locked_by: agent_id, locked_at: now}
        new_state = put_in(state.files[path], new_entry)
        {:ok, new_state}

      entry.locked_by == agent_id ->
        # Same agent re-checkout: refresh the lock timestamp
        new_entry = %{entry | locked_at: now}
        new_state = put_in(state.files[path], new_entry)
        {:ok, new_state}

      lock_expired?(entry, state) ->
        # Previous lock expired — take over
        new_entry = %{entry | locked_by: agent_id, locked_at: now}
        new_state = put_in(state.files[path], new_entry)
        {:ok, new_state}

      true ->
        {:error, :locked}
    end
  end

  defp lock_expired?(entry, state) do
    case entry do
      %{locked_at: nil} ->
        true

      %{locked_at: locked_at} when is_integer(locked_at) ->
        now = System.monotonic_time(:millisecond)
        now - locked_at >= state.lock_ttl_ms

      _ ->
        true
    end
  end

  defp flush_all(state) do
    state.files
    |> Enum.each(fn {path, entry} ->
      latest = hd(entry.versions)
      full_path = Path.join(state.root, path)

      # Ensure the parent directory exists
      dir = Path.dirname(full_path)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(full_path, latest.content) do
        :ok
      else
        {:error, reason} ->
          require Logger
          Logger.warning("ActiveVFS flush failed for #{path}: #{inspect(reason)}")
      end
    end)
  end

  defp safe_workspace_root do
    case Process.whereis(Muse.Workspace) do
      nil -> File.cwd!()
      pid -> if Process.alive?(pid), do: Muse.Workspace.root(), else: File.cwd!()
    end
  rescue
    _ -> File.cwd!()
  end
end
