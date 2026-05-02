defmodule MuseWeb.HomeLive do
  use MuseWeb, :live_view

  @collapse_timeout_ms 10_000

  # Allowed window names — never convert arbitrary user strings to atoms
  @window_names %{
    "events" => "Events",
    "reload" => "Recent files",
    "universal-agent" => "Universal agent",
    "settings" => "Settings",
    "statistics" => "Statistics",
    "agents" => "Agent tree"
  }

  @impl true
  def mount(_params, _session, socket) do
    state = Muse.State.get()
    workspace = safe_workspace_root()
    reload_status = safe_reload_status()
    diagnostics = safe_diagnostics()
    self_healing_issues = safe_self_healing_issues()
    diagnostic_issue_statuses = compute_issue_statuses(self_healing_issues)

    diagnostics_open? = diagnostics != []

    if connected?(socket) do
      Muse.State.subscribe()
      safe_subscribe_diagnostics()
      safe_subscribe_self_healing()
      safe_subscribe_agent_registry()
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
        open_windows: MapSet.new(),
        active_window: nil,
        beam_stats: Muse.BeamStats.snapshot(),
        agent_snapshot: safe_agent_snapshot()
      )

    # Schedule initial collapse if diagnostics exist on mount
    socket =
      if diagnostics_open? and connected?(socket) do
        schedule_collapse(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("submit", %{"text" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      try do
        Muse.submit(:web, text)
        state = Muse.State.get()
        {:noreply, assign(socket, state: state, input: "")}
      rescue
        e ->
          {:noreply, socket |> put_flash(:error, Exception.message(e)) |> assign(input: text)}
      end
    end
  end

  @impl true
  def handle_event("simulate_backend_error", _params, socket) do
    if Mix.env() != :prod do
      safe_emit_simulated_error()
    end

    {:noreply, socket}
  end

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
  def handle_event("toggle_window", %{"window" => window_name}, socket) do
    if Map.has_key?(@window_names, window_name) do
      open = socket.assigns.open_windows

      if MapSet.member?(open, window_name) do
        new_open = MapSet.delete(open, window_name)

        new_active =
          if socket.assigns.active_window == window_name,
            do: nil,
            else: socket.assigns.active_window

        {:noreply, assign(socket, open_windows: new_open, active_window: new_active)}
      else
        new_open = MapSet.put(open, window_name)
        {:noreply, assign(socket, open_windows: new_open, active_window: window_name)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_window", %{"window" => window_name}, socket) do
    new_open = MapSet.delete(socket.assigns.open_windows, window_name)

    new_active =
      if socket.assigns.active_window == window_name, do: nil, else: socket.assigns.active_window

    {:noreply, assign(socket, open_windows: new_open, active_window: new_active)}
  end

  @impl true
  def handle_event("focus_window", %{"window" => window_name}, socket) do
    {:noreply, assign(socket, active_window: window_name)}
  end

  @impl true
  def handle_event("refresh_stats", _params, socket) do
    {:noreply, assign(socket, beam_stats: Muse.BeamStats.snapshot())}
  end

  @impl true
  def handle_event("queue_diagnostic_fix", %{"diagnostic_id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case Enum.find(socket.assigns.diagnostics, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      diagnostic ->
        case safe_queue_diagnostic(diagnostic) do
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

  @impl true
  def handle_info({:muse_event, _event}, socket) do
    state = Muse.State.get()
    reload_status = safe_reload_status()
    {:noreply, assign(socket, state: state, reload_status: reload_status)}
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
    self_healing_issues = safe_self_healing_issues()
    statuses = compute_issue_statuses(self_healing_issues)

    {:noreply,
     assign(socket, self_healing_issues: self_healing_issues, diagnostic_issue_statuses: statuses)}
  end

  @impl true
  def handle_info({:self_healing_issues_cleared, _fixed}, socket) do
    self_healing_issues = safe_self_healing_issues()
    statuses = compute_issue_statuses(self_healing_issues)

    {:noreply,
     assign(socket, self_healing_issues: self_healing_issues, diagnostic_issue_statuses: statuses)}
  end

  # Catch-all for unknown PubSub messages
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <header class="app-header">
        <div class="app-brand">
          <span class="brand-mark">Muse</span>
          <span class="brand-context">Backend console</span>
        </div>
        <div class="header-actions">
          <div class="icon-dock">
            <button type="button" class={"dock-icon #{window_active?(@open_windows, "events")}"} phx-click="toggle_window" phx-value-window="events" title="Events" aria-label="Open events window">📋</button>
            <button type="button" class={"dock-icon #{window_active?(@open_windows, "reload")}"} phx-click="toggle_window" phx-value-window="reload" title="Recent files" aria-label="Open recent files window">📂</button>
            <button type="button" class={"dock-icon #{window_active?(@open_windows, "universal-agent")}"} phx-click="toggle_window" phx-value-window="universal-agent" title="Universal agent" aria-label="Open universal agent window">🤖</button>
            <button type="button" class={"dock-icon #{window_active?(@open_windows, "settings")}"} phx-click="toggle_window" phx-value-window="settings" title="Settings" aria-label="Open settings window">⚙️</button>
            <button type="button" class={"dock-icon #{window_active?(@open_windows, "statistics")}"} phx-click="toggle_window" phx-value-window="statistics" title="Statistics" aria-label="Open statistics window">📊</button>
            <button type="button" class={"dock-icon #{window_active?(@open_windows, "agents")}"} phx-click="toggle_window" phx-value-window="agents" title="Agent tree" aria-label="Open agent tree window">🌳</button>
          </div>
          <button
            type="button"
            id="reload-status"
            class={"reload-pill " <> window_active?(@open_windows, "reload")}
            phx-click="toggle_window"
            phx-value-window="reload"
            aria-label="Open recent files window"
          >
            <%= reload_pill_text(@reload_status) %>
          </button>
          <%= if @diagnostics != [] and not @diagnostics_open? do %>
            <button
              type="button"
              id="diagnostics-badge"
              class="diagnostic-pill"
              phx-click="open_diagnostics"
              aria-label="Open diagnostics panel"
            >
              ⚠ <%= length(@diagnostics) %> diagnostic<%= if length(@diagnostics) != 1, do: "s", else: "" %>
            </button>
          <% end %>
          <div id="workspace" class="workspace-chip" title={@workspace}>
            <span class="workspace-label">Workspace</span>
            <span class="workspace-path"><%= @workspace %></span>
          </div>
        </div>
      </header>

      <%= if @diagnostics != [] and @diagnostics_open? do %>
        <aside id="diagnostics-popup" class="diagnostics-popup" role="region" aria-labelledby="diagnostics-title" aria-live="polite">
          <div class="diagnostic-title-bar">
            <span id="diagnostics-title" class="diagnostic-title">Backend diagnostics</span>
            <button type="button" class="diagnostics-collapse-btn" phx-click="collapse_diagnostics" title="Minimize" aria-label="Minimize diagnostics panel">
              ✕
            </button>
          </div>
          <%= for diagnostic <- Enum.take(@diagnostics, 5) do %>
            <article class={["diagnostic-notice", Atom.to_string(diagnostic.level)]}>
              <div class="diagnostic-header">
                <span class="diagnostic-level"><%= diagnostic.level |> Atom.to_string() |> String.upcase() %></span>
                <time class="diagnostic-timestamp" datetime={DateTime.to_iso8601(diagnostic.timestamp)}>
                  <%= diagnostic_timestamp(diagnostic.timestamp) %>
                </time>
              </div>
              <p class="diagnostic-message"><%= diagnostic.message %></p>
              <div class="diagnostic-actions">
                <%= case Map.get(@diagnostic_issue_statuses, diagnostic.id) do %>
                  <% nil -> %>
                    <button
                      type="button"
                      class="diagnostic-action-btn"
                      phx-click="queue_diagnostic_fix"
                      phx-value-diagnostic_id={Integer.to_string(diagnostic.id)}
                    >
                      Add to next agent turn
                    </button>
                  <% :queued -> %>
                    <button type="button" class="diagnostic-queued" disabled>Queued for next agent turn</button>
                  <% :in_progress -> %>
                    <button type="button" class="diagnostic-queued" disabled>In progress</button>
                  <% :fixed -> %>
                    <button type="button" class="diagnostic-queued" disabled>Already fixed</button>
                  <% :failed -> %>
                    <button type="button" class="diagnostic-queued" disabled>Self-healing failed</button>
                  <% :ignored -> %>
                    <button type="button" class="diagnostic-queued" disabled>Ignored</button>
                <% end %>
              </div>
            </article>
          <% end %>
          <%= if length(@diagnostics) > 5 do %>
            <p class="diagnostics-more">+<%= length(@diagnostics) - 5 %> more backend diagnostics</p>
          <% end %>
          <%= if @self_healing_issues != [] do %>
            <div class="self-healing-summary">
              <span class="self-healing-summary-title">Self-healing queue: <%= length(@self_healing_issues) %> issue<%= if length(@self_healing_issues) != 1, do: "s", else: "" %></span>
            </div>
          <% end %>
        </aside>
      <% end %>

      <%= if MapSet.member?(@open_windows, "events") do %>
        <div id="window-events" class="managed-window" phx-hook="DraggableWindow">
          <div class="window-title-bar">
            <span class="window-title">Events</span>
            <button type="button" class="window-close-btn" phx-click="close_window" phx-value-window="events" aria-label="Close events window">✕</button>
          </div>
          <div class="window-body">
            <%= for event <- Enum.reverse(@state.events) |> Enum.take(20) do %>
              <div class={event_row_class(event)}>
                <span class="event-source"><%= event.source %></span>
                <span class={event_badge_class(event)}><%= event.type %></span>
                <span class="event-meta"><%= event_meta(event) %></span>
              </div>
            <% end %>
            <%= if @state.events == [] do %>
              <p class="agent-placeholder">No events yet</p>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if MapSet.member?(@open_windows, "reload") do %>
        <div id="window-reload" class="managed-window" phx-hook="DraggableWindow">
          <div class="window-title-bar">
            <span class="window-title">Recent files</span>
            <button type="button" class="window-close-btn" phx-click="close_window" phx-value-window="reload" aria-label="Close recent files window">✕</button>
          </div>
          <div class="window-body">
            <%= if @reload_status[:status] == :unavailable do %>
              <p class="agent-placeholder">Reload unavailable</p>
            <% else %>
              <div class="stat-row">
                <span class="stat-label">Generation</span>
                <span class="stat-value"><%= @reload_status[:generation] %></span>
              </div>
              <%= if @reload_status[:last_error] do %>
                <div class="stat-row">
                  <span class="stat-label">Last error</span>
                  <span class="stat-value"><%= @reload_status[:last_error] %></span>
                </div>
              <% end %>
              <%= for file <- (@reload_status[:recent_files] || []) do %>
                <div class="file-entry">
                  <div class="file-path"><%= file[:basename] %></div>
                  <div class="file-meta">
                    <span><%= file[:modified_count] %> reload<%= if file[:modified_count] != 1, do: "s", else: "" %></span>
                    <span>+<%= file[:lines_added] %> lines</span>
                  </div>
                </div>
              <% end %>
              <%= if (@reload_status[:recent_files] || []) == [] do %>
                <p class="agent-placeholder">No recent file changes</p>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if MapSet.member?(@open_windows, "universal-agent") do %>
        <div id="window-universal-agent" class="managed-window" phx-hook="DraggableWindow">
          <div class="window-title-bar">
            <span class="window-title">Universal agent</span>
            <button type="button" class="window-close-btn" phx-click="close_window" phx-value-window="universal-agent" aria-label="Close universal agent window">✕</button>
          </div>
          <div class="window-body">
            <p class="agent-placeholder">No universal agent runtime connected</p>
          </div>
        </div>
      <% end %>

      <%= if MapSet.member?(@open_windows, "settings") do %>
        <div id="window-settings" class="managed-window" phx-hook="DraggableWindow">
          <div class="window-title-bar">
            <span class="window-title">Settings</span>
            <button type="button" class="window-close-btn" phx-click="close_window" phx-value-window="settings" aria-label="Close settings window">✕</button>
          </div>
          <div class="window-body">
            <div class="settings-row">
              <span class="settings-label">Theme</span>
              <span class="settings-value">Dark</span>
            </div>
            <div class="settings-row">
              <span class="settings-label">Workspace</span>
              <span class="settings-value"><%= @workspace %></span>
            </div>
            <div class="settings-row">
              <span class="settings-label">Watch mode</span>
              <span class="settings-value"><%= if @reload_status[:status] == :unavailable, do: "Off", else: "On" %></span>
            </div>
          </div>
        </div>
      <% end %>

      <%= if MapSet.member?(@open_windows, "statistics") do %>
        <div id="window-statistics" class="managed-window" phx-hook="DraggableWindow">
          <div class="window-title-bar">
            <span class="window-title">Statistics</span>
            <button type="button" class="window-close-btn" phx-click="close_window" phx-value-window="statistics" aria-label="Close statistics window">✕</button>
          </div>
          <div class="window-body">
            <div class="stat-section-title">Memory</div>
            <div class="stat-row">
              <span class="stat-label">Total</span>
              <span class="stat-value"><%= format_bytes(@beam_stats.total_memory) %></span>
            </div>
            <%= for {key, val} <- (Map.get(@beam_stats, :memory, %{}) |> Enum.sort()) do %>
              <div class="stat-row">
                <span class="stat-label"><%= format_mem_key(key) %></span>
                <span class="stat-value"><%= format_bytes(val) %></span>
              </div>
            <% end %>
            <div class="stat-section-title">Processes</div>
            <div class="stat-row">
              <span class="stat-label">Count</span>
              <span class="stat-value"><%= @beam_stats.process_count %></span>
            </div>
            <div class="stat-row">
              <span class="stat-label">Limit</span>
              <span class="stat-value"><%= @beam_stats.process_limit %></span>
            </div>
            <div class="stat-section-title">Ports</div>
            <div class="stat-row">
              <span class="stat-label">Count / Limit</span>
              <span class="stat-value"><%= @beam_stats.port_count %> / <%= @beam_stats.port_limit %></span>
            </div>
            <div class="stat-section-title">Schedulers</div>
            <div class="stat-row">
              <span class="stat-label">Total / Online</span>
              <span class="stat-value"><%= @beam_stats.scheduler_count %> / <%= @beam_stats.schedulers_online %></span>
            </div>
            <div class="stat-section-title">Runtime</div>
            <div class="stat-row">
              <span class="stat-label">OTP Release</span>
              <span class="stat-value"><%= @beam_stats.otp_release %></span>
            </div>
            <button type="button" class="secondary-button" phx-click="refresh_stats" style="margin-top:8px;width:100%">Refresh</button>
          </div>
        </div>
      <% end %>

      <%= if MapSet.member?(@open_windows, "agents") do %>
        <div id="window-agents" class="managed-window" phx-hook="DraggableWindow">
          <div class="window-title-bar">
            <span class="window-title">Agent tree</span>
            <button type="button" class="window-close-btn" phx-click="close_window" phx-value-window="agents" aria-label="Close agent tree window">✕</button>
          </div>
          <div class="window-body">
            <%= if @agent_snapshot == :unavailable do %>
              <p class="agent-placeholder">Agent registry unavailable</p>
            <% else %>
              <%= for agent <- sorted_agents(@agent_snapshot.agents) do %>
                <div class={"agent-entry #{agent_indent_class(agent, @agent_snapshot.agents)}"}>
                  <div class="agent-header-row">
                    <span class="agent-name"><%= agent.name %></span>
                    <span class={"agent-status #{agent.status}"}><%= agent.status %></span>
                  </div>
                  <%= if agent.task do %>
                    <div class="agent-detail">✦ <%= agent.task %></div>
                  <% end %>
                  <%= if agent.current_tool do %>
                    <div class="agent-detail">🔧 <%= agent.current_tool %></div>
                  <% end %>
                  <%= if agent.current_file do %>
                    <div class="agent-detail">📂 <%= agent.current_file %></div>
                  <% end %>
                  <%= if agent.progress != nil do %>
                    <div class="agent-progress-row">
                      <div class="agent-progress-bar">
                        <div class="agent-progress-fill" style={"width:#{round(agent.progress * 100)}%"}></div>
                      </div>
                      <span class="agent-progress-label"><%= round(agent.progress * 100) %>%</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <%= if @agent_snapshot.agents == [] do %>
                <p class="agent-placeholder">No agents registered</p>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <div class="dashboard-grid">
        <section id="events" class="panel events-panel">
          <div class="panel-header">
            <h2 class="panel-title">Events</h2>
            <p class="panel-description"><%= length(@state.events) %> event<%= if length(@state.events) != 1, do: "s", else: "" %> received · newest first</p>
          </div>
          <div class="panel-body event-log">
            <%= for event <- Enum.reverse(@state.events) do %>
              <article class={event_row_class(event)}>
                <div class="event-main">
                  <span class="event-source"><%= event.source %></span>
                  <span class={event_badge_class(event)}><%= event.type %></span>
                  <span class="event-meta"><%= event_meta(event) %></span>
                </div>
                <div class="event-message"><%= event_display(event) %></div>
              </article>
            <% end %>
          </div>
        </section>

        <aside class="side-panel">
                    <%= if Mix.env() != :prod do %>
            <section id="dev-tools" class="panel dev-tools-panel">
              <div class="panel-header">
                <h2 class="panel-title">Dev tools</h2>
              </div>
              <div class="panel-body">
                <button type="button" class="secondary-button" phx-click="simulate_backend_error">Simulate backend error</button>
              </div>
            </section>
          <% end %>
        </aside>
      </div>

      <section id="input-form" class="panel command-panel">
        <div class="panel-header">
          <h2 class="panel-title">Command</h2>
          <p class="panel-description">Send a message or command to Muse.</p>
        </div>
        <div class="panel-body">
          <form phx-submit="submit" class="command-bar">
            <input type="text" name="text" value={@input} class="command-input" placeholder="Enter command or message..." />
            <button type="submit" class="primary-button">Send</button>
          </form>
        </div>
      </section>
    </main>
    """
  end

  # -- Private helpers ----------------------------------------------------------

  defp window_active?(open_windows, name) do
    if MapSet.member?(open_windows, name), do: "active", else: ""
  end

  defp reload_pill_text(%{status: :unavailable}), do: "Reload unavailable"

  defp reload_pill_text(%{recent_file: %{basename: basename, lines_added: lines}})
       when is_binary(basename) do
    "#{basename} · +#{lines} lines"
  end

  defp reload_pill_text(%{generation: gen}) when is_integer(gen) and gen > 0 do
    "Reload gen #{gen}"
  end

  defp reload_pill_text(_), do: "Watching files"

  defp sorted_agents(agents) do
    # Simple parent/child ordering: parent agents first, children indented under parent
    # Build a lookup for parent_id -> children, then flatten
    by_id = Map.new(agents, &{&1.id, &1})
    roots = Enum.filter(agents, &(is_nil(&1.parent_id) or not Map.has_key?(by_id, &1.parent_id)))

    Enum.flat_map(roots, fn root ->
      children = Enum.filter(agents, &(&1.parent_id == root.id))
      [root | children]
    end)
  end

  defp agent_indent_class(agent, all_agents) do
    if agent.parent_id != nil and Enum.any?(all_agents, &(&1.id == agent.parent_id)) do
      "agent-child"
    else
      ""
    end
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp format_mem_key(key) when is_atom(key) do
    key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_mem_key(key), do: to_string(key)

  defp event_display(%Muse.Event{data: %{text: text}}), do: text
  defp event_display(%Muse.Event{data: %{file: file}}), do: file

  defp event_display(%Muse.Event{data: %{files: files}}) when is_list(files),
    do: Enum.join(files, ", ")

  defp event_display(%Muse.Event{data: %{issues: issues}}) when is_list(issues),
    do: "#{length(issues)} issue(s) attached"

  defp event_display(%Muse.Event{data: data}), do: inspect(data)

  defp event_row_class(%Muse.Event{type: type, data: data}) do
    cond do
      errorish?(type) or errorish?(data) -> "event-row event-row-error"
      successish?(type) -> "event-row event-row-success"
      true -> "event-row"
    end
  end

  defp event_badge_class(%Muse.Event{type: type, data: data}) do
    cond do
      errorish?(type) or errorish?(data) ->
        "event-badge event-badge-danger"

      successish?(type) ->
        "event-badge event-badge-success"

      type in [:user_message, :assistant_message, :queued_issues_attached] ->
        "event-badge event-badge-accent"

      true ->
        "event-badge event-badge-neutral"
    end
  end

  defp event_meta(%Muse.Event{timestamp: timestamp, data: data}) do
    parts = []

    parts =
      case timestamp do
        %DateTime{} -> [diagnostic_timestamp(timestamp) | parts]
        _ -> parts
      end

    parts =
      if is_map(data) and Map.has_key?(data, :generation) do
        ["gen #{data[:generation]}" | parts]
      else
        parts
      end

    parts =
      if is_map(data) and is_list(data[:files]) do
        n = length(data[:files])
        label = if n == 1, do: "file", else: "files"
        ["#{n} #{label}" | parts]
      else
        parts
      end

    parts
    |> Enum.reverse()
    |> Enum.join(" · ")
  end

  defp errorish?(term) when is_atom(term) do
    term in [:error, :failed, :failure, :critical, :reload_failed]
  end

  defp errorish?(%{type: type}), do: errorish?(type)

  defp errorish?(term) when is_binary(term) do
    String.downcase(term) in ["error", "failed", "failure", "critical"]
  end

  defp errorish?(_), do: false

  defp successish?(term) when is_atom(term) do
    term in [:success, :reloaded, :fixed, :info, :reload_success, :rollback_success]
  end

  defp successish?(term) when is_binary(term) do
    down = String.downcase(term)
    down in ["success", "reloaded", "fixed", "info", "reload_success", "rollback_success"]
  end

  defp successish?(_), do: false

  defp diagnostic_timestamp(%DateTime{} = timestamp) do
    time =
      timestamp
      |> DateTime.to_time()
      |> Time.truncate(:second)
      |> Time.to_string()

    time <> " UTC"
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

  defp safe_diagnostics do
    case Process.whereis(Muse.Diagnostics) do
      nil ->
        []

      pid ->
        if Process.alive?(pid) do
          Muse.Diagnostics.list()
        else
          []
        end
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_subscribe_diagnostics do
    _ = Muse.Diagnostics.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_self_healing_issues do
    case Process.whereis(Muse.SelfHealingQueue) do
      nil ->
        []

      pid ->
        if Process.alive?(pid) do
          Muse.SelfHealingQueue.list()
        else
          []
        end
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_subscribe_self_healing do
    _ = Muse.SelfHealingQueue.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_subscribe_agent_registry do
    _ = Muse.AgentRegistry.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_agent_snapshot do
    case Process.whereis(Muse.AgentRegistry) do
      nil ->
        :unavailable

      pid ->
        if Process.alive?(pid) do
          Muse.AgentRegistry.snapshot()
        else
          :unavailable
        end
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp safe_queue_diagnostic(diagnostic) do
    case Process.whereis(Muse.SelfHealingQueue) do
      nil ->
        {:error, :queue_unavailable}

      pid ->
        if Process.alive?(pid) do
          case Muse.SelfHealingQueue.add_diagnostic(diagnostic) do
            %Muse.SelfHealingIssue{} = issue -> {:ok, issue}
            {:error, :duplicate} -> {:error, :duplicate}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :queue_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :queue_unavailable}
  end

  defp safe_workspace_root do
    case Process.whereis(Muse.Workspace) do
      nil ->
        "unknown"

      pid ->
        if Process.alive?(pid), do: Muse.Workspace.root(), else: "unknown"
    end
  end

  defp safe_reload_status do
    case Process.whereis(Muse.DevReloader) do
      nil ->
        %{status: :unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.DevReloader.status()
        else
          %{status: :unavailable}
        end
    end
  end

  defp safe_emit_simulated_error do
    case Process.whereis(Muse.Diagnostics) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          Muse.Diagnostics.emit(
            :error,
            "Simulated backend error for popup testing",
            %{source: :web, simulated?: true}
          )
        end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
