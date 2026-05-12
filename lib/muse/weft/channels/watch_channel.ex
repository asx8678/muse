defmodule Muse.Weft.Channels.WatchChannel do
  @moduledoc """
  File system watching WebSocket channel.

  Implements `Muse.Weft.Behaviour` and the `Phoenix.Channel` contract
  (without `use Phoenix.Channel`) to route file system events to
  a browser or external client.

  ## Topic format

      watch:<ref>

  ## Session registry

  Uses a named public ETS table:

    * `:weft_watch_sessions` — stores `{ref, count, %{path => watcher_pid}}`

  Multiple clients watching the same ref share the underlying
  `FileSystem` watcher(s). Each client subscribes to the watcher and
  receives `{:file_event, pid, {path, events}}` messages.

  The channel is opt-in via config:

      config :muse, :weft, enabled_channels: ["watch"]
  """

  @behaviour Muse.Weft.Behaviour

  alias MuseWeb.ExternalEventFilter

  @sessions_table :weft_watch_sessions
  @coalesce_window_ms 100

  # -- Phoenix.Channel contract ------------------------------------------------

  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      shutdown: 5000,
      restart: :temporary
    }
  end

  def start_link(triplet) do
    GenServer.start_link(Phoenix.Channel.Server, triplet, hibernate_after: 15_000)
  end

  def __intercepts__, do: []

  def __socket__(:private) do
    %{log_join: :info, log_handle_in: :debug}
  end

  # -- Config ------------------------------------------------------------------

  defp watch_enabled? do
    Application.get_env(:muse, :weft, [])
    |> Keyword.get(:enabled_channels, [])
    |> Enum.member?("watch")
  end

  # -- ETS tables --------------------------------------------------------------

  @doc """
  Create the :ets tables used by this channel if they don't already exist.
  """
  def ensure_tables do
    if :ets.whereis(@sessions_table) == :undefined do
      :ets.new(@sessions_table, [:named_table, :public, :set])
    end

    :ok
  end

  # -- Phoenix.Channel join ----------------------------------------------------

  def join("watch:" <> _ = topic, payload, socket) do
    case init(topic, payload, socket) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  # -- Muse.Weft.Behaviour init ------------------------------------------------

  @impl Muse.Weft.Behaviour
  def init(topic, payload, socket) do
    if not watch_enabled?() do
      {:error, "watch_channel_disabled"}
    else
      ensure_tables()

      case String.split(topic, ":", parts: 2) do
        ["watch", ref] ->
          if ExternalEventFilter.valid_session_id?(ref) do
            path = Map.get(payload, "path", File.cwd!())
            socket = do_join(ref, path, socket)
            {:ok, socket}
          else
            {:error, "invalid_ref"}
          end

        _ ->
          {:error, "invalid_topic"}
      end
    end
  end

  defp do_join(ref, path, socket) do
    case :ets.lookup(@sessions_table, ref) do
      [{^ref, _count, watchers}] ->
        Enum.each(watchers, fn {_p, pid} -> file_system_module().subscribe(pid) end)
        :ets.update_counter(@sessions_table, ref, {2, 1})

        socket
        |> Phoenix.Socket.assign(:watch_ref, ref)
        |> Phoenix.Socket.assign(:watch_paths, Map.keys(watchers))

      [] ->
        {:ok, watcher_pid} = file_system_module().start_link(dirs: [path])
        file_system_module().subscribe(watcher_pid)

        :ets.insert(@sessions_table, {ref, 1, %{path => watcher_pid}})

        socket
        |> Phoenix.Socket.assign(:watch_ref, ref)
        |> Phoenix.Socket.assign(:watch_paths, [path])
        |> Phoenix.Socket.assign(:pending_event, nil)
    end
  end

  # -- Muse.Weft.Behaviour handle_in ------------------------------------------

  @impl Muse.Weft.Behaviour
  def handle_in("subscribe", %{"path" => path}, socket) do
    ref = socket.assigns.watch_ref
    existing_paths = socket.assigns.watch_paths || []

    if path in existing_paths do
      {:reply, {:ok, %{ok: true, path: path}}, socket}
    else
      {:ok, watcher_pid} = file_system_module().start_link(dirs: [path])
      file_system_module().subscribe(watcher_pid)

      case :ets.lookup(@sessions_table, ref) do
        [{^ref, _count, watchers}] ->
          new_watchers = Map.put(watchers, path, watcher_pid)
          :ets.update_element(@sessions_table, ref, [{3, new_watchers}])

          socket = Phoenix.Socket.assign(socket, :watch_paths, [path | existing_paths])
          {:reply, {:ok, %{ok: true, path: path}}, socket}

        [] ->
          :ets.insert(@sessions_table, {ref, 1, %{path => watcher_pid}})

          socket = Phoenix.Socket.assign(socket, :watch_paths, [path | existing_paths])
          {:reply, {:ok, %{ok: true, path: path}}, socket}
      end
    end
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  # -- Phoenix.Channel handle_info ---------------------------------------------

  def handle_info({:file_event, _pid, :stop}, socket) do
    {:noreply, socket}
  end

  def handle_info({:file_event, _pid, {path, events}}, socket) do
    now = System.monotonic_time(:millisecond)
    pending = Map.get(socket.assigns, :pending_event)

    case maybe_coalesce_rename(pending, path, events, now) do
      {:coalesced, old_path, new_path} ->
        if pending && pending[:timer], do: Process.cancel_timer(pending.timer)

        Phoenix.Channel.push(socket, "renamed", %{
          old_path: old_path,
          new_path: new_path
        })

        {:noreply, Phoenix.Socket.assign(socket, :pending_event, nil)}

      {:pending, pending_event} ->
        {:noreply, Phoenix.Socket.assign(socket, :pending_event, pending_event)}

      {:flush_and_emit, event_type} ->
        if pending && pending[:timer], do: Process.cancel_timer(pending.timer)

        if pending do
          Phoenix.Channel.push(socket, "fs_event", %{
            type: pending.type,
            path: pending.path
          })
        end

        Phoenix.Channel.push(socket, "fs_event", %{
          type: event_type,
          path: path
        })

        {:noreply, Phoenix.Socket.assign(socket, :pending_event, nil)}
    end
  end

  def handle_info(:flush_pending_event, socket) do
    pending = Map.get(socket.assigns, :pending_event)

    if pending do
      Phoenix.Channel.push(socket, "fs_event", %{
        type: pending.type,
        path: pending.path
      })
    end

    {:noreply, Phoenix.Socket.assign(socket, :pending_event, nil)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Muse.Weft.Behaviour terminate -------------------------------------------

  @impl Muse.Weft.Behaviour
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :watch_ref) do
      nil ->
        :ok

      ref ->
        case :ets.lookup(@sessions_table, ref) do
          [{^ref, count, watchers}] ->
            new_count = count - 1

            if new_count <= 0 do
              Enum.each(watchers, fn {_path, pid} ->
                if is_pid(pid) and Process.alive?(pid) do
                  Process.exit(pid, :kill)
                end
              end)

              :ets.delete(@sessions_table, ref)
            else
              :ets.update_element(@sessions_table, ref, [{2, new_count}])
            end

          [] ->
            :ok
        end
    end
  end

  # -- Private -----------------------------------------------------------------

  defp file_system_module do
    Application.get_env(:muse, :weft_watch_file_system_module, FileSystem)
  end

  defp maybe_coalesce_rename(nil, path, events, now) do
    type = classify_events(events)

    if type in ["created", "deleted", "removed", "moved_from", "moved_to"] do
      timer = Process.send_after(self(), :flush_pending_event, @coalesce_window_ms)
      {:pending, %{path: path, type: type, ts: now, timer: timer}}
    else
      {:flush_and_emit, type}
    end
  end

  defp maybe_coalesce_rename(pending, path, events, now) do
    type = classify_events(events)
    delta = now - pending.ts

    cond do
      delta > @coalesce_window_ms ->
        {:flush_and_emit, type}

      rename_pair?(pending.type, type) and pending.path != path ->
        {old_path, new_path} =
          if pending.type in ["deleted", "removed"],
            do: {pending.path, path},
            else: {path, pending.path}

        {:coalesced, old_path, new_path}

      true ->
        {:flush_and_emit, type}
    end
  end

  defp classify_events(events) do
    cond do
      :renamed in events -> "renamed"
      :moved_to in events and :moved_from in events -> "renamed"
      :created in events -> "created"
      :deleted in events or :removed in events -> "deleted"
      :modified in events -> "modified"
      :closed in events -> "closed"
      true -> "unknown"
    end
  end

  defp rename_pair?(type1, type2) do
    (type1 in ["created", "moved_to"] and type2 in ["deleted", "removed", "moved_from"]) or
      (type1 in ["deleted", "removed", "moved_from"] and type2 in ["created", "moved_to"])
  end
end
