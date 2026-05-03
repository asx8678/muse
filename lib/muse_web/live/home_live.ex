defmodule MuseWeb.HomeLive do
  use MuseWeb, :live_view

  import MuseWeb.ConsoleComponents,
    only: [
      app_header: 1,
      chat_panel: 1,
      context_panel: 1,
      diagnostics_popup: 1,
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

  alias MuseWeb.BackendBridge
  alias MuseWeb.ConsoleCommand

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

    # Diagnostics drawer always closed on initial render, even if diagnostics exist
    diagnostics_open? = false

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
        sidebar_state: :expanded,
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
            {:noreply, socket |> assign(state: state, input: "") |> push_clear_command_input()}
          rescue
            e ->
              socket = socket |> assign(input: text) |> add_toast(Exception.message(e), :error)
              {:noreply, socket}
          end

        {:command, action} ->
          {output, socket} = ConsoleCommand.dispatch_command(action, socket)

          toast_type =
            if(String.starts_with?(output, "Error"), do: :error, else: :success)

          entry = make_history_entry(text, output, toast_type)
          socket = add_toast(socket, output, toast_type)

          {:noreply,
           socket
           |> assign(command_history: socket.assigns.command_history ++ [entry], input: "")
           |> push_clear_command_input()}

        {:command, action, args} ->
          {output, socket} = ConsoleCommand.dispatch_command_with_args(action, args, socket)

          toast_type =
            if(String.starts_with?(output, "Error"), do: :error, else: :success)

          entry = make_history_entry(text, output, toast_type)
          socket = add_toast(socket, output, toast_type)

          {:noreply,
           socket
           |> assign(command_history: socket.assigns.command_history ++ [entry], input: "")
           |> push_clear_command_input()}

        {:unknown, cmd} ->
          msg = "Unknown command: #{cmd}. Type /help for available commands."
          entry = make_history_entry(text, msg, :error)
          socket = socket |> add_toast(msg, :error)

          {:noreply,
           socket
           |> assign(command_history: socket.assigns.command_history ++ [entry], input: "")
           |> push_clear_command_input()}
      end
    end
  end

  @impl true
  def handle_event("use_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, input: prompt)}
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
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        event = Enum.find(socket.assigns.state.events, &(&1.id == id))

        if event do
          json = format_event_json(event)
          {:noreply, push_event(socket, "copy_to_clipboard", %{text: json, label: "Event JSON"})}
        else
          {:noreply, add_toast(socket, "Event not found", :error)}
        end

      :error ->
        {:noreply, add_toast(socket, "Invalid event ID", :error)}
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
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        toasts = Enum.reject(socket.assigns.toasts, &(&1.id == id))
        {:noreply, assign(socket, toasts: toasts)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_event_detail", %{"id" => id_str}, socket) do
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        new_id = if socket.assigns.expanded_event_id == id, do: nil, else: id
        {:noreply, assign(socket, expanded_event_id: new_id)}

      :error ->
        {:noreply, socket}
    end
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
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        log = Enum.find(socket.assigns.logs, &(&1.id == id))

        if log do
          json = format_log_json(log)
          {:noreply, push_event(socket, "copy_to_clipboard", %{text: json, label: "Log JSON"})}
        else
          {:noreply, add_toast(socket, "Log not found", :error)}
        end

      :error ->
        {:noreply, add_toast(socket, "Invalid log ID", :error)}
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
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        new_id = if socket.assigns.expanded_log_id == id, do: nil, else: id
        {:noreply, assign(socket, expanded_log_id: new_id)}

      :error ->
        {:noreply, socket}
    end
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

  # -- Sidebar handlers -------------------------------------------------------

  @impl true
  def handle_event("set_sidebar_state", %{"state" => state_str}, socket) do
    case state_str do
      s when s in ~w(expanded rail hidden) ->
        {:noreply, assign(socket, sidebar_state: String.to_atom(s))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    new_state =
      case socket.assigns.sidebar_state do
        :expanded -> :rail
        :rail -> :expanded
        :hidden -> :expanded
      end

    {:noreply, assign(socket, sidebar_state: new_state)}
  end

  # -- Diagnostics handlers ---------------------------------------------------

  @impl true
  def handle_event("open_diagnostics", _params, socket) do
    {:noreply, assign(socket, diagnostics_open?: true)}
  end

  @impl true
  def handle_event("collapse_diagnostics", _params, socket) do
    {:noreply, assign(socket, diagnostics_open?: false)}
  end

  @impl true
  def handle_event("queue_diagnostic_fix", %{"diagnostic_id" => id_str}, socket) do
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
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

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("copy_diagnostic", %{"diagnostic_id" => id_str}, socket) do
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        case Enum.find(socket.assigns.diagnostics, &(&1.id == id)) do
          nil ->
            {:noreply, add_toast(socket, "Diagnostic not found", :error)}

          diagnostic ->
            text = "#{String.upcase(to_string(diagnostic.level))}: #{diagnostic.message}"

            {:noreply,
             push_event(socket, "copy_to_clipboard", %{text: text, label: "Diagnostic"})}
        end

      :error ->
        {:noreply, add_toast(socket, "Invalid diagnostic ID", :error)}
    end
  end

  @impl true
  def handle_event("jump_to_diagnostic_file", %{"diagnostic_id" => id_str}, socket) do
    case MuseWeb.safe_to_integer(id_str) do
      {:ok, id} ->
        case Enum.find(socket.assigns.diagnostics, &(&1.id == id)) do
          nil ->
            {:noreply, add_toast(socket, "Diagnostic not found", :error)}

          diagnostic ->
            file = diagnostic_file(diagnostic)
            line = diagnostic_line(diagnostic)

            if file do
              {:noreply,
               push_event(socket, "jump_to_file", %{
                 file: file,
                 line: line || 1
               })}
            else
              {:noreply, add_toast(socket, "No file location in this diagnostic", :warning)}
            end
        end

      :error ->
        {:noreply, add_toast(socket, "Invalid diagnostic ID", :error)}
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

    # Do NOT auto-open drawer or schedule collapse
    socket = assign(socket, diagnostics: diagnostics)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:muse_diagnostics_cleared}, socket) do
    {:noreply, assign(socket, diagnostics: [], diagnostics_open?: false)}
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
      <.app_header workspace={@workspace} reload_status={@reload_status} state={@state} diagnostics={@diagnostics} diagnostics_open?={@diagnostics_open?} agent_runtime={@agent_runtime} sidebar_state={@sidebar_state} />
      <main class={"main-layout sidebar-#{@sidebar_state}"}>
        <.context_panel workspace={@workspace} reload_status={@reload_status} diagnostics={@diagnostics} diagnostics_open?={@diagnostics_open?} agent_runtime={@agent_runtime} agent_snapshot={@agent_snapshot} beam_stats={@beam_stats} logs={@logs} sidebar_state={@sidebar_state} diagnostic_issue_statuses={@diagnostic_issue_statuses} self_healing_issues={@self_healing_issues} />
        <.chat_panel messages={chat_messages(@state.events)} input={@input} />
      </main>
      <.diagnostics_popup diagnostics={@diagnostics} diagnostics_open?={@diagnostics_open?} diagnostic_issue_statuses={@diagnostic_issue_statuses} self_healing_issues={@self_healing_issues} />
      <.toast_container toasts={@toasts} />
    </main>
    """
  end

  # -- Private helpers --------------------------------------------------------

  defp make_history_entry(input, output, type) do
    %{
      id: System.unique_integer([:positive]),
      input: input,
      output: output,
      type: type,
      timestamp: format_timestamp(DateTime.utc_now())
    }
  end

  defp push_clear_command_input(socket) do
    push_event(socket, "clear_command_input", %{})
  end

  defp add_toast(socket, message, type) do
    id = System.unique_integer([:positive])
    toast = %{id: id, message: message, type: type}

    if connected?(socket) do
      Process.send_after(self(), {:dismiss_toast, id}, @toast_timeout_ms)
    end

    assign(socket, toasts: socket.assigns.toasts ++ [toast])
  end

  defp compute_issue_statuses(issues) do
    Map.new(issues, fn issue -> {issue.diagnostic_id, issue.status} end)
  end

  defp diagnostic_file(%{metadata: meta}) when is_map(meta) do
    Map.get(meta, :file) || Map.get(meta, "file")
  end

  defp diagnostic_file(_), do: nil

  defp diagnostic_line(%{metadata: meta}) when is_map(meta) do
    line = Map.get(meta, :line) || Map.get(meta, "line")
    MuseWeb.safe_to_integer_or_nil(line)
  end

  defp diagnostic_line(_), do: nil

  # -- Chat-first helpers -----------------------------------------------------

  defp chat_messages(events) do
    events
    |> Enum.filter(&(&1.type in [:user_message, :assistant_message]))
    |> Enum.map(fn event ->
      %{
        id: event.id,
        role: chat_role(event),
        text: chat_text(event),
        timestamp: format_timestamp(event.timestamp),
        source: event.source
      }
    end)
  end

  defp chat_role(%{type: :assistant_message}), do: :assistant
  defp chat_role(%{type: :user_message}), do: :user
  defp chat_role(_), do: :system

  defp chat_text(%{data: data}) when is_map(data),
    do: Map.get(data, :text) || Map.get(data, "text") || ""

  defp chat_text(%{data: data}) when is_binary(data), do: data
  defp chat_text(%{data: nil}), do: ""
  defp chat_text(%{data: data}), do: inspect(data)
end
