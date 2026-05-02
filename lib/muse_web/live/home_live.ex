defmodule MuseWeb.HomeLive do
  use MuseWeb, :live_view

  @collapse_timeout_ms 10_000

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
        diagnostic_issue_statuses: diagnostic_issue_statuses
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
            # Already in queue — update local status tracking
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
  def handle_info({:self_healing_issue_added, issue}, socket) do
    if Enum.any?(socket.assigns.self_healing_issues, &(&1.id == issue.id)) do
      # Already present from optimistic local update
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
          <section id="reload-status" class="panel status-panel">
            <div class="panel-header">
              <h2 class="panel-title">Reload status</h2>
            </div>
            <div class="panel-body">
              <%= if @reload_status[:status] == :unavailable do %>
                <p class="status-unavailable">Unavailable</p>
              <% else %>
                <div class="status-row">
                  <span class="status-label">Generation</span>
                  <span class="status-value"><%= @reload_status[:generation] %></span>
                </div>
                <%= if @reload_status[:last_error] do %>
                  <div class="status-row">
                    <span class="status-label">Last error</span>
                    <span class="status-value"><%= @reload_status[:last_error] %></span>
                  </div>
                <% end %>
                <%= if @reload_status[:last_reload_at] do %>
                  <div class="status-row">
                    <span class="status-label">Last reload</span>
                    <span class="status-value"><%= @reload_status[:last_reload_at] %></span>
                  </div>
                <% end %>
                <%= if @reload_status[:pending_changes] do %>
                  <div class="status-row">
                    <span class="status-label">Pending changes</span>
                    <span class="status-value">Yes</span>
                  </div>
                <% end %>
              <% end %>
            </div>
          </section>

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
    # Cancel any existing timer
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
