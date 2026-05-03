defmodule MuseWeb.ConsoleCommand do
  @moduledoc """
  Command dispatch and palette actions for the Muse console.

  Delegates command logic to `Muse.CommandDispatcher` and applies
  returned effects to the LiveView socket.  Web-specific concerns
  (clipboard push events, socket assigns, toasts) live here;
  backend logic lives in the shared dispatcher.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3, connected?: 1]

  alias MuseWeb.BackendBridge
  alias Muse.CommandDispatcher

  @toast_timeout_ms 5_000

  # -- Build context from socket -----------------------------------------------

  defp build_context(socket) do
    %{
      events: socket.assigns.state.events,
      logs: socket.assigns.logs,
      diagnostics: socket.assigns.diagnostics,
      agent_snapshot: socket.assigns.agent_snapshot,
      workspace: socket.assigns.workspace,
      reload_status: socket.assigns.reload_status,
      agent_runtime: socket.assigns.agent_runtime,
      beam_stats: socket.assigns.beam_stats,
      event_filter: socket.assigns.event_filter,
      event_search: socket.assigns.event_search,
      log_filter: socket.assigns.log_filter,
      log_search: socket.assigns.log_search,
      command_history: socket.assigns.command_history,
      state: socket.assigns.state
    }
  end

  # -- Apply effects to socket -------------------------------------------------

  defp apply_effects(socket, effects) do
    Enum.reduce(effects, socket, fn effect, sock -> apply_effect(sock, effect) end)
  end

  defp apply_effect(socket, {:switch_tab, tab}) do
    assign(socket, active_tab: tab)
  end

  defp apply_effect(socket, {:clear_input}) do
    socket
  end

  defp apply_effect(socket, {:toast, type, message}) do
    add_toast(socket, message, type)
  end

  defp apply_effect(socket, {:set_event_search, query}) do
    assign(socket, event_search: query)
  end

  defp apply_effect(socket, {:set_event_filter, filter}) do
    assign(socket, event_filter: filter)
  end

  defp apply_effect(socket, {:set_log_search, query}) do
    assign(socket, log_search: query)
  end

  defp apply_effect(socket, {:set_log_filter, filter}) do
    assign(socket, log_filter: filter)
  end

  defp apply_effect(socket, {:refresh, :events}) do
    assign(socket, state: Muse.State.get())
  end

  defp apply_effect(socket, {:refresh, :logs}) do
    assign(socket, logs: BackendBridge.safe_logs())
  end

  defp apply_effect(socket, {:refresh, :diagnostics}) do
    assign(socket, diagnostics: BackendBridge.safe_diagnostics())
  end

  defp apply_effect(socket, {:refresh, :runtime}) do
    assign(socket, agent_runtime: BackendBridge.safe_agent_runtime_snapshot())
  end

  defp apply_effect(socket, {:refresh, :stats}) do
    assign(socket, beam_stats: Muse.BeamStats.snapshot())
  end

  defp apply_effect(socket, {:refresh, :agents}) do
    assign(socket, agent_snapshot: BackendBridge.safe_agent_snapshot())
  end

  defp apply_effect(socket, {:refresh, _unknown}) do
    socket
  end

  defp apply_effect(socket, {:copy_to_clipboard, text, label}) do
    push_event(socket, "copy_to_clipboard", %{text: text, label: label})
  end

  # -- 2-arity dispatch --------------------------------------------------------

  def dispatch_command(action, socket) do
    context = build_context(socket)
    {_status, output, effects} = CommandDispatcher.dispatch(action, nil, context)
    socket = apply_effects(socket, effects)
    {output, socket}
  end

  # -- 3-arity dispatch (with args) ---------------------------------------------

  def dispatch_command_with_args(action, args, socket) do
    context = build_context(socket)
    {_status, output, effects} = CommandDispatcher.dispatch(action, args, context)
    socket = apply_effects(socket, effects)
    {output, socket}
  end

  # -- Filter normalization (delegated to CommandDispatcher) -------------------

  defdelegate normalize_filter(normalized), to: CommandDispatcher
  defdelegate normalize_log_filter(normalized), to: CommandDispatcher

  # -- Palette -----------------------------------------------------------------

  def palette_actions do
    [
      %{id: "open_events", label: "Open Events", icon: "📋", shortcut: "Ctrl+E"},
      %{id: "open_files", label: "Open Files", icon: "📂", shortcut: "Ctrl+F"},
      %{id: "open_agents", label: "Open Agents", icon: "🌳", shortcut: "Ctrl+A"},
      %{id: "open_stats", label: "Open Stats", icon: "📊", shortcut: "Ctrl+R"},
      %{id: "open_settings", label: "Open Settings", icon: "⚙️", shortcut: "Ctrl+,"},
      %{id: "open_logs", label: "Open Logs", icon: "📝", shortcut: "Ctrl+L"},
      %{id: "simulate_event", label: "Simulate event", icon: "🧪"},
      %{id: "simulate_backend_error", label: "Simulate backend error", icon: "💥"},
      %{id: "clear_events", label: "Clear events", icon: "🗑️"},
      %{id: "export_events", label: "Export events", icon: "📤"},
      %{id: "copy_diagnostics", label: "Export diagnostics", icon: "📋"},
      %{id: "clear_logs", label: "Clear logs", icon: "🗑️"},
      %{id: "export_logs", label: "Export logs", icon: "📤"},
      %{id: "connect_runtime", label: "Connect runtime", icon: "🔗"},
      %{id: "disconnect_runtime", label: "Disconnect runtime", icon: "✂️"}
    ]
  end

  def execute_palette_action(action, socket) do
    case action do
      id when id in ["open_events", "open_files", "open_agents", "open_stats", "open_settings"] ->
        tab = String.replace(id, "open_", "")
        assign(socket, active_tab: tab)

      "simulate_event" ->
        if Mix.env() != :prod do
          event = Muse.Event.new(:web, :simulated, %{text: "Simulated from palette"})
          Muse.State.append(event)

          assign(socket, state: Muse.State.get())
          |> add_toast("Simulated event from palette", :success)
        else
          socket
        end

      "simulate_backend_error" ->
        if Mix.env() != :prod do
          BackendBridge.safe_emit_simulated_error()
          event = Muse.Event.new(:web, :error, %{text: "Simulated from palette"})
          Muse.State.append(event)

          assign(socket, state: Muse.State.get())
          |> add_toast("Backend error simulated", :warning)
        else
          socket
        end

      "clear_events" ->
        Muse.State.clear()
        assign(socket, state: Muse.State.get()) |> add_toast("Events cleared", :info)

      "export_events" ->
        dispatch_command(:export_events, socket) |> elem(1)

      "copy_diagnostics" ->
        dispatch_command(:copy_diagnostics, socket) |> elem(1)

      "open_logs" ->
        assign(socket, active_tab: "logs")

      "clear_logs" ->
        case BackendBridge.safe_clear_logs() do
          :ok ->
            assign(socket, logs: BackendBridge.safe_logs()) |> add_toast("Logs cleared", :info)

          {:error, _} ->
            socket
        end

      "export_logs" ->
        dispatch_command(:export_logs, socket) |> elem(1)

      "connect_runtime" ->
        case BackendBridge.safe_connect_agent_runtime() do
          {:error, reason} when is_binary(reason) ->
            assign(socket, agent_runtime: BackendBridge.safe_agent_runtime_snapshot())
            |> add_toast("Runtime: #{reason}", :warning)

          {:error, _} ->
            add_toast(socket, "Agent runtime unavailable", :warning)
        end

      "disconnect_runtime" ->
        case BackendBridge.safe_disconnect_agent_runtime() do
          {:ok, _} ->
            assign(socket, agent_runtime: BackendBridge.safe_agent_runtime_snapshot())
            |> add_toast("Runtime disconnected", :info)

          {:error, _} ->
            add_toast(socket, "Agent runtime unavailable", :warning)
        end

      _ ->
        socket
    end
  end

  # -- Toast helper (duplicated from HomeLive for low-risk extraction) -------

  defp add_toast(socket, message, type) do
    id = System.unique_integer([:positive])
    toast = %{id: id, message: message, type: type}

    if connected?(socket) do
      Process.send_after(self(), {:dismiss_toast, id}, @toast_timeout_ms)
    end

    assign(socket, toasts: socket.assigns.toasts ++ [toast])
  end
end
