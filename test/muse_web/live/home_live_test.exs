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

    # Decompress and verify
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
         <<length::unsigned-big-32, "IHDR", rest::binary>>,
         _ihdr,
         idat
       ) do
    <<w::unsigned-big-32, h::unsigned-big-32, _bd::8, ct::8, 0, 0, 0, _crc::binary-size(4),
      next::binary>> = rest

    read_png_chunks(next, %{width: w, height: h, color_type: ct}, idat)
  end

  defp read_png_chunks(
         <<length::unsigned-big-32, "IDAT", rest::binary>>,
         ihdr,
         idat
       ) do
    cdata = binary_part(rest, 0, length)
    after_data = binary_part(rest, length, byte_size(rest) - length)
    <<_crc::binary-size(4), next::binary>> = after_data
    read_png_chunks(next, ihdr, idat ++ [cdata])
  end

  defp read_png_chunks(
         <<_length::unsigned-big-32, _type::binary-size(4), rest::binary>>,
         ihdr,
         idat
       ) do
    skip = _length + 4
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

  # -- Tests --------------------------------------------------------------------

  test "renders workspace root", %{workspace_root: workspace_root} do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ workspace_root
    assert html =~ ~r/id="workspace"/
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

    assert html =~ ~s(class="brand-mark")
    assert html =~ ~s(id="workspace")
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

    html = view |> element("form") |> render_submit(%{"text" => "from the web"})

    assert html =~ "from the web"
    assert html =~ "Placeholder response"
  end

  test "reload status unavailable when DevReloader not running" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Reload unavailable"
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
    assert html =~ ~s(class="diagnostic-notice warning")
  end

  test "renders diagnostics with action buttons" do
    Muse.Diagnostics.emit(:error, "actionable error")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Add to next agent turn"
    assert html =~ ~s(class="diagnostic-actions")
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
    assert html =~ ~s(class="diagnostic-notice error")
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

    html = view |> element("form") |> render_submit(%{"text" => "   "})

    assert html =~ "Muse"
  end

  # -- Dashboard layout ---------------------------------------------------------

  test "renders app-shell dashboard container" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="app-shell")
  end

  test "renders compact header with brand" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ "CLI Coding Agent"
    refute html =~ "Self-healing development console"
    assert html =~ ~s(class="app-header")
    assert html =~ ~s(class="brand-mark")
    assert html =~ "Backend console"
  end

  test "no theme toggle in dark-only mode" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ ~s(data-theme-toggle)
    refute html =~ ~s(class="theme-toggle")
  end

  test "renders dashboard grid with panels and workspace chip" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "events-panel"
    assert html =~ "side-panel"
    assert html =~ "workspace-chip"
    assert html =~ "dev-tools-panel"
    assert html =~ "dashboard-grid"
  end

  test "renders event log with event badges, rows, and meta" do
    Muse.submit(:cli, "badge test")

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "event-log"
    assert html =~ "event-row"
    assert html =~ "event-badge"
    assert html =~ "event-source"
    assert html =~ "event-message"
    assert html =~ "event-meta"
    assert html =~ "UTC"
  end

  test "renders command panel with premium styling" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "command-bar"
    assert html =~ "command-panel"
    assert html =~ "primary-button"
  end

  # -- Self-healing diagnostic tests --------------------------------------------

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
    assert html =~ ~s(class="diagnostic-queued")
    assert html =~ ~s(disabled)
  end

  test "in-progress diagnostic shows In progress label" do
    diagnostic = Muse.Diagnostics.emit(:error, "progress error")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_in_progress(issue.id)

    {:ok, view, _html} = live(build_conn(), "/")

    html = render(view)
    assert html =~ "In progress"
    assert html =~ ~s(disabled)
  end

  test "failed diagnostic shows Self-healing failed label" do
    diagnostic = Muse.Diagnostics.emit(:error, "failed error")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_failed(issue.id, "compile error")

    {:ok, view, _html} = live(build_conn(), "/")

    html = render(view)
    assert html =~ "Self-healing failed"
    assert html =~ ~s(disabled)
  end

  test "fixed diagnostic shows Already fixed label" do
    diagnostic = Muse.Diagnostics.emit(:warning, "fixed warning")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_fixed(issue.id)

    {:ok, view, _html} = live(build_conn(), "/")

    html = render(view)
    assert html =~ "Already fixed"
    assert html =~ ~s(disabled)
  end

  test "collapse button collapses diagnostics to badge" do
    Muse.Diagnostics.emit(:warning, "collapsible warning")

    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element(".diagnostics-collapse-btn") |> render_click()

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

  # -- Simulate backend error ---------------------------------------------------

  test "dev tools section renders in test env" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="dev-tools")
    assert html =~ "Simulate backend error"
  end

  test "clicking Simulate backend error shows diagnostics popup" do
    {:ok, view, html} = live(build_conn(), "/")
    refute html =~ ~s(id="diagnostics-popup")

    view |> element("[phx-click='simulate_backend_error']") |> render_click()

    html = render(view)
    assert html =~ ~s(id="diagnostics-popup")
    assert html =~ "Simulated backend error for popup testing"
  end

  describe "static assets" do
    test "serves /assets/css/app.css with theme variables" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ "--bg: #0f1117"
      assert conn.resp_body =~ "--panel"
      assert conn.resp_body =~ ".app-shell"
      assert conn.resp_body =~ ".dashboard-grid"
      assert conn.resp_body =~ ".panel"
      assert conn.resp_body =~ ".events-panel"
      assert conn.resp_body =~ ".command-bar"
      assert conn.resp_body =~ ".secondary-button"
      assert conn.resp_body =~ ".diagnostic-pill"
      assert conn.resp_body =~ ".workspace-chip"
      assert conn.resp_body =~ ".event-log"
      assert conn.resp_body =~ ".event-row-error"
      refute conn.resp_body =~ ".muse-hero"
      refute conn.resp_body =~ ".theme-toggle"
      assert conn.resp_body =~ ".diagnostics-popup"
      assert conn.resp_body =~ ".diagnostic-notice.warning"
      assert conn.resp_body =~ ".diagnostic-notice.error"
      assert conn.resp_body =~ ".diagnostic-notice.critical"
      # Window management CSS classes
      assert conn.resp_body =~ ".icon-dock"
      assert conn.resp_body =~ ".dock-icon"
      assert conn.resp_body =~ ".managed-window"
      assert conn.resp_body =~ ".window-title-bar"
      assert conn.resp_body =~ ".window-body"
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

  # -- Window management tests --------------------------------------------------

  describe "icon dock and window management" do
    test "renders icon dock with window toggle buttons" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(class="icon-dock")
      assert html =~ "dock-icon"
      assert html =~ "phx-click=\"toggle_window\""
    end

    test "renders reload-status pill in header" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(id="reload-status")
      assert html =~ "reload-pill"
      assert html =~ "Reload unavailable"
    end

    test "all six window icons are present" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(phx-value-window="events")
      assert html =~ ~s(phx-value-window="reload")
      assert html =~ ~s(phx-value-window="universal-agent")
      assert html =~ ~s(phx-value-window="settings")
      assert html =~ ~s(phx-value-window="statistics")
      assert html =~ ~s(phx-value-window="agents")
    end

    test "clicking statistics icon opens window-statistics with BEAM info" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-statistics")
      assert html =~ "managed-window"
      # BEAM stats content
      assert html =~ "Total"
      assert html =~ "Processes"
      assert html =~ "Schedulers"
    end

    test "clicking events icon opens window-events" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='events']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-events")
    end

    test "clicking reload icon opens window-reload" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element(".dock-icon[phx-value-window='reload']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-reload")
    end

    test "clicking agents icon opens window-agents" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='agents']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-agents")
      assert html =~ "Agent tree"
    end

    test "clicking settings icon opens window-settings" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='settings']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-settings")
      assert html =~ "Settings"
    end

    test "clicking universal-agent icon opens window-universal-agent" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='universal-agent']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-universal-agent")
      assert html =~ "No universal agent runtime connected"
    end

    test "closing a window removes it from the DOM" do
      {:ok, view, _html} = live(build_conn(), "/")

      # Open statistics window
      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-statistics")

      # Close it
      view
      |> element("[phx-click='close_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      refute html =~ ~s(id="window-statistics")
    end

    test "toggling an open window closes it" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-statistics")

      # Toggle again closes it
      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      refute html =~ ~s(id="window-statistics")
    end

    test "opened window receives active-window class for z-index" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      assert html =~ "active-window"
    end

    test "focusing a different window moves active-window class" do
      {:ok, view, _html} = live(build_conn(), "/")

      # Open statistics
      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      # Open events (becomes active)
      view
      |> element("[phx-click='toggle_window'][phx-value-window='events']")
      |> render_click()

      html = render(view)
      # Both windows open, events is active
      assert html =~ ~s(id="window-statistics")
      assert html =~ ~s(id="window-events")
    end

    test "reload window shows Reload unavailable when DevReloader not running" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element(".dock-icon[phx-value-window='reload']")
      |> render_click()

      html = render(view)
      assert html =~ "Reload unavailable"
    end

    test "managed windows use DraggableWindow hook" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(phx-hook="DraggableWindow")
    end

    test "agent window shows No agents registered when registry is empty" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='agents']")
      |> render_click()

      html = render(view)
      assert html =~ "No agents registered"
    end

    test "refresh_stats event updates BEAM stats" do
      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element("[phx-click='toggle_window'][phx-value-window='statistics']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="window-statistics")

      view
      |> element("[phx-click='refresh_stats']")
      |> render_click()

      html = render(view)
      # Stats window still present after refresh
      assert html =~ ~s(id="window-statistics")
    end
  end

  describe "window management CSS" do
    test "CSS includes managed window and dock classes" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ ".icon-dock"
      assert conn.resp_body =~ ".dock-icon"
      assert conn.resp_body =~ ".managed-window"
      assert conn.resp_body =~ ".window-title-bar"
      assert conn.resp_body =~ ".window-body"
      assert conn.resp_body =~ ".stat-row"
      assert conn.resp_body =~ ".agent-entry"
      assert conn.resp_body =~ ".file-entry"
    end
  end
end
