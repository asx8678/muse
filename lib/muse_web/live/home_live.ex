defmodule MuseWeb.HomeLive do
  use MuseWeb, :live_view

  import MuseWeb.ConsoleComponents,
    only: [
      events_tab: 1,
      logs_tab: 1,
      files_tab: 1,
      agents_tab: 1,
      stats_tab: 1,
      settings_tab: 1,
      app_header: 1,
      status_bar: 1,
      diagnostics_popup: 1,
      dev_sidebar: 1,
      command_console: 1,
      toast_container: 1
    ]

  import MuseWeb.EventFormatter,
    only: [
      filtered_events: 3,
      format_event_json: 1,
      event_to_map: 1,
      format_timestamp: 1
    ]

  import MuseWeb.LogFormatter,
    only: [
      filtered_logs: 3,
      format_log_json: 1,
      format_logs_json: 1
    ]

  import MuseWeb.ExportJSON, only: [json_safe: 1, build_diagnostics_payload: 1]
  import MuseWeb.ConsoleCommand, only: [palette_actions: 0]

  alias MuseWeb.BackendBridge
  alias MuseWeb.ConsoleCommand

  @collapse_timeout_ms 10_000
  @toast_timeout_ms 5_000

  @tabs [
    {"events", "📋", "Events"},
    {"logs", "📝", "Logs"},
    {"files", "📂", "Files"},
    {"agents", "🌳", "Agents"},
    {"stats", "📊", "Stats"},
    {"settings", "⚙️", "Settings"}
  ]

  # -- Mount ------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    state = Muse.State.get()
    workspace = BackendBridge.safe_workspace_root()
    reload_status = BackendBridge.safe_reload_status()
    diagnostics = BackendBridge.safe_diagnostics()
    self_healing_issues = BackendBridge.safe_self_healing_issues()
    diagnostic_issue_statuses = compute_issue_statuses(self_healing_issues)

    diagnostics_open? = diagnostics != []

    if connected?(socket) do
      Muse.State.subscribe()
      BackendBridge.safe_subscribe_diagnostics()
      BackendBridge.safe_subscribe_self_healing()
      BackendBridge.safe_subscribe_agent_registry()
      BackendBridge.safe_subscribe_logs()
      BackendBridge.safe_subscribe_agent_runtime()
    end

    socket =
      socket
      |> assign(
        state: state,
        input: "",
        workspace: workspace,
        reload_status: reload_status,
        diagnostics: diagnostics,
        diagnostics_open?: diagnostics_open?,
        diagnostics_collapse_ref: nil,
        diagnostics_collapse_timer_ref: nil,
        self_healing_issues: self_healing_issues,
        diagnostic_issue_statuses: diagnostic_issue_statuses,
        beam_stats: Muse.BeamStats.snapshot(),
        agent_snapshot: BackendBridge.safe_agent_snapshot(),
        # Sprint 1 assigns
        tabs: @tabs,
        active_tab: "events",
        event_filter: "all",
        event_search: "",
        command_history: [],
        toasts: [],
        expanded_event_id: nil,
        # Log assigns
        logs: BackendBridge.safe_logs(),
        log_filter: "all",
        log_search: "",
        expanded_log_id: nil,
        # Agent runtime assigns
        agent_runtime: BackendBridge.safe_agent_runtime_snapshot(),
        # Legacy assigns kept for compatibility
        open_windows: MapSet.new(),
        active_window: nil
      )

    socket =
      if diagnostics_open? and connected?(socket) do
        schedule_collapse(socket)
      else
        socket
      end

    {:ok, socket}
  end

  # -- Event handlers ---------------------------------------------------------

  @impl true
  def handle_event("submit", %{"text" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      case Muse.Commands.parse(text) do
        :empty ->
          {:noreply, socket}

        {:message, msg} ->
          try do
            Muse.submit(:web, msg)
            state = Muse.State.get()
            socket = assign(socket, state: state, input: "")
            entry = make_history_entry(msg, "Message sent to Muse.", :success)
            {:noreply, assign(socket, command_history: socket.assigns.command_history ++ [entry])}
          rescue
            e ->
              entry = make_history_entry(msg, "Error: #{Exception.message(e)}", :error)
              socket = socket |> assign(input: text) |> add_toast(Exception.message(e), :error)

              {:noreply,
               assign(socket, command_history: socket.assigns.command_history ++ [entry])}
          end

        {:command, action} ->
          {output, socket} = ConsoleCommand.dispatch_command(action, socket)

          entry =
            make_history_entry(
              text,
              output,
              if(String.starts_with?(output, "Error"), do: :error, else: :success)
            )

          {:noreply,
           assign(socket, command_history: socket.assigns.command_history ++ [entry], input: "")}

        {:command, action, args} ->
          {output, socket} = ConsoleCommand.dispatch_command_with_args(action, args, socket)

          entry =
            make_history_entry(
              text,
              output,
              if(String.starts_with?(output, "Error"), do: :error, else: :success)
            )

          {:noreply,
           assign(socket, command_history: socket.assigns.command_history ++ [entry], input: "")}

        {:unknown, cmd} ->
          entry =
            make_history_entry(
              text,
              "Unknown command: #{cmd}. Type /help for available commands.",
              :error
            )

          {:noreply,
           assign(socket, command_history: socket.assigns.command_history ++ [entry], input: "")}
      end
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if tab in Enum.map(@tabs, &elem(&1, 0)) do
      {:noreply, assign(socket, active_tab: tab)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_event_filter", %{"filter" => filter}, socket) do
    if filter in ~w(all errors warnings info) do
      {:noreply, assign(socket, event_filter: filter)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_event_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, event_search: String.trim(query || ""))}
  end

  @impl true
  def handle_event("clear_event_search", _params, socket) do
    {:noreply, assign(socket, event_search: "")}
  end

  @impl true
  def handle_event("clear_event_filters", _params, socket) do
    {:noreply, assign(socket, event_filter: "all", event_search: "")}
  end

  @impl true
  def handle_event("copy_event_json", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    event = Enum.find(socket.assigns.state.events, &(&1.id == id))

    if event do
      json = format_event_json(event)
      {:noreply, push_event(socket, "copy_to_clipboard", %{text: json, label: "Event JSON"})}
    else
      {:noreply, add_toast(socket, "Event not found", :error)}
    end
  end

  @impl true
  def handle_event("export_events", _params, socket) do
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

    {:noreply,
     push_event(socket, "copy_to_clipboard", %{
       text: json,
       label: "#{length(filtered)} events exported"
     })}
  rescue
    e -> {:noreply, add_toast(socket, "Export failed: #{Exception.message(e)}", :error)}
  end

  @impl true
  def handle_event("clear_events", _params, socket) do
    Muse.State.clear()
    state = Muse.State.get()
    socket = socket |> assign(state: state) |> add_toast("Events cleared", :info)
    {:noreply, socket}
  end

  @impl true
  def handle_event("simulate_event", _params, socket) do
    if Mix.env() != :prod do
      event = Muse.Event.new(:web, :simulated, %{text: "Simulated test event from dev tools"})
      Muse.State.append(event)
      state = Muse.State.get()
      socket = socket |> assign(state: state) |> add_toast("Simulated event created", :success)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("simulate_backend_error", _params, socket) do
    if Mix.env() != :prod do
      BackendBridge.safe_emit_simulated_error()
      # Also create an event in the event log for visibility
      event =
        Muse.Event.new(:web, :error, %{text: "Simulated backend error triggered from dev tools"})

      Muse.State.append(event)
      state = Muse.State.get()

      socket =
        socket
        |> assign(state: state)
        |> add_toast("Backend error simulated — check diagnostics", :warning)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("force_reload_watcher", _params, socket) do
    socket =
      case BackendBridge.safe_force_reload() do
        :ok -> socket |> add_toast("Watcher rescan triggered", :success)
        {:error, reason} -> socket |> add_toast("Watcher error: #{reason}", :warning)
      end

    {:noreply, assign(socket, reload_status: BackendBridge.safe_reload_status())}
  end

  @impl true
  def handle_event("refresh_stats", _params, socket) do
    {:noreply,
     assign(socket, beam_stats: Muse.BeamStats.snapshot()) |> add_toast("Stats refreshed", :info)}
  end

  @impl true
  def handle_event("dismiss_toast", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    toasts = Enum.reject(socket.assigns.toasts, &(&1.id == id))
    {:noreply, assign(socket, toasts: toasts)}
  end

  @impl true
  def handle_event("toggle_event_detail", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    new_id = if socket.assigns.expanded_event_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_event_id: new_id)}
  end

  @impl true
  def handle_event("copy_diagnostics", _params, socket) do
    payload = build_diagnostics_payload(socket.assigns)
    json = Jason.encode!(payload, pretty: true)
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: json, label: "Diagnostics"})}
  rescue
    e -> {:noreply, add_toast(socket, "Diagnostics copy failed: #{Exception.message(e)}", :error)}
  end

  @impl true
  def handle_event("command_palette_action", %{"action" => action}, socket) do
    socket = ConsoleCommand.execute_palette_action(action, socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("connect_agent_runtime", _params, socket) do
    case BackendBridge.safe_connect_agent_runtime() do
      {:error, reason} when is_binary(reason) ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()

        socket =
          socket |> assign(agent_runtime: runtime) |> add_toast("Runtime: #{reason}", :warning)

        {:noreply, socket}

      {:error, _} ->
        socket = socket |> add_toast("Agent runtime unavailable", :warning)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_agent_runtime", _params, socket) do
    case BackendBridge.safe_retry_agent_runtime() do
      {:error, reason} when is_binary(reason) ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()

        socket =
          socket |> assign(agent_runtime: runtime) |> add_toast("Runtime: #{reason}", :warning)

        {:noreply, socket}

      {:error, _} ->
        socket = socket |> add_toast("Agent runtime unavailable", :warning)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("disconnect_agent_runtime", _params, socket) do
    case BackendBridge.safe_disconnect_agent_runtime() do
      {:ok, _snapshot} ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()

        socket =
          socket |> assign(agent_runtime: runtime) |> add_toast("Runtime disconnected", :info)

        {:noreply, socket}

      {:error, _} ->
        socket = socket |> add_toast("Agent runtime unavailable", :warning)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_agent_runtime_endpoint", %{"endpoint" => endpoint}, socket) do
    case BackendBridge.safe_set_agent_runtime_endpoint(endpoint) do
      :ok ->
        runtime = BackendBridge.safe_agent_runtime_snapshot()
        {:noreply, assign(socket, agent_runtime: runtime)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_log_filter", %{"filter" => filter}, socket) do
    if filter in ~w(all errors warnings info debug) do
      {:noreply, assign(socket, log_filter: filter)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_log_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, log_search: String.trim(query || ""))}
  end

  @impl true
  def handle_event("clear_log_search", _params, socket) do
    {:noreply, assign(socket, log_search: "")}
  end

  @impl true
  def handle_event("clear_log_filters", _params, socket) do
    {:noreply, assign(socket, log_filter: "all", log_search: "")}
  end

  @impl true
  def handle_event("clear_logs", _params, socket) do
    case BackendBridge.safe_clear_logs() do
      :ok ->
        {:noreply,
         assign(socket, logs: BackendBridge.safe_logs()) |> add_toast("Logs cleared", :info)}

      {:error, _} ->
        {:noreply, add_toast(socket, "Log buffer unavailable", :warning)}
    end
  end

  @impl true
  def handle_event("copy_log_json", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    log = Enum.find(socket.assigns.logs, &(&1.id == id))

    if log do
      json = format_log_json(log)
      {:noreply, push_event(socket, "copy_to_clipboard", %{text: json, label: "Log JSON"})}
    else
      {:noreply, add_toast(socket, "Log not found", :error)}
    end
  end

  @impl true
  def handle_event("export_logs", _params, socket) do
    filtered =
      filtered_logs(
        socket.assigns.logs,
        socket.assigns.log_filter,
        socket.assigns.log_search
      )

    json = format_logs_json(filtered)

    {:noreply,
     push_event(socket, "copy_to_clipboard", %{
       text: json,
       label: "#{length(filtered)} logs exported"
     })}
  rescue
    e -> {:noreply, add_toast(socket, "Export failed: #{Exception.message(e)}", :error)}
  end

  @impl true
  def handle_event("toggle_log_detail", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    new_id = if socket.assigns.expanded_log_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_log_id: new_id)}
  end

  @impl true
  def handle_event("simulate_log", _params, socket) do
    if Mix.env() != :prod do
      case BackendBridge.safe_append_log(
             :info,
             "Simulated log entry from dev tools",
             %{simulated: true},
             :dev
           ) do
        {:ok, _entry} ->
          {:noreply,
           assign(socket, logs: BackendBridge.safe_logs())
           |> add_toast("Simulated log created", :success)}

        {:error, _} ->
          {:noreply, add_toast(socket, "Log buffer unavailable", :warning)}
      end
    else
      {:noreply, socket}
    end
  end

  # Diagnostics handlers (preserved from legacy)
  @impl true
  def handle_event("open_diagnostics", _params, socket) do
    {:noreply, assign(socket, diagnostics_open?: true) |> schedule_collapse()}
  end

  @impl true
  def handle_event("collapse_diagnostics", _params, socket) do
    cancel_timer(socket)

    {:noreply,
     assign(socket,
       diagnostics_open?: false,
       diagnostics_collapse_ref: nil,
       diagnostics_collapse_timer_ref: nil
     )}
  end

  @impl true
  def handle_event("queue_diagnostic_fix", %{"diagnostic_id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case Enum.find(socket.assigns.diagnostics, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      diagnostic ->
        case BackendBridge.safe_queue_diagnostic(diagnostic) do
          {:ok, issue} ->
            self_healing_issues =
              [issue | socket.assigns.self_healing_issues]
              |> Enum.uniq_by(& &1.diagnostic_id)

            statuses = Map.put(socket.assigns.diagnostic_issue_statuses, id, :queued)

            {:noreply,
             assign(socket,
               self_healing_issues: self_healing_issues,
               diagnostic_issue_statuses: statuses
             )}

          {:error, :duplicate} ->
            statuses = Map.put(socket.assigns.diagnostic_issue_statuses, id, :queued)
            {:noreply, assign(socket, diagnostic_issue_statuses: statuses)}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  # Legacy window handlers kept for compatibility
  @impl true
  def handle_event("toggle_window", %{"window" => _window_name}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_window", %{"window" => _window_name}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("focus_window", %{"window" => _window_name}, socket) do
    {:noreply, socket}
  end

  # -- Info handlers ----------------------------------------------------------

  @impl true
  def handle_info({:muse_event, _event}, socket) do
    state = Muse.State.get()
    reload_status = BackendBridge.safe_reload_status()
    {:noreply, assign(socket, state: state, reload_status: reload_status)}
  end

  @impl true
  def handle_info({:muse_events_cleared}, socket) do
    state = Muse.State.get()
    {:noreply, assign(socket, state: state)}
  end

  @impl true
  def handle_info({:muse_diagnostic, diagnostic}, socket) do
    diagnostics =
      [diagnostic | socket.assigns.diagnostics]
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(50)

    socket =
      socket
      |> assign(diagnostics: diagnostics, diagnostics_open?: true)
      |> schedule_collapse()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:muse_diagnostics_cleared}, socket) do
    cancel_timer(socket)

    {:noreply,
     assign(socket,
       diagnostics: [],
       diagnostics_open?: false,
       diagnostics_collapse_ref: nil,
       diagnostics_collapse_timer_ref: nil
     )}
  end

  @impl true
  def handle_info({:collapse_diagnostics, ref}, socket) do
    if socket.assigns.diagnostics_collapse_ref == ref do
      {:noreply,
       assign(socket,
         diagnostics_open?: false,
         diagnostics_collapse_ref: nil,
         diagnostics_collapse_timer_ref: nil
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:dismiss_toast, id}, socket) do
    toasts = Enum.reject(socket.assigns.toasts, &(&1.id == id))
    {:noreply, assign(socket, toasts: toasts)}
  end

  @impl true
  def handle_info({:muse_log, _entry}, socket) do
    {:noreply, assign(socket, logs: BackendBridge.safe_logs())}
  end

  @impl true
  def handle_info({:muse_logs_cleared}, socket) do
    {:noreply, assign(socket, logs: BackendBridge.safe_logs())}
  end

  @impl true
  def handle_info({:muse_agent_runtime_updated, snapshot}, socket) do
    {:noreply, assign(socket, agent_runtime: snapshot)}
  end

  @impl true
  def handle_info({:muse_agent_registry_updated, snapshot}, socket) do
    {:noreply, assign(socket, agent_snapshot: snapshot)}
  end

  @impl true
  def handle_info({:self_healing_issue_added, issue}, socket) do
    if Enum.any?(socket.assigns.self_healing_issues, &(&1.id == issue.id)) do
      statuses = Map.put(socket.assigns.diagnostic_issue_statuses, issue.diagnostic_id, :queued)
      {:noreply, assign(socket, diagnostic_issue_statuses: statuses)}
    else
      self_healing_issues =
        [issue | socket.assigns.self_healing_issues]
        |> Enum.uniq_by(& &1.diagnostic_id)

      statuses = Map.put(socket.assigns.diagnostic_issue_statuses, issue.diagnostic_id, :queued)

      {:noreply,
       assign(socket,
         self_healing_issues: self_healing_issues,
         diagnostic_issue_statuses: statuses
       )}
    end
  end

  @impl true
  def handle_info({:self_healing_issue_updated, issue}, socket) do
    self_healing_issues =
      Enum.map(socket.assigns.self_healing_issues, fn existing ->
        if existing.id == issue.id, do: issue, else: existing
      end)

    statuses =
      Map.put(socket.assigns.diagnostic_issue_statuses, issue.diagnostic_id, issue.status)

    {:noreply,
     assign(socket, self_healing_issues: self_healing_issues, diagnostic_issue_statuses: statuses)}
  end

  @impl true
  def handle_info({:self_healing_issue_removed, _issue}, socket) do
    self_healing_issues = BackendBridge.safe_self_healing_issues()
    statuses = compute_issue_statuses(self_healing_issues)

    {:noreply,
     assign(socket, self_healing_issues: self_healing_issues, diagnostic_issue_statuses: statuses)}
  end

  @impl true
  def handle_info({:self_healing_issues_cleared, _fixed}, socket) do
    self_healing_issues = BackendBridge.safe_self_healing_issues()
    statuses = compute_issue_statuses(self_healing_issues)

    {:noreply,
     assign(socket, self_healing_issues: self_healing_issues, diagnostic_issue_statuses: statuses)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <main id="muse-shell" class="app-shell" phx-hook="KeyboardShortcuts">
      <div id="clipboard-handler" phx-hook="ClipboardHandler" style="display:none" aria-hidden="true"></div>
      <.app_header tabs={@tabs} active_tab={@active_tab} />
      <.status_bar state={@state} reload_status={@reload_status} workspace={@workspace} diagnostics={@diagnostics} diagnostics_open?={@diagnostics_open?} agent_runtime={@agent_runtime} />
      <.diagnostics_popup diagnostics={@diagnostics} diagnostics_open?={@diagnostics_open?} diagnostic_issue_statuses={@diagnostic_issue_statuses} self_healing_issues={@self_healing_issues} />
      <div class="console-layout">
        <main class="console-main">
          <%= case @active_tab do %>
            <% "events" -> %>
              <.events_tab events={@state.events} filter={@event_filter} search={@event_search} expanded_id={@expanded_event_id} />
            <% "logs" -> %>
              <.logs_tab logs={@logs} filter={@log_filter} search={@log_search} expanded_id={@expanded_log_id} />
            <% "files" -> %>
              <.files_tab reload_status={@reload_status} />
            <% "agents" -> %>
              <.agents_tab agent_snapshot={@agent_snapshot} agent_runtime={@agent_runtime} />
            <% "stats" -> %>
              <.stats_tab beam_stats={@beam_stats} />
            <% "settings" -> %>
              <.settings_tab workspace={@workspace} reload_status={@reload_status} />
          <% end %>
        </main>
        <.dev_sidebar reload_status={@reload_status} command_history={@command_history} />
      </div>
      <.command_console input={@input} command_history={@command_history} />
      <div id="command-palette" class="command-palette" role="dialog" aria-label="Command palette" aria-modal="true" phx-hook="CommandPalette" data-palette-actions={Jason.encode!(palette_actions())} style="display:none">
        <div class="command-palette-backdrop" data-action="close"></div>
        <div class="command-palette-inner">
          <input
            type="text"
            class="command-palette-input"
            placeholder="Type a command or action…"
            aria-label="Search commands and actions"
          />
          <ul id="command-palette-list" class="command-palette-list" role="listbox" aria-label="Suggestions" phx-update="ignore"></ul>
          <div class="command-palette-footer">
            <span class="palette-hint">↑↓ Navigate · ↵ Select · Esc Close</span>
            <span class="palette-shortcut">Ctrl+K</span>
          </div>
        </div>
      </div>
      <.toast_container toasts={@toasts} />
    </main>
    """
  end

  # -- Private helpers (remaining in HomeLive) --------------------------------

  defp make_history_entry(input, output, type) do
    %{
      id: System.unique_integer([:positive]),
      input: input,
      output: output,
      type: type,
      timestamp: format_timestamp(DateTime.utc_now())
    }
  end

  defp add_toast(socket, message, type) do
    id = System.unique_integer([:positive])
    toast = %{id: id, message: message, type: type}

    if connected?(socket) do
      Process.send_after(self(), {:dismiss_toast, id}, @toast_timeout_ms)
    end

    assign(socket, toasts: socket.assigns.toasts ++ [toast])
  end

  defp schedule_collapse(socket) do
    cancel_timer(socket)

    ref = make_ref()
    timer_ref = Process.send_after(self(), {:collapse_diagnostics, ref}, @collapse_timeout_ms)
    assign(socket, diagnostics_collapse_ref: ref, diagnostics_collapse_timer_ref: timer_ref)
  end

  defp cancel_timer(socket) do
    if timer_ref = socket.assigns.diagnostics_collapse_timer_ref do
      Process.cancel_timer(timer_ref)
    end

    :ok
  end

  defp compute_issue_statuses(issues) do
    Map.new(issues, fn issue -> {issue.diagnostic_id, issue.status} end)
  end
end
