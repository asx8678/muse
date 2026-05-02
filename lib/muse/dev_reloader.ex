defmodule Muse.DevReloader do
  @moduledoc """
  Development hot-code watcher with rollback support.

  Polls watched source files for changes, compiles them, runs a health
  check, and — on success — increments the generation counter and saves a
  snapshot for rollback.  On failure the previous snapshot is restored so
  the system keeps running with known-good code.

  ## Test-friendly options

  The following `start_link/1` options are intended for tests:

    * `:poll?`         – set `false` to disable periodic polling (default `true`)
    * `:poll_interval`  – override poll interval in ms (default `1000`)
    * `:debounce_ms`    – override debounce delay in ms (default `300`)
    * `:watch_globs`   – list of glob patterns to scan (default watches `lib/`)
    * `:exclude`        – list of file paths to exclude from reload
    * `:compile_fun`    – `fn files -> :ok | {:error, reason} end`
    * `:health_fun`    – `fn -> :ok | raise end`  (default `&Muse.Health.check!/0`)
    * `:name`           – GenServer name (default `__MODULE__`)

  """

  use GenServer

  @default_poll_interval 1000
  @default_debounce_ms 300
  @default_watch_globs ~w(lib/muse.ex lib/muse/**/*.ex lib/muse_web/**/*.ex)
  @default_exclude ~w(lib/muse/dev_reloader.ex lib/muse/application.ex)
  @max_recent_files 20

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec reload() :: :ok | {:error, String.t()}
  def reload, do: GenServer.call(__MODULE__, :force_reload)

  @spec rollback() :: :ok | {:error, String.t()}
  def rollback, do: GenServer.call(__MODULE__, :rollback)

  # -- @doc false helpers (used by tests) ---------------------------------------

  @doc false
  def scan_mtimes(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reduce(%{}, fn path, acc ->
      case File.stat(path) do
        {:ok, stat} -> Map.put(acc, path, stat.mtime)
        {:error, _} -> acc
      end
    end)
  end

  @doc false
  def find_changed(old_mtimes, new_mtimes, exclude) do
    exclude_set = MapSet.new(exclude)

    new_mtimes
    |> Enum.filter(fn {path, new_mtime} ->
      not MapSet.member?(exclude_set, path) and Map.get(old_mtimes, path) != new_mtime
    end)
    |> Enum.map(fn {path, _} -> path end)
  end

  @doc false
  def snapshot_modules do
    for {module, _loaded} <- :code.all_loaded(),
        muse_module?(module),
        obj_code = :code.get_object_code(module),
        obj_code != :error do
      {_mod, binary, filename} = obj_code
      {module, {module, binary, filename}}
    end
    |> Map.new()
  end

  @doc false
  def restore_snapshot(snapshot) when is_map(snapshot) do
    for {_key, {mod, binary, filename}} <- snapshot do
      try do
        :code.purge(mod)
        :code.delete(mod)
        :code.load_binary(mod, filename, binary)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init(opts) do
    watch_globs = Keyword.get(opts, :watch_globs, @default_watch_globs)
    poll? = Keyword.get(opts, :poll?, true)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      poll?: poll?,
      poll_interval: poll_interval,
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      watch_globs: watch_globs,
      exclude: Keyword.get(opts, :exclude, @default_exclude),
      compile_fun: Keyword.get(opts, :compile_fun, &default_compile/1),
      health_fun: Keyword.get(opts, :health_fun, &Muse.Health.check!/0),
      generation: 0,
      last_good_snapshot: nil,
      last_error: nil,
      last_reload_at: nil,
      pending_changes: nil,
      debounce_ref: nil,
      mtimes: scan_mtimes(watch_globs),
      file_line_counts:
        initial_line_counts(watch_globs, Keyword.get(opts, :exclude, @default_exclude)),
      recent_files: []
    }

    if state.poll?, do: schedule_poll(state.poll_interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      generation: state.generation,
      last_error: state.last_error,
      last_reload_at: state.last_reload_at,
      pending_changes: state.pending_changes,
      recent_files: state.recent_files,
      recent_file: List.first(state.recent_files)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:force_reload, _from, state) do
    {result, new_state} = do_reload(state, :force)
    new_state = %{new_state | pending_changes: nil, debounce_ref: nil}
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:rollback, _from, state) do
    {result, new_state} = do_rollback(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state =
      if state.poll? do
        new_mtimes = scan_mtimes(state.watch_globs)
        changed = find_changed(state.mtimes, new_mtimes, state.exclude)
        state = %{state | mtimes: new_mtimes}

        if changed != [] do
          ref = make_ref()
          Process.send_after(self(), {:debounce, ref}, state.debounce_ms)
          %{state | pending_changes: changed, debounce_ref: ref}
        else
          state
        end
      else
        state
      end

    if new_state.poll?, do: schedule_poll(new_state.poll_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:debounce, ref}, %{debounce_ref: ref} = state) do
    if state.pending_changes do
      {_result, new_state} = do_reload(state, {:auto, state.pending_changes})
      {:noreply, %{new_state | pending_changes: nil, debounce_ref: nil}}
    else
      {:noreply, %{state | debounce_ref: nil}}
    end
  end

  def handle_info({:debounce, _stale_ref}, state) do
    {:noreply, state}
  end

  # -- Reload logic -------------------------------------------------------------

  defp do_reload(state, mode) do
    files = files_to_reload(state, mode)
    snapshot = snapshot_modules()
    compile_fun = state.compile_fun
    health_fun = state.health_fun

    case compile_fun.(files) do
      :ok ->
        case safe_health_check(health_fun) do
          :ok ->
            new_mtimes = scan_mtimes(state.watch_globs)

            {new_file_line_counts, new_recent_files} =
              update_file_stats(files, state.file_line_counts, state.recent_files)

            new_state = %{
              state
              | generation: state.generation + 1,
                last_good_snapshot: snapshot,
                last_error: nil,
                last_reload_at: DateTime.utc_now(),
                mtimes: new_mtimes,
                file_line_counts: new_file_line_counts,
                recent_files: new_recent_files
            }

            try_append_event(:dev_reloader, :reload_success, %{
              generation: new_state.generation,
              files: files
            })

            {:ok, new_state}

          {:error, error} ->
            restore_snapshot(snapshot)

            new_state = %{state | last_error: error, mtimes: scan_mtimes(state.watch_globs)}

            try_append_event(:dev_reloader, :reload_failed, %{error: error, files: files})
            try_emit_diagnostic(:error, "Reload failed: #{error}", %{files: files})

            {{:error, error}, new_state}
        end

      {:error, reason} ->
        restore_snapshot(snapshot)
        error = to_string(reason)
        new_state = %{state | last_error: error, mtimes: scan_mtimes(state.watch_globs)}
        try_append_event(:dev_reloader, :reload_failed, %{error: error, files: files})
        try_emit_diagnostic(:error, "Reload failed: #{error}", %{files: files})
        {{:error, error}, new_state}
    end
  end

  defp files_to_reload(state, :force) do
    state.watch_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&(&1 in state.exclude))
  end

  defp files_to_reload(_state, {:auto, files}), do: files

  # -- Rollback logic -----------------------------------------------------------

  defp do_rollback(%{last_good_snapshot: nil} = state) do
    {{:error, "no snapshot available for rollback"}, state}
  end

  defp do_rollback(%{last_good_snapshot: snapshot} = state) when is_map(snapshot) do
    restore_snapshot(snapshot)
    try_append_event(:dev_reloader, :rollback_success, %{generation: state.generation})
    {:ok, state}
  end

  # -- Health check wrapper -----------------------------------------------------

  defp safe_health_check(health_fun) do
    try do
      health_fun.()
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  # -- Default compile ----------------------------------------------------------

  defp default_compile(files) do
    try do
      Enum.each(files, &Code.compile_file/1)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # -- Diagnostics/event broadcasting (best-effort) -----------------------------

  defp try_emit_diagnostic(level, message, metadata) do
    try do
      case Process.whereis(Muse.Diagnostics) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid) do
            Muse.Diagnostics.emit(level, message, metadata)
          end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp try_append_event(source, type, data) do
    try do
      case Process.whereis(Muse.State) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid) do
            event = Muse.Event.new(source, type, data)
            Muse.State.append(event)
          end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # -- File stat tracking (recent files with modified_count & lines_added) ----

  @doc false
  @spec scan_file_stats(String.t()) :: %{line_count: non_neg_integer()}
  def scan_file_stats(path) do
    try do
      content = File.read!(path)
      line_count = count_lines(content)
      %{line_count: line_count}
    rescue
      _ -> %{line_count: 0}
    catch
      _, _ -> %{line_count: 0}
    end
  end

  @doc false
  @spec line_counts_for_files([String.t()]) :: %{String.t() => non_neg_integer()}
  def line_counts_for_files(paths) do
    paths
    |> Enum.reduce(%{}, fn path, acc ->
      Map.put(acc, path, scan_file_stats(path).line_count)
    end)
  end

  @doc false
  @spec count_lines(String.t()) :: non_neg_integer()
  def count_lines(content) when is_binary(content) do
    case content do
      "" -> 0
      _ -> content |> String.split("\n") |> length()
    end
  end

  @doc false
  defp update_file_stats(files, old_line_counts, recent_files) do
    now = DateTime.utc_now()

    {new_line_counts, updated_entries} =
      Enum.reduce(files, {old_line_counts, []}, fn path, {lc_acc, entries_acc} ->
        old_lc = Map.get(lc_acc, path, 0)
        new_stats = scan_file_stats(path)
        new_lc = new_stats.line_count
        lines_added = max(new_lc - old_lc, 0)

        entry = %{
          path: path,
          basename: Path.basename(path),
          modified_count: 1,
          lines_added: lines_added,
          last_modified_at: now
        }

        {Map.put(lc_acc, path, new_lc), [entry | entries_acc]}
      end)

    # Merge with existing recent_files — update modified_count if same path
    merged =
      Enum.reduce(updated_entries, recent_files, fn entry, acc ->
        case Enum.find_index(acc, &(&1.path == entry.path)) do
          nil ->
            [entry | acc]

          idx ->
            List.update_at(acc, idx, fn existing ->
              %{
                existing
                | modified_count: existing.modified_count + 1,
                  lines_added: existing.lines_added + entry.lines_added,
                  last_modified_at: entry.last_modified_at
              }
            end)
        end
      end)

    # Sort newest-first and cap
    merged =
      merged
      |> Enum.sort_by(& &1.last_modified_at, {:desc, DateTime})
      |> Enum.take(@max_recent_files)

    {new_line_counts, merged}
  end

  defp initial_line_counts(globs, exclude) do
    exclude_set = MapSet.new(exclude)

    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&MapSet.member?(exclude_set, &1))
    |> line_counts_for_files()
  end

  # -- Module classification ----------------------------------------------------

  defp muse_module?(module) do
    mod_str = Atom.to_string(module)

    String.starts_with?(mod_str, "Elixir.Muse.") or mod_str == "Elixir.Muse" or
      String.starts_with?(mod_str, "Elixir.MuseWeb.") or mod_str == "Elixir.MuseWeb"
  end

  # -- Scheduling ---------------------------------------------------------------

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
