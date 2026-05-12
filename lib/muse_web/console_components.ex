defmodule MuseWeb.ConsoleComponents do
  @moduledoc """
  LiveView function components for the Muse console tabs and panels.

  These components render UI fragments and delegate event handling
  back to the parent LiveView via `phx-click` strings. All IDs,
  classes, and ARIA attributes are preserved for test compatibility.
  """

  use Phoenix.Component

  import MuseWeb.EventFormatter,
    only: [
      filtered_events: 3,
      event_row_class: 1,
      event_timestamp: 1,
      event_severity: 1,
      event_badge_class: 1,
      event_meta: 1,
      event_display: 1,
      format_event_json: 1,
      format_timestamp: 1
    ]

  import MuseWeb.LogFormatter,
    only: [
      filtered_logs: 3,
      log_level_display: 1,
      log_badge_class: 1,
      log_row_class: 1,
      log_timestamp: 1,
      format_log_json: 1
    ]

  alias Muse.Env, as: AppEnv

  # -- Legacy/advanced tab components (not rendered by default) -----------------
  # The following tab components are preserved for future/advanced use.
  # They are NOT rendered in the chat-first HomeLive layout.

  # -- Events tab -------------------------------------------------------------

  attr(:events, :list, required: true)
  attr(:filter, :string, required: true)
  attr(:search, :string, required: true)
  attr(:expanded_id, :integer, required: true)

  def events_tab(assigns) do
    ~H"""
    <section class="panel events-panel" role="tabpanel" aria-label="Events">
      <div class="panel-header">
        <div class="events-header-row">
          <h2 class="panel-title">Events</h2>
          <div class="event-filters" role="radiogroup" aria-label="Event filter">
            <%= for f <- ~w(all errors warnings info) do %>
              <button
                type="button"
                role="radio"
                class={"event-filter-btn #{if @filter == f, do: "event-filter-active", else: ""}"}
                aria-checked={if @filter == f, do: "true", else: "false"}
                phx-click="set_event_filter"
                phx-value-filter={f}
              >
                <%= String.capitalize(f) %>
              </button>
            <% end %>
          </div>
          <button type="button" class="secondary-button event-clear-btn" phx-click="clear_events">Clear events</button>
        </div>
        <div class="events-search-row">
          <form phx-change="set_event_search" class="event-search-form">
            <input
              type="text"
              name="query"
              class="event-search-input"
              placeholder="Search events…"
              value={@search}
              aria-label="Search events"
            />
          </form>
          <%= if @search != "" do %>
            <button type="button" class="event-search-clear" phx-click="clear_event_search" aria-label="Clear search">✕</button>
          <% end %>
          <%= if @filter != "all" or @search != "" do %>
            <button type="button" class="secondary-button event-clear-filters-btn" phx-click="clear_event_filters">Clear filters</button>
          <% end %>
          <button type="button" class="secondary-button event-export-btn" phx-click="export_events" title="Export filtered events as JSON">Export</button>
        </div>
        <p class="panel-description">
          Muse watches your backend workspace, tracks events, manages Muses, and lets you send runtime commands.
          <%= length(@events) %> event<%= if length(@events) != 1, do: "s", else: "" %> received · newest first
          <%= if @filter != "all" or @search != "" do %>
            · <%= length(filtered_events(Enum.reverse(@events), @filter, @search)) %> matching
          <% end %>
        </p>
      </div>
      <div class="panel-body event-log">
        <%= if @events == [] do %>
          <div class="empty-state">
            <p class="empty-state-title">No events yet</p>
            <p class="empty-state-description">
              Events are created by backend activity, file changes, Muse actions, and commands you send.
            </p>
            <div class="empty-state-actions">
              <button type="button" class="secondary-button" phx-click="simulate_event">Simulate event</button>
              <button type="button" class="secondary-button" disabled>View event schema</button>
            </div>
          </div>
        <% else %>
          <% filtered = filtered_events(Enum.reverse(@events), @filter, @search) %>
          <%= if filtered == [] do %>
            <div class="empty-state">
              <p class="empty-state-title">No matching events</p>
              <p class="empty-state-description">
                No events match your current filter or search. Try adjusting your search or clearing filters.
              </p>
              <div class="empty-state-actions">
                <button type="button" class="secondary-button" phx-click="clear_event_filters">Clear filters/search</button>
              </div>
            </div>
          <% else %>
            <%= for event <- filtered do %>
              <article class={event_row_class(event)}>
                <button
                  type="button"
                  class="event-main event-expand-btn"
                  phx-click="toggle_event_detail"
                  phx-value-id={event.id}
                  aria-expanded={if @expanded_id == event.id, do: "true", else: "false"}
                  aria-controls={"event-detail-#{event.id}"}
                >
                  <span class="event-timestamp"><%= event_timestamp(event.timestamp) %></span>
                  <span class={"event-severity event-severity-#{event_severity(event)}"}><%= event_severity(event) %></span>
                  <span class="event-source"><%= event.source %></span>
                  <span class={event_badge_class(event)}><%= event.type %></span>
                  <span class="event-meta"><%= event_meta(event) %></span>
                </button>
                <div class="event-message"><%= event_display(event) %></div>
                <div class="event-row-actions">
                  <button
                    type="button"
                    class="event-copy-json-btn"
                    phx-click="copy_event_json"
                    phx-value-id={event.id}
                    aria-label="Copy event JSON"
                    title="Copy JSON to clipboard"
                  >📋 Copy JSON</button>
                </div>
                <%= if @expanded_id == event.id do %>
                  <div class="event-detail" id={"event-detail-#{event.id}"} role="region">
                    <pre class="event-detail-json"><%= format_event_json(event) %></pre>
                  </div>
                <% end %>
              </article>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # -- Logs tab --------------------------------------------------------------

  attr(:logs, :list, required: true)
  attr(:filter, :string, required: true)
  attr(:search, :string, required: true)
  attr(:expanded_id, :integer, required: true)

  def logs_tab(assigns) do
    ~H"""
    <section class="panel logs-panel" role="tabpanel" aria-label="Logs">
      <div class="panel-header">
        <div class="events-header-row">
          <h2 class="panel-title">Logs</h2>
          <div class="event-filters" role="radiogroup" aria-label="Log filter">
            <%= for f <- ~w(all errors warnings info debug) do %>
              <button
                type="button"
                role="radio"
                class={"event-filter-btn #{if @filter == f, do: "event-filter-active", else: ""}"}
                aria-checked={if @filter == f, do: "true", else: "false"}
                phx-click="set_log_filter"
                phx-value-filter={f}
              >
                <%= String.capitalize(f) %>
              </button>
            <% end %>
          </div>
          <button type="button" class="secondary-button event-clear-btn" phx-click="clear_logs">Clear logs</button>
        </div>
        <div class="events-search-row">
          <form phx-change="set_log_search" class="event-search-form">
            <input
              type="text"
              name="query"
              class="event-search-input"
              placeholder="Search logs…"
              value={@search}
              aria-label="Search logs"
            />
          </form>
          <%= if @search != "" do %>
            <button type="button" class="event-search-clear" phx-click="clear_log_search" aria-label="Clear log search">✕</button>
          <% end %>
          <%= if @filter != "all" or @search != "" do %>
            <button type="button" class="secondary-button event-clear-filters-btn" phx-click="clear_log_filters">Clear filters</button>
          <% end %>
          <button type="button" class="secondary-button event-export-btn" phx-click="export_logs" title="Export filtered logs as JSON">Export</button>
        </div>
        <p class="panel-description">
          Structured log entries from the backend and runtime.
          <%= length(@logs) %> log<%= if length(@logs) != 1, do: "s", else: "" %> recorded · newest first
          <%= if @filter != "all" or @search != "" do %>
            · <%= length(filtered_logs(@logs, @filter, @search)) %> matching
          <% end %>
        </p>
      </div>
      <div class="panel-body event-log">
        <%= if @logs == [] do %>
          <div class="empty-state">
            <p class="empty-state-title">No logs yet</p>
            <p class="empty-state-description">
              Logs from the backend/runtime will appear here.
            </p>
            <div class="empty-state-actions">
              <%= if AppEnv.dev_tools_enabled?() do %>
                <button type="button" class="secondary-button" phx-click="simulate_log">Simulate log</button>
              <% end %>
            </div>
          </div>
        <% else %>
          <% filtered = filtered_logs(@logs, @filter, @search) %>
          <%= if filtered == [] do %>
            <div class="empty-state">
              <p class="empty-state-title">No matching logs</p>
              <p class="empty-state-description">
                No logs match your current filter or search. Try adjusting your search or clearing filters.
              </p>
              <div class="empty-state-actions">
                <button type="button" class="secondary-button" phx-click="clear_log_filters">Clear filters/search</button>
              </div>
            </div>
          <% else %>
            <%= for log <- filtered do %>
              <article class={log_row_class(log.level)}>
                <button
                  type="button"
                  class="event-main event-expand-btn"
                  phx-click="toggle_log_detail"
                  phx-value-id={log.id}
                  aria-expanded={if @expanded_id == log.id, do: "true", else: "false"}
                  aria-controls={"log-detail-#{log.id}"}
                >
                  <span class="event-timestamp"><%= log_timestamp(log.timestamp) %></span>
                  <span class={log_badge_class(log.level)}><%= log_level_display(log.level) %></span>
                  <span class="event-source"><%= log.source %></span>
                  <span class="event-message-text"><%= log.message %></span>
                </button>
                <div class="event-row-actions">
                  <button
                    type="button"
                    class="event-copy-json-btn"
                    phx-click="copy_log_json"
                    phx-value-id={log.id}
                    aria-label="Copy log JSON"
                    title="Copy JSON to clipboard"
                  >📋 Copy JSON</button>
                </div>
                <%= if @expanded_id == log.id do %>
                  <div class="event-detail" id={"log-detail-#{log.id}"} role="region">
                    <pre class="event-detail-json"><%= format_log_json(log) %></pre>
                  </div>
                <% end %>
              </article>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # -- Files tab --------------------------------------------------------------

  attr(:reload_status, :map, required: true)

  def files_tab(assigns) do
    ~H"""
    <section class="panel files-panel" role="tabpanel" aria-label="Files">
      <div class="panel-header">
        <h2 class="panel-title">Files</h2>
        <p class="panel-description">File watcher and recent changes</p>
      </div>
      <div class="panel-body">
        <%= if @reload_status[:status] == :unavailable do %>
          <div class="empty-state">
            <p class="empty-state-title">File watcher unavailable</p>
            <p class="empty-state-description">
              The file watcher is not running. Start Muse with file watching enabled to track source changes.
            </p>
            <div class="empty-state-actions">
              <button type="button" class="secondary-button" disabled>Rescan</button>
              <button type="button" class="secondary-button" disabled>Pause</button>
            </div>
          </div>
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
            <div class="empty-state">
              <p class="empty-state-title">No recent file changes</p>
              <p class="empty-state-description">The watcher is active and monitoring your workspace for changes.</p>
              <div class="empty-state-actions">
                <button type="button" class="secondary-button" phx-click="force_reload_watcher">Rescan</button>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # -- Agents tab --------------------------------------------------------------

  attr(:agent_snapshot, :any, required: true)
  attr(:agent_runtime, :map, default: nil)

  def agents_tab(assigns) do
    ~H"""
    <section class="panel agents-panel" role="tabpanel" aria-label="Muses">
      <div class="panel-header">
        <h2 class="panel-title">Muses</h2>
        <p class="panel-description">Muse tree and runtime status</p>
      </div>
      <div class="panel-body">
        <% runtime = @agent_runtime || %{status: :disconnected, endpoint: "", last_error: nil, last_attempt_at: nil, health: :inactive} %>
        <div class="agent-runtime-card" id="agent-runtime-card">
          <div class="agent-runtime-header">
            <h3 class="agent-runtime-title">Muse Runtime</h3>
            <span class={"agent-runtime-status agent-runtime-status-#{runtime.status}"}>
              <span class={"status-dot #{runtime_status_dot(runtime.status)}"}></span>
              <%= runtime_status_label(runtime.status) %>
            </span>
          </div>
          <div class="agent-runtime-details">
            <form phx-change="set_agent_runtime_endpoint" class="agent-runtime-endpoint-form">
              <label class="stat-label" for="agent-runtime-endpoint-input">Endpoint</label>
              <input
                type="text"
                id="agent-runtime-endpoint-input"
                name="endpoint"
                class="agent-runtime-endpoint-input"
                value={runtime[:endpoint] || ""}
                placeholder="ws://localhost:4000"
                aria-label="Muse runtime endpoint"
              />
            </form>
            <%= if runtime[:last_attempt_at] do %>
              <div class="stat-row">
                <span class="stat-label">Last attempt</span>
                <span class="stat-value"><%= format_timestamp(runtime.last_attempt_at) %></span>
              </div>
            <% end %>
            <%= if runtime[:last_error] do %>
              <div class="stat-row">
                <span class="stat-label">Error</span>
                <span class="stat-value stat-value-error"><%= runtime.last_error %></span>
              </div>
            <% end %>
          </div>
          <div class="agent-runtime-actions">
            <%= if runtime.status == :disconnected or runtime.status == :error do %>
              <button type="button" class="secondary-button" phx-click="connect_agent_runtime" title="Connect to Muse runtime">Connect</button>
              <button type="button" class="secondary-button" phx-click="retry_agent_runtime" title="Retry Muse runtime connection">Retry</button>
            <% end %>
            <%= if runtime.status == :connected or runtime.status == :connecting do %>
              <button type="button" class="secondary-button" phx-click="disconnect_agent_runtime" title="Disconnect Muse runtime">Disconnect</button>
            <% end %>
            <button type="button" class="secondary-button" phx-click="switch_tab" phx-value-tab="logs" title="Open logs tab">Open logs</button>
          </div>
        </div>

        <%= if @agent_snapshot == :unavailable do %>
          <div class="empty-state">
            <p class="empty-state-title">Muse registry unavailable</p>
            <p class="empty-state-description">
              The Muse registry is not running. Start the Muse runtime to register and manage Muses.
            </p>
            <div class="empty-state-actions">
              <button type="button" class="secondary-button" phx-click="connect_agent_runtime">Connect runtime</button>
              <button type="button" class="secondary-button" disabled>View setup instructions</button>
            </div>
          </div>
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
            <div class="empty-state">
              <p class="empty-state-title">No Muses registered</p>
              <p class="empty-state-description">
                Start or connect a Muse runtime to register Muses. Muses handle tasks like self-healing, code review, and more.
              </p>
              <div class="empty-state-actions">
                <button type="button" class="secondary-button" phx-click="connect_agent_runtime">Connect runtime</button>
                <button type="button" class="secondary-button" disabled>View setup instructions</button>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # -- Stats tab --------------------------------------------------------------

  attr(:beam_stats, :map, required: true)

  def stats_tab(assigns) do
    ~H"""
    <section class="panel stats-panel" role="tabpanel" aria-label="Stats">
      <div class="panel-header">
        <h2 class="panel-title">Statistics</h2>
        <p class="panel-description">BEAM runtime statistics</p>
      </div>
      <div class="panel-body">
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
    </section>
    """
  end

  # -- Settings tab -----------------------------------------------------------

  attr(:workspace, :string, required: true)
  attr(:reload_status, :map, required: true)

  def settings_tab(assigns) do
    ~H"""
    <section class="panel settings-panel" role="tabpanel" aria-label="Settings">
      <div class="panel-header">
        <h2 class="panel-title">Settings</h2>
      </div>
      <div class="panel-body">
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
    </section>
    """
  end

  # -- Agent helpers ----------------------------------------------------------

  def sorted_agents(agents) do
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

  # -- Formatting helpers -----------------------------------------------------

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_bytes(_), do: "—"

  defp format_cpu(nil), do: "—"
  defp format_cpu(pct) when is_float(pct), do: "#{pct}%"
  defp format_cpu(_), do: "—"

  defp file_status_label(:created), do: "new"
  defp file_status_label(:deleted), do: "del"
  defp file_status_label(:modified), do: "edt"
  defp file_status_label(_), do: ""

  defp format_atom_pct(count, limit) when is_integer(count) and is_integer(limit) and limit > 0 do
    pct = Float.round(count / limit * 100, 1)
    "#{count} (#{pct}%)"
  end

  defp format_atom_pct(_count, _limit), do: "—"

  def format_mem_key(key) when is_atom(key) do
    key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  def format_mem_key(key), do: to_string(key)

  # -- Chat-first shell components --------------------------------------------

  attr(:workspace, :string, required: true)
  attr(:reload_status, :map, required: true)
  attr(:state, :map, required: true)
  attr(:diagnostics, :list, required: true)
  attr(:diagnostics_open?, :boolean, required: true)
  attr(:sidebar_state, :atom, default: :expanded)

  def app_header(assigns) do
    ~H"""
    <header class="app-header">
      <button type="button" class="mobile-sidebar-toggle" phx-click="toggle_mobile_sidebar" aria-label="Toggle context sidebar" aria-expanded={to_string(@sidebar_state == :expanded)} aria-controls="workspace-context-sidebar">
        <span class="mobile-sidebar-toggle-icon" aria-hidden="true">☰</span>
      </button>
      <div class="app-brand muse-brand">
        <img src="/images/muse-logo-header.png" alt="Muse CLI Coding Muse" class="muse-brand__logo" />
      </div>
      <div class="status-chips">
        <.status_chip label="backend" tone="green" dot={true} value="connected" />
        <.status_chip label="watcher" tone={watcher_tone(@reload_status)} dot={true} value={watcher_label(@reload_status)} />
        <.status_chip label="workspace" tone="neutral" dot={false} value={short_path(@workspace)} />
        <%= if @diagnostics != [] do %>
          <.status_chip
            label="diagnostics"
            tone="yellow"
            dot={true}
            value={"#{length(@diagnostics)} issue#{if length(@diagnostics) != 1, do: "s", else: ""}"}
            click="open_diagnostics"
            aria_expanded={if(@diagnostics_open?, do: "true", else: "false")}
            aria_controls="diagnostics-drawer"
          />
        <% end %>
        <%= if @sidebar_state == :hidden do %>
          <button type="button" class="status-chip context-reopen-chip" phx-click="set_sidebar_state" phx-value-state="expanded">
            ☰ context
          </button>
        <% end %>
      </div>
    </header>
    """
  end

  attr(:label, :string, required: true)
  attr(:tone, :string, required: true)
  attr(:dot, :boolean, default: false)
  attr(:value, :string, required: true)
  attr(:click, :string, default: nil)
  attr(:aria_expanded, :string, default: nil)
  attr(:aria_controls, :string, default: nil)

  def status_chip(assigns) do
    ~H"""
    <%= if @click do %>
      <button type="button" class={"status-chip status-chip-#{@tone}"} phx-click={@click} aria-expanded={@aria_expanded} aria-controls={@aria_controls}>
        <%= if @dot do %><span class={"status-dot #{chip_dot_class(@tone)}"}></span><% end %>
        <span class="status-chip-label"><%= @label %></span>
        <span class="status-chip-value"><%= @value %></span>
      </button>
    <% else %>
      <span class={"status-chip status-chip-#{@tone}"}>
        <%= if @dot do %><span class={"status-dot #{chip_dot_class(@tone)}"}></span><% end %>
        <span class="status-chip-label"><%= @label %></span>
        <span class="status-chip-value"><%= @value %></span>
      </span>
    <% end %>
    """
  end

  attr(:messages, :list, required: true)
  attr(:input, :string, required: true)
  attr(:submitting?, :boolean, default: false)
  attr(:active_turn_id, :any, default: nil)
  attr(:chat_tabs, :list, default: [])
  attr(:active_chat_tab, :any, default: :process)

  def chat_panel(assigns) do
    ~H"""
    <section class="chat-panel" aria-label="Muse conversation" role="region">
      <div class="muse-bg muse-bg--main" aria-hidden="true"></div>
      <.chat_tab_bar tabs={@chat_tabs} active_tab={@active_chat_tab} />
      <div class="chat-scroll" id="chat-scroll" phx-hook="ChatAutoScroll" role="log" aria-live="polite" :if={@active_chat_tab == :process}>
        <%= if @messages == [] do %>
          <div class="chat-empty">
            <h1>muse</h1>
            <p>Ask muse to inspect, explain, fix, or generate code in this workspace.</p>
            <div class="prompt-chips" role="group" aria-label="Suggested prompts">
              <button type="button" class="prompt-chip" phx-click="use_prompt" phx-value-prompt="Explain this project" aria-label="Use prompt: Explain this project">Explain this project</button>
              <button type="button" class="prompt-chip" phx-click="use_prompt" phx-value-prompt="Check recent backend errors" aria-label="Use prompt: Check recent backend errors">Check recent backend errors</button>
              <button type="button" class="prompt-chip" phx-click="use_prompt" phx-value-prompt="Review changed files" aria-label="Use prompt: Review changed files">Review changed files</button>
              <button type="button" class="prompt-chip" phx-click="use_prompt" phx-value-prompt="Help me connect the Muse runtime" aria-label="Use prompt: Help me connect the Muse runtime">Help me connect the Muse runtime</button>
            </div>
          </div>
        <% else %>
          <.chat_messages messages={@messages} />
        <% end %>
      </div>
      <div class="chat-scroll" id="tab-detail-scroll" role="tabpanel" :if={@active_chat_tab != :process}>
        <%= render_chat_tab_content(@chat_tabs, @active_chat_tab) %>
      </div>
      <.chat_composer input={@input} submitting?={@submitting?} active_turn_id={@active_turn_id} />
    </section>
    """
  end

  attr(:tabs, :list, default: [])
  attr(:active_tab, :any, default: :process)

  def chat_tab_bar(assigns) do
    ~H"""
    <div class="chat-tab-bar">
      <button type="button" class={"chat-tab chat-tab-pinned #{if @active_tab == :process, do: "chat-tab-active"}"} phx-click="switch_chat_tab" phx-value-tab="process">
        <span class="chat-tab-icon">💬</span>
        <span class="chat-tab-label">Process</span>
        <span class="chat-tab-pin" title="Always open">🔒</span>
      </button>
      <%= for tab <- @tabs do %>
        <button type="button" class={"chat-tab #{if @active_tab == tab.id, do: "chat-tab-active"}"} phx-click="switch_chat_tab" phx-value-tab={tab.id}>
          <span class="chat-tab-label"><%= tab.title %></span>
          <span class="chat-tab-close" phx-click="close_chat_tab" phx-value-tab={tab.id} phx-stop-propagation title="Close tab">✕</span>
        </button>
      <% end %>
    </div>
    """
  end

  attr(:messages, :list, required: true)

  def chat_messages(assigns) do
    ~H"""
    <div class="chat-messages">
      <%= for msg <- @messages do %>
        <.chat_message message={msg} />
      <% end %>
    </div>
    """
  end

  attr(:message, :map, required: true)

  def chat_message(assigns) do
    ~H"""
    <div class={"chat-message #{chat_message_role_class(@message.role)}"}>
      <div class="chat-message-header">
        <span class="chat-message-role"><%= chat_message_role_label(@message.role) %></span>
        <%= if @message[:timestamp] do %>
          <time class="chat-message-time"><%= @message.timestamp %></time>
        <% end %>
        <%= if @message[:source] do %>
          <span class="chat-message-source">· <%= @message.source %></span>
        <% end %>
      </div>
      <div class="chat-bubble"><%= @message.text %></div>
    </div>
    """
  end

  attr(:input, :string, required: true)
  attr(:submitting?, :boolean, default: false)
  attr(:active_turn_id, :any, default: nil)

  def chat_composer(assigns) do
    ~H"""
    <div id="input-form" class="chat-composer" phx-hook="CommandConsole" data-slash-commands={Jason.encode!(Muse.Commands.slash_commands_json())} role="form" aria-label="Message composer">
      <form id="command-form" phx-submit="submit" class="chat-composer-form">
        <textarea
          id="chat-input-textarea"
          name="text"
          class="chat-input command-input"
          placeholder={if @submitting?, do: "Muse is thinking...", else: "Ask Muse anything, or type /help..."}
          rows="1"
          aria-label="Message to Muse"
          disabled={@submitting?}
        ><%= @input %></textarea>
        <button type="submit" class="primary-button chat-send-button" aria-label="Send message to Muse" disabled={@submitting?}>
          <%= if @submitting? do %>
            <span class="spinner" aria-hidden="true"></span> Working…
          <% else %>
            Send
          <% end %>
        </button>
      </form>
    </div>
    """
  end

  defp render_chat_tab_content(tabs, active_id) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      nil -> ""
      tab -> render_tab_content(tab)
    end
  end

  defp render_tab_content(%{type: :diagnostic, data: diagnostic}) do
    level_class = case diagnostic.level do
      :error -> "detail-error"
      :warning -> "detail-warning"
      :critical -> "detail-critical"
      _ -> ""
    end

    assigns = %{diagnostic: diagnostic, level_class: level_class}

    ~H"""
    <div class="detail-panel">
      <div class={"detail-header #{@level_class}"}>
        <span class="detail-level"><%= String.upcase(to_string(@diagnostic.level)) %></span>
        <time class="detail-timestamp"><%= diagnostic_timestamp(@diagnostic.timestamp) %></time>
      </div>
      <div class="detail-message"><%= @diagnostic.message %></div>
      <%= if @diagnostic.metadata && @diagnostic.metadata != %{} do %>
        <div class="detail-metadata">
          <h4>Metadata</h4>
          <pre><%= inspect(@diagnostic.metadata, pretty: true, limit: :infinity) %></pre>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_tab_content(_), do: ""

  defp diagnostic_timestamp(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601()
  end
  defp diagnostic_timestamp(_), do: ""

  attr(:workspace, :string, required: true)
  attr(:reload_status, :map, required: true)
  attr(:diagnostics, :list, required: true)
  attr(:diagnostics_open?, :boolean, default: false)
  attr(:beam_stats, :map, default: %{})
  attr(:logs, :list, default: [])
  attr(:sidebar_state, :atom, default: :expanded)
  attr(:diagnostic_issue_statuses, :map, default: %{})
  attr(:self_healing_issues, :list, default: [])

  def context_panel(assigns) do
    ~H"""
    <aside id="workspace-context-sidebar" class={"context-sidebar context-panel context-sidebar-#{@sidebar_state}"} aria-label="Workspace context and session status" role="complementary" phx-hook="MobileSidebar">
      <div class="muse-bg muse-bg--sidebar" aria-hidden="true"></div>
      <%= case @sidebar_state do %>
        <% :rail -> %>
          <div class="context-rail">
            <button type="button" class="rail-btn" phx-click="set_sidebar_state" phx-value-state="expanded" title="Expand sidebar" aria-label="Expand sidebar">☰</button>
            <button type="button" class="rail-btn" phx-click="set_sidebar_state" phx-value-state="expanded" title="Muse" aria-label="Muse section">🌳</button>
            <button type="button" class="rail-btn" phx-click="set_sidebar_state" phx-value-state="expanded" title="Workspace" aria-label="Workspace section">📂</button>
            <button type="button" class="rail-btn" phx-click="set_sidebar_state" phx-value-state="expanded" title="Diagnostics" aria-label="Diagnostics section">⚠</button>
            <button type="button" class="rail-btn" phx-click="set_sidebar_state" phx-value-state="expanded" title="Files" aria-label="Files section">📄</button>
            <button type="button" class="rail-btn" phx-click="set_sidebar_state" phx-value-state="expanded" title="Stats" aria-label="Stats section">📊</button>
          </div>
        <% :hidden -> %>
          <%!-- minimal content, CSS hides --%>
        <% :expanded -> %>
          <div class="context-sidebar-header">
            <span class="context-sidebar-title">Context</span>
            <div class="context-sidebar-actions">
              <button type="button" class="context-icon-btn" phx-click="set_sidebar_state" phx-value-state="rail" title="Collapse to rail" aria-label="Collapse to rail">◧</button>
              <button type="button" class="context-icon-btn" phx-click="set_sidebar_state" phx-value-state="hidden" title="Hide sidebar" aria-label="Hide sidebar">✕</button>
            </div>
          </div>

          <.mini_card title="workspace">
            <div class="mini-card-row">
              <span class="mini-card-path"><%= short_path(@workspace) %></span>
              <span class={"status-dot #{if @reload_status[:status] == :unavailable, do: "status-dot-gray", else: "status-dot-green"}"}></span>
            </div>
          </.mini_card>

          <.context_diagnostics_card diagnostics={@diagnostics} diagnostic_issue_statuses={@diagnostic_issue_statuses} self_healing_issues={@self_healing_issues} />

          <.mini_card title="beams">
            <div class="mini-card-row">
              <span class="mini-card-label">cpu</span>
              <span><%= format_cpu(@beam_stats[:cpu_current]) %></span>
            </div>
            <div class="mini-card-row">
              <span class="mini-card-label">cpu 1h</span>
              <span><%= format_cpu(@beam_stats[:cpu_hourly_avg]) %></span>
            </div>
            <div class="mini-card-row">
              <span class="mini-card-label">memory</span>
              <span><%= format_bytes(@beam_stats[:total_memory] || 0) %></span>
            </div>
            <div class="mini-card-row">
              <span class="mini-card-label">modules</span>
              <span><%= @beam_stats[:loaded_modules] || 0 %></span>
            </div>
            <div class="mini-card-row">
              <span class="mini-card-label">atoms</span>
              <span><%= format_atom_pct(@beam_stats[:atoms] || 0, @beam_stats[:atom_limit] || 1) %></span>
            </div>
            <div class="mini-card-row">
              <span class="mini-card-label">gc</span>
              <span><%= @beam_stats[:gc_count] || 0 %></span>
            </div>
          </.mini_card>

          <.mini_card title="recent files">
            <%= for file <- recent_files_rich(@reload_status) do %>
              <div class="mini-card-row mini-card-file">
                <span class="mini-card-path"><%= file.basename %></span>
                <span class="mini-card-status"><%= file_status_label(file.status) %></span>
                <%= if file.lines_added && file.lines_added > 0 do %>
                  <span class="mini-card-added">+<%= file.lines_added %></span>
                <% end %>
                <%= if file.lines_removed && file.lines_removed > 0 do %>
                  <span class="mini-card-removed">−<%= file.lines_removed %></span>
                <% end %>
                <%= if file.modified_count && file.modified_count > 1 do %>
                  <span class="mini-card-count">×<%= file.modified_count %></span>
                <% end %>
              </div>
            <% end %>
            <%= if recent_files_rich(@reload_status) == [] do %>
              <div class="mini-card-row mini-card-subtle">none yet</div>
            <% end %>
          </.mini_card>

      <% end %>
    </aside>
    """
  end

  attr(:diagnostics, :list, required: true)
  attr(:diagnostic_issue_statuses, :map, required: true)
  attr(:self_healing_issues, :list, required: true)

  def context_diagnostics_card(assigns) do
    ~H"""
    <%= if @diagnostics == [] do %>
      <.mini_card title="diagnostics" class="mini-card-muted">
        <div class="mini-card-row">
          <span class="diagnostic-count">0</span> <span>issues</span>
        </div>
        <div class="mini-card-row mini-card-subtle">all clear</div>
      </.mini_card>
    <% else %>
      <.mini_card title="diagnostics" class="mini-card-alert">
        <div class="mini-card-row">
          <span class="diagnostic-count"><%= length(@diagnostics) %></span> <span>issue<%= if length(@diagnostics) != 1, do: "s", else: "" %></span>
        </div>
        <div class="diagnostic-latest"><%= diagnostic_summary(List.first(@diagnostics)) %></div>
        <div class="diagnostic-card-actions">
          <button type="button" class="mini-card-btn" phx-click="open_diagnostics" aria-expanded="false" aria-controls="diagnostics-drawer">open details</button>
          <%= if Enum.any?(@diagnostic_issue_statuses, fn {_id, status} -> status == :saved end) do %>
            <button type="button" class="mini-card-btn" disabled>saved ✓</button>
          <% else %>
            <button type="button" class="mini-card-btn" phx-click="save_to_fix">save to fix</button>
          <% end %>
        </div>
      </.mini_card>
    <% end %>
    """
  end

  attr(:title, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:aria_label, :string, default: nil)
  slot(:inner_block, required: true)

  def mini_card(assigns) do
    card_class =
      ["mini-card", assigns[:class]] |> Enum.filter(&(&1 != "" and &1 != nil)) |> Enum.join(" ")

    assigns = assign(assigns, :card_class, card_class)

    ~H"""
    <div class={@card_class} aria-label={Map.get(assigns, :aria_label)}>
      <h3 class="mini-card-title"><%= @title %></h3>
      <div class="mini-card-body"><%= render_slot(@inner_block) %></div>
    </div>
    """
  end

  # -- Legacy/advanced shell components (not rendered by default) --------------
  # The following shell components are preserved for future/advanced use.
  # They are NOT rendered in the chat-first HomeLive layout.

  attr(:state, :map, required: true)
  attr(:reload_status, :map, required: true)
  attr(:workspace, :string, required: true)
  attr(:diagnostics, :list, required: true)
  attr(:diagnostics_open?, :boolean, required: true)
  attr(:agent_runtime, :map, default: nil)

  def status_bar(assigns) do
    ~H"""
    <section class="status-bar" aria-label="System status">
      <div class="status-item" title="Backend connection status">
        <span class={"status-dot status-dot-green"}></span>
        <span class="status-item-label">Backend</span>
        <span class="status-item-value">Connected</span>
      </div>
      <div class="status-item" title="File watcher status">
        <span class={"status-dot #{if @reload_status[:status] == :unavailable, do: "status-dot-gray", else: "status-dot-green"}"}></span>
        <span class="status-item-label">File watcher</span>
        <span class="status-item-value"><%= if @reload_status[:status] == :unavailable, do: "Unavailable", else: "Active" %></span>
      </div>
      <div class="status-item" title="Workspace root path">
        <span class="status-dot status-dot-yellow"></span>
        <span class="status-item-label">Workspace</span>
        <span class="status-item-value status-item-path" title={@workspace}><%= @workspace %></span>
      </div>
      <div class="status-item" title="Muse runtime connection">
        <% runtime = @agent_runtime || %{status: :disconnected} %>
        <span class={"status-dot #{runtime_status_dot(runtime.status)}"}></span>
        <span class="status-item-label">Muse</span>
        <span class="status-item-value"><%= runtime_status_label(runtime.status) %></span>
      </div>
      <div class="status-item" title="Total events received">
        <span class={"status-dot #{status_dot_color(length(@state.events))}"}></span>
        <span class="status-item-label">Events</span>
        <span class="status-item-value"><%= length(@state.events) %></span>
      </div>
      <%= if @diagnostics != [] and not @diagnostics_open? do %>
        <button
          type="button"
          id="diagnostics-badge"
          class="diagnostic-pill"
          phx-click="open_diagnostics"
          aria-label="Open diagnostics panel"
          aria-expanded="false"
          aria-controls="diagnostics-drawer"
        >
          ⚠ <%= length(@diagnostics) %> diagnostic<%= if length(@diagnostics) != 1, do: "s", else: "" %>
        </button>
      <% end %>
    </section>
    """
  end

  attr(:diagnostics, :list, required: true)
  attr(:diagnostics_open?, :boolean, required: true)
  attr(:diagnostic_issue_statuses, :map, required: true)
  attr(:self_healing_issues, :list, required: true)

  def diagnostics_popup(assigns) do
    ~H"""
    <%= if @diagnostics != [] and @diagnostics_open? do %>
      <aside id="diagnostics-drawer" class="diagnostics-drawer" role="dialog" aria-modal="true" aria-labelledby="diagnostics-title" phx-hook="DiagnosticsDrawer">
        <div class="diagnostic-title-bar">
          <span id="diagnostics-title" class="diagnostic-title">Diagnostics</span>
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
            <%= if diagnostic_location(diagnostic) do %>
              <div class="diagnostic-location"><%= diagnostic_location(diagnostic) %></div>
            <% end %>
            <div class="diagnostic-actions">
              <%= case Map.get(@diagnostic_issue_statuses, diagnostic.id) do %>
                <% nil -> %>
                  <button
                    type="button"
                    class="diagnostic-action-btn"
                    phx-click="queue_diagnostic_fix"
                    phx-value-diagnostic_id={Integer.to_string(diagnostic.id)}
                  >
                    save to fix
                  </button>
                <% :queued -> %>
                  <button type="button" class="diagnostic-queued" disabled>saved ✓</button>
                <% :in_progress -> %>
                  <button type="button" class="diagnostic-queued" disabled>In progress</button>
                <% :fixed -> %>
                  <button type="button" class="diagnostic-queued" disabled>Already fixed</button>
                <% :failed -> %>
                  <button type="button" class="diagnostic-queued" disabled>Self-healing failed</button>
                <% :ignored -> %>
                  <button type="button" class="diagnostic-queued" disabled>Ignored</button>
              <% end %>
              <button
                type="button"
                class="diagnostic-action-btn"
                phx-click="copy_diagnostic"
                phx-value-diagnostic_id={Integer.to_string(diagnostic.id)}
              >Copy error</button>
              <button
                type="button"
                class={"diagnostic-action-btn #{if diagnostic_file_value(diagnostic), do: "", else: "diagnostic-action-disabled"}"}
                phx-click="jump_to_diagnostic_file"
                phx-value-diagnostic_id={Integer.to_string(diagnostic.id)}
                disabled={is_nil(diagnostic_file_value(diagnostic))}
              >Jump to file</button>
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
    """
  end

  # Legacy dev sidebar – not rendered by default in chat-first layout

  attr(:reload_status, :map, required: true)
  attr(:command_history, :list, required: true)

  def dev_sidebar(assigns) do
    ~H"""
    <aside class="dev-sidebar">
      <%= if AppEnv.dev_tools_enabled?() do %>
        <section id="dev-tools" class="panel dev-tools-panel">
          <div class="panel-header">
            <h2 class="panel-title">Dev tools</h2>
          </div>
          <div class="panel-body">
            <div class="dev-tool-group">
              <h3 class="dev-tool-group-title">Simulate</h3>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="simulate_event" title="Create a simulated test event">Simulate event</button>
              <button type="button" class="secondary-button dev-tool-btn dev-tool-btn-warning" phx-click="simulate_backend_error" title="Simulate a backend error (dev only)">Simulate backend error</button>
            </div>
            <div class="dev-tool-separator"></div>
            <div class="dev-tool-group">
              <h3 class="dev-tool-group-title">Actions</h3>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="clear_events" title="Remove all events from the log">Clear events</button>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="force_reload_watcher" title="Trigger a watcher rescan">Rescan watcher</button>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="refresh_stats" title="Refresh BEAM runtime statistics">Refresh stats</button>
            </div>
            <div class="dev-tool-separator"></div>
            <div class="dev-tool-group">
              <h3 class="dev-tool-group-title">Export</h3>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="copy_diagnostics" title="Copy diagnostics to clipboard">Copy diagnostics</button>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="export_logs" title="Export logs to clipboard">Export logs</button>
            </div>
            <div class="dev-tool-separator"></div>
            <div class="dev-tool-group">
              <h3 class="dev-tool-group-title">Muse runtime</h3>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="connect_agent_runtime" title="Connect to Muse runtime">Connect runtime</button>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="retry_agent_runtime" title="Retry Muse runtime connection">Retry connection</button>
              <button type="button" class="secondary-button dev-tool-btn" phx-click="disconnect_agent_runtime" title="Disconnect Muse runtime">Disconnect</button>
            </div>
          </div>
        </section>
      <% end %>

      <section class="panel setup-panel">
        <div class="panel-header">
          <h2 class="panel-title">Setup checklist</h2>
        </div>
        <div class="panel-body">
          <ul class="setup-checklist">
            <li class="setup-item setup-item-done">
              <span class="setup-check">✓</span>
              <span class="setup-text">Workspace detected</span>
            </li>
            <li class={"setup-item #{if @reload_status[:status] != :unavailable, do: "setup-item-done", else: ""}"}>
              <span class="setup-check"><%= if @reload_status[:status] != :unavailable, do: "✓", else: "○" %></span>
              <span class="setup-text">File watching enabled</span>
            </li>
            <li class="setup-item">
              <span class="setup-check">○</span>
              <span class="setup-text">Connect Muse runtime</span>
            </li>
            <li class="setup-item">
              <span class="setup-check">○</span>
              <span class="setup-text">Register first Muse</span>
            </li>
            <li class={"setup-item #{if @command_history != [], do: "setup-item-done", else: ""}"}>
              <span class="setup-check"><%= if @command_history != [], do: "✓", else: "○" %></span>
              <span class="setup-text">Send first command</span>
            </li>
          </ul>
        </div>
      </section>
    </aside>
    """
  end

  # Legacy command console – replaced by chat_composer in chat-first layout

  attr(:input, :string, required: true)
  attr(:command_history, :list, required: true)

  def command_console(assigns) do
    ~H"""
    <section id="input-form" class="command-console" aria-label="Command console" phx-hook="CommandConsole" data-slash-commands={Jason.encode!(Muse.Commands.slash_commands_json())}>
      <div class="command-history" id="command-history">
        <%= for entry <- @command_history do %>
          <div class={"command-history-entry command-history-#{entry.type}"}>
            <span class="command-history-input"><%= entry.input %></span>
            <pre class="command-history-output"><%= entry.output %></pre>
            <time class="command-history-time"><%= entry.timestamp %></time>
          </div>
        <% end %>
      </div>
      <form id="command-form" phx-submit="submit" class="command-bar">
        <textarea
          name="text"
          class="command-input"
          placeholder="Type /help for commands or ask Muse a question."
          rows="1"
          aria-label="Command input"
        ><%= @input %></textarea>
        <button type="submit" class="primary-button" aria-label="Send command">Send</button>
      </form>
    </section>
    """
  end

  attr(:toasts, :list, required: true)

  def toast_container(assigns) do
    ~H"""
    <div class="toast-container" aria-label="Notifications">
      <%= for toast <- @toasts do %>
        <div class={"toast toast-#{toast.type}"} id={"toast-#{toast.id}"} phx-hook="ToastAutoDismiss" role="alert">
          <span class="toast-message"><%= toast.message %></span>
          <button type="button" class="toast-dismiss" phx-click="dismiss_toast" phx-value-id={toast.id} aria-label={"Dismiss #{toast.type} notification: #{toast.message}"}>✕</button>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Helper for status bar ------------------------------------------------

  # -- Chat-first data helpers -----------------------------------------------

  @doc """
  Transforms a list of Event structs into chat message maps
  suitable for rendering in `chat_panel`.
  """
  def events_to_messages(events) when is_list(events) do
    Enum.map(events, fn event ->
      %{
        role: event_source_to_role(event.source),
        text: format_event_data(event.data),
        timestamp: event.timestamp,
        source: event.source
      }
    end)
  end

  defp event_source_to_role(:user), do: :user
  defp event_source_to_role(_), do: :assistant

  defp format_event_data(%{text: text}), do: text
  defp format_event_data(%{file: file}), do: file
  defp format_event_data(%{files: files}) when is_list(files), do: Enum.join(files, ", ")
  defp format_event_data(%{issues: issues}) when is_list(issues), do: "#{length(issues)} issues"
  defp format_event_data(data), do: inspect(data)

  # -- Chat-first private helpers -------------------------------------------

  defp short_path(path) when is_binary(path) do
    path |> String.split("/") |> Enum.take(-2) |> Enum.join("/")
  end

  defp short_path(_), do: "—"

  defp watcher_label(%{status: :unavailable}), do: "unavailable"
  defp watcher_label(_), do: "active"

  defp watcher_tone(%{status: :unavailable}), do: "gray"
  defp watcher_tone(_), do: "green"

  defp diagnostic_summary(nil), do: ""

  defp diagnostic_summary(%{message: msg}) when is_binary(msg) do
    if String.length(msg) > 80 do
      String.slice(msg, 0, 80) <> "…"
    else
      msg
    end
  end

  defp diagnostic_summary(d), do: String.slice(to_string(d), 0, 80)

  defp recent_files_rich(%{recent_files: files}) when is_list(files) and files != [] do
    files |> Enum.take(10)
  end

  defp recent_files_rich(_), do: []

  defp chip_dot_class("green"), do: "status-dot-green"
  defp chip_dot_class("success"), do: "status-dot-green"
  defp chip_dot_class("yellow"), do: "status-dot-yellow"
  defp chip_dot_class("warning"), do: "status-dot-yellow"
  defp chip_dot_class("red"), do: "status-dot-red"
  defp chip_dot_class("danger"), do: "status-dot-red"
  defp chip_dot_class("accent"), do: "status-dot-yellow"
  defp chip_dot_class("neutral"), do: "status-dot-gray"
  defp chip_dot_class("gray"), do: "status-dot-gray"
  defp chip_dot_class(_), do: "status-dot-gray"

  defp chat_message_role_class(:user), do: "chat-message-user"
  defp chat_message_role_class(:assistant), do: "chat-message-assistant"
  defp chat_message_role_class(role), do: "chat-message-#{role}"

  defp chat_message_role_label(:user), do: "you"
  defp chat_message_role_label(:assistant), do: "muse"
  defp chat_message_role_label(role), do: to_string(role)

  # -- Legacy private helpers -------------------------------------------------

  defp status_dot_color(0), do: "status-dot-gray"
  defp status_dot_color(count) when count > 10, do: "status-dot-green"
  defp status_dot_color(_), do: "status-dot-green"

  # tab_tooltip removed – tab nav no longer rendered by default

  # -- Agent runtime helpers --------------------------------------------------

  defp runtime_status_dot(:connected), do: "status-dot-green"
  defp runtime_status_dot(:connecting), do: "status-dot-yellow"
  defp runtime_status_dot(:error), do: "status-dot-red"
  defp runtime_status_dot(:disconnected), do: "status-dot-gray"
  defp runtime_status_dot(_), do: "status-dot-gray"

  defp runtime_status_label(:connected), do: "Connected"
  defp runtime_status_label(:connecting), do: "Connecting…"
  defp runtime_status_label(:error), do: "Error"
  defp runtime_status_label(:disconnected), do: "Disconnected"
  defp runtime_status_label(other), do: String.capitalize(to_string(other))

  # -- Session status card (PR20) ------------------------------------------

  attr(:session_status, :any, default: nil)
  attr(:submitting?, :boolean, default: false)
  attr(:streaming_buffers, :map, default: %{})

  def session_status_card(assigns) do
    ~H"""
    <%= cond do %>
      <% @session_status == nil -> %>
        <.mini_card title="session" aria_label="Session status">
          <div class="mini-card-row" role="status" aria-label="Session status: Disconnected">
            <span class="status-dot status-dot-red" aria-hidden="true"></span>
            <span>Disconnected</span>
          </div>
          <div class="mini-card-row mini-card-subtle">Session not available</div>
        </.mini_card>
      <% true -> %>
        <.mini_card title="session" aria_label="Session status">
          <div class="mini-card-row" role="status" aria-label={"Session status: #{session_status_label(@session_status.status)}"}>
            <span class={"status-dot #{session_status_dot(@session_status.status)}"} aria-hidden="true"></span>
            <span><%= session_status_label(@session_status.status) %></span>
          </div>
          <%= if @session_status[:active_muse] do %>
            <div class="mini-card-row" aria-label={"Active Muse: #{@session_status.active_muse}"}>
              <span class="mini-card-label">Muse</span>
              <span><%= @session_status.active_muse %></span>
            </div>
          <% end %>
          <%= if @session_status[:active_plan_id] do %>
            <div class="mini-card-row" aria-label={"Active plan: #{short_plan_id(@session_status)}"}>
              <span class="mini-card-label">plan</span>
              <span><%= short_plan_id(@session_status) %> <%= plan_status_badge(@session_status) %></span>
            </div>
          <% end %>
          <%= if @session_status[:pending_patch] do %>
            <div class="mini-card-row" role="alert" aria-label="Patch awaiting approval">
              <span class="mini-card-label">patch</span>
              <span class="mini-card-pending">pending</span>
            </div>
          <% end %>
          <%= if @session_status[:active_turn_id] do %>
            <div class="mini-card-row" aria-label="Muse turn running">
              <span class="mini-card-label">turn</span>
              <span>running</span>
            </div>
          <% end %>
          <%= if @submitting? and map_size(@streaming_buffers) > 0 do %>
            <div class="mini-card-row" aria-label="Streaming in progress">
              <span class="mini-card-label">stream</span>
              <span class="mini-card-streaming">streaming…</span>
            </div>
          <% end %>
        </.mini_card>
    <% end %>
    """
  end

  defp session_status_dot(:idle), do: "status-dot-gray"
  defp session_status_dot(:running), do: "status-dot-green"
  defp session_status_dot(:planning), do: "status-dot-yellow"
  defp session_status_dot(:awaiting_plan_approval), do: "status-dot-yellow"
  defp session_status_dot(:executing), do: "status-dot-green"
  defp session_status_dot(:awaiting_patch_approval), do: "status-dot-yellow"
  defp session_status_dot(:verifying), do: "status-dot-green"
  defp session_status_dot(:reviewing), do: "status-dot-blue"
  defp session_status_dot(:done), do: "status-dot-green"
  defp session_status_dot(:failed), do: "status-dot-red"
  defp session_status_dot(:error), do: "status-dot-red"
  defp session_status_dot(:cancelled), do: "status-dot-gray"
  # T3-24: Lifecycle states for connecting/recovering/dead sessions
  defp session_status_dot(:connecting), do: "status-dot-yellow"
  defp session_status_dot(:recovering), do: "status-dot-yellow"
  defp session_status_dot(:dead), do: "status-dot-red"
  defp session_status_dot(_), do: "status-dot-gray"

  defp session_status_label(:idle), do: "Idle"
  defp session_status_label(:running), do: "Running"
  defp session_status_label(:planning), do: "Planning"
  defp session_status_label(:awaiting_plan_approval), do: "Plan awaiting approval"
  defp session_status_label(:executing), do: "Executing"
  defp session_status_label(:awaiting_patch_approval), do: "Patch awaiting approval"
  defp session_status_label(:verifying), do: "Verifying"
  defp session_status_label(:reviewing), do: "Reviewing"
  defp session_status_label(:done), do: "Done"
  defp session_status_label(:failed), do: "Failed"
  defp session_status_label(:error), do: "Error"
  defp session_status_label(:cancelled), do: "Cancelled"
  # T3-24: Lifecycle states for connecting/recovering/dead sessions
  defp session_status_label(:connecting), do: "Connecting…"
  defp session_status_label(:recovering), do: "Recovering…"
  defp session_status_label(:dead), do: "Session lost"
  defp session_status_label(other), do: String.capitalize(to_string(other))

  defp short_plan_id(%{plan: %Muse.Plan{} = p}), do: Muse.PlanHistory.display_plan_id(p)
  defp short_plan_id(%{active_plan_id: id}) when is_binary(id), do: id
  defp short_plan_id(_), do: ""

  defp plan_status_badge(%{plan: %Muse.Plan{status: status}}) do
    "(#{status})"
  end

  defp plan_status_badge(_), do: ""

  # -- Patch proposal panel (PR17) ------------------------------------------

  @max_diff_display_lines 80

  attr(:patch_proposal, :any, default: nil)

  def patch_proposal_panel(assigns) do
    ~H"""
    <%= if @patch_proposal do %>
      <aside id="patch-proposal-panel" class="patch-proposal-panel" role="region" aria-label="Patch proposal awaiting approval">
        <div class="patch-proposal-header">
          <span class="patch-proposal-title">Patch Proposal</span>
          <button type="button" class="patch-proposal-dismiss" phx-click="dismiss_patch_proposal" title="Dismiss" aria-label="Dismiss patch proposal">✕</button>
        </div>
        <div class="patch-proposal-body">
          <div class="patch-proposal-hash">
            <span class="patch-proposal-label">Hash:</span>
            <code class="patch-proposal-hash-value"><%= truncate_hash(@patch_proposal[:patch_hash] || @patch_proposal["patch_hash"] || @patch_proposal[:hash] || @patch_proposal["hash"] || "unknown") %></code>
          </div>
          <%= if patch_proposal_files(@patch_proposal) != [] do %>
            <div class="patch-proposal-files">
              <span class="patch-proposal-label">Affected files:</span>
              <ul class="patch-proposal-file-list">
                <%= for file <- patch_proposal_files(@patch_proposal) do %>
                  <li><code><%= file %></code></li>
                <% end %>
              </ul>
            </div>
          <% end %>
          <%= if patch_proposal_diff(@patch_proposal) do %>
            <div class="patch-proposal-diff-section">
              <span class="patch-proposal-label">Diff:</span>
              <pre class="patch-proposal-diff-pre"><code class="patch-proposal-diff-code"><%= truncate_diff(patch_proposal_diff(@patch_proposal), max_diff_display_lines()) %></code></pre>
            </div>
          <% end %>
          <div class="patch-proposal-guidance">
            <p>Approve with <code>/approve patch</code> or reject with <code>/reject patch</code></p>
            <p class="patch-proposal-lifecycle">Approved patches can be applied with checkpoint protection via /apply patch</p>
          </div>
        </div>
      </aside>
    <% end %>
    """
  end

  defp max_diff_display_lines, do: @max_diff_display_lines

  defp truncate_hash(nil), do: "unknown"

  defp truncate_hash(hash) when is_binary(hash) do
    String.slice(hash, 0, 12)
  end

  defp truncate_hash(other), do: to_string(other) |> String.slice(0, 12)

  defp patch_proposal_files(%{files: files}) when is_list(files), do: files
  defp patch_proposal_files(%{"files" => files}) when is_list(files), do: files
  defp patch_proposal_files(%{affected_files: files}) when is_list(files), do: files
  defp patch_proposal_files(%{"affected_files" => files}) when is_list(files), do: files
  defp patch_proposal_files(_), do: []

  defp patch_proposal_diff(%{diff: diff}) when is_binary(diff), do: diff
  defp patch_proposal_diff(%{"diff" => diff}) when is_binary(diff), do: diff
  defp patch_proposal_diff(_), do: nil

  defp truncate_diff(nil, _max_lines), do: ""

  defp truncate_diff(diff, max_lines) when is_binary(diff) do
    lines = String.split(diff, "\n")

    if length(lines) > max_lines do
      (Enum.take(lines, max_lines) ++ ["… (#{length(lines) - max_lines} more lines)"])
      |> Enum.join("\n")
    else
      diff
    end
  end

  # -- Diagnostics metadata helpers ------------------------------------------

  def diagnostic_file_value(%{metadata: meta}) when is_map(meta) do
    Map.get(meta, :file) || Map.get(meta, "file")
  end

  def diagnostic_file_value(_), do: nil

  def diagnostic_line_value(%{metadata: meta}) when is_map(meta) do
    line = Map.get(meta, :line) || Map.get(meta, "line")
    MuseWeb.safe_to_integer_or_nil(line)
  end

  def diagnostic_line_value(_), do: nil

  def diagnostic_level(%{level: level}), do: level
  def diagnostic_level(_), do: :info

  defp diagnostic_location(diagnostic) do
    file = diagnostic_file_value(diagnostic)
    line = diagnostic_line_value(diagnostic)

    cond do
      file && line -> "#{file}:#{line}"
      file -> file
      true -> nil
    end
  end
end
