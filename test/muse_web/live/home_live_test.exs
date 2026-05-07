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

  # -- Helper to open diagnostics drawer from sidebar card ---------------------

  defp open_diagnostics_drawer(view) do
    view |> element(".mini-card-btn[phx-click='open_diagnostics']") |> render_click()
  end

  # -- Core rendering tests ----------------------------------------------------

  test "workspace root appears in context panel", %{workspace_root: _workspace_root} do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="context-sidebar)
    assert html =~ "workspace"
  end

  test "renders browser assets" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(src="/assets/app.js")
  end

  test "initial HTTP render uses root layout while HomeLive renders content fragment",
       %{workspace_root: _workspace_root} do
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

    assert html =~ "muse-brand"

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

  # -- Chat-first initial render assertions ------------------------------------

  test "renders chat-first UI with lowercase muse" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "muse"
  end

  test "renders chat panel and composer elements" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="chat-panel")
    assert html =~ ~s(class="chat-scroll")
    assert html =~ ~s(class="chat-input command-input")
    assert html =~ ~s(class="chat-composer")
    assert html =~ ~s(class="chat-composer-form")
    assert html =~ "chat-send-button"
    assert html =~ ~s(id="command-form")
    assert html =~ "Ask Muse anything, or type /help"
    assert html =~ "Help me connect the Muse runtime"
    refute html =~ "Help me connect the agent runtime"
  end

  test "renders context sidebar panel" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="context-sidebar)
    assert html =~ ~s(status-chip)
    assert html =~ ~s(class="status-chips")
  end

  test "does not render legacy tab nav or backend console" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ "Backend console"
    refute html =~ ~s(class="tab-nav")
    refute html =~ ~s(role="tablist")
    refute html =~ ~s(id="dev-tools")
    refute html =~ ~s(dev-tools-panel)
    refute html =~ ~s(dev-tool-btn)
    refute html =~ ~s(class="command-console")
    refute html =~ ~s(class="events-panel")
  end

  test "header includes workspace chip" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="status-chips")
    assert html =~ "workspace"
  end

  test "header uses runtime label instead of agent" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "runtime"
  end

  test "renders main-layout container with default sidebar-expanded" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="main-layout sidebar-expanded")
  end

  # -- Sidebar state tests -----------------------------------------------------

  test "default sidebar state is expanded" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="main-layout sidebar-expanded")
    assert html =~ ~s(context-sidebar-expanded)
  end

  test "context panel appears before chat panel in HTML" do
    {:ok, _view, html} = live(build_conn(), "/")
    context_pos = first_index!(html, "context-sidebar")
    chat_pos = first_index!(html, "chat-panel")
    assert context_pos < chat_pos, "context sidebar should appear before chat panel"
  end

  test "collapse sidebar to rail" do
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(".context-icon-btn[phx-click='set_sidebar_state'][phx-value-state='rail']")
    |> render_click()

    html = render(view)
    assert html =~ ~s(sidebar-rail)
    assert html =~ ~s(context-sidebar-rail)
  end

  test "hide sidebar" do
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(".context-icon-btn[phx-click='set_sidebar_state'][phx-value-state='hidden']")
    |> render_click()

    html = render(view)
    assert html =~ ~s(sidebar-hidden)
    assert html =~ ~s(context-sidebar-hidden)
  end

  test "restore sidebar from hidden via reopen chip" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Hide first
    view
    |> element(".context-icon-btn[phx-click='set_sidebar_state'][phx-value-state='hidden']")
    |> render_click()

    html = render(view)
    assert html =~ ~s(sidebar-hidden)

    # Click reopen chip in header
    view |> element(".context-reopen-chip") |> render_click()
    html = render(view)
    assert html =~ ~s(sidebar-expanded)
    assert html =~ ~s(context-sidebar-expanded)
  end

  test "toggle_sidebar cycles expanded -> rail -> expanded" do
    {:ok, view, _html} = live(build_conn(), "/")

    {:noreply, socket} =
      MuseWeb.HomeLive.handle_event(
        "toggle_sidebar",
        %{},
        view.pid |> :sys.get_state() |> Map.get(:socket)
      )

    assert socket.assigns.sidebar_state == :rail

    {:noreply, socket} = MuseWeb.HomeLive.handle_event("toggle_sidebar", %{}, socket)
    assert socket.assigns.sidebar_state == :expanded
  end

  test "toggle_sidebar from hidden goes to expanded" do
    {:ok, view, _html} = live(build_conn(), "/")

    # Set to hidden first
    view
    |> element(".context-icon-btn[phx-click='set_sidebar_state'][phx-value-state='hidden']")
    |> render_click()

    {:noreply, socket} =
      MuseWeb.HomeLive.handle_event(
        "toggle_sidebar",
        %{},
        view.pid |> :sys.get_state() |> Map.get(:socket)
      )

    assert socket.assigns.sidebar_state == :expanded
  end

  test "set_sidebar_state rejects invalid values" do
    {:ok, view, _html} = live(build_conn(), "/")

    {:noreply, socket} =
      MuseWeb.HomeLive.handle_event(
        "set_sidebar_state",
        %{"state" => "invalid"},
        view.pid |> :sys.get_state() |> Map.get(:socket)
      )

    assert socket.assigns.sidebar_state == :expanded
  end

  # -- Existing events render as chat bubbles ----------------------------------

  test "renders existing events as chat messages" do
    Muse.submit(:cli, "hello from test")
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "hello from test"
    assert html =~ ~s(chat-message-user)
    assert html =~ ~s(chat-message)
    refute html =~ "newest first"
  end

  test "events appear in chat bubble order" do
    Muse.submit(:cli, "older event alpha")
    Muse.submit(:cli, "newer event bravo")
    {:ok, _view, html} = live(build_conn(), "/")
    older_pos = first_index!(html, "older event alpha")
    newer_pos = first_index!(html, "newer event bravo")
    assert newer_pos > older_pos, "newer event should appear after older event in chat"
  end

  # -- Form submit tests -------------------------------------------------------

  test "form submit creates user and assistant chat messages" do
    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element("#command-form") |> render_submit(%{"text" => "from the web"})

    assert html =~ "from the web"
    assert html =~ "Placeholder response"
    assert html =~ ~s(chat-message-user)
    assert html =~ ~s(chat-message-assistant)

    events = Muse.State.events()
    assert Enum.any?(events, &(&1.type == :user_message && &1.source == :web))
    assert Enum.any?(events, &(&1.type == :assistant_message))
  end

  test "blank submit is ignored" do
    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element("#command-form") |> render_submit(%{"text" => "   "})

    assert html =~ "muse"
  end

  test "successful message submit pushes clear_command_input event" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "hello clear test"})

    assert_push_event(view, "clear_command_input", %{})
  end

  test "unknown slash command pushes clear_command_input event" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/nope"})

    assert_push_event(view, "clear_command_input", %{})
  end

  test "valid slash command pushes clear_command_input event" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/help"})

    assert_push_event(view, "clear_command_input", %{})
  end

  # -- Streaming delta rendering tests ----------------------------------------

  describe "streaming delta chat rendering" do
    test "replayed delta events render concatenated text in chat" do
      # Submit a message which now emits deltas
      Muse.submit(:cli, "delta test")

      {:ok, _view, html} = live(build_conn(), "/")

      # The assistant message text should appear in chat
      assert html =~ "Placeholder response"
    end

    test "PubSub delta event updates LiveView" do
      {:ok, view, _html} = live(build_conn(), "/")

      # Submit via web, which emits events via State
      view |> element("#command-form") |> render_submit(%{"text" => "web delta"})

      # LiveView should show the assistant text
      html = render(view)
      assert html =~ "Placeholder response"
    end
  end

  # -- Diagnostics tests -------------------------------------------------------

  test "does not render diagnostics drawer when there are no diagnostics" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ ~s(id="diagnostics-drawer")
    refute html =~ ~s(id="diagnostics-popup")
    refute html =~ ~s(id="diagnostics-badge")
  end

  test "diagnostics exist on mount but drawer does NOT auto-open" do
    Muse.Diagnostics.emit(:warning, "existing backend warning")

    {:ok, _view, html} = live(build_conn(), "/")

    # Drawer should NOT be open on initial mount
    refute html =~ ~s(id="diagnostics-drawer")
    # But diagnostics card in sidebar should show count
    assert html =~ ~s(context-sidebar)
    assert html =~ "1 issue"
  end

  test "diagnostics sidebar card shows count and latest without opening drawer" do
    Muse.Diagnostics.emit(:warning, "sidebar card test")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(diagnostic-count)
    assert html =~ "1 issue"
    refute html =~ ~s(id="diagnostics-drawer")
  end

  test "clicking open details in sidebar opens diagnostics drawer" do
    Muse.Diagnostics.emit(:warning, "drawer open test")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)

    html = render(view)
    assert html =~ ~s(id="diagnostics-drawer")
    assert html =~ "drawer open test"
  end

  test "renders diagnostics drawer with action buttons" do
    Muse.Diagnostics.emit(:error, "actionable error")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)

    assert html =~ "Add to next Muse turn"
    assert html =~ "diagnostic-actions"
    assert html =~ "Copy error"
    assert html =~ "Jump to file"
  end

  test "diagnostics drawer has accessibility attributes" do
    Muse.Diagnostics.emit(:warning, "a11y test")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)

    assert html =~ ~s(role="region")
    assert html =~ ~s(aria-labelledby="diagnostics-title")
    assert html =~ ~s(id="diagnostics-title")
    assert html =~ ~s(aria-label="Minimize diagnostics panel")
  end

  test "diagnostics do NOT auto-open on real-time emit" do
    {:ok, view, _html} = live(build_conn(), "/")
    refute render(view) =~ ~s(id="diagnostics-drawer")

    Muse.Diagnostics.emit(:error, "late backend error")

    html = render(view)
    # Drawer should NOT auto-open
    refute html =~ ~s(id="diagnostics-drawer")
    # But diagnostics should be tracked
    assert html =~ "1 issue"
  end

  test "renders latest five diagnostics and a more count" do
    for n <- 1..6 do
      Muse.Diagnostics.emit(:warning, "diagnostic #{n}")
    end

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)

    assert html =~ "diagnostic 6"
    assert html =~ "diagnostic 2"
    refute html =~ "diagnostic 1"
    assert html =~ "+1 more backend diagnostics"
  end

  test "clears diagnostics drawer when clear broadcast arrives" do
    Muse.Diagnostics.emit(:critical, "critical before clear")
    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)
    assert html =~ "critical before clear"

    Muse.Diagnostics.clear()

    html = render(view)
    refute html =~ ~s(id="diagnostics-drawer")
    refute html =~ "critical before clear"
  end

  # -- Diagnostics collapse tests ----------------------------------------------

  test "collapse button closes diagnostics drawer" do
    Muse.Diagnostics.emit(:warning, "collapsible warning")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)
    assert html =~ ~s(id="diagnostics-drawer")

    view |> element(".diagnostics-collapse-btn") |> render_click()

    html = render(view)
    refute html =~ ~s(id="diagnostics-drawer")
    # Diagnostics status chip remains in header
    assert html =~ ~s(status-chip)
    assert html =~ "diagnostic"
  end

  test "clicking diagnostics chip reopens drawer" do
    Muse.Diagnostics.emit(:warning, "chip reopen test")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)
    assert html =~ ~s(id="diagnostics-drawer")

    view |> element(".diagnostics-collapse-btn") |> render_click()
    html = render(view)
    refute html =~ ~s(id="diagnostics-drawer")

    # Click the diagnostics status chip in the header
    view |> element(".status-chip-yellow") |> render_click()
    html = render(view)
    assert html =~ ~s(id="diagnostics-drawer")
    assert html =~ "chip reopen test"
  end

  # -- Self-healing diagnostic tests ------------------------------------------

  test "clicking Add to next Muse turn queues the diagnostic" do
    diagnostic = Muse.Diagnostics.emit(:warning, "queue me")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)

    view
    |> element(
      "#diagnostics-drawer [phx-click='queue_diagnostic_fix'][phx-value-diagnostic_id='#{diagnostic.id}']"
    )
    |> render_click()

    html = render(view)
    assert html =~ "Queued for next Muse turn"
  end

  test "queued diagnostic renders disabled state" do
    diagnostic = Muse.Diagnostics.emit(:error, "queued error")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)

    view
    |> element(
      "#diagnostics-drawer [phx-click='queue_diagnostic_fix'][phx-value-diagnostic_id='#{diagnostic.id}']"
    )
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

    open_diagnostics_drawer(view)
    html = render(view)

    assert html =~ "In progress"
    assert html =~ "disabled"
  end

  test "failed diagnostic shows Self-healing failed label" do
    diagnostic = Muse.Diagnostics.emit(:error, "failed error")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_failed(issue.id, "compile error")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)

    assert html =~ "Self-healing failed"
    assert html =~ "disabled"
  end

  test "fixed diagnostic shows Already fixed label" do
    diagnostic = Muse.Diagnostics.emit(:warning, "fixed warning")
    issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)
    Muse.SelfHealingQueue.mark_fixed(issue.id)

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)
    html = render(view)

    assert html =~ "Already fixed"
    assert html =~ "disabled"
  end

  test "self-healing summary shows when issues exist" do
    diagnostic = Muse.Diagnostics.emit(:warning, "summary test")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)

    view
    |> element(
      "#diagnostics-drawer [phx-click='queue_diagnostic_fix'][phx-value-diagnostic_id='#{diagnostic.id}']"
    )
    |> render_click()

    html = render(view)
    assert html =~ "Self-healing queue"
  end

  # -- Diagnostics copy and jump actions ---------------------------------------

  test "copy_diagnostic pushes clipboard event" do
    diagnostic = Muse.Diagnostics.emit(:warning, "copy this diagnostic")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)

    view
    |> element(
      "#diagnostics-drawer [phx-click='copy_diagnostic'][phx-value-diagnostic_id='#{diagnostic.id}']"
    )
    |> render_click()

    # Should succeed without error
    html = render(view)
    assert html =~ ~s(id="diagnostics-drawer")
  end

  test "jump_to_diagnostic_file warns when no metadata" do
    Muse.Diagnostics.emit(:warning, "no file meta")

    {:ok, view, _html} = live(build_conn(), "/")

    open_diagnostics_drawer(view)

    # Jump button should be disabled when no file metadata
    html = render(view)
    assert html =~ "diagnostic-action-disabled"
  end

  # -- Malformed ID robustness tests -------------------------------------------

  describe "malformed client IDs" do
    test "dismiss_toast with non-integer id does not crash" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "dismiss_toast",
          %{"id" => "abc"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      # Socket is still live, no crash
      assert socket.assigns != nil
    end

    test "dismiss_toast with empty string id does not crash" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "dismiss_toast",
          %{"id" => ""},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert socket.assigns != nil
    end

    test "dismiss_toast with partial integer id does not crash" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "dismiss_toast",
          %{"id" => "1x"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert socket.assigns != nil
    end

    test "toggle_event_detail with non-integer id does not crash" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "toggle_event_detail",
          %{"id" => "abc"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert socket.assigns.expanded_event_id == nil
    end

    test "toggle_log_detail with non-integer id does not crash" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "toggle_log_detail",
          %{"id" => "not-a-number"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert socket.assigns.expanded_log_id == nil
    end

    test "copy_event_json with non-integer id returns error toast" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "copy_event_json",
          %{"id" => "abc"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert Enum.any?(socket.assigns.toasts, &String.contains?(&1.message, "Invalid event ID"))
    end

    test "copy_log_json with non-integer id returns error toast" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "copy_log_json",
          %{"id" => ""},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert Enum.any?(socket.assigns.toasts, &String.contains?(&1.message, "Invalid log ID"))
    end

    test "queue_diagnostic_fix with non-integer id does not crash" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "queue_diagnostic_fix",
          %{"diagnostic_id" => "1x"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert socket.assigns != nil
    end

    test "copy_diagnostic with non-integer id returns error toast" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "copy_diagnostic",
          %{"diagnostic_id" => "abc"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert Enum.any?(
               socket.assigns.toasts,
               &String.contains?(&1.message, "Invalid diagnostic ID")
             )
    end

    test "jump_to_diagnostic_file with non-integer id returns error toast" do
      {:ok, view, _html} = live(build_conn(), "/")

      {:noreply, socket} =
        MuseWeb.HomeLive.handle_event(
          "jump_to_diagnostic_file",
          %{"diagnostic_id" => "not-an-id"},
          view.pid |> :sys.get_state() |> Map.get(:socket)
        )

      assert Enum.any?(
               socket.assigns.toasts,
               &String.contains?(&1.message, "Invalid diagnostic ID")
             )
    end
  end

  # -- Malformed diagnostic line metadata tests --------------------------------

  describe "malformed diagnostic line metadata" do
    test "diagnostic_line returns nil for non-integer line value" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{"line" => "abc"}}) ==
               nil
    end

    test "diagnostic_line_value handles empty string" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{"line" => ""}}) == nil
    end

    test "diagnostic_line_value handles partial integer like 1x" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{"line" => "1x"}}) ==
               nil
    end

    test "diagnostic_line_value handles integer line value" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{"line" => 42}}) == 42
    end

    test "diagnostic_line_value handles string integer line value" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{"line" => "42"}}) == 42
    end

    test "diagnostic_line_value handles missing line" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{}}) == nil
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{}) == nil
    end

    test "diagnostic_line_value handles atom-key line" do
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{line: 10}}) == 10
      assert MuseWeb.ConsoleComponents.diagnostic_line_value(%{metadata: %{line: "10"}}) == 10
    end
  end

  # -- Slash command tests -----------------------------------------------------

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

  test "/clear events clears the event log" do
    Muse.submit(:cli, "event to clear via command")

    {:ok, view, _html} = live(build_conn(), "/")
    html = render(view)
    assert html =~ "event to clear via command"

    view |> element("#command-form") |> render_submit(%{"text" => "/clear events"})

    html = render(view)
    refute html =~ "event to clear via command"
  end

  test "unknown slash command shows error" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/unknown-cmd"})

    html = render(view)
    assert html =~ "Unknown command"
  end

  test "/workspace shows workspace info" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/workspace"})

    html = render(view)
    assert html =~ "Workspace"
  end

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

  test "/reload-status shows watcher status" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/reload-status"})

    html = render(view)
    assert html =~ "File watcher"
  end

  test "/simulate event creates a simulated event" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/simulate event"})

    html = render(view)
    assert html =~ "Simulated event"
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

  test "/simulate event with extra args does not crash" do
    {:ok, view, _html} = live(build_conn(), "/")

    html =
      view
      |> element("#command-form")
      |> render_submit(%{"text" => "/simulate event extra"})

    assert html =~ "Simulated event created"
  end

  # -- Context panel tests -----------------------------------------------------

  test "context panel renders compact sections: agent, workspace, diagnostics, stats" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="context-sidebar)
    assert html =~ "Muse"
    assert html =~ "workspace"
    assert html =~ "diagnostics"
    assert html =~ "stats"
  end

  test "context panel does not render noisy action buttons by default" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ "Simulate backend error"
    refute html =~ "Retry connection"
    refute html =~ "Simulate event"
  end

  test "context panel shows diagnostics summary when diagnostics exist" do
    Muse.Diagnostics.emit(:warning, "diagnostic in context test")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(class="context-sidebar)
    assert html =~ "diagnostics"
    assert html =~ "1 issue"
  end

  test "chat panel still exists when diagnostics are active" do
    Muse.Diagnostics.emit(:warning, "chat with diagnostics")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(class="chat-panel")
    # Drawer not auto-opened
    refute html =~ ~s(id="diagnostics-drawer")
  end

  # -- JS hook attachment tests ------------------------------------------------

  test "app shell has KeyboardShortcuts hook" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="muse-shell")
    assert html =~ ~s(phx-hook="KeyboardShortcuts")
  end

  test "chat composer has CommandConsole hook and stable id" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="input-form")
    assert html =~ ~s(phx-hook="CommandConsole")
  end

  test "toast elements have ToastAutoDismiss hook" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/clear events"})
    html = render(view)
    assert html =~ ~s(phx-hook="ToastAutoDismiss")
  end

  test "no theme toggle in dark-only mode" do
    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ ~s(data-theme-toggle)
    refute html =~ "theme-toggle"
  end

  test "clipboard handler hook element exists" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(id="clipboard-handler")
    assert html =~ ~s(phx-hook="ClipboardHandler")
  end

  test "chat composer has data-slash-commands" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "data-slash-commands"
  end

  # -- Toast notification tests -----------------------------------------------

  test "toast container renders with aria-live" do
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "toast-container"
    assert html =~ ~s(aria-live="polite")
  end

  test "toast dismiss button works" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#command-form") |> render_submit(%{"text" => "/help"})
    html = render(view)
    assert html =~ "toast"

    # Dismiss the first toast found
    view |> element(".toast-dismiss") |> render_click()
    html = render(view)
    # Toasts are removed but container remains
    assert html =~ "toast-container"
  end

  # -- Diagnostics in header chip test -----------------------------------------

  test "diagnostics status chip appears in header when diagnostics exist" do
    Muse.Diagnostics.emit(:warning, "header chip test")

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(status-chip)
    assert html =~ "1 issue"
  end

  # -- Static assets -----------------------------------------------------------

  describe "static assets" do
    test "serves /assets/css/app.css with chat-first UI classes" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ "--bg: #1a1a1a"
      assert conn.resp_body =~ "--panel"
      assert conn.resp_body =~ ".app-shell"
      assert conn.resp_body =~ ".main-layout"
      assert conn.resp_body =~ ".chat-panel"
      assert conn.resp_body =~ ".chat-scroll"
      assert conn.resp_body =~ ".chat-composer"
      assert conn.resp_body =~ ".chat-message-user"
      assert conn.resp_body =~ ".chat-message-assistant"
      assert conn.resp_body =~ ".context-sidebar"
      assert conn.resp_body =~ ".context-rail"
      assert conn.resp_body =~ ".sidebar-expanded"
      assert conn.resp_body =~ ".sidebar-rail"
      assert conn.resp_body =~ ".sidebar-hidden"
      assert conn.resp_body =~ ".diagnostics-drawer"
      assert conn.resp_body =~ ".status-chip"
      assert conn.resp_body =~ ".diagnostics-popup"
      assert conn.resp_body =~ ".toast-container"
      assert conn.resp_body =~ ".panel"
      assert conn.resp_body =~ ".diagnostic-pill"
      assert conn.resp_body =~ ".diagnostic-notice.warning"
      assert conn.resp_body =~ ".diagnostic-notice.error"
      assert conn.resp_body =~ ".diagnostic-notice.critical"
      assert conn.resp_body =~ ".status-dot"
      assert conn.resp_body =~ ".toast"
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

  describe "Muse branding – logo, backgrounds, tokens" do
    test "header renders logo image without visible text label" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(class="muse-brand__logo")
      assert html =~ ~s(src="/images/muse-logo-header.png")
      assert html =~ ~s(alt="Muse CLI Coding Muse")
      # Visible label span removed — brand area has logo only
      refute html =~ ~s(class="brand-mark muse-brand__label")
    end

    test "chat-panel contains muse-bg muse-bg--main background layer" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(class="muse-bg muse-bg--main")
      # Background layer appears before chat-scroll (first child)
      bg_pos = first_index!(html, "muse-bg--main")
      scroll_pos = first_index!(html, "chat-scroll")
      assert bg_pos < scroll_pos, "muse-bg--main should appear before chat-scroll"
    end

    test "context-sidebar contains muse-bg muse-bg--sidebar background layer" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(class="muse-bg muse-bg--sidebar")
    end

    test "background layers are aria-hidden" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(class="muse-bg muse-bg--main" aria-hidden="true")
      assert html =~ ~s(class="muse-bg muse-bg--sidebar" aria-hidden="true")
    end

    test "CSS includes exact Muse violet design tokens" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ "--muse-violet-1:"
      assert conn.resp_body =~ "--muse-violet-2:"
      assert conn.resp_body =~ "--muse-violet-soft:"
      assert conn.resp_body =~ "--muse-violet-glow:"
      assert conn.resp_body =~ "--muse-violet-border:"
      assert conn.resp_body =~ "--muse-stripe-opacity-main:"
      assert conn.resp_body =~ "--muse-stripe-opacity-sidebar:"
      assert conn.resp_body =~ "--muse-stripe-blur:"
    end

    test "CSS includes new readability and status design tokens" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      # Readability tokens
      assert conn.resp_body =~ "--text-secondary:"
      assert conn.resp_body =~ "--text-placeholder:"
      assert conn.resp_body =~ "--text-disabled:"
      assert conn.resp_body =~ "--bg-elevated:"
      assert conn.resp_body =~ "--panel-soft:"
      assert conn.resp_body =~ "--panel-solid:"
      assert conn.resp_body =~ "--input-bg:"
      assert conn.resp_body =~ "--border-muted:"
      # Focus tokens
      assert conn.resp_body =~ "--focus-ring:"
      assert conn.resp_body =~ "--focus-outline:"
      # Status semantic tokens
      assert conn.resp_body =~ "--status-ok:"
      assert conn.resp_body =~ "--status-ok-bg:"
      assert conn.resp_body =~ "--status-warn:"
      assert conn.resp_body =~ "--status-warn-bg:"
      assert conn.resp_body =~ "--status-error:"
      assert conn.resp_body =~ "--status-error-bg:"
      assert conn.resp_body =~ "--status-inactive:"
      assert conn.resp_body =~ "--status-inactive-bg:"
      # Shadow tokens
      assert conn.resp_body =~ "--shadow-card:"
      assert conn.resp_body =~ "--shadow-accent:"
      # Placeholder rule
      assert conn.resp_body =~ "input::placeholder"
      # Focus ring styles
      assert conn.resp_body =~ "--focus-ring"
      # Status chip semantic styles
      assert conn.resp_body =~ ".status-chip-label"
      assert conn.resp_body =~ ".status-chip-value"
    end

    test "CSS includes brand and logo styling" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ ".muse-brand__logo"
    end

    test "CSS includes background layer classes with layering" do
      conn = build_conn() |> get("/assets/css/app.css")
      assert conn.status == 200
      assert conn.resp_body =~ ".muse-bg {"
      assert conn.resp_body =~ ".muse-bg--main"
      assert conn.resp_body =~ ".muse-bg--sidebar"
      # mix-blend-mode normal for improved readability
      assert conn.resp_body =~ "mix-blend-mode: normal"
      # z-index and pointer-events
      assert conn.resp_body =~ "z-index: 0"
      assert conn.resp_body =~ "pointer-events: none"
      # Readability overlay pseudo-elements on panels
      assert conn.resp_body =~ ".chat-panel::after"
      assert conn.resp_body =~ ".context-sidebar::after"
      # Content z-index above overlays
      assert conn.resp_body =~ ".chat-panel > :not(.muse-bg)"
      assert conn.resp_body =~ ".context-sidebar > :not(.muse-bg)"
      # Rail dim rule
      assert conn.resp_body =~ ".context-sidebar-rail .muse-bg--sidebar"
      # Responsive breakpoints
      assert conn.resp_body =~ "max-width: 900px"
      assert conn.resp_body =~ "max-width: 640px"
      # Responsive logo widths
      assert conn.resp_body =~ "width: 124px"
      assert conn.resp_body =~ "width: 104px"
      # Sidebar header spacing
      assert conn.resp_body =~ ".context-sidebar-header"
      # Background layers disabled (opacity: 0) — ready for future image
      assert conn.resp_body =~ "opacity: 0"
    end

    test "static assets serve branding images with 200" do
      for path <- [
            "/images/muse-logo-header.png",
            "/images/muse-bg-main.png",
            "/images/muse-bg-sidebar.png"
          ] do
        conn = build_conn() |> get(path)
        assert conn.status == 200, "Expected 200 for #{path}, got #{conn.status}"
      end
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

  # -- Patch proposal panel (PR17) -----------------------------------------------

  describe "patch proposal panel" do
    test "does not render patch proposal panel when no patch_proposal assign" do
      {:ok, _view, html} = live(build_conn(), "/")
      refute html =~ ~s(id="patch-proposal-panel")
    end

    test "renders patch proposal panel when patch_proposed event arrives" do
      {:ok, view, _html} = live(build_conn(), "/")

      event =
        Muse.Event.new(
          :conductor,
          :patch_proposed,
          %{
            patch_id: "patch_abc123",
            hash: "abc123def456",
            affected_files: ["lib/muse/example.ex"],
            diff: "--- a/foo.ex\n+++ b/foo.ex\n@@ -1 +1 @@\n-old\n+new"
          },
          visibility: :user
        )

      Muse.State.append(event)
      html = render(view)
      assert html =~ ~s(id="patch-proposal-panel")
      assert html =~ "patch_abc123"
    end

    test "clears patch proposal panel when patch_approved event arrives" do
      {:ok, view, _html} = live(build_conn(), "/")

      # First, show the panel via a patch_proposed event
      proposed_event =
        Muse.Event.new(
          :conductor,
          :patch_proposed,
          %{
            patch_id: "patch_abc123",
            hash: "abc123def456",
            affected_files: ["lib/muse/example.ex"],
            diff: "--- a/foo.ex"
          },
          visibility: :user
        )

      Muse.State.append(proposed_event)
      html = render(view)
      assert html =~ ~s(id="patch-proposal-panel")

      # Now approve — panel should clear
      approved_event =
        Muse.Event.new(:cli, :patch_approved, %{patch_id: "patch_abc123", status: "approved"},
          visibility: :user
        )

      Muse.State.append(approved_event)
      html = render(view)
      refute html =~ ~s(id="patch-proposal-panel")
    end

    test "clears patch proposal panel when patch_rejected event arrives" do
      {:ok, view, _html} = live(build_conn(), "/")

      proposed_event =
        Muse.Event.new(
          :conductor,
          :patch_proposed,
          %{
            patch_id: "patch_abc123",
            hash: "abc123def456",
            affected_files: ["lib/muse/example.ex"],
            diff: "--- a/foo.ex"
          },
          visibility: :user
        )

      Muse.State.append(proposed_event)
      html = render(view)
      assert html =~ ~s(id="patch-proposal-panel")

      rejected_event =
        Muse.Event.new(:cli, :patch_rejected, %{patch_id: "patch_abc123", status: "rejected"},
          visibility: :user
        )

      Muse.State.append(rejected_event)
      html = render(view)
      refute html =~ ~s(id="patch-proposal-panel")
    end

    test "dismiss button clears patch proposal panel" do
      {:ok, view, _html} = live(build_conn(), "/")

      proposed_event =
        Muse.Event.new(
          :conductor,
          :patch_proposed,
          %{
            patch_id: "patch_abc123",
            hash: "abc123def456",
            affected_files: ["lib/muse/example.ex"],
            diff: "--- a/foo.ex"
          },
          visibility: :user
        )

      Muse.State.append(proposed_event)
      html = render(view)
      assert html =~ ~s(id="patch-proposal-panel")

      view |> element(".patch-proposal-dismiss") |> render_click()
      html = render(view)
      refute html =~ ~s(id="patch-proposal-panel")
    end

    test "patch proposal panel shows /approve patch guidance" do
      {:ok, view, _html} = live(build_conn(), "/")

      proposed_event =
        Muse.Event.new(
          :conductor,
          :patch_proposed,
          %{
            patch_id: "patch_abc123",
            hash: "abc123def456",
            affected_files: ["lib/muse/example.ex"],
            diff: "--- a/foo.ex"
          },
          visibility: :user
        )

      Muse.State.append(proposed_event)
      html = render(view)
      assert html =~ "/approve patch"
      assert html =~ "apply" or html =~ "checkpoint"
    end
  end

  # -- Accessibility tests -----------------------------------------------------

  describe "accessibility markers" do
    test "chat panel has proper ARIA attributes" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(aria-label="Muse conversation")
      assert html =~ ~s(role="region")
    end

    test "chat scroll has live region for conversation history" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(role="log")
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-label="Conversation history")
    end

    test "chat composer has accessible label" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(aria-label="Message composer")
      # Textarea carries the accessible label directly (no visible label element)
      assert html =~ ~s(aria-label="Message to Muse")
      # No visible “Message to Muse” label element is rendered
      refute html =~ ~s(<label for="chat-input-textarea")
    end

    test "chat composer uses concise placeholder" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(placeholder="Ask Muse anything, or type /help...")
    end

    test "chat composer does not render standalone helper text" do
      {:ok, _view, html} = live(build_conn(), "/")
      # The old visible help span is removed; no chat-input-help element
      refute html =~ ~s(id="chat-input-help")
      refute html =~ ~s(Type a message or use /help to see available commands)
    end

    test "send button has descriptive aria-label" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(aria-label="Send message to Muse")
    end

    test "context panel has complementary role" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(role="complementary")
      assert html =~ ~s(aria-label="Workspace context and session status")
    end

    test "toast container has live region" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(class="toast-container")
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-label="Notifications")
    end

    test "prompt chips have accessible labels" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ ~s(aria-label="Use prompt: Explain this project")
      assert html =~ ~s(aria-label="Use prompt: Check recent backend errors")
      assert html =~ ~s(aria-label="Use prompt: Review changed files")
    end
  end

  # -- Command discoverability tests --------------------------------------------

  describe "command discoverability" do
    test "chat placeholder hints at /help" do
      {:ok, _view, html} = live(build_conn(), "/")
      # The textarea should have a concise placeholder
      assert html =~ "Ask Muse anything, or type /help"
    end

    test "chat input does not have separate help text span" do
      {:ok, _view, html} = live(build_conn(), "/")
      refute html =~ ~s(aria-describedby="chat-input-help")
      refute html =~ ~s(id="chat-input-help")
    end

    test "slash commands data attribute includes key commands" do
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ "data-slash-commands"
      # Key commands should be available for autocomplete
      assert html =~ "/help"
      assert html =~ "/muses"
      assert html =~ "/plan"
      assert html =~ "/session"
    end

    test "context panel shows session status with accessible labels" do
      {:ok, _view, html} = live(build_conn(), "/")
      # Session status card should have proper labels
      assert html =~ "session" or html =~ "Session"
    end

    test "status chips show connection status" do
      {:ok, _view, html} = live(build_conn(), "/")
      # Header status chips should be visible
      assert html =~ "backend"
      assert html =~ "workspace"
    end
  end
end
