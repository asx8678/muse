defmodule Muse.CLI.TuiTest do
  use ExUnit.Case, async: false

  alias ExRatatui.Layout.Rect
  alias Muse.CLI.Tui

  # ExRatatui mutates global terminal state, so async: false

  # -- Helpers -------------------------------------------------------------------

  defp mount_tui(overrides \\ []) do
    opts =
      Keyword.merge(
        [halt?: false, workspace: "/tmp/proj", web_url: "http://127.0.0.1:4000"],
        overrides
      )

    Tui.mount(opts)
  end

  defp frame(w \\ 120, h \\ 24), do: %ExRatatui.Frame{width: w, height: h}

  defp key(code, mods \\ []),
    do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: mods}

  defp widget_at(state, index) do
    Tui.render(state, frame()) |> Enum.at(index)
  end

  defp main_widget(state) do
    {widget, _rect} = widget_at(state, 2)
    widget
  end

  # -- mount/1 -------------------------------------------------------------------

  describe "mount/1" do
    test "returns initial state with defaults" do
      {:ok, state} = mount_tui()

      assert is_reference(state.input_state)
      assert state.halt? == false
      assert state.status == "Ready"
      assert state.focus == :input
      assert state.show_help? == false
      assert state.active_tab == "events"
      assert state.diagnostics == []
      assert state.agent_snapshot == :unavailable
      assert is_map(state.beam_stats)
    end

    test "stores workspace and web_url" do
      {:ok, state} = mount_tui(workspace: "/custom", web_url: "http://0.0.0.0:8080")
      assert state.workspace == "/custom"
      assert state.web_url == "http://0.0.0.0:8080"
    end

    test "scroll defaults to 0 for all tabs" do
      {:ok, state} = mount_tui()

      for tab <- ~w(events logs diagnostics agents stats settings) do
        assert state.scroll[tab] == 0
      end
    end
  end

  # -- render/2 — layout ---------------------------------------------------------

  describe "render/2 — layout" do
    test "returns 5 widget-rect pairs: header, tabs, main, input, footer" do
      {:ok, state} = mount_tui()
      widgets = Tui.render(state, frame())

      assert length(widgets) == 5

      for {w, r} <- widgets do
        assert %Rect{} = r
        assert is_map(w)
      end
    end

    test "with help shown returns 6 widget-rect pairs (adds popup)" do
      {:ok, state} = mount_tui()
      state = %{state | show_help?: true}
      widgets = Tui.render(state, frame())

      assert length(widgets) == 6
      {popup, _rect} = List.last(widgets)
      assert %ExRatatui.Widgets.Popup{} = popup
    end

    test "header shows workspace and web URL" do
      {:ok, state} = mount_tui(workspace: "/tmp/proj", web_url: "http://127.0.0.1:4000")
      {header, _} = widget_at(state, 0)
      assert header.text =~ "Muse TUI"
      assert header.text =~ "proj"
      assert header.text =~ "http://127.0.0.1:4000"
    end

    test "header shows web=off when web_url nil" do
      {:ok, state} = mount_tui(web_url: nil)
      {header, _} = widget_at(state, 0)
      assert header.text =~ "web=off"
    end

    test "tabs widget shows correct selected tab" do
      {:ok, state} = mount_tui()
      {tabs, _} = widget_at(state, 1)
      assert %ExRatatui.Widgets.Tabs{} = tabs
      assert tabs.selected == 0
      assert length(tabs.titles) == 6
    end

    test "tabs selected updates with active_tab" do
      {:ok, state} = mount_tui()
      {tabs, _} = widget_at(%{state | active_tab: "logs"}, 1)
      assert tabs.selected == 1
    end

    test "input widget shows focus indicator" do
      {:ok, state} = mount_tui()
      {input, _} = widget_at(%{state | focus: :input}, 3)
      assert input.block.title =~ "*"

      {input2, _} = widget_at(%{state | focus: :main}, 3)
      refute input2.block.title =~ "*"
    end

    test "footer shows mode indicator" do
      {:ok, state} = mount_tui()
      {footer, _} = widget_at(%{state | focus: :input}, 4)
      assert footer.text =~ "INPUT"

      {footer2, _} = widget_at(%{state | focus: :main}, 4)
      assert footer2.text =~ "MAIN"
    end

    test "narrow width still renders 5 widgets" do
      {:ok, state} = mount_tui()
      widgets = Tui.render(state, frame(80, 24))
      assert length(widgets) == 5
    end
  end

  # -- render/2 — tab content ----------------------------------------------------

  describe "render/2 — tab content" do
    test "events tab renders List" do
      {:ok, state} = mount_tui()
      assert %ExRatatui.Widgets.List{} = main_widget(state)
    end

    test "events tab with data renders items" do
      event = %Muse.Event{
        id: 1,
        timestamp: DateTime.utc_now(),
        source: :cli,
        type: :user_message,
        data: %{text: "hi"}
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | events: [event]}} end)
      assert length(main_widget(state).items) == 1
    end

    test "events with non-string data don't crash" do
      event = %Muse.Event{
        id: 1,
        timestamp: DateTime.utc_now(),
        source: :muse,
        type: :test,
        data: %{issues: [%{id: 42}]}
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | events: [event]}} end)
      assert length(main_widget(state).items) == 1
    end

    test "logs tab renders List" do
      {:ok, state} = mount_tui()
      assert %ExRatatui.Widgets.List{} = main_widget(%{state | active_tab: "logs"})
    end

    test "logs tab with data renders items" do
      entry = %Muse.LogEntry{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :error,
        source: :app,
        message: "boom"
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | logs: [entry]}} end)
      assert length(main_widget(%{state | active_tab: "logs"}).items) == 1
    end

    test "diagnostics tab renders List" do
      {:ok, state} = mount_tui()
      assert %ExRatatui.Widgets.List{} = main_widget(%{state | active_tab: "diagnostics"})
    end

    test "diagnostics with data renders items" do
      diag = %{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :error,
        message: "oops",
        metadata: %{source: :test}
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | diagnostics: [diag]}} end)
      assert length(main_widget(%{state | active_tab: "diagnostics"}).items) == 1
    end

    test "diagnostics source reads string-key metadata" do
      diag = %{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :error,
        message: "boom",
        metadata: %{"source" => "muse.web", "file" => "router.ex", "line" => 42}
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | diagnostics: [diag]}} end)
      main = main_widget(%{state | active_tab: "diagnostics"})
      assert length(main.items) == 1
    end

    test "diagnostics shows file:line from metadata" do
      diag = %{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :warning,
        message: "deprecated",
        metadata: %{source: :compiler, file: "lib/foo.ex", line: 10}
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | diagnostics: [diag]}} end)
      main = main_widget(%{state | active_tab: "diagnostics"})
      [item] = main.items
      # Last span should contain file:line
      last_span = List.last(item.spans)
      assert last_span.content =~ "lib/foo.ex"
      assert last_span.content =~ ":10"
    end

    test "agents tab renders Table" do
      {:ok, state} = mount_tui()
      assert %ExRatatui.Widgets.Table{} = main_widget(%{state | active_tab: "agents"})
    end

    test "agents tab with data renders rows" do
      agent = %{
        id: "a1",
        name: "Coder",
        status: :idle,
        kind: :coder,
        task: "thinking",
        progress: nil
      }

      {:ok, state} =
        mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | agent_snapshot: %{agents: [agent]}}} end)

      main = main_widget(%{state | active_tab: "agents"})
      assert length(main.rows) == 1
      assert main.header == ["Name", "Status", "Kind", "Task", "Progress"]
    end

    test "stats tab renders Paragraph with BEAM info" do
      {:ok, state} = mount_tui()
      main = main_widget(%{state | active_tab: "stats"})
      assert %ExRatatui.Widgets.Paragraph{} = main
      assert main.text =~ "BEAM"
    end

    test "settings tab renders Paragraph with key bindings" do
      {:ok, state} = mount_tui()
      main = main_widget(%{state | active_tab: "settings"})
      assert %ExRatatui.Widgets.Paragraph{} = main
      assert main.text =~ "Workspace"
      assert main.text =~ "Ctrl+E"
    end

    test "help popup renders with key reference" do
      {:ok, state} = mount_tui()
      state = %{state | show_help?: true}
      {popup, _} = List.last(Tui.render(state, frame()))
      assert %ExRatatui.Widgets.Popup{} = popup
      assert %ExRatatui.Widgets.Paragraph{} = popup.content
      assert popup.content.text =~ "Key Reference"
    end
  end

  # -- handle_event/2 — quit keys ------------------------------------------------

  describe "handle_event/2 — quit keys" do
    setup do
      {:ok, state} = mount_tui()
      {:ok, state: state}
    end

    test "Ctrl+C stops", %{state: state} do
      assert {:stop, _} = Tui.handle_event(key("c", ["ctrl"]), state)
    end

    test "Ctrl+Q stops", %{state: state} do
      assert {:stop, _} = Tui.handle_event(key("q", ["ctrl"]), state)
    end

    test "Esc quits when help not shown", %{state: state} do
      assert {:stop, _} = Tui.handle_event(key("esc"), state)
    end

    test "Esc closes help instead of quitting", %{state: state} do
      state = %{state | show_help?: true}
      {:noreply, new} = Tui.handle_event(key("esc"), state)
      refute new.show_help?
    end
  end

  # -- handle_event/2 — tab switching --------------------------------------------

  describe "handle_event/2 — tab switching" do
    setup do
      {:ok, state} = mount_tui()
      {:ok, state: state}
    end

    test "Tab cycles to next tab when focus is main", %{state: state} do
      state = %{state | focus: :main}
      {:noreply, new} = Tui.handle_event(key("tab"), state)
      assert new.active_tab == "logs"
    end

    test "Shift+Tab cycles to previous tab when focus is main", %{state: state} do
      state = %{state | focus: :main, active_tab: "logs"}
      {:noreply, new} = Tui.handle_event(key("back_tab"), state)
      assert new.active_tab == "events"
    end

    test "Tab switches focus to main when focus is input", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("tab"), state)
      assert new.focus == :main
    end

    test "Ctrl+E switches to events", %{state: state} do
      state = %{state | active_tab: "logs"}
      {:noreply, new} = Tui.handle_event(key("e", ["ctrl"]), state)
      assert new.active_tab == "events"
    end

    test "Ctrl+L switches to logs", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("l", ["ctrl"]), state)
      assert new.active_tab == "logs"
    end

    test "Ctrl+D switches to diagnostics", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("d", ["ctrl"]), state)
      assert new.active_tab == "diagnostics"
    end

    test "Ctrl+A switches to agents", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("a", ["ctrl"]), state)
      assert new.active_tab == "agents"
    end

    test "Ctrl+S switches to stats", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("s", ["ctrl"]), state)
      assert new.active_tab == "stats"
    end

    test "Ctrl+, switches to settings", %{state: state} do
      {:noreply, new} = Tui.handle_event(key(",", ["ctrl"]), state)
      assert new.active_tab == "settings"
    end

    test "tab cycling wraps around", %{state: state} do
      state = %{state | focus: :main, active_tab: "settings"}
      {:noreply, new} = Tui.handle_event(key("tab"), state)
      assert new.active_tab == "events"
    end

    test "backward tab cycling wraps around", %{state: state} do
      state = %{state | focus: :main, active_tab: "events"}
      {:noreply, new} = Tui.handle_event(key("back_tab"), state)
      assert new.active_tab == "settings"
    end
  end

  # -- handle_event/2 — scroll keys ---------------------------------------------

  describe "handle_event/2 — scroll" do
    setup do
      events =
        Enum.map(1..20, fn i ->
          %Muse.Event{
            id: i,
            timestamp: DateTime.utc_now(),
            source: :cli,
            type: :msg,
            data: %{text: "e#{i}"}
          }
        end)

      {:ok, state} = mount_tui()
      state = %{state | focus: :main, events: events}
      {:ok, state: state}
    end

    test "down scrolls by 1", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("down"), state)
      assert new.scroll["events"] == 1
    end

    test "up scrolls back by 1", %{state: state} do
      state = %{state | scroll: %{state.scroll | "events" => 3}}
      {:noreply, new} = Tui.handle_event(key("up"), state)
      assert new.scroll["events"] == 2
    end

    test "j scrolls down by 1", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("j"), state)
      assert new.scroll["events"] == 1
    end

    test "k scrolls up by 1", %{state: state} do
      state = %{state | scroll: %{state.scroll | "events" => 3}}
      {:noreply, new} = Tui.handle_event(key("k"), state)
      assert new.scroll["events"] == 2
    end

    test "page_down scrolls by 10", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("page_down"), state)
      assert new.scroll["events"] == 10
    end

    test "page_up scrolls back by 10", %{state: state} do
      state = %{state | scroll: %{state.scroll | "events" => 15}}
      {:noreply, new} = Tui.handle_event(key("page_up"), state)
      assert new.scroll["events"] == 5
    end

    test "home scrolls to 0", %{state: state} do
      state = %{state | scroll: %{state.scroll | "events" => 15}}
      {:noreply, new} = Tui.handle_event(key("home"), state)
      assert new.scroll["events"] == 0
    end

    test "end scrolls to max", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("end"), state)
      assert new.scroll["events"] >= 0
    end

    test "scroll doesn't go below 0", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("up"), state)
      assert new.scroll["events"] == 0
    end

    test "scroll keys don't work when focus is input", %{state: state} do
      state = %{state | focus: :input}
      {:noreply, new} = Tui.handle_event(key("down"), state)
      assert new.scroll["events"] == 0
    end

    test "i key returns focus to input", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("i"), state)
      assert new.focus == :input
    end
  end

  # -- handle_event/2 — help toggle ----------------------------------------------

  describe "handle_event/2 — help" do
    setup do
      {:ok, state} = mount_tui()
      {:ok, state: state}
    end

    test "? toggles help when focus is main", %{state: state} do
      state = %{state | focus: :main}
      {:noreply, new} = Tui.handle_event(key("?"), state)
      assert new.show_help? == true

      {:noreply, new2} = Tui.handle_event(key("?"), new)
      assert new2.show_help? == false
    end

    test "? types into input when focus is input", %{state: state} do
      {:noreply, new} = Tui.handle_event(key("?"), state)
      refute new.show_help?
    end
  end

  # -- handle_event/2 — input submit ---------------------------------------------

  describe "handle_event/2 — input submit" do
    test "Enter with plain text submits" do
      start_supervised!({Muse.State, []})
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "hello")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.status =~ "Sent: hello"
      assert ExRatatui.text_input_get_value(new.input_state) == ""
    end

    test "Enter with empty input does nothing" do
      {:ok, state} = mount_tui()
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.status == "Ready"
    end

    test "/help dispatches through CommandDispatcher" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/help")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.status =~ "Available commands"
    end

    test "/events dispatches through CommandDispatcher" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/events")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.status =~ "event(s) recorded"
    end

    test "/search events hello sets event_search and switches tab" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/search events hello")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.event_search == "hello"
      assert new.active_tab == "events"
    end

    test "/filter logs errors sets log_filter" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/filter logs errors")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.log_filter == "errors"
    end

    test "/stats dispatches through CommandDispatcher" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/stats")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.status =~ "BEAM Stats"
    end

    test "unknown command dispatches through CommandDispatcher" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/bogus")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.status =~ "Unknown command"
    end

    test "printable key forwards to text input when focus is input" do
      {:ok, state} = mount_tui()
      {:noreply, _} = Tui.handle_event(key("a"), state)
      assert ExRatatui.text_input_get_value(state.input_state) == "a"
    end
  end

  # -- handle_event/2 — Ctrl+R reload -------------------------------------------

  describe "handle_event/2 — Ctrl+R reload" do
    test "triggers reload and updates status" do
      {:ok, state} = mount_tui()
      {:noreply, new} = Tui.handle_event(key("r", ["ctrl"]), state)
      assert is_binary(new.status)
    end
  end

  # -- handle_info/2 — PubSub ---------------------------------------------------

  describe "handle_info/2 — PubSub" do
    setup do
      {:ok, state} = mount_tui()
      {:ok, state: state}
    end

    test "muse_event updates events", %{state: state} do
      {:noreply, new} = Tui.handle_info({:muse_event, nil}, state)
      assert %Tui{} = new
    end

    test "muse_log updates logs", %{state: state} do
      {:noreply, new} = Tui.handle_info({:muse_log, nil}, state)
      assert %Tui{} = new
    end

    test "muse_logs_cleared empties logs", %{state: state} do
      {:noreply, new} = Tui.handle_info({:muse_logs_cleared}, state)
      assert new.logs == []
    end

    test "muse_events_cleared empties events", %{state: state} do
      {:noreply, new} = Tui.handle_info({:muse_events_cleared}, state)
      assert new.events == []
    end

    test "muse_diagnostic updates diagnostics", %{state: state} do
      {:noreply, new} = Tui.handle_info({:muse_diagnostic, nil}, state)
      assert %Tui{} = new
    end

    test "muse_diagnostics_cleared empties diagnostics", %{state: state} do
      {:noreply, new} = Tui.handle_info({:muse_diagnostics_cleared}, state)
      assert new.diagnostics == []
    end

    test "muse_agent_registry_updated updates agent_snapshot", %{state: state} do
      snapshot = %{agents: [%{id: "a1", name: "Coder"}]}
      {:noreply, new} = Tui.handle_info({:muse_agent_registry_updated, snapshot}, state)
      assert new.agent_snapshot == snapshot
    end

    test "muse_agent_runtime_updated updates agent_runtime", %{state: state} do
      snapshot = %{status: :connected, endpoint: "ws://localhost:4000"}
      {:noreply, new} = Tui.handle_info({:muse_agent_runtime_updated, snapshot}, state)
      assert new.agent_runtime == snapshot
    end

    test "unknown message is ignored", %{state: state} do
      {:noreply, new} = Tui.handle_info(:unknown, state)
      assert new == state
    end
  end

  # -- terminate/2 ---------------------------------------------------------------

  describe "terminate/2" do
    test "does not halt when halt? is false" do
      {:ok, state} = mount_tui(halt?: false)
      assert :ok == Tui.terminate(:shutdown, state)
    end
  end

  # -- child_spec/1 --------------------------------------------------------------

  describe "child_spec/1" do
    test "is a worker" do
      spec = Tui.child_spec([])
      assert spec.id == Tui
      assert spec.type == :worker
    end
  end

  # -- Dispatcher switch_tab effect -----------------------------------------------

  describe "dispatcher switch_tab effect" do
    test "switches active_tab via /open logs" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/open logs")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.active_tab == "logs"
    end

    test "switches to agents via /open agents" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/open agents")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.active_tab == "agents"
    end

    test "/open logs also sets focus to main" do
      {:ok, state} = mount_tui()
      ExRatatui.text_input_set_value(state.input_state, "/open logs")
      {:noreply, new} = Tui.handle_event(key("enter"), state)
      assert new.focus == :main
    end
  end

  # -- Event search/filter rendering ----------------------------------------------

  describe "render/2 — event search/filter" do
    test "event search filters items" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "hello"}
        },
        %Muse.Event{
          id: 2,
          timestamp: DateTime.utc_now(),
          source: :web,
          type: :user_message,
          data: %{text: "world"}
        }
      ]

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | events: events}} end)
      state = %{state | event_search: "hello"}
      main = main_widget(state)
      assert length(main.items) == 1
    end

    test "event filter errors shows only errorish events" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :muse,
          type: :error,
          data: %{text: "boom"}
        },
        %Muse.Event{
          id: 2,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "ok"}
        }
      ]

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | events: events}} end)
      state = %{state | event_filter: "errors"}
      main = main_widget(state)
      assert length(main.items) == 1
    end

    test "event filter all shows everything" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :muse,
          type: :error,
          data: %{text: "boom"}
        },
        %Muse.Event{
          id: 2,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "ok"}
        }
      ]

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | events: events}} end)
      main = main_widget(state)
      assert length(main.items) == 2
    end

    test "events title includes filter when not all" do
      {:ok, state} = mount_tui()
      state = %{state | event_filter: "errors"}
      main = main_widget(state)
      assert main.block.title =~ "errors"
    end

    test "events title includes search term" do
      {:ok, state} = mount_tui()
      state = %{state | event_search: "hello"}
      main = main_widget(state)
      assert main.block.title =~ "hello"
    end
  end

  # -- Log search/filter rendering -------------------------------------------------

  describe "render/2 — log search/filter" do
    test "log search filters items" do
      logs = [
        %Muse.LogEntry{
          id: 1,
          timestamp: DateTime.utc_now(),
          level: :info,
          source: :app,
          message: "started"
        },
        %Muse.LogEntry{
          id: 2,
          timestamp: DateTime.utc_now(),
          level: :error,
          source: :app,
          message: "boom"
        }
      ]

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | logs: logs}} end)
      state = %{state | active_tab: "logs", log_search: "boom"}
      main = main_widget(state)
      assert length(main.items) == 1
    end

    test "log filter errors shows only error entries" do
      logs = [
        %Muse.LogEntry{
          id: 1,
          timestamp: DateTime.utc_now(),
          level: :info,
          source: :app,
          message: "ok"
        },
        %Muse.LogEntry{
          id: 2,
          timestamp: DateTime.utc_now(),
          level: :error,
          source: :app,
          message: "boom"
        }
      ]

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | logs: logs}} end)
      state = %{state | active_tab: "logs", log_filter: "errors"}
      main = main_widget(state)
      assert length(main.items) == 1
    end

    test "logs title includes filter when not all" do
      {:ok, state} = mount_tui()
      state = %{state | active_tab: "logs", log_filter: "errors"}
      main = main_widget(state)
      assert main.block.title =~ "errors"
    end

    test "logs title includes search term" do
      {:ok, state} = mount_tui()
      state = %{state | active_tab: "logs", log_search: "crash"}
      main = main_widget(state)
      assert main.block.title =~ "crash"
    end

    test "log search matches metadata" do
      logs = [
        %Muse.LogEntry{
          id: 1,
          timestamp: DateTime.utc_now(),
          level: :info,
          source: :app,
          message: "request done",
          metadata: %{request_id: "abc123"}
        },
        %Muse.LogEntry{
          id: 2,
          timestamp: DateTime.utc_now(),
          level: :info,
          source: :app,
          message: "other thing",
          metadata: %{}
        }
      ]

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | logs: logs}} end)
      state = %{state | active_tab: "logs", log_search: "abc123"}
      main = main_widget(state)
      assert length(main.items) == 1
    end

    test "log search is robust when metadata absent" do
      log_no_meta = %{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :info,
        source: :app,
        message: "hello"
      }

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | logs: [log_no_meta]}} end)
      state = %{state | active_tab: "logs", log_search: "hello"}
      main = main_widget(state)
      assert length(main.items) == 1
    end
  end

  # -- Scroll rendering ------------------------------------------------------------

  describe "render/2 — scroll offset" do
    test "events scroll offset skips items" do
      events =
        Enum.map(1..10, fn i ->
          %Muse.Event{
            id: i,
            timestamp: DateTime.utc_now(),
            source: :cli,
            type: :msg,
            data: %{text: "e#{i}"}
          }
        end)

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | events: events}} end)
      state = %{state | scroll: %{"events" => 5}}
      main = main_widget(state)
      # 10 events reversed => newest first, drop 5 => 5 items
      assert length(main.items) == 5
    end

    test "logs scroll offset skips items" do
      logs =
        Enum.map(1..10, fn i ->
          %Muse.LogEntry{
            id: i,
            timestamp: DateTime.utc_now(),
            level: :info,
            source: :app,
            message: "log#{i}"
          }
        end)

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | logs: logs}} end)
      state = %{state | active_tab: "logs", scroll: %{"logs" => 5}}
      main = main_widget(state)
      assert length(main.items) == 5
    end

    test "diagnostics scroll offset skips items" do
      diags =
        Enum.map(1..10, fn i ->
          %{
            id: i,
            timestamp: DateTime.utc_now(),
            level: :error,
            message: "d#{i}",
            metadata: %{source: :test}
          }
        end)

      {:ok, state} = mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | diagnostics: diags}} end)
      state = %{state | active_tab: "diagnostics", scroll: %{"diagnostics" => 5}}
      main = main_widget(state)
      assert length(main.items) == 5
    end

    test "agents scroll offset skips rows" do
      agents =
        Enum.map(1..10, fn i ->
          %{id: "a#{i}", name: "Agent#{i}", status: :idle, kind: :coder, task: nil, progress: nil}
        end)

      {:ok, state} =
        mount_tui() |> then(fn {:ok, s} -> {:ok, %{s | agent_snapshot: %{agents: agents}}} end)

      state = %{state | active_tab: "agents", scroll: %{"agents" => 5}}
      main = main_widget(state)
      assert length(main.rows) == 5
    end

    test "stats paragraph scroll reflects state" do
      {:ok, state} = mount_tui()
      state = %{state | active_tab: "stats", scroll: %{"stats" => 3}}
      main = main_widget(state)
      assert main.scroll == {3, 0}
    end

    test "settings paragraph scroll reflects state" do
      {:ok, state} = mount_tui()
      state = %{state | active_tab: "settings", scroll: %{"settings" => 5}}
      main = main_widget(state)
      assert main.scroll == {5, 0}
    end
  end
end
