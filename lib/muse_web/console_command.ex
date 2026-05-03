defmodule MuseWeb.ConsoleCommand do
  @moduledoc """
  Command dispatch and palette actions for the Muse console.

  Handles routing of slash commands to their implementations.
  Functions take a socket and return `{output, socket}` to preserve
  the existing LiveView interface as a transitional refactor.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3, connected?: 1]

  import MuseWeb.EventFormatter,
    only: [
      filtered_events: 3,
      event_to_map: 1
    ]

  import MuseWeb.LogFormatter,
    only: [
      filtered_logs: 3,
      format_logs_json: 1
    ]

  import MuseWeb.ConsoleComponents, only: [format_bytes: 1]

  import MuseWeb.ExportJSON, only: [json_safe: 1, build_diagnostics_payload: 1]

  alias MuseWeb.BackendBridge

  @toast_timeout_ms 5_000

  # -- 2-arity dispatch -------------------------------------------------------

  def dispatch_command(:help, socket) do
    {Muse.Commands.help_text(), socket}
  end

  def dispatch_command(:events, socket) do
    count = length(socket.assigns.state.events)
    {"Event log: #{count} event(s) recorded.", socket}
  end

  def dispatch_command(:agents, socket) do
    case socket.assigns.agent_snapshot do
      :unavailable -> {"Agent registry unavailable.", socket}
      %{agents: agents} -> {"Agent registry: #{length(agents)} agent(s).", socket}
    end
  end

  def dispatch_command(:simulate_event, socket) do
    if Mix.env() != :prod do
      event = Muse.Event.new(:web, :simulated, %{text: "Simulated test event from command"})
      Muse.State.append(event)
      state = Muse.State.get()
      socket = socket |> assign(state: state) |> add_toast("Simulated event created", :success)
      {"Simulated event created.", socket}
    else
      {"Simulate not available in production.", socket}
    end
  end

  def dispatch_command(:simulate_backend_error, socket) do
    if Mix.env() != :prod do
      BackendBridge.safe_emit_simulated_error()
      event = Muse.Event.new(:web, :error, %{text: "Simulated backend error from command"})
      Muse.State.append(event)
      state = Muse.State.get()
      socket = socket |> assign(state: state) |> add_toast("Backend error simulated", :warning)
      {"Simulated backend error created.", socket}
    else
      {"Simulate not available in production.", socket}
    end
  end

  def dispatch_command(:clear_history, socket) do
    {"Command history cleared.", assign(socket, command_history: [])}
  end

  def dispatch_command(:clear_events, socket) do
    Muse.State.clear()
    state = Muse.State.get()
    socket = socket |> assign(state: state) |> add_toast("Events cleared", :info)
    {"Events cleared.", socket}
  end

  def dispatch_command(:reload_status, socket) do
    status = socket.assigns.reload_status

    msg =
      case status[:status] do
        :unavailable -> "File watcher: Unavailable"
        _ -> "File watcher: Active (gen #{status[:generation]})"
      end

    {msg, socket}
  end

  def dispatch_command(:workspace, socket) do
    {"Workspace: #{socket.assigns.workspace}", socket}
  end

  def dispatch_command(:stats, socket) do
    stats = Muse.BeamStats.snapshot()

    msg =
      "BEAM Stats: #{stats.process_count} processes, #{format_bytes(stats.total_memory)} memory, OTP #{stats.otp_release}"

    {msg, assign(socket, beam_stats: stats)}
  end

  def dispatch_command(:diagnostics, socket) do
    count = length(socket.assigns.diagnostics)

    levels =
      socket.assigns.diagnostics
      |> Enum.group_by(& &1.level)
      |> Enum.map(fn {level, items} -> "#{length(items)} #{level}" end)
      |> Enum.join(", ")

    msg = if count == 0, do: "No diagnostics.", else: "Diagnostics: #{count} (#{levels})"
    {msg, socket}
  end

  def dispatch_command(:copy_diagnostics, socket) do
    payload = build_diagnostics_payload(socket.assigns)
    json = Jason.encode!(payload, pretty: true)
    socket = push_event(socket, "copy_to_clipboard", %{text: json, label: "Diagnostics"})
    {"Diagnostics copied to clipboard.", socket}
  rescue
    e -> {"Error: #{Exception.message(e)}", socket}
  end

  def dispatch_command(:export_events, socket) do
    events = socket.assigns.state.events

    filtered =
      filtered_events(
        Enum.reverse(events),
        socket.assigns.event_filter,
        socket.assigns.event_search
      )

    payload =
      %{
        "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "filter" => socket.assigns.event_filter,
        "search" => socket.assigns.event_search,
        "total_events" => length(events),
        "exported_count" => length(filtered),
        "events" => Enum.map(filtered, &event_to_map/1)
      }
      |> json_safe()

    json = Jason.encode!(payload, pretty: true)

    socket =
      push_event(socket, "copy_to_clipboard", %{
        text: json,
        label: "#{length(filtered)} events exported"
      })

    {"#{length(filtered)} events exported to clipboard.", socket}
  rescue
    e -> {"Error: #{Exception.message(e)}", socket}
  end

  def dispatch_command(:search_events, socket) do
    socket = assign(socket, active_tab: "events")
    {"Usage: /search events <query>", socket}
  end

  def dispatch_command(:filter_events, socket) do
    current = String.capitalize(socket.assigns.event_filter)
    socket = assign(socket, active_tab: "events")
    {"Usage: /filter events errors|warnings|info|all (current: #{current})", socket}
  end

  def dispatch_command(:open_events, socket),
    do: {"Switched to Events tab.", assign(socket, active_tab: "events")}

  def dispatch_command(:open_files, socket),
    do: {"Switched to Files tab.", assign(socket, active_tab: "files")}

  def dispatch_command(:open_agents, socket),
    do: {"Switched to Agents tab.", assign(socket, active_tab: "agents")}

  def dispatch_command(:open_stats, socket),
    do: {"Switched to Stats tab.", assign(socket, active_tab: "stats")}

  def dispatch_command(:open_settings, socket),
    do: {"Switched to Settings tab.", assign(socket, active_tab: "settings")}

  def dispatch_command(:open_logs, socket),
    do: {"Switched to Logs tab.", assign(socket, active_tab: "logs")}

  def dispatch_command(:logs, socket) do
    count = length(socket.assigns.logs)
    {"Log buffer: #{count} log entry(s) recorded.", socket}
  end

  def dispatch_command(:clear_logs, socket) do
    case BackendBridge.safe_clear_logs() do
      :ok ->
        socket =
          socket |> assign(logs: BackendBridge.safe_logs()) |> add_toast("Logs cleared", :info)

        {"Logs cleared.", socket}

      {:error, _reason} ->
        {"Error: Log buffer unavailable.", socket}
    end
  end

  def dispatch_command(:export_logs, socket) do
    filtered =
      filtered_logs(
        socket.assigns.logs,
        socket.assigns.log_filter,
        socket.assigns.log_search
      )

    json = format_logs_json(filtered)

    socket =
      push_event(socket, "copy_to_clipboard", %{
        text: json,
        label: "#{length(filtered)} logs exported"
      })

    {"#{length(filtered)} logs exported to clipboard.", socket}
  rescue
    e -> {"Error: #{Exception.message(e)}", socket}
  end

  def dispatch_command(:search_logs, socket) do
    socket = assign(socket, active_tab: "logs")
    {"Usage: /search logs <query>", socket}
  end

  def dispatch_command(:filter_logs, socket) do
    current = String.capitalize(socket.assigns.log_filter)
    socket = assign(socket, active_tab: "logs")
    {"Usage: /filter logs errors|warnings|info|debug|all (current: #{current})", socket}
  end

  def dispatch_command(:runtime, socket) do
    runtime = socket.assigns.agent_runtime

    msg =
      case runtime.status do
        :disconnected -> "Agent runtime: Disconnected (endpoint: #{runtime.endpoint})"
        :connecting -> "Agent runtime: Connecting to #{runtime.endpoint}..."
        :connected -> "Agent runtime: Connected to #{runtime.endpoint}"
        :error -> "Agent runtime: Error — #{runtime.last_error} (endpoint: #{runtime.endpoint})"
      end

    {msg, socket}
  end

  def dispatch_command(:connect_runtime, socket) do
    case BackendBridge.safe_connect_agent_runtime() do
      {:error, reason} when is_binary(reason) ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()

        socket =
          socket |> assign(agent_runtime: runtime) |> add_toast("Runtime: #{reason}", :warning)

        {"Runtime: #{reason}", socket}

      {:error, _reason} ->
        socket = socket |> add_toast("Agent runtime unavailable", :warning)
        {"Agent runtime unavailable.", socket}
    end
  end

  def dispatch_command(:disconnect_runtime, socket) do
    case BackendBridge.safe_disconnect_agent_runtime() do
      {:ok, _snapshot} ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()

        socket =
          socket |> assign(agent_runtime: runtime) |> add_toast("Runtime disconnected", :info)

        {"Runtime disconnected.", socket}

      {:error, _reason} ->
        socket = socket |> add_toast("Agent runtime unavailable", :warning)
        {"Agent runtime unavailable.", socket}
    end
  end

  # Catch-all: unknown action falls through to safe error instead of crashing
  def dispatch_command(action, socket) do
    {"Unknown command action: #{inspect(action)}. Type /help for available commands.", socket}
  end

  # -- 3-arity dispatch (with args) -------------------------------------------

  def dispatch_command_with_args(:search_events, args, socket) do
    socket = assign(socket, event_search: args, active_tab: "events")
    {"Searching events for: #{args}", socket}
  end

  def dispatch_command_with_args(:filter_events, args, socket) do
    normalized = String.downcase(String.trim(args))

    case normalize_filter(normalized) do
      {:ok, filter} ->
        socket = assign(socket, event_filter: filter, active_tab: "events")
        {"Event filter set to: #{String.capitalize(filter)}", socket}

      {:error, invalid} ->
        socket = assign(socket, active_tab: "events")

        {"Error: Unknown filter \"#{invalid}\". Usage: /filter events errors|warnings|info|all",
         socket}
    end
  end

  def dispatch_command_with_args(:simulate_event, _args, socket) do
    dispatch_command(:simulate_event, socket)
  end

  def dispatch_command_with_args(:simulate_backend_error, _args, socket) do
    dispatch_command(:simulate_backend_error, socket)
  end

  def dispatch_command_with_args(:search_logs, args, socket) do
    socket = assign(socket, log_search: args, active_tab: "logs")
    {"Searching logs for: #{args}", socket}
  end

  def dispatch_command_with_args(:filter_logs, args, socket) do
    normalized = String.downcase(String.trim(args))

    case normalize_log_filter(normalized) do
      {:ok, filter} ->
        socket = assign(socket, log_filter: filter, active_tab: "logs")
        {"Log filter set to: #{String.capitalize(filter)}", socket}

      {:error, invalid} ->
        socket = assign(socket, active_tab: "logs")

        {"Error: Unknown filter \"#{invalid}\". Usage: /filter logs errors|warnings|info|debug|all",
         socket}
    end
  end

  def dispatch_command_with_args(:connect_runtime, args, socket) do
    endpoint = String.trim(args)

    if endpoint != "" do
      _ = BackendBridge.safe_set_agent_runtime_endpoint(endpoint)
    end

    case BackendBridge.safe_connect_agent_runtime(endpoint) do
      {:error, reason} when is_binary(reason) ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()

        socket =
          socket |> assign(agent_runtime: runtime) |> add_toast("Runtime: #{reason}", :warning)

        {"Runtime: #{reason}", socket}

      {:error, _reason} ->
        socket = socket |> add_toast("Agent runtime unavailable", :warning)
        {"Agent runtime unavailable.", socket}
    end
  end

  # Catch-all: delegate to 2-arity dispatch_command for any other action+args
  def dispatch_command_with_args(action, _args, socket) do
    dispatch_command(action, socket)
  end

  # -- Filter normalization ---------------------------------------------------

  @valid_filters ~w(errors warnings info all)

  def normalize_filter(normalized) when normalized in @valid_filters, do: {:ok, normalized}
  def normalize_filter("error"), do: {:ok, "errors"}
  def normalize_filter("warning"), do: {:ok, "warnings"}
  def normalize_filter(invalid), do: {:error, invalid}

  # -- Log filter normalization -----------------------------------------------

  @valid_log_filters ~w(all errors warnings info debug)

  def normalize_log_filter(normalized) when normalized in @valid_log_filters,
    do: {:ok, normalized}

  def normalize_log_filter("error"), do: {:ok, "errors"}
  def normalize_log_filter("warning"), do: {:ok, "warnings"}
  def normalize_log_filter(invalid), do: {:error, invalid}

  # -- Palette ----------------------------------------------------------------

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
