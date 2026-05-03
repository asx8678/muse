defmodule MuseWeb.HomeLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MuseWeb.Endpoint

  # -- Helpers ------------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

      _pid ->
        :ok
    end
  end

  defp start_workspace(root) do
    stop_named(Muse.Workspace)
    {:ok, _} = Muse.Workspace.start_link(root: root)
  end

  defp start_state do
    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])
  end

  defp start_diagnostics do
    stop_named(Muse.Diagnostics)
    {:ok, _} = Muse.Diagnostics.start_link(install_logger_handler?: false)
  end

  defp start_self_healing_queue do
    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = Muse.SelfHealingQueue.start_link([])
  end

  defp start_agent_registry do
    stop_named(Muse.AgentRegistry)
    {:ok, _} = Muse.AgentRegistry.start_link([])
  end

  defp start_endpoint do
    stop_named(MuseWeb.Endpoint)
    {:ok, _} = MuseWeb.Endpoint.start_link()
  end

  defp first_index!(html, needle) do
    [prefix, _suffix] = String.split(html, needle, parts: 2)
    String.length(prefix)
  end

  defp occurrences(html, needle) do
    html
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  defp inject_live_reload_frame(html) do
    String.replace(
      html,
      "</body>",
      ~s(<iframe src="/phoenix/live_reload/frame"></iframe></body>)
    )
  end

  defp assert_png_valid(data, expected_w, expected_h) do
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, rest::binary>> = data
    {ihdr, idat_parts} = read_png_chunks(rest, nil, [])
    assert ihdr != nil, "PNG missing IHDR"
    assert idat_parts != [], "PNG missing IDAT"

    assert ihdr.width == expected_w
    assert ihdr.height == expected_h
    assert ihdr.width > 0 and ihdr.height > 0

    raw = :zlib.uncompress(IO.iodata_to_binary(idat_parts))
    bpp = %{0 => 1, 2 => 3, 4 => 2, 6 => 4}[ihdr.color_type]
    expected_len = ihdr.height * (1 + ihdr.width * bpp)
    assert byte_size(raw) == expected_len
  end

  defp read_png_chunks(<<>>, ihdr, idat), do: {ihdr, idat}

  defp read_png_chunks(<<0, 0, 0, 0, "IEND", _crc::binary-size(4), _::binary>>, ihdr, idat) do
    {ihdr, idat}
  end

  defp read_png_chunks(
         <<_length::unsigned-big-32, "IHDR", rest::binary>>,
         _ihdr,
         idat
       ) do
    <<w::unsigned-big-32, h::unsigned-big-32, _bd::8, ct::8, 0, 0, 0, _crc::binary-size(4),
      next::binary>> = rest

    read_png_chunks(next, %{width: w, height: h, color_type: ct}, idat)
  end

  defp read_png_chunks(
         <<len::unsigned-big-32, "IDAT", rest::binary>>,
         ihdr,
         idat
       ) do
    cdata = binary_part(rest, 0, len)
    after_data = binary_part(rest, len, byte_size(rest) - len)
    <<_crc::binary-size(4), next::binary>> = after_data
    read_png_chunks(next, ihdr, idat ++ [cdata])
  end

  defp read_png_chunks(
         <<chunk_len::unsigned-big-32, _type::binary-size(4), rest::binary>>,
         ihdr,
         idat
       ) do
    skip = chunk_len + 4
    <<_::binary-size(skip), next::binary>> = rest
    read_png_chunks(next, ihdr, idat)
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    ensure_pubsub()

    tmp_dir = System.tmp_dir!()
    workspace_root = Path.join(tmp_dir, "muse_test_ws_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)

    Muse.Diagnostics.LoggerHandler.remove()
    start_workspace(workspace_root)
    start_state()
    start_diagnostics()
    start_self_healing_queue()
    start_agent_registry()
    start_endpoint()

    on_exit(fn ->
      Muse.Diagnostics.LoggerHandler.remove()
      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.AgentRegistry)
      stop_named(Muse.SelfHealingQueue)
      stop_named(Muse.Diagnostics)
      stop_named(Muse.State)
      stop_named(Muse.Workspace)
      File.rm_rf!(workspace_root)
    end)

    {:ok, workspace_root: workspace_root}
  end

  # -- Core rendering tests ----------------------------------------------------

  test "renders workspace root", %{workspace_root: workspace_root} do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ workspace_root
  end

  test "renders browser assets" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(src="/assets/app.js")
  end

  test "initial HTTP render uses root layout while HomeLive renders content fragment", %{
    workspace_root: workspace_root
  } do
    conn = build_conn() |> get("/")
    html = html_response(conn, 200)

    assert html =~ "<!DOCTYPE html>"
    assert html =~ ~s(<html lang="en" class="dark">)
    assert occurrences(html, "<!DOCTYPE html>") == 1
    assert occurrences(html, "<html") == 1
    assert occurrences(html, "<body>") == 1
    assert occurrences(html, "</body>") == 1
    assert occurrences(html, "</html>") == 1
    assert html =~ ~s(<meta name="csrf-token")
    assert html =~ ~s(<title>Muse</title>)
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(src="/assets/app.js")
    assert html =~ ~s(data-phx-main)

    assert html =~ "brand-mark"
    assert html =~ workspace_root

    assert first_index!(html, ~s(data-phx-main)) < first_index!(html, ~s(app-header))
    assert first_index!(html, ~s(</main>)) < first_index!(html, ~s(</body>))
  end

  test "LiveReload frame injected before body close remains outside LiveView root" do
    html = build_conn() |> get("/") |> html_response(200)
    html_with_live_reload = inject_live_reload_frame(html)

    live_view_start = first_index!(html_with_live_reload, ~s(data-phx-main))
    live_view_end = first_index!(html_with_live_reload, ~s(</div>))
    live_reload_frame = first_index!(html_with_live_reload, "/phoenix/live_reload/frame")
    body_close = first_index!(html_with_live_reload, ~s(</body>))

    assert live_view_start < live_view_end
    assert live_view_end < live_reload_frame
    assert live_reload_frame < body_close
  end

  test "renders existing events" do
    Muse.submit(:cli, "hello from test")
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "hello from test"
    assert html =~ "newest first"
  end

  test "newest events render before older events" do
    Muse.submit(:cli, "older event alpha")
    Muse.submit(:cli, "newer event bravo")
    {:ok, _view, html} = live(build_conn(), "/")
    older_pos = first_index!(html, "older event alpha")
    newer_pos = first_index!(html, "newer event bravo")
    assert newer_pos < older_pos, "newer event should appear before older event in HTML"
  end

  test "form submit appends web event and renders response" do
    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element("#command-form") |> render_submit(%{"text" => "from the web"})

    assert html =~ "from the web"
    assert html =~ "Placeholder response"
  end

  test "reload status unavailable when DevReloader not running" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Unavailable"
  end

  test "does not render diagnostics popup when there are no diagnostics" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ ~s(id="diagnostics-popup")
    refute html =~ ~s(id="diagnostics-badge")
  end

  test "renders full diagnostics popup when diagnostics exist on mount" do
    Muse.Diagnostics.emit(:warning, "existing backend warning")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="diagnostics-popup")
    assert html =~ "Backend diagnostics"
    assert html =~ "existing backend warning"
    assert html =~ "diagnostic-notice warning"
  end

  test "renders diagnostics with action buttons" do
    Muse.Diagnostics.emit(:error, "actionable error")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Add to next agent turn"
    assert html =~ "diagnostic-actions"
  end

  test "diagnostics popup has accessibility attributes" do
    Muse.Diagnostics.emit(:warning, "a11y test")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(role="region")
    assert html =~ ~s(aria-labelledby="diagnostics-title")
    assert html =~ ~s(id="diagnostics-title")
    assert html =~ ~s(aria-label="Minimize diagnostics panel")
  end

  test "updates diagnostics popup in real time" do
    {:ok, view, html} = live(build_conn(), "/")
    refute html =~ ~s(id="diagnostics-popup")

    Muse.Diagnostics.emit(:error, "late backend error")

    html = render(view)
    assert html =~ ~s(id="diagnostics-popup")
    assert html =~ "late backend error"
    assert html =~ "diagnostic-notice error"
  end

  test "renders latest five diagnostics and a more count" do
    for n <- 1..6 do
      Muse.Diagnostics.emit(:warning, "diagnostic #{n}")
    end

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "diagnostic 6"
    assert html =~ "diagnostic 2"
    refute html =~ "diagnostic 1"
    assert html =~ "+1 more backend diagnostics"
  end

  test "clears diagnostics popup when clear broadcast arrives" do
    Muse.Diagnostics.emit(:critical, "critical before clear")
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "critical before clear"

    Muse.Diagnostics.clear()

    html = render(view)
    refute html =~ ~s(id="diagnostics-popup")
    refute html =~ "critical before clear"
  end

  test "blank submit is ignored" do
    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element("#command-form") |> render_submit(%{"text" => "   "})

    assert html =~ "Muse"
  end

  # -- Dashboard layout (Sprint 1) -------------------------------------------

  test "renders app-shell dashboard container" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "app-shell"
  end

  test "renders compact header with brand and tab nav" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "app-header"
    assert html =~ "brand-mark"
    assert html =~ "Backend console"
    assert html =~ "tab-nav"
    assert html =~ ~s(role="tablist")
  end

  # -- JS hook attachment tests ----------------------------------------------

  test "app shell has KeyboardShortcuts hook" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="muse-shell")
    assert html =~ ~s(phx-hook="KeyboardShortcuts")
  end

  test "command console has CommandConsole hook and stable id" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="input-form")
    assert html =~ ~s(phx-hook="CommandConsole")
  end

  test "toast elements have ToastAutoDismiss hook" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Trigger a toast
    view |> element(".dev-tool-btn[phx-click='simulate_event']") |> render_click()
    html = render(view)
    assert html =~ ~s(phx-hook="ToastAutoDismiss")
  end

  test "no theme toggle in dark-only mode" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ ~s(data-theme-toggle)
    refute html =~ "theme-toggle"
  end

  test "renders console layout with events and sidebar" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "console-layout"
    assert html =~ "console-main"
    assert html =~ "dev-sidebar"
    assert html =~ "events-panel"
    assert html =~ "dev-tools-panel"
  end

  # -- Status bar tests -------------------------------------------------------

  test "renders status bar with status items" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "status-bar"
    assert html =~ "Backend"
    assert html =~ "Connected"
    assert html =~ "File watcher"
    assert html =~ "Universal agent"
    assert html =~ "Disconnected"
    assert html =~ "status-dot-green"
    assert html =~ "status-dot-gray"
  end

  test "status bar items have title tooltips" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Backend connection status"
    assert html =~ "File watcher status"
    assert html =~ "Workspace root path"
    assert html =~ "Universal agent runtime connection"
    assert html =~ "Total events received"
  end

  test "status bar shows file watcher as unavailable when not running" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Unavailable"
  end

  # -- Tab navigation tests ---------------------------------------------------

  test "renders tab navigation with labeled tabs" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(role="tab")
    assert html =~ "Events"
    assert html =~ "Files"
    assert html =~ "Agents"
    assert html =~ "Stats"
    assert html =~ "Settings"
  end

  test "tab buttons have title tooltips with shortcut hints" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Events (Ctrl+E)"
    assert html =~ "Files (Ctrl+F)"
    assert html =~ "Agents (Ctrl+A)"
    assert html =~ "Stats (Ctrl+R)"
    assert html =~ "Settings (Ctrl+,)"
  end

  test "events tab is active by default" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "tab-active"
    assert html =~ ~s(aria-selected="true")
  end

  test "switching tab updates active state" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='stats']") |> render_click()
    html = render(view)
    assert html =~ "Statistics"
    assert html =~ "stats-panel"
  end

  test "switching to files tab shows file watcher content" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='files']") |> render_click()
    html = render(view)
    assert html =~ "files-panel"
    assert html =~ "File watcher"
  end

  test "switching to agents tab shows agent content" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
    html = render(view)
    assert html =~ "agents-panel"
  end

  test "switching to settings tab shows settings" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='settings']") |> render_click()
    html = render(view)
    assert html =~ "settings-panel"
    assert html =~ "Theme"
    assert html =~ "Dark"
  end

  # -- Event display tests ----------------------------------------------------

  test "renders event log with event badges, rows, meta, and timestamps" do
    Muse.submit(:cli, "badge test")

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-log"
    assert html =~ "event-row"
    assert html =~ "event-badge"
    assert html =~ "event-source"
    assert html =~ "event-message"
    assert html =~ "event-meta"
    assert html =~ "event-timestamp"
    assert html =~ "event-severity"
  end

  test "events have severity indicators" do
    Muse.submit(:cli, "severity test")

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-severity-info"
  end

  # -- Event filter tests -----------------------------------------------------

  test "renders event filter buttons" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-filters"
    assert html =~ ~s(role="radiogroup")
    assert html =~ "All"
    assert html =~ "Errors"
    assert html =~ "Warnings"
    assert html =~ "Info"
  end

  test "setting event filter updates view" do
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element("[phx-click='set_event_filter'][phx-value-filter='errors']")
    |> render_click()

    html = render(view)
    assert html =~ "event-filter-active"
  end

  # -- Clear events test ------------------------------------------------------

  test "clearing events removes them from display" do
    Muse.submit(:cli, "event to clear")

    {:ok, view, _html} = live(build_conn(), "/")
    html = render(view)
    assert html =~ "event to clear"

    view |> element(".dev-tool-btn[phx-click='clear_events']") |> render_click()

    html = render(view)
    refute html =~ "event to clear"
    assert html =~ "No events yet"
  end

  test "events cleared broadcast refreshes state without explicit clear_events click" do
    Muse.submit(:cli, "broadcast clear event")

    {:ok, view, _html} = live(build_conn(), "/")
    html = render(view)
    assert html =~ "broadcast clear event"

    # Clear via backend broadcast, not via UI button
    Muse.State.clear()

    html = render(view)
    refute html =~ "broadcast clear event"
  end

  # -- Expandable event detail test -------------------------------------------

  test "clicking event row toggles JSON detail" do
    Muse.submit(:cli, "expandable event")

    {:ok, view, _html} = live(build_conn(), "/")

    # Get the first event's ID from state
    [first_event | _] = Muse.State.events()

    view
    |> element(".event-expand-btn[phx-value-id='#{first_event.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "event-detail-json"
  end

  test "event expand button has aria-expanded and aria-controls" do
    Muse.submit(:cli, "a11y event")

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-expand-btn"
    assert html =~ "aria-expanded"
    assert html =~ "aria-controls"
  end

  test "event expand button updates aria-expanded when toggled" do
    Muse.submit(:cli, "toggle a11y event")

    {:ok, view, _html} = live(build_conn(), "/")

    # Initially collapsed
    html = render(view)
    assert html =~ ~s(aria-expanded="false")

    # Expand
    [first_event | _] = Muse.State.events()

    view
    |> element(".event-expand-btn[phx-value-id='#{first_event.id}']")
    |> render_click()

    html = render(view)
    assert html =~ ~s(aria-expanded="true")
  end

  test "event detail region has id matching aria-controls" do
    Muse.submit(:cli, "controls event")

    {:ok, view, _html} = live(build_conn(), "/")

    [first_event | _] = Muse.State.events()

    view
    |> element(".event-expand-btn[phx-value-id='#{first_event.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "event-detail-#{first_event.id}"
    assert html =~ ~s(role="region")
  end

  # -- Empty states tests -----------------------------------------------------

  test "events empty state shows explanation and CTAs" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "No events yet"
    assert html =~ "Simulate event"
    assert html =~ "View event schema"
    assert html =~ "Muse watches your backend workspace"
  end

  test "agents empty state shows explanation and CTAs" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
    html = render(view)
    assert html =~ "No agents registered"
    assert html =~ "Connect runtime"
  end

  test "files empty state shows watcher status" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='files']") |> render_click()
    html = render(view)
    assert html =~ "File watcher unavailable"
  end

  # -- Dev tools tests --------------------------------------------------------

  test "dev tools section renders with expanded actions" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="dev-tools")
    assert html =~ "Simulate event"
    assert html =~ "Simulate backend error"
    assert html =~ "Clear events"
    assert html =~ "Rescan watcher"
    assert html =~ "Refresh stats"
    assert html =~ "Copy diagnostics"
    assert html =~ "Connect runtime"
    assert html =~ "Retry connection"
  end

  test "dev tool buttons have title tooltips" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Create a simulated test event"
    assert html =~ "Simulate a backend error (dev only)"
    assert html =~ "Remove all events from the log"
    assert html =~ "Trigger a watcher rescan"
    assert html =~ "Refresh BEAM runtime statistics"
    assert html =~ "Copy diagnostics to clipboard"
    assert html =~ "Connect to universal agent runtime"
    assert html =~ "Retry agent runtime connection"
  end

  test "dev tools have grouped sections" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "dev-tool-group"
    assert html =~ "Simulate"
    assert html =~ "Actions"
    assert html =~ "Export"
    assert html =~ "Agent runtime"
  end

  test "simulate backend error button has warning styling" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "dev-tool-btn-warning"
  end

  test "clicking Simulate event creates an event and toast" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element(".dev-tool-btn[phx-click='simulate_event']") |> render_click()

    html = render(view)
    assert html =~ "Simulated test event"
    assert html =~ "toast"
  end

  test "clicking Simulate backend error shows diagnostics popup and toast" do
    {:ok, view, html} = live(build_conn(), "/")
    refute html =~ ~s(id="diagnostics-popup")

    view |> element("[phx-click='simulate_backend_error']") |> render_click()

    html = render(view)
    assert html =~ ~s(id="diagnostics-popup")
    assert html =~ "Simulated backend error for popup testing"
    assert html =~ "toast"
  end

  # -- Toast notification tests -----------------------------------------------

  test "toast container renders with aria-live" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "toast-container"
    assert html =~ ~s(aria-live="polite")
  end

  test "toast dismiss button works" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Trigger a toast
    view |> element(".dev-tool-btn[phx-click='simulate_event']") |> render_click()
    html = render(view)
    assert html =~ "toast"

    # Dismiss it
    view |> element("[phx-click='dismiss_toast']") |> render_click()
    html = render(view)
    # Toast should be removed (no more toast-message class)
    refute html =~ "toast-message"
  end

  # -- Command console tests --------------------------------------------------

  test "renders command console with textarea" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "command-console"
    assert html =~ "command-bar"
    assert html =~ "command-input"
    assert html =~ "primary-button"
    assert html =~ "Type /help for commands or ask Muse a question."
  end

  test "command history area exists" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="command-history")
  end

  # -- Slash command tests ----------------------------------------------------

  test "/help command returns help text" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/help"})

    html = render(view)
    assert html =~ "Available commands"
    assert html =~ "/events"
    assert html =~ "/clear events"
  end

  test "/events command shows event summary" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/events"})

    html = render(view)
    assert html =~ "event(s) recorded"
  end

  test "/agents command shows agent status" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/agents"})

    html = render(view)
    assert html =~ "agent(s)"
  end

  test "/simulate event creates a simulated event" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/simulate event"})

    html = render(view)
    assert html =~ "Simulated event"
  end

  test "/simulate backend-error creates backend error" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/simulate backend-error"})

    html = render(view)
    assert html =~ "Simulated backend error"
  end

  test "/clear events clears the event log" do
    Muse.submit(:cli, "event to clear via command")

    {:ok, view, _html} = live(build_conn(), "/")
    html = render(view)
    assert html =~ "event to clear via command"

    view |> element("#command-form") |> render_submit(%{"text" => "/clear events"})

    html = render(view)
    refute html =~ "event to clear via command"
  end

  test "/clear clears command history" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Submit something to create history
    view |> element("#command-form") |> render_submit(%{"text" => "/help"})
    html = render(view)
    assert html =~ "command-history-entry"
    assert html =~ "Available commands"

    # Clear history - /clear itself creates one entry but clears the rest
    view |> element("#command-form") |> render_submit(%{"text" => "/clear"})

    html = render(view)
    # The /help command's output (Available commands) should be gone
    # Only the /clear command's entry should remain
    refute html =~ "Available commands"
    assert html =~ "Command history cleared"
  end

  test "/reload-status shows watcher status" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/reload-status"})

    html = render(view)
    assert html =~ "File watcher"
  end

  test "/workspace shows workspace info" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/workspace"})

    html = render(view)
    assert html =~ "Workspace"
  end

  test "unknown slash command shows error" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/unknown-cmd"})

    html = render(view)
    assert html =~ "Unknown command"
  end

  test "command history shows input and output" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/help"})
    html = render(view)
    assert html =~ "command-history-entry"
    assert html =~ "command-history-input"
    assert html =~ "command-history-output"
  end

  # -- Setup checklist tests --------------------------------------------------

  test "renders setup checklist" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Setup checklist"
    assert html =~ "Workspace detected"
    assert html =~ "File watching enabled"
    assert html =~ "Connect universal agent runtime"
    assert html =~ "Register first agent"
    assert html =~ "Send first command"
  end

  test "workspace detected shows as done" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "setup-item-done"
    assert html =~ "Workspace detected"
  end

  # -- Agent runtime tests ---------------------------------------------------

  test "connect agent runtime shows toast when runtime unavailable" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='connect_agent_runtime']") |> render_click()

    html = render(view)
    # AgentRuntime not started in test, so safe_connect returns unavailable error
    assert html =~ "Agent runtime unavailable"
  end

  test "retry agent runtime shows toast when runtime unavailable" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='retry_agent_runtime']") |> render_click()

    html = render(view)
    assert html =~ "Agent runtime unavailable"
  end

  # -- Self-healing diagnostic tests ------------------------------------------

  test "clicking Add to next agent turn queues the diagnostic" do
    diagnostic = Muse.Diagnostics.emit(:warning, "queue me")

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element("[phx-click='queue_diagnostic_fix'][phx-value-diagnostic_id='#{diagnostic.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "Queued for next agent turn"
  end

  test "queued diagnostic renders disabled state" do
    diagnostic = Muse.Diagnostics.emit(:error, "queued error")

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element("[phx-click='queue_diagnostic_fix'][phx-value-diagnostic_id='#{diagnostic.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "diagnostic-queued"
    assert html =~ "disabled"
  end

  test "in-progress diagnostic shows In progress label" do
    diagnostic = Muse.Diagnostics.emit(:error, "progress error")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_in_progress(issue.id)

    {:ok, view, _html} = live(build_conn(), "/")

    html = render(view)
    assert html =~ "In progress"
    assert html =~ "disabled"
  end

  test "failed diagnostic shows Self-healing failed label" do
    diagnostic = Muse.Diagnostics.emit(:error, "failed error")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_failed(issue.id, "compile error")

    {:ok, view, _html} = live(build_conn(), "/")

    html = render(view)
    assert html =~ "Self-healing failed"
    assert html =~ "disabled"
  end

  test "fixed diagnostic shows Already fixed label" do
    diagnostic = Muse.Diagnostics.emit(:warning, "fixed warning")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_fixed(issue.id)

    {:ok, view, _html} = live(build_conn(), "/")

    html = render(view)
    assert html =~ "Already fixed"
    assert html =~ "disabled"
  end

  test "collapse button collapses diagnostics to badge" do
    Muse.Diagnostics.emit(:warning, "collapsible warning")

    {:ok, view, _html} = live(build_conn(), "/")

    view |> element(".diagnostics-collapse-btn") |> render_click()

    html = render(view)
    assert html =~ ~s(id="diagnostics-badge")
    refute html =~ ~s(id="diagnostics-popup")
    assert html =~ "diagnostic"
  end

  test "clicking badge reopens diagnostics popup" do
    Muse.Diagnostics.emit(:warning, "badge reopen test")

    {:ok, view, _html} = live(build_conn(), "/")

    view |> element(".diagnostics-collapse-btn") |> render_click()
    html = render(view)
    assert html =~ ~s(id="diagnostics-badge")

    html = view |> element("#diagnostics-badge") |> render_click()
    assert html =~ ~s(id="diagnostics-popup")
    assert html =~ "badge reopen test"
    refute html =~ ~s(id="diagnostics-badge")
  end

  test "collapse via handle_info renders badge when ref matches" do
    Muse.Diagnostics.emit(:warning, "timed collapse")
    {:ok, view, _html} = live(build_conn(), "/")

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    current_ref = assigns.diagnostics_collapse_ref
    send(view.pid, {:collapse_diagnostics, current_ref})

    html = render(view)
    assert html =~ ~s(id="diagnostics-badge")
    refute html =~ ~s(id="diagnostics-popup")
  end

  test "stale collapse ref is ignored" do
    Muse.Diagnostics.emit(:warning, "stale ref test")
    {:ok, view, _html} = live(build_conn(), "/")

    stale_ref = :erlang.make_ref()
    send(view.pid, {:collapse_diagnostics, stale_ref})

    html = render(view)
    assert html =~ ~s(id="diagnostics-popup")
  end

  test "self-healing summary shows when issues exist" do
    diagnostic = Muse.Diagnostics.emit(:warning, "summary test")

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element("[phx-click='queue_diagnostic_fix'][phx-value-diagnostic_id='#{diagnostic.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "Self-healing queue"
  end

  # -- Agent tab tests --------------------------------------------------------

  test "agents tab shows No agents registered when registry is empty" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
    html = render(view)
    assert html =~ "No agents registered"
  end

  test "stats tab shows BEAM info and refresh button" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='switch_tab'][phx-value-tab='stats']") |> render_click()
    html = render(view)
    assert html =~ "Total"
    assert html =~ "Processes"
    assert html =~ "Schedulers"
    assert html =~ "Refresh"
  end

  test "refresh_stats event updates BEAM stats" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Switch to stats tab
    view |> element("[phx-click='switch_tab'][phx-value-tab='stats']") |> render_click()

    # Click the refresh button in the stats panel specifically
    view |> element(".stats-panel [phx-click='refresh_stats']") |> render_click()
    html = render(view)
    assert html =~ "Statistics"
  end

  # -- Force reload watcher test ----------------------------------------------

  test "force reload watcher when DevReloader not running shows toast" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("[phx-click='force_reload_watcher']") |> render_click()

    html = render(view)
    # Should show a toast about watcher status
    assert html =~ "toast"
  end

  # -- Copy diagnostics placeholder test --------------------------------------

  test "copy diagnostics triggers clipboard push event" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Should not raise — the handler pushes a copy_to_clipboard event to the client
    html = view |> element("[phx-click='copy_diagnostics']") |> render_click()
    # LiveView still renders without errors
    assert html =~ "Muse"
  end

  # -- Static assets -----------------------------------------------------------

  describe "static assets" do
    test "serves /assets/css/app.css with theme variables" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ "--bg: #0f1117"
      assert conn.resp_body =~ "--panel"
      assert conn.resp_body =~ ".app-shell"
      assert conn.resp_body =~ ".console-layout"
      assert conn.resp_body =~ ".panel"
      assert conn.resp_body =~ ".events-panel"
      assert conn.resp_body =~ ".command-bar"
      assert conn.resp_body =~ ".command-console"
      assert conn.resp_body =~ ".secondary-button"
      assert conn.resp_body =~ ".diagnostic-pill"
      assert conn.resp_body =~ ".event-log"
      assert conn.resp_body =~ ".event-row-error"
      refute conn.resp_body =~ ".muse-hero"
      refute conn.resp_body =~ ".theme-toggle"
      assert conn.resp_body =~ ".diagnostics-popup"
      assert conn.resp_body =~ ".diagnostic-notice.warning"
      assert conn.resp_body =~ ".diagnostic-notice.error"
      assert conn.resp_body =~ ".diagnostic-notice.critical"
      # Sprint 1 CSS classes
      assert conn.resp_body =~ ".tab-nav"
      assert conn.resp_body =~ ".tab-btn"
      assert conn.resp_body =~ ".status-bar"
      assert conn.resp_body =~ ".status-dot"
      assert conn.resp_body =~ ".toast-container"
      assert conn.resp_body =~ ".toast"
      assert conn.resp_body =~ ".command-history"
      assert conn.resp_body =~ ".setup-checklist"
      assert conn.resp_body =~ ".empty-state"
      assert conn.resp_body =~ ".event-filters"
      assert conn.resp_body =~ ".dev-tool-group"
    end

    test "light mode background image is a fully valid PNG" do
      conn = build_conn() |> get("/images/muse-bg-light.png")
      assert conn.status == 200
      path = Path.join([:code.priv_dir(:muse), "static", "images", "muse-bg-light.png"])
      assert_png_valid(File.read!(path), 800, 600)
    end

    test "dark mode background image is a fully valid PNG" do
      conn = build_conn() |> get("/images/muse-bg-dark.png")
      assert conn.status == 200
      path = Path.join([:code.priv_dir(:muse), "static", "images", "muse-bg-dark.png"])
      assert_png_valid(File.read!(path), 800, 600)
    end
  end

  # -- Phase 2: Event search + filter combination --------------------------------

  test "renders event search input" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-search-input"
    assert html =~ "Search events"
  end

  test "event search input submits phx-change" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(".event-search-form") |> render_change(%{"query" => "test query"})
    html = render(view)
    assert html =~ "test query"
  end

  test "clear event search button appears when search is set" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(".event-search-form") |> render_change(%{"query" => "findme"})
    html = render(view)
    assert html =~ "event-search-clear"
  end

  test "clear event search clears the query" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(".event-search-form") |> render_change(%{"query" => "findme"})
    html = render(view)
    assert html =~ "findme"

    view |> element(".event-search-clear") |> render_click()
    html = render(view)
    refute html =~ "findme"
  end

  test "clear filters button appears when filter is not all or search is set" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("[phx-click='set_event_filter'][phx-value-filter='errors']") |> render_click()
    html = render(view)
    assert html =~ "event-clear-filters-btn"
  end

  test "clear filters resets both filter and search" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(".event-search-form") |> render_change(%{"query" => "test"})
    view |> element("[phx-click='set_event_filter'][phx-value-filter='errors']") |> render_click()
    html = render(view)
    assert html =~ "event-clear-filters-btn"

    view |> element(".event-clear-filters-btn") |> render_click()
    html = render(view)
    refute html =~ "event-clear-filters-btn"
  end

  test "event search + filter combination narrows results" do
    Muse.submit(:cli, "searchable event alpha")
    Muse.State.append(Muse.Event.new(:web, :error, %{text: "searchable error event"}))

    {:ok, view, _html} = live(build_conn(), "/")
    # Set filter to errors and search to "searchable"
    view |> element("[phx-click='set_event_filter'][phx-value-filter='errors']") |> render_click()
    view |> element(".event-search-form") |> render_change(%{"query" => "searchable"})
    html = render(view)
    # Should show matching count
    assert html =~ "matching"
  end

  test "no matching events shows empty state with clear filters" do
    Muse.submit(:cli, "some event")

    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(".event-search-form") |> render_change(%{"query" => "zzz-no-match-xyz"})
    html = render(view)
    assert html =~ "No matching events"
    assert html =~ "Clear filters/search"
  end

  # -- Phase 2: Copy/export actions ---------------------------------------------

  test "events have copy JSON button" do
    Muse.submit(:cli, "copyable event")
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-copy-json-btn"
    assert html =~ "Copy JSON"
  end

  test "copy event JSON handler works without crash" do
    Muse.submit(:cli, "copy target")
    {:ok, view, _html} = live(build_conn(), "/")

    [event | _] = Muse.State.events()
    html = view |> element(".event-copy-json-btn[phx-value-id='#{event.id}']") |> render_click()
    assert html =~ "Muse"
  end

  test "copy event JSON with non-encodable data does not crash" do
    # Event data contains a tuple, a PID-like ref string, and a nested map with atom keys
    Muse.State.append(
      Muse.Event.new(:web, :tricky, {1, {:nested, :tuple}, %{atom_key: "val", pid: self()}})
    )

    {:ok, view, _html} = live(build_conn(), "/")

    [event | _] = Muse.State.events()
    html = view |> element(".event-copy-json-btn[phx-value-id='#{event.id}']") |> render_click()
    assert html =~ "Muse"
  end

  test "copy/export event JSON with non-string map keys does not crash" do
    # Integer keys and tuple keys — must be converted to strings for JSON
    Muse.State.append(
      Muse.Event.new(:web, :weird_keys, %{{:tuple, 1} => :ok, 123 => "number-key", "str" => 42})
    )

    {:ok, view, _html} = live(build_conn(), "/")

    [event | _] = Muse.State.events()
    html = view |> element(".event-copy-json-btn[phx-value-id='#{event.id}']") |> render_click()
    assert html =~ "Muse"

    html = view |> element(".event-export-btn") |> render_click()
    assert html =~ "Muse"
  end

  test "export events with non-encodable data does not crash" do
    Muse.State.append(
      Muse.Event.new(:web, :tricky, {1, {:nested, :tuple}, %{atom_key: "val", pid: self()}})
    )

    {:ok, view, _html} = live(build_conn(), "/")
    html = view |> element(".event-export-btn") |> render_click()
    assert html =~ "Muse"
  end

  test "copy diagnostics with beam stats does not crash" do
    {:ok, view, _html} = live(build_conn(), "/")
    html = view |> element("[phx-click='copy_diagnostics']") |> render_click()
    assert html =~ "Muse"
  end

  test "copy event JSON for event with DateTime in data does not crash" do
    Muse.State.append(
      Muse.Event.new(:web, :time_data, %{occurred_at: DateTime.utc_now(), label: "test"})
    )

    {:ok, view, _html} = live(build_conn(), "/")

    [event | _] = Muse.State.events()
    html = view |> element(".event-copy-json-btn[phx-value-id='#{event.id}']") |> render_click()
    assert html =~ "Muse"
  end

  test "export events button renders" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-export-btn"
    assert html =~ "Export"
  end

  test "export events handler works" do
    {:ok, view, _html} = live(build_conn(), "/")
    html = view |> element(".event-export-btn") |> render_click()
    assert html =~ "Muse"
  end

  test "copy diagnostics handler triggers clipboard push" do
    {:ok, view, _html} = live(build_conn(), "/")
    html = view |> element("[phx-click='copy_diagnostics']") |> render_click()
    assert html =~ "Muse"
  end

  # -- Phase 2: New slash commands -----------------------------------------------

  test "/stats command shows BEAM stats" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/stats"})
    html = render(view)
    assert html =~ "BEAM Stats"
  end

  test "/diagnostics command shows diagnostics summary" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/diagnostics"})
    html = render(view)
    assert html =~ "diagnostics"
  end

  test "/copy diagnostics triggers clipboard" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/copy diagnostics"})
    html = render(view)
    assert html =~ "Diagnostics copied"
  end

  test "/export events exports events" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/export events"})
    html = render(view)
    assert html =~ "events exported"
  end

  test "/search events sets search and switches tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/search events myquery"})
    html = render(view)
    assert html =~ "Searching events for: myquery"
  end

  test "/filter events sets filter and switches tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/filter events errors"})
    html = render(view)
    assert html =~ "Event filter set to: Errors"
  end

  # -- Phase 2 robustness: command-dispatch edge cases -------------------------

  test "/search events without query shows usage and does not crash" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/search events"})
    html = render(view)
    assert html =~ "Usage: /search events"
    # Should be on events tab
    assert html =~ "events-panel"
  end

  test "/filter events without severity shows usage and current filter" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/filter events"})
    html = render(view)
    assert html =~ "Usage: /filter events"
    assert html =~ "current: All"
    # Should be on events tab
    assert html =~ "events-panel"
  end

  test "/filter events with invalid severity shows error and does not change filter" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Set filter to warnings first
    view
    |> element("[phx-click='set_event_filter'][phx-value-filter='warnings']")
    |> render_click()

    html =
      view
      |> element("#command-form")
      |> render_submit(%{"text" => "/filter events nonsense"})

    assert html =~ "Unknown filter"
    assert html =~ "Usage: /filter events"
    # Filter should still be warnings, not silently changed to all
    assert html =~ "event-filter-active"
    # Should be on events tab
    assert html =~ "events-panel"
  end

  test "/simulate event with extra args does not crash" do
    {:ok, view, _html} = live(build_conn(), "/")

    html =
      view
      |> element("#command-form")
      |> render_submit(%{"text" => "/simulate event extra"})

    assert html =~ "Simulated event created"
  end

  test "/open events switches to events tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    # Switch away first
    view |> element("[phx-click='switch_tab'][phx-value-tab='stats']") |> render_click()
    html = render(view)
    assert html =~ "Statistics"

    # Switch back via command
    view |> element("#command-form") |> render_submit(%{"text" => "/open events"})
    html = render(view)
    assert html =~ "Switched to Events tab"
  end

  test "/open files switches to files tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/open files"})
    html = render(view)
    assert html =~ "Switched to Files tab"
  end

  test "/open agents switches to agents tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/open agents"})
    html = render(view)
    assert html =~ "Switched to Agents tab"
  end

  test "/open stats switches to stats tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/open stats"})
    html = render(view)
    assert html =~ "Switched to Stats tab"
  end

  test "/open settings switches to settings tab" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> element("#command-form") |> render_submit(%{"text" => "/open settings"})
    html = render(view)
    assert html =~ "Switched to Settings tab"
  end

  # -- Phase 2: Command palette -------------------------------------------------

  test "command palette element renders" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="command-palette")
    assert html =~ "command-palette"
    assert html =~ ~s(role="dialog")
  end

  test "command palette has data-palette-actions" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "data-palette-actions"
  end

  test "command palette has keyboard navigation hints" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Navigate"
    assert html =~ "Ctrl+K"
  end

  test "command palette action handler works" do
    {:ok, view, _html} = live(build_conn(), "/")
    view |> render_hook("command_palette_action", %{"action" => "open_events"})
    html = render(view)
    assert html =~ "Events"
  end

  # -- Phase 2: JS hook elements -----------------------------------------------

  test "clipboard handler hook element exists" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="clipboard-handler")
    assert html =~ ~s(phx-hook="ClipboardHandler")
  end

  test "command console has data-slash-commands" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "data-slash-commands"
  end

  # -- Phase 2: CSS classes for new features -----------------------------------

  describe "Phase 2 static assets" do
    test "serves /assets/css/app.css with Phase 2 classes" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ ".event-search-input"
      assert conn.resp_body =~ ".event-copy-json-btn"
      assert conn.resp_body =~ ".command-suggestions"
      assert conn.resp_body =~ ".command-palette"
      assert conn.resp_body =~ ".palette-item"
      assert conn.resp_body =~ ".command-palette-input"
      assert conn.resp_body =~ ".events-search-row"
    end
  end

  describe "Runtime + Logs CSS classes" do
    test "serves /assets/css/app.css with log and runtime styles" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ ".log-badge"
      assert conn.resp_body =~ ".log-badge-debug"
      assert conn.resp_body =~ ".log-badge-info"
      assert conn.resp_body =~ ".log-badge-warning"
      assert conn.resp_body =~ ".log-badge-error"
      assert conn.resp_body =~ ".log-badge-critical"
      assert conn.resp_body =~ ".log-row"
      assert conn.resp_body =~ ".log-row-error"
      assert conn.resp_body =~ ".log-row-warning"
      assert conn.resp_body =~ ".agent-runtime-card"
      assert conn.resp_body =~ ".status-dot-red"
      assert conn.resp_body =~ ".agent-runtime-endpoint-input"
    end
  end

  # -- Logs tab tests -----------------------------------------------------------

  describe "Logs tab" do
    test "logs tab is present in navigation" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ "Logs"
    end

    test "switching to logs tab shows logs panel" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='logs']") |> render_click()
      html = render(view)
      assert html =~ "logs-panel"
    end

    test "logs tab shows empty state when no logs" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='logs']") |> render_click()
      html = render(view)
      assert html =~ "No logs yet"
      assert html =~ "Logs from the backend/runtime will appear here"
    end

    test "logs tab shows simulate button in non-prod" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='logs']") |> render_click()
      html = render(view)

      if Mix.env() != :prod do
        assert html =~ "Simulate log"
      end
    end

    test "logs tab has filter buttons" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='logs']") |> render_click()
      html = render(view)
      assert html =~ "set_log_filter"
    end

    test "logs tab has search input" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='logs']") |> render_click()
      html = render(view)
      assert html =~ "Search logs"
    end

    test "logs tab has clear and export buttons" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='logs']") |> render_click()
      html = render(view)
      assert html =~ "clear_logs"
      assert html =~ "export_logs"
    end
  end

  # -- Agent runtime UI tests ---------------------------------------------------

  describe "Agent runtime UI" do
    test "agents tab shows runtime card" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
      html = render(view)
      assert html =~ "agent-runtime-card"
      assert html =~ "Universal agent runtime"
    end

    test "runtime card shows connect/retry buttons when disconnected" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
      html = render(view)
      assert html =~ "connect_agent_runtime"
      assert html =~ "retry_agent_runtime"
    end

    test "dev sidebar has disconnect button" do
      {:ok, view, _html} = live(build_conn(), "/")

      html = render(view)
      assert html =~ "disconnect_agent_runtime"
    end

    test "runtime card shows endpoint input" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
      html = render(view)
      assert html =~ "agent-runtime-endpoint-input"
      assert html =~ "set_agent_runtime_endpoint"
    end

    test "endpoint input has aria-label" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("[phx-click='switch_tab'][phx-value-tab='agents']") |> render_click()
      html = render(view)
      assert html =~ ~s(aria-label="Agent runtime endpoint")
    end
  end
end
