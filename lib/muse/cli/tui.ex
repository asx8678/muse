defmodule Muse.CLI.Tui do
  @moduledoc """
  Full-screen ExRatatui TUI for `--tui` mode.

  Layout: header | tabs | main content | input | footer.
  Optional help popup overlay when `show_help?` is true.

  Six tabs: Events, Logs, Diagnostics, Muses, Stats, Settings.
  Focus model: :input (text input receives keys) or :main (scroll/tab keys).
  Input dispatches through Muse.CommandDispatcher for slash-commands.
  """

  use ExRatatui.App

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, List, Paragraph, Popup, Table, Tabs, TextInput}

  @tab_labels ["Events", "Logs", "Diagnostics", "Muses", "Stats", "Settings"]
  @tab_keys ~w(events logs diagnostics agents stats settings)
  @tab_index Enum.zip(@tab_keys, 0..5) |> Map.new()
  @scroll_page 10

  # -- State --------------------------------------------------------------------

  defstruct input_state: nil,
            logs: [],
            events: [],
            diagnostics: [],
            agent_snapshot: :unavailable,
            agent_runtime: nil,
            beam_stats: %{},
            session_status: nil,
            status: "Ready",
            halt?: true,
            workspace: nil,
            web_url: nil,
            active_tab: "events",
            event_search: "",
            event_filter: "all",
            log_search: "",
            log_filter: "all",
            focus: :input,
            show_help?: false,
            scroll: %{
              "events" => 0,
              "logs" => 0,
              "diagnostics" => 0,
              "agents" => 0,
              "stats" => 0,
              "settings" => 0
            }

  @type t :: %__MODULE__{
          input_state: reference(),
          logs: [map()],
          events: [map()],
          diagnostics: [map()],
          agent_snapshot: :unavailable | %{agents: [map()]},
          agent_runtime: map() | nil,
          beam_stats: map(),
          session_status: map() | nil,
          status: String.t(),
          halt?: boolean(),
          workspace: String.t() | nil,
          web_url: String.t() | nil,
          active_tab: String.t(),
          event_search: String.t(),
          event_filter: String.t(),
          log_search: String.t(),
          log_filter: String.t(),
          focus: :input | :main,
          show_help?: boolean(),
          scroll: %{String.t() => non_neg_integer()}
        }

  # -- ExRatatui.App callbacks --------------------------------------------------

  @impl true
  def mount(opts) do
    input_state = ExRatatui.text_input_new()
    halt? = Keyword.get(opts, :halt?, true)
    workspace = Keyword.get(opts, :workspace)
    web_url = Keyword.get(opts, :web_url)

    safe_subscribe(Muse.State)
    safe_subscribe(Muse.LogBuffer)
    Muse.Backend.safe_subscribe_diagnostics()
    Muse.Backend.safe_subscribe_agent_registry()
    Muse.Backend.safe_subscribe_agent_runtime()

    logs = safe_list(Muse.LogBuffer)
    events = safe_events(Muse.State)
    diagnostics = Muse.Backend.safe_diagnostics()
    agent_snapshot = Muse.Backend.safe_agent_snapshot()
    agent_runtime = Muse.Backend.safe_agent_runtime_snapshot()
    beam_stats = safe_beam_stats()
    session_status = safe_session_status()

    {:ok,
     %__MODULE__{
       input_state: input_state,
       logs: logs,
       events: events,
       diagnostics: diagnostics,
       agent_snapshot: agent_snapshot,
       agent_runtime: agent_runtime,
       beam_stats: beam_stats,
       session_status: session_status,
       halt?: halt?,
       workspace: workspace,
       web_url: web_url
     }}
  end

  @impl true
  def render(state, frame) do
    full = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_rect, tabs_rect, main_rect, input_rect, footer_rect] =
      Layout.split(full, :vertical, [
        {:length, 3},
        {:length, 3},
        {:min, 0},
        {:length, 3},
        {:length, 1}
      ])

    widgets =
      [
        {render_header(state, frame.width), header_rect},
        {render_tabs(state), tabs_rect},
        render_active_tab(state, main_rect),
        {render_input(state), input_rect},
        {render_footer(state), footer_rect}
      ]

    if state.show_help? do
      widgets ++ [{render_help_popup(), full}]
    else
      widgets
    end
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{kind: "release"}, %__MODULE__{} = state),
    do: {:noreply, state}

  def handle_event(%ExRatatui.Event.Key{code: "enter"}, %__MODULE__{focus: :input} = state) do
    value = ExRatatui.text_input_get_value(state.input_state) |> String.trim()
    handle_input(value, state)
  end

  # Ctrl+C / Ctrl+q — always quit
  def handle_event(%ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  def handle_event(%ExRatatui.Event.Key{code: "q", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  # Esc — close help if shown, else switch focus or quit
  def handle_event(%ExRatatui.Event.Key{code: "esc"}, %__MODULE__{show_help?: true} = state),
    do: {:noreply, %{state | show_help?: false}}

  def handle_event(%ExRatatui.Event.Key{code: "esc"}, %__MODULE__{focus: :input} = state),
    do: {:noreply, %{state | focus: :main}}

  def handle_event(%ExRatatui.Event.Key{code: "esc"}, %__MODULE__{focus: :main} = state),
    do: {:stop, state}

  # Tab / Shift+Tab — always cycle tabs (visible change on every press)
  def handle_event(%ExRatatui.Event.Key{code: "tab"}, state) do
    {:noreply, %{state | active_tab: next_tab(state.active_tab, 1)}}
  end

  def handle_event(%ExRatatui.Event.Key{code: "back_tab"}, state) do
    {:noreply, %{state | active_tab: next_tab(state.active_tab, -1)}}
  end

  # Ctrl+letter tab shortcuts (always work regardless of focus)
  def handle_event(%ExRatatui.Event.Key{code: "e", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | active_tab: "events"}}

  def handle_event(%ExRatatui.Event.Key{code: "l", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | active_tab: "logs"}}

  def handle_event(%ExRatatui.Event.Key{code: "d", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | active_tab: "diagnostics"}}

  def handle_event(%ExRatatui.Event.Key{code: "a", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | active_tab: "agents"}}

  def handle_event(%ExRatatui.Event.Key{code: "s", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | active_tab: "stats"}}

  def handle_event(%ExRatatui.Event.Key{code: ",", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | active_tab: "settings"}}

  # Ctrl+R — reload
  def handle_event(%ExRatatui.Event.Key{code: "r", modifiers: ["ctrl"]}, state) do
    {_status, output, effects} =
      Muse.CommandDispatcher.dispatch(:reload, nil, build_tui_context(state))

    {:noreply, apply_effects(%{state | status: output}, effects)}
  end

  # ? — toggle help (only when not typing)
  def handle_event(%ExRatatui.Event.Key{code: "?", kind: "press"}, %__MODULE__{} = state) do
    if state.focus == :input do
      ExRatatui.text_input_handle_key(state.input_state, "?")
      {:noreply, state}
    else
      {:noreply, %{state | show_help?: not state.show_help?}}
    end
  end

  # Scroll keys — only when focus is main
  def handle_event(%ExRatatui.Event.Key{code: "up"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, -1)}

  def handle_event(%ExRatatui.Event.Key{code: "down"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, 1)}

  def handle_event(%ExRatatui.Event.Key{code: "page_up"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, -@scroll_page)}

  def handle_event(%ExRatatui.Event.Key{code: "page_down"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, @scroll_page)}

  def handle_event(%ExRatatui.Event.Key{code: "home"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_to(state, 0)}

  def handle_event(%ExRatatui.Event.Key{code: "end"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_to(state, :max)}

  # j/k scroll in main focus
  def handle_event(%ExRatatui.Event.Key{code: "j"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, 1)}

  def handle_event(%ExRatatui.Event.Key{code: "k"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, -1)}

  # i — return focus to input
  def handle_event(%ExRatatui.Event.Key{code: "i"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, %{state | focus: :input}}

  # / — focus input with slash pre-typed (quick command entry)
  def handle_event(%ExRatatui.Event.Key{code: "/"}, %__MODULE__{focus: :main} = state) do
    ExRatatui.text_input_set_value(state.input_state, "/")
    {:noreply, %{state | focus: :input}}
  end

  # Printable/editable keys — forward to text input when focus is input
  def handle_event(%ExRatatui.Event.Key{} = key, %__MODULE__{focus: :input} = state) do
    if editable_key?(key) do
      ExRatatui.text_input_handle_key(state.input_state, key.code)
    end

    {:noreply, state}
  end

  # Mouse events — click to focus, click tab row to select, wheel to scroll.
  # NOTE: ExRatatui's NIF does not currently enable terminal mouse capture,
  # so these handlers won't fire until that is added upstream. They are
  # included for forward-compatibility and testability.
  def handle_event(
        %ExRatatui.Event.Mouse{kind: "down", button: "left", x: x, y: y},
        state
      ) do
    # Layout: header(3) | tabs(3) | main(?) | input(3) | footer(1)
    # Approximate row positions; tab row = rows 3–5, input = rows (height-4)–(height-2)
    cond do
      # Tab row click (rows 3–5 in standard layout)
      y >= 3 and y < 6 ->
        tab = tab_from_x(x, state)
        {:noreply, %{state | active_tab: tab}}

      # Input area click (last 4 rows minus footer)
      true ->
        {:noreply, %{state | focus: :input}}
    end
  end

  def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_up"}, %__MODULE__{focus: :main} = state),
    do: {:noreply, scroll_by(state, -3)}

  def handle_event(
        %ExRatatui.Event.Mouse{kind: "scroll_down"},
        %__MODULE__{focus: :main} = state
      ),
      do: {:noreply, scroll_by(state, 3)}

  # Catch-all
  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info({:muse_event, _event}, %__MODULE__{} = state) do
    {:noreply, %{state | events: safe_events(Muse.State)}}
  end

  def handle_info({:muse_log, _entry}, %__MODULE__{} = state) do
    {:noreply, %{state | logs: safe_list(Muse.LogBuffer)}}
  end

  def handle_info({:muse_logs_cleared}, %__MODULE__{} = state),
    do: {:noreply, %{state | logs: []}}

  def handle_info({:muse_events_cleared}, %__MODULE__{} = state),
    do: {:noreply, %{state | events: []}}

  def handle_info({:muse_diagnostic, _diag}, %__MODULE__{} = state) do
    {:noreply, %{state | diagnostics: Muse.Backend.safe_diagnostics()}}
  end

  def handle_info({:muse_diagnostics_cleared}, %__MODULE__{} = state),
    do: {:noreply, %{state | diagnostics: []}}

  def handle_info({:muse_agent_registry_updated, snapshot}, %__MODULE__{} = state),
    do: {:noreply, %{state | agent_snapshot: snapshot}}

  def handle_info({:muse_agent_runtime_updated, snapshot}, %__MODULE__{} = state),
    do: {:noreply, %{state | agent_runtime: snapshot}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{halt?: true}), do: System.halt(0)
  def terminate(_reason, %__MODULE__{}), do: :ok

  # -- Input dispatch -----------------------------------------------------------

  defp handle_input("", state), do: {:noreply, state}

  defp handle_input(text, %__MODULE__{} = state) do
    ExRatatui.text_input_set_value(state.input_state, "")
    dispatch(Muse.Commands.parse(text), state)
  end

  defp dispatch(:empty, state), do: {:noreply, state}

  defp dispatch({:message, msg}, state) do
    Muse.submit(:tui, msg)
    {:noreply, %{state | status: "Sent: #{msg}"}}
  end

  defp dispatch({:unknown, cmd}, state),
    do: {:noreply, %{state | status: "Unknown command: #{cmd}"}}

  defp dispatch({:command, action, args}, state),
    do: dispatch_command(action, args, state)

  defp dispatch({:command, action}, state),
    do: dispatch_command(action, nil, state)

  defp dispatch_command(action, args, state) do
    context = build_tui_context(state)
    {_status, output, effects} = Muse.CommandDispatcher.dispatch(action, args, context)
    {:noreply, apply_effects(%{state | status: output}, effects)}
  end

  # -- Context + effects ---------------------------------------------------------

  defp build_tui_context(state) do
    %{
      events: state.events,
      logs: state.logs,
      diagnostics: state.diagnostics,
      agent_snapshot: state.agent_snapshot,
      workspace: state.workspace,
      reload_status: Muse.Backend.safe_reload_status(),
      agent_runtime: state.agent_runtime,
      beam_stats: state.beam_stats,
      event_filter: state.event_filter,
      event_search: state.event_search,
      log_filter: state.log_filter,
      log_search: state.log_search,
      session_id: "default",
      source: :tui,
      session_status: state.session_status
    }
  end

  defp apply_effects(state, effects) do
    Enum.reduce(effects, state, &apply_effect(&2, &1))
  end

  defp apply_effect(state, {:switch_tab, tab}) when tab in @tab_keys,
    do: %{state | active_tab: tab, focus: :main}

  defp apply_effect(state, {:switch_tab, tab}),
    do: %{state | status: "Unsupported TUI tab: #{tab}"}

  defp apply_effect(state, {:clear_input}), do: state
  defp apply_effect(state, {:toast, _type, message}), do: %{state | status: message}

  defp apply_effect(state, {:set_event_search, q}),
    do: %{state | event_search: q, scroll: Map.put(state.scroll, "events", 0)}

  defp apply_effect(state, {:set_event_filter, f}),
    do: %{state | event_filter: f, scroll: Map.put(state.scroll, "events", 0)}

  defp apply_effect(state, {:set_log_search, q}),
    do: %{state | log_search: q, scroll: Map.put(state.scroll, "logs", 0)}

  defp apply_effect(state, {:set_log_filter, f}),
    do: %{state | log_filter: f, scroll: Map.put(state.scroll, "logs", 0)}

  defp apply_effect(state, {:refresh, :events}),
    do: %{state | events: safe_events(Muse.State)}

  defp apply_effect(state, {:refresh, :logs}),
    do: %{state | logs: safe_list(Muse.LogBuffer)}

  defp apply_effect(state, {:refresh, :diagnostics}),
    do: %{state | diagnostics: Muse.Backend.safe_diagnostics()}

  defp apply_effect(state, {:refresh, :runtime}),
    do: %{state | agent_runtime: Muse.Backend.safe_agent_runtime_snapshot()}

  defp apply_effect(state, {:refresh, :stats}),
    do: %{state | beam_stats: safe_beam_stats()}

  defp apply_effect(state, {:refresh, :agents}),
    do: %{state | agent_snapshot: Muse.Backend.safe_agent_snapshot()}

  defp apply_effect(state, {:refresh, :session}),
    do: %{state | session_status: safe_session_status()}

  defp apply_effect(state, {:refresh, _}), do: state
  defp apply_effect(state, {:copy_to_clipboard, _text, _label}), do: state

  # -- Scroll helpers ------------------------------------------------------------

  defp scroll_by(state, delta) do
    tab = state.active_tab
    max = content_count(state, tab)
    current = Map.get(state.scroll, tab, 0)
    new = (current + delta) |> max(0) |> min(max(0, max - 1))
    %{state | scroll: Map.put(state.scroll, tab, new)}
  end

  defp scroll_to(state, 0) do
    %{state | scroll: Map.put(state.scroll, state.active_tab, 0)}
  end

  defp scroll_to(state, :max) do
    max = content_count(state, state.active_tab)
    %{state | scroll: Map.put(state.scroll, state.active_tab, max(0, max - 1))}
  end

  defp content_count(state, "events"),
    do: state.events |> filter_events(state.event_filter, state.event_search) |> length()

  defp content_count(state, "logs"),
    do: state.logs |> filter_logs(state.log_filter, state.log_search) |> length()

  defp content_count(state, "diagnostics"), do: length(state.diagnostics)

  defp content_count(state, "agents") do
    case state.agent_snapshot do
      %{agents: agents} -> length(agents)
      _ -> 0
    end
  end

  defp content_count(state, "stats"), do: stats_line_count(state)
  defp content_count(state, "settings"), do: settings_line_count(state)
  defp content_count(_state, _tab), do: 0

  # -- Tab cycling ---------------------------------------------------------------

  defp next_tab(current, delta) do
    idx = Map.get(@tab_index, current, 0)
    new_idx = rem(idx + delta + length(@tab_keys), length(@tab_keys))
    Enum.at(@tab_keys, new_idx)
  end

  # -- Render: header ------------------------------------------------------------

  defp render_header(%__MODULE__{workspace: ws, web_url: web_url}, width) do
    ws_short = ws && Path.basename(ws)

    web_str =
      case web_url do
        nil -> "web=off"
        url -> url
      end

    text =
      ["  Muse TUI"]
      |> maybe_add("  ws=#{ws_short}", ws_short)
      |> maybe_add("  #{web_str}", true)
      |> maybe_add("  #{width}w", true)
      |> Enum.join()

    %Paragraph{
      text: text,
      style: %Style{fg: :cyan, modifiers: [:bold], bg: :dark_gray},
      block: %Block{
        title: " Muse ",
        borders: [:bottom],
        border_style: %Style{fg: :cyan}
      }
    }
  end

  # -- Render: tabs --------------------------------------------------------------

  defp render_tabs(%__MODULE__{active_tab: active_tab}) do
    selected = Map.get(@tab_index, active_tab, 0)

    %Tabs{
      titles: @tab_labels,
      selected: selected,
      style: %Style{fg: :white},
      highlight_style: %Style{fg: :cyan, modifiers: [:bold, :underlined]},
      block: %Block{
        title: " Tabs ",
        borders: [:bottom],
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  # -- Render: active tab content ------------------------------------------------

  defp render_active_tab(state, rect) do
    widget = render_tab(state, state.active_tab)
    {widget, rect}
  end

  defp render_tab(state, "events") do
    offset = Map.get(state.scroll, "events", 0)
    filtered = filter_events(state.events, state.event_filter, state.event_search)
    total = length(filtered)

    title =
      [" Events"]
      |> maybe_add(" (#{state.event_filter})", state.event_filter != "all")
      |> maybe_add(" search=#{state.event_search}", state.event_search != "")
      |> maybe_add(" #{min(offset + 1, total)}-#{min(offset + 100, total)}/#{total}", total > 0)
      |> Enum.join()
      |> Kernel.<>(" ")

    items =
      filtered
      |> Enum.reverse()
      |> Enum.drop(offset)
      |> Enum.take(100)
      |> Enum.map(fn event ->
        ts = format_ts(event.timestamp)
        source = event.source || :unknown
        type = event.type || :unknown
        text = event_summary(event)

        Line.new([
          Span.new("[#{ts}] ", style: %Style{fg: :dark_gray}),
          Span.new("[#{source}:#{type}] ", style: %Style{fg: :magenta, modifiers: [:bold]}),
          Span.new(text, style: %Style{fg: :white})
        ])
      end)

    %List{
      items: items,
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :magenta}
      }
    }
  end

  defp render_tab(state, "logs") do
    offset = Map.get(state.scroll, "logs", 0)
    filtered = filter_logs(state.logs, state.log_filter, state.log_search)
    total = length(filtered)

    title =
      [" Logs"]
      |> maybe_add(" (#{state.log_filter})", state.log_filter != "all")
      |> maybe_add(" search=#{state.log_search}", state.log_search != "")
      |> maybe_add(" #{min(offset + 1, total)}-#{min(offset + 100, total)}/#{total}", total > 0)
      |> Enum.join()
      |> Kernel.<>(" ")

    items =
      filtered
      |> Enum.drop(offset)
      |> Enum.take(100)
      |> Enum.map(fn entry ->
        ts = format_ts(entry.timestamp)
        level = entry.level || :info
        msg = entry.message || ""

        Line.new([
          Span.new("[#{ts}] ", style: %Style{fg: :dark_gray}),
          Span.new("[#{level}] ", style: %Style{fg: level_fg(level), modifiers: [:bold]}),
          Span.new(msg, style: %Style{fg: :white})
        ])
      end)

    %List{
      items: items,
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }
  end

  defp render_tab(state, "diagnostics") do
    offset = Map.get(state.scroll, "diagnostics", 0)
    total = length(state.diagnostics)

    title =
      [" Diagnostics"]
      |> maybe_add(" #{min(offset + 1, total)}-#{min(offset + 100, total)}/#{total}", total > 0)
      |> Enum.join()
      |> Kernel.<>(" ")

    items =
      state.diagnostics
      |> Enum.drop(offset)
      |> Enum.take(100)
      |> Enum.map(fn diag ->
        ts = format_ts(Map.get(diag, :timestamp))
        level = Map.get(diag, :level, :unknown)
        msg = Map.get(diag, :message, "")
        meta = Map.get(diag, :metadata, %{})
        source = meta[:source] || Map.get(meta, "source", "—")
        file = meta[:file] || Map.get(meta, "file")
        line = meta[:line] || Map.get(meta, "line")
        loc = if file, do: " #{file}#{if line, do: ":#{line}", else: ""}", else: ""

        Line.new([
          Span.new("[#{ts}] ", style: %Style{fg: :dark_gray}),
          Span.new("[#{level}] ", style: %Style{fg: level_fg(level), modifiers: [:bold]}),
          Span.new("#{source}: ", style: %Style{fg: :yellow}),
          Span.new(msg, style: %Style{fg: :white}),
          Span.new(loc, style: %Style{fg: :dark_gray})
        ])
      end)

    %List{
      items: items,
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :yellow}
      }
    }
  end

  defp render_tab(state, "agents") do
    offset = Map.get(state.scroll, "agents", 0)

    agents =
      case state.agent_snapshot do
        %{agents: a} -> a
        _ -> []
      end

    total = length(agents)

    title =
      [" Muses"]
      |> maybe_add(" #{min(offset + 1, total)}-#{min(offset + 50, total)}/#{total}", total > 0)
      |> Enum.join()
      |> Kernel.<>(" ")

    rows =
      agents
      |> Enum.drop(offset)
      |> Enum.take(50)
      |> Enum.map(fn a ->
        name = Map.get(a, :name, "—")
        status = Map.get(a, :status, "—") |> to_string()
        kind = Map.get(a, :kind, "—") |> to_string()
        task = Map.get(a, :task) || "—"
        progress = format_progress(Map.get(a, :progress))

        [name, status, kind, task, progress]
      end)

    %Table{
      rows: rows,
      header: ["Name", "Status", "Kind", "Task", "Progress"],
      widths: [{:length, 16}, {:length, 10}, {:length, 10}, {:percentage, 50}, {:length, 8}],
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :green}
      }
    }
  end

  defp render_tab(state, "stats") do
    bs = state.beam_stats
    total = Map.get(bs, :total_memory, 0)
    procs = Map.get(bs, :process_count, 0)
    proc_lim = Map.get(bs, :process_limit, 0)
    ports = Map.get(bs, :port_count, 0)
    scheds = Map.get(bs, :scheduler_count, 0)
    scheds_on = Map.get(bs, :schedulers_online, 0)
    otp = Map.get(bs, :otp_release, "?")

    runtime_status =
      case state.agent_runtime do
        %{status: s} -> to_string(s)
        _ -> "unavailable"
      end

    lines = [
      "  BEAM Statistics",
      "",
      "  Processes:  #{procs} / #{proc_lim}",
      "  Memory:     #{format_bytes(total)}",
      "  Schedulers: #{scheds_on} online / #{scheds} total",
      "  Ports:      #{ports}",
      "  OTP:        #{otp}",
      "",
      "  Runtime:    #{runtime_status}"
    ]

    scroll_y = Map.get(state.scroll, "stats", 0)

    %Paragraph{
      text: Enum.join(lines, "\n"),
      style: %Style{fg: :white},
      block: %Block{
        title: " Stats ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      },
      scroll: {scroll_y, 0}
    }
  end

  defp render_tab(state, "settings") do
    session_lines =
      case state.session_status do
        nil ->
          ["  Session: No active session"]

        status ->
          session_status = Map.get(status, :status, :idle)
          active_muse = Map.get(status, :active_muse)
          plan_id = Map.get(status, :active_plan_id)
          pending = Map.get(status, :pending_patch)
          turn = Map.get(status, :active_turn_id)

          lines = ["  Session: #{session_status}"]

          lines =
            if active_muse do
              lines ++ ["  Active Muse: #{active_muse}"]
            else
              lines
            end

          lines =
            if plan_id do
              plan_status =
                case Map.get(status, :plan) do
                  %{status: s} -> " (#{s})"
                  _ -> ""
                end

              lines ++ ["  Plan: #{plan_id}#{plan_status}"]
            else
              lines
            end

          lines =
            if pending do
              lines ++ ["  Patch: pending approval"]
            else
              lines
            end

          if turn do
            lines ++ ["  Turn: running"]
          else
            lines
          end
      end

    lines =
      session_lines ++
        [
          "",
          "  Muse Settings",
          "",
          "  Workspace:   #{state.workspace || "unknown"}",
          "  Web URL:     #{state.web_url || "off"}",
          "  Event filter: #{state.event_filter}",
          "  Event search: #{state.event_search || "—"}",
          "  Log filter:   #{state.log_filter}",
          "  Log search:   #{state.log_search || "—"}",
          "",
          "  Key bindings:",
          "    Tab / Shift+Tab   cycle tabs (always)",
          "    Esc               INPUT→main / MAIN→quit",
          "    i                 focus input (from MAIN)",
          "    /                 focus input with / (from MAIN)",
          "    Ctrl+E/L/D/A/S/,  jump to tab",
          "    Ctrl+R             reload",
          "    ?                  toggle help (MAIN only)",
          "    j/k ↑/↓            scroll (MAIN only)",
          "    PgUp/PgDn          scroll 10",
          "    Home/End            scroll to edge",
          "    Ctrl+Q / Ctrl+C    quit",
          "",
          "  Distribution: Muse runs as a single BEAM node."
        ]

    scroll_y = Map.get(state.scroll, "settings", 0)

    %Paragraph{
      text: Enum.join(lines, "\n"),
      style: %Style{fg: :white},
      block: %Block{
        title: " Settings ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      },
      scroll: {scroll_y, 0}
    }
  end

  # -- Render: input -------------------------------------------------------------

  defp render_input(%__MODULE__{input_state: input_state, focus: focus}) do
    title = if focus == :input, do: " Input * ", else: " Input "

    %TextInput{
      state: input_state,
      placeholder: "Type message or /command … (Enter=send, Esc=main)",
      placeholder_style: %Style{fg: :dark_gray},
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: if(focus == :input, do: :green, else: :dark_gray)}
      }
    }
  end

  # -- Render: footer ------------------------------------------------------------

  defp render_footer(%__MODULE__{status: status, focus: focus}) do
    focus_str = if focus == :input, do: "INPUT", else: "MAIN"
    mode = " mode=#{focus_str}"

    hint =
      case focus do
        :input ->
          " Tab/⇧Tab: tabs | Esc: main | Enter: send | type: input | ⌃Q: quit"

        :main ->
          " Tab/⇧Tab: tabs | i: type | /: cmd | ?: help | Esc: quit | ⌃Q: quit"
      end

    %Paragraph{
      text: " #{status}#{mode}  |#{hint}",
      style: %Style{fg: :dark_gray}
    }
  end

  # -- Render: help popup --------------------------------------------------------

  defp render_help_popup do
    help_text =
      Enum.join(
        [
          "  Muse TUI — Key Reference",
          "",
          "  Tab / Shift+Tab     Cycle tabs (always works)",
          "  Ctrl+E              Events tab",
          "  Ctrl+L              Logs tab",
          "  Ctrl+D              Diagnostics tab",
          "  Ctrl+A              Muses tab",
          "  Ctrl+S              Stats tab",
          "  Ctrl+,              Settings tab",
          "  Ctrl+R              Reload",
          "",
          "  When INPUT focus:",
          "    Enter              Send input",
          "    Esc                Switch to MAIN focus",
          "    (typing goes to input field)",
          "",
          "  When MAIN focus:",
          "    i                  Switch to INPUT focus",
          "    /                  Switch to INPUT with / prefix",
          "    j/k  ↑/↓           Scroll",
          "    PgUp/PgDn          Page scroll",
          "    Home/End            Scroll edges",
          "    Esc                 Quit",
          "",
          "  ?                   Toggle this help (MAIN focus)",
          "  Ctrl+Q / Ctrl+C     Quit (always works)",
          "",
          "  Press Esc to close."
        ],
        "\n"
      )

    %Popup{
      content: %Paragraph{
        text: help_text,
        style: %Style{fg: :white}
      },
      block: %Block{
        title: " Help ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :yellow}
      },
      percent_width: 60,
      percent_height: 70
    }
  end

  # -- Tab-from-x helper (for mouse click on tab row) --------------------------

  defp tab_from_x(x, _state) do
    # 6 tabs roughly evenly spaced; each tab ~20 chars wide at 120 cols
    idx = min(div(x, 20), 5)
    Enum.at(@tab_keys, idx)
  end

  # -- Key classification --------------------------------------------------------

  defp editable_key?(%ExRatatui.Event.Key{code: code, kind: kind, modifiers: modifiers})
       when kind in ["press", "repeat", nil] do
    editable_modifier?(modifiers) and
      (code in ~w(backspace delete left right home end) or
         (byte_size(code) == 1 and String.printable?(code)))
  end

  defp editable_key?(_), do: false

  defp editable_modifier?([]), do: true
  defp editable_modifier?(["shift"]), do: true
  defp editable_modifier?(_), do: false

  # -- Helpers -------------------------------------------------------------------

  defp event_summary(%Muse.Event{} = event), do: Muse.EventDisplay.summary(event)
  defp event_summary(other), do: Muse.EventDisplay.summary(other)

  defp level_fg(:error), do: :red
  defp level_fg(:warning), do: :yellow
  defp level_fg(:debug), do: :dark_gray
  defp level_fg(:critical), do: :red
  defp level_fg(_), do: :white

  defp format_ts(%DateTime{} = dt),
    do: dt |> DateTime.to_string() |> String.slice(11, 8)

  defp format_ts(_), do: "--:--:--"

  defp format_progress(nil), do: "—"
  defp format_progress(p) when is_float(p), do: "#{Float.round(p * 100, 0)}%"
  defp format_progress(p) when is_number(p), do: "#{p}%"
  defp format_progress(_), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp maybe_add(list, _segment, false), do: list
  defp maybe_add(list, segment, _), do: list ++ [segment]

  # -- Filtering (lightweight, mirrors CommandDispatcher logic) ------------------

  defp filter_events(events, "all", ""), do: events

  defp filter_events(events, filter, search) do
    events
    |> filter_events_by_severity(filter)
    |> filter_events_by_search(search)
  end

  defp filter_events_by_severity(events, "all"), do: events

  defp filter_events_by_severity(events, "errors"),
    do: Enum.filter(events, &(event_severity(&1) == :error))

  defp filter_events_by_severity(events, "warnings"),
    do: Enum.filter(events, &(event_severity(&1) == :warning))

  defp filter_events_by_severity(events, "info"),
    do: Enum.filter(events, &(event_severity(&1) == :info))

  defp filter_events_by_severity(events, _), do: events

  defp event_severity(%Muse.Event{type: type, data: data}) do
    cond do
      errorish?(type) or errorish?(data) -> :error
      type == :warning -> :warning
      true -> :info
    end
  end

  defp errorish?(term) when is_atom(term),
    do: term in [:error, :failed, :failure, :critical, :reload_failed]

  defp errorish?(%{type: type}), do: errorish?(type)

  defp errorish?(term) when is_binary(term),
    do: String.downcase(term) in ["error", "failed", "failure", "critical"]

  defp errorish?(_), do: false

  defp filter_events_by_search(events, ""), do: events
  defp filter_events_by_search(events, nil), do: events

  defp filter_events_by_search(events, query) when is_binary(query) do
    q = String.downcase(query)
    Enum.filter(events, &event_matches_search?(&1, q))
  end

  defp event_matches_search?(event, query) do
    searchable =
      [
        Atom.to_string(event.source || :unknown),
        Atom.to_string(event.type || :unknown),
        event_summary(event),
        inspect(Muse.EventDisplay.safe_data(event.data))
      ]
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(searchable, query)
  end

  defp filter_logs(logs, "all", ""), do: logs

  defp filter_logs(logs, filter, search) do
    logs
    |> filter_logs_by_level(filter)
    |> filter_logs_by_search(search)
  end

  defp filter_logs_by_level(logs, "all"), do: logs

  defp filter_logs_by_level(logs, "errors"),
    do: Enum.filter(logs, &(&1.level in [:error, :critical]))

  defp filter_logs_by_level(logs, "warnings"),
    do: Enum.filter(logs, &(&1.level == :warning))

  defp filter_logs_by_level(logs, "info"),
    do: Enum.filter(logs, &(&1.level == :info))

  defp filter_logs_by_level(logs, "debug"),
    do: Enum.filter(logs, &(&1.level == :debug))

  defp filter_logs_by_level(logs, _), do: logs

  defp filter_logs_by_search(logs, ""), do: logs
  defp filter_logs_by_search(logs, nil), do: logs

  defp filter_logs_by_search(logs, query) when is_binary(query) do
    q = String.downcase(query)
    Enum.filter(logs, &log_matches_search?(&1, q))
  end

  defp log_matches_search?(entry, query) do
    metadata_str =
      case Map.get(entry, :metadata) do
        m when is_map(m) -> inspect(m)
        nil -> ""
        other -> inspect(other)
      end

    searchable =
      [
        safe_to_string(entry.level),
        safe_to_string(entry.source),
        entry.message || "",
        metadata_str
      ]
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(searchable, query)
  end

  defp safe_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_to_string(v) when is_binary(v), do: v
  defp safe_to_string(v), do: inspect(v)

  # -- Paragraph line-count helpers ----------------------------------------------

  defp stats_line_count(state) do
    render_tab(state, "stats").text |> String.split("\n") |> length()
  end

  defp settings_line_count(state) do
    render_tab(state, "settings").text |> String.split("\n") |> length()
  end

  # -- Safe helpers --------------------------------------------------------------

  defp safe_subscribe(mod) do
    try do
      mod.subscribe()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp safe_list(mod) do
    try do
      mod.list()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp safe_events(mod) do
    try do
      mod.events()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp safe_beam_stats do
    try do
      Muse.BeamStats.snapshot()
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  defp safe_session_status do
    try do
      case Muse.SessionRouter.status("default") do
        {:ok, status} -> status
        {:error, _} -> nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
