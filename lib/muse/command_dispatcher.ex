defmodule Muse.CommandDispatcher do
  @moduledoc """
  Shared command dispatcher for all Muse interfaces (Web, TUI, REPL).

  Returns plain data — no LiveView sockets, no Phoenix imports.
  Every call returns `{:ok, output, effects}` or `{:error, output, effects}`
  where `output` is a human-readable string and `effects` is a list of
  effect tuples for the caller to apply.

  ## Effect tuples

      {:switch_tab, tab}
      {:clear_input}
      {:toast, type, message}          — type ∈ :info | :success | :warning | :error
      {:set_event_search, query}
      {:set_event_filter, filter}
      {:set_log_search, query}
      {:set_log_filter, filter}
      {:refresh, resource}             — resource ∈ :events | :logs | :diagnostics | :runtime | :stats | :agents
      {:copy_to_clipboard, text, label}

  ## Context map

  The `context` argument is a plain map providing the data the dispatcher
  needs.  Web callers typically pass a subset of `socket.assigns`; TUI/REPL
  callers build a smaller context from their own state.

  Expected keys (all optional — missing keys produce safe fallbacks):

      events, logs, diagnostics, agent_snapshot, workspace,
      reload_status, agent_runtime, beam_stats,
      event_filter, event_search, log_filter, log_search,
      command_history
  """

  alias Muse.Backend

  # -- Public API --------------------------------------------------------------

  @spec dispatch(atom(), String.t() | nil, map()) ::
          {:ok, String.t(), [effect]} | {:error, String.t(), [effect]}
        when effect: tuple()
  def dispatch(action, args \\ nil, context \\ %{})

  # -- Help --------------------------------------------------------------------

  def dispatch(:help, _args, _context) do
    {:ok, Muse.Commands.help_text(), []}
  end

  # -- Events ------------------------------------------------------------------

  def dispatch(:events, _args, context) do
    events = Map.get(context, :events, [])
    count = length(events)

    summary = "Event log: #{count} event(s) recorded."

    output =
      if count > 0 and count <= 10 do
        lines =
          Enum.map(events, fn e ->
            "[#{e.source}] #{event_display_text(e)}"
          end)

        summary <> "\n" <> Enum.join(lines, "\n")
      else
        if count > 10 do
          recent =
            events
            |> Enum.take(-10)
            |> Enum.map(fn e -> "[#{e.source}] #{event_display_text(e)}" end)

          summary <> " (showing last 10)\n" <> Enum.join(recent, "\n")
        else
          summary
        end
      end

    {:ok, output, []}
  end

  # -- Agents ------------------------------------------------------------------

  def dispatch(:agents, _args, context) do
    case Map.get(context, :agent_snapshot, :unavailable) do
      :unavailable ->
        {:ok, "Muse registry unavailable.", []}

      %{agents: agents} ->
        count = length(agents)
        label = if count == 1, do: "Muse", else: "Muses"
        {:ok, "Muse registry: #{count} #{label}.", []}
    end
  end

  # -- Simulate ----------------------------------------------------------------

  def dispatch(:simulate_event, _args, _context) do
    if Mix.env() != :prod do
      event = Muse.Event.new(:web, :simulated, %{text: "Simulated test event from command"})
      Muse.State.append(event)

      {:ok, "Simulated event created.",
       [{:refresh, :events}, {:toast, :success, "Simulated event created"}]}
    else
      {:ok, "Simulate not available in production.", []}
    end
  end

  def dispatch(:simulate_backend_error, _args, _context) do
    if Mix.env() != :prod do
      Backend.safe_emit_simulated_error()

      event = Muse.Event.new(:web, :error, %{text: "Simulated backend error from command"})
      Muse.State.append(event)

      {:ok, "Simulated backend error created.",
       [{:refresh, :events}, {:toast, :warning, "Backend error simulated"}]}
    else
      {:ok, "Simulate not available in production.", []}
    end
  end

  # -- Clear -------------------------------------------------------------------

  def dispatch(:clear_history, _args, _context) do
    {:ok, "Command history cleared.", []}
  end

  def dispatch(:clear_events, _args, _context) do
    Muse.State.clear()
    {:ok, "Events cleared.", [{:refresh, :events}, {:toast, :info, "Events cleared"}]}
  end

  # -- Reload ------------------------------------------------------------------

  def dispatch(:reload, _args, _context) do
    case Backend.safe_force_reload() do
      :ok ->
        {:ok, "Reload initiated.", [{:refresh, :events}, {:toast, :success, "Reloaded"}]}

      {:error, reason} ->
        {:error, "Reload failed: #{inspect(reason)}", [{:toast, :error, "Reload failed"}]}
    end
  end

  # -- Rollback ----------------------------------------------------------------

  def dispatch(:rollback, _args, _context) do
    case safe_dev_rollback() do
      :ok ->
        {:ok, "Rollback completed.", [{:refresh, :events}, {:toast, :success, "Rolled back"}]}

      {:error, reason} ->
        {:error, "Rollback failed: #{inspect(reason)}", [{:toast, :error, "Rollback failed"}]}
    end
  end

  # -- Reload status -----------------------------------------------------------

  def dispatch(:reload_status, _args, context) do
    status = Map.get(context, :reload_status, %{status: :unavailable})

    msg =
      case status[:status] do
        :unavailable -> "File watcher: Unavailable"
        _ -> "File watcher: Active (gen #{status[:generation]})"
      end

    {:ok, msg, []}
  end

  # -- Workspace ---------------------------------------------------------------

  def dispatch(:workspace, _args, context) do
    workspace = Map.get(context, :workspace) || Backend.safe_workspace_root()
    {:ok, "Workspace: #{workspace}", []}
  end

  # -- Stats -------------------------------------------------------------------

  def dispatch(:stats, _args, _context) do
    stats = Muse.BeamStats.snapshot()

    msg =
      "BEAM Stats: #{stats.process_count} processes, #{format_bytes(stats.total_memory)} memory, OTP #{stats.otp_release}"

    {:ok, msg, [{:refresh, :stats}]}
  end

  # -- Diagnostics -------------------------------------------------------------

  def dispatch(:diagnostics, _args, context) do
    diagnostics = Map.get(context, :diagnostics, [])

    levels =
      diagnostics
      |> Enum.group_by(& &1.level)
      |> Enum.map(fn {level, items} -> "#{length(items)} #{level}" end)
      |> Enum.join(", ")

    msg =
      if diagnostics == [],
        do: "No diagnostics.",
        else: "Diagnostics: #{length(diagnostics)} (#{levels})"

    {:ok, msg, []}
  end

  # -- Copy diagnostics --------------------------------------------------------

  def dispatch(:copy_diagnostics, _args, context) do
    diagnostics = Map.get(context, :diagnostics, nil)

    if diagnostics == nil do
      {:error, "Diagnostics data not available in context.", []}
    else
      payload = build_diagnostics_payload(context)
      json = Jason.encode!(payload, pretty: true)
      {:ok, "Diagnostics copied to clipboard.", [{:copy_to_clipboard, json, "Diagnostics"}]}
    end
  rescue
    e -> {:error, "Error: #{Exception.message(e)}", []}
  end

  # -- Export events -----------------------------------------------------------

  def dispatch(:export_events, _args, context) do
    events = get_in(context, [:state, :events]) || Map.get(context, :events, [])

    if events == [] and not Map.has_key?(context, :events) and not Map.has_key?(context, :state) do
      {:error, "Events data not available in context.", []}
    else
      event_filter = Map.get(context, :event_filter, "all")
      event_search = Map.get(context, :event_search, "")
      events_list = if is_list(events), do: events, else: []

      filtered =
        events_list
        |> Enum.reverse()
        |> filter_events_by_severity(event_filter)
        |> filter_events_by_search(event_search)

      payload = %{
        "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "filter" => event_filter,
        "search" => event_search,
        "total_events" => length(events_list),
        "exported_count" => length(filtered),
        "events" => Enum.map(filtered, &event_to_map/1)
      }

      json = Jason.encode!(payload, pretty: true)

      {:ok, "#{length(filtered)} events exported to clipboard.",
       [{:copy_to_clipboard, json, "#{length(filtered)} events exported"}]}
    end
  rescue
    e -> {:error, "Error: #{Exception.message(e)}", []}
  end

  # -- Search events -----------------------------------------------------------

  def dispatch(:search_events, nil, _context) do
    {:ok, "Usage: /search events <query>", [{:switch_tab, "events"}]}
  end

  def dispatch(:search_events, "", _context) do
    {:ok, "Usage: /search events <query>", [{:switch_tab, "events"}]}
  end

  def dispatch(:search_events, args, _context) do
    {:ok, "Searching events for: #{args}", [{:set_event_search, args}, {:switch_tab, "events"}]}
  end

  # -- Filter events -----------------------------------------------------------

  def dispatch(:filter_events, nil, context) do
    current = String.capitalize(Map.get(context, :event_filter, "all"))

    {:ok, "Usage: /filter events errors|warnings|info|all (current: #{current})",
     [{:switch_tab, "events"}]}
  end

  def dispatch(:filter_events, "", context) do
    dispatch(:filter_events, nil, context)
  end

  def dispatch(:filter_events, args, _context) do
    normalized = String.downcase(String.trim(args))

    case normalize_filter(normalized) do
      {:ok, filter} ->
        {:ok, "Event filter set to: #{String.capitalize(filter)}",
         [{:set_event_filter, filter}, {:switch_tab, "events"}]}

      {:error, invalid} ->
        {:error,
         "Error: Unknown filter \"#{invalid}\". Usage: /filter events errors|warnings|info|all",
         [{:switch_tab, "events"}]}
    end
  end

  # -- Open tabs ---------------------------------------------------------------

  def dispatch(:open_events, _args, _context),
    do: {:ok, "Switched to Events tab.", [{:switch_tab, "events"}]}

  def dispatch(:open_files, _args, _context),
    do: {:ok, "Switched to Files tab.", [{:switch_tab, "files"}]}

  def dispatch(:open_agents, _args, _context),
    do: {:ok, "Switched to Muses tab.", [{:switch_tab, "agents"}]}

  def dispatch(:open_stats, _args, _context),
    do: {:ok, "Switched to Stats tab.", [{:switch_tab, "stats"}]}

  def dispatch(:open_settings, _args, _context),
    do: {:ok, "Switched to Settings tab.", [{:switch_tab, "settings"}]}

  def dispatch(:open_logs, _args, _context),
    do: {:ok, "Switched to Logs tab.", [{:switch_tab, "logs"}]}

  # -- Logs --------------------------------------------------------------------

  def dispatch(:logs, _args, context) do
    logs = Map.get(context, :logs, [])
    {:ok, "Log buffer: #{length(logs)} log entry(s) recorded.", []}
  end

  # -- Clear logs --------------------------------------------------------------

  def dispatch(:clear_logs, _args, _context) do
    case Backend.safe_clear_logs() do
      :ok ->
        {:ok, "Logs cleared.", [{:refresh, :logs}, {:toast, :info, "Logs cleared"}]}

      {:error, _reason} ->
        {:error, "Error: Log buffer unavailable.", []}
    end
  end

  # -- Export logs -------------------------------------------------------------

  def dispatch(:export_logs, _args, context) do
    logs = Map.get(context, :logs, nil)

    if logs == nil do
      {:error, "Logs data not available in context.", []}
    else
      log_filter = Map.get(context, :log_filter, "all")
      log_search = Map.get(context, :log_search, "")

      filtered =
        logs
        |> filter_logs_by_level(log_filter)
        |> filter_logs_by_search(log_search)

      payload = %{
        "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "total_count" => length(filtered),
        "logs" => Enum.map(filtered, &log_entry_to_map/1)
      }

      json = Jason.encode!(payload, pretty: true)

      {:ok, "#{length(filtered)} logs exported to clipboard.",
       [{:copy_to_clipboard, json, "#{length(filtered)} logs exported"}]}
    end
  rescue
    e -> {:error, "Error: #{Exception.message(e)}", []}
  end

  # -- Search logs -------------------------------------------------------------

  def dispatch(:search_logs, nil, _context) do
    {:ok, "Usage: /search logs <query>", [{:switch_tab, "logs"}]}
  end

  def dispatch(:search_logs, "", _context) do
    {:ok, "Usage: /search logs <query>", [{:switch_tab, "logs"}]}
  end

  def dispatch(:search_logs, args, _context) do
    {:ok, "Searching logs for: #{args}", [{:set_log_search, args}, {:switch_tab, "logs"}]}
  end

  # -- Filter logs -------------------------------------------------------------

  def dispatch(:filter_logs, nil, context) do
    current = String.capitalize(Map.get(context, :log_filter, "all"))

    {:ok, "Usage: /filter logs errors|warnings|info|debug|all (current: #{current})",
     [{:switch_tab, "logs"}]}
  end

  def dispatch(:filter_logs, "", context) do
    dispatch(:filter_logs, nil, context)
  end

  def dispatch(:filter_logs, args, _context) do
    normalized = String.downcase(String.trim(args))

    case normalize_log_filter(normalized) do
      {:ok, filter} ->
        {:ok, "Log filter set to: #{String.capitalize(filter)}",
         [{:set_log_filter, filter}, {:switch_tab, "logs"}]}

      {:error, invalid} ->
        {:error,
         "Error: Unknown filter \"#{invalid}\". Usage: /filter logs errors|warnings|info|debug|all",
         [{:switch_tab, "logs"}]}
    end
  end

  # -- Runtime -----------------------------------------------------------------

  def dispatch(:runtime, _args, context) do
    runtime = Map.get(context, :agent_runtime) || Backend.safe_agent_runtime_snapshot()

    msg =
      case runtime.status do
        :disconnected -> "Muse runtime: Disconnected (endpoint: #{runtime.endpoint})"
        :connecting -> "Muse runtime: Connecting to #{runtime.endpoint}..."
        :connected -> "Muse runtime: Connected to #{runtime.endpoint}"
        :error -> "Muse runtime: Error — #{runtime.last_error} (endpoint: #{runtime.endpoint})"
      end

    {:ok, msg, []}
  end

  # -- Connect runtime --------------------------------------------------------

  def dispatch(:connect_runtime, nil, _context) do
    case Backend.safe_connect_agent_runtime() do
      {:error, reason} when is_binary(reason) ->
        {:ok, "Runtime: #{reason}",
         [{:refresh, :runtime}, {:toast, :warning, "Runtime: #{reason}"}]}

      {:error, _reason} ->
        {:ok, "Muse runtime unavailable.", [{:toast, :warning, "Muse runtime unavailable"}]}
    end
  end

  def dispatch(:connect_runtime, args, _context) do
    endpoint = String.trim(args)

    if endpoint != "" do
      _ = Backend.safe_set_agent_runtime_endpoint(endpoint)
    end

    case Backend.safe_connect_agent_runtime(endpoint) do
      {:error, reason} when is_binary(reason) ->
        {:ok, "Runtime: #{reason}",
         [{:refresh, :runtime}, {:toast, :warning, "Runtime: #{reason}"}]}

      {:error, _reason} ->
        {:ok, "Muse runtime unavailable.", [{:toast, :warning, "Muse runtime unavailable"}]}
    end
  end

  # -- Disconnect runtime ------------------------------------------------------

  def dispatch(:disconnect_runtime, _args, _context) do
    case Backend.safe_disconnect_agent_runtime() do
      {:ok, _snapshot} ->
        {:ok, "Runtime disconnected.",
         [{:refresh, :runtime}, {:toast, :info, "Runtime disconnected"}]}

      {:error, _reason} ->
        {:ok, "Muse runtime unavailable.", [{:toast, :warning, "Muse runtime unavailable"}]}
    end
  end

  # -- Catch-all ---------------------------------------------------------------

  def dispatch(action, _args, _context) do
    {:error, "Unknown command action: #{inspect(action)}. Type /help for available commands.", []}
  end

  # -- Filter normalization (shared) -------------------------------------------

  @valid_filters ~w(errors warnings info all)

  @spec normalize_filter(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_filter(normalized) when normalized in @valid_filters, do: {:ok, normalized}
  def normalize_filter("error"), do: {:ok, "errors"}
  def normalize_filter("warning"), do: {:ok, "warnings"}
  def normalize_filter(invalid), do: {:error, invalid}

  @valid_log_filters ~w(all errors warnings info debug)

  @spec normalize_log_filter(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_log_filter(normalized) when normalized in @valid_log_filters,
    do: {:ok, normalized}

  def normalize_log_filter("error"), do: {:ok, "errors"}
  def normalize_log_filter("warning"), do: {:ok, "warnings"}
  def normalize_log_filter(invalid), do: {:error, invalid}

  # -- Internal formatting helpers ---------------------------------------------

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  # -- Event filtering (inline, no MuseWeb deps) -------------------------------

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
      type in [:warning] -> :warning
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
    searchable_parts = [
      Atom.to_string(event.source),
      Atom.to_string(event.type),
      event_display_text(event),
      inspect(event.data)
    ]

    searchable = searchable_parts |> Enum.join(" ") |> String.downcase()
    String.contains?(searchable, query)
  end

  defp event_display_text(%Muse.Event{data: %{text: text}}), do: text
  defp event_display_text(%Muse.Event{data: %{file: file}}), do: file
  defp event_display_text(%Muse.Event{data: data}), do: inspect(data)

  defp event_to_map(%Muse.Event{} = event) do
    %{
      "id" => event.id,
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "source" => Atom.to_string(event.source),
      "type" => Atom.to_string(event.type),
      "data" => json_safe(event.data)
    }
  end

  # -- Log filtering (inline, no MuseWeb deps) ---------------------------------

  defp filter_logs_by_level(logs, "all"), do: logs

  defp filter_logs_by_level(logs, "errors"),
    do: Enum.filter(logs, &(&1.level in [:error, :critical]))

  defp filter_logs_by_level(logs, "warnings"), do: Enum.filter(logs, &(&1.level == :warning))
  defp filter_logs_by_level(logs, "info"), do: Enum.filter(logs, &(&1.level == :info))
  defp filter_logs_by_level(logs, "debug"), do: Enum.filter(logs, &(&1.level == :debug))
  defp filter_logs_by_level(logs, _), do: logs

  defp filter_logs_by_search(logs, ""), do: logs
  defp filter_logs_by_search(logs, nil), do: logs

  defp filter_logs_by_search(logs, query) when is_binary(query) do
    q = String.downcase(query)
    Enum.filter(logs, &log_matches_search?(&1, q))
  end

  defp log_matches_search?(entry, query) do
    searchable_parts = [
      safe_to_string(entry.level),
      safe_to_string(entry.source),
      entry.message,
      inspect(entry.metadata)
    ]

    searchable = searchable_parts |> Enum.join(" ") |> String.downcase()
    String.contains?(searchable, query)
  end

  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value), do: inspect(value)

  defp log_entry_to_map(%Muse.LogEntry{} = entry) do
    %{
      "id" => entry.id,
      "timestamp" => safe_timestamp_iso(entry.timestamp),
      "level" => safe_to_string(entry.level),
      "source" => safe_to_string(entry.source),
      "message" => safe_to_string(entry.message),
      "metadata" => json_safe(entry.metadata)
    }
  end

  defp safe_timestamp_iso(%DateTime{} = ts), do: DateTime.to_iso8601(ts)
  defp safe_timestamp_iso(nil), do: nil
  defp safe_timestamp_iso(other), do: safe_to_string(other)

  # -- JSON safety (minimal, no MuseWeb deps) ----------------------------------

  defp json_safe(term) when is_binary(term), do: term
  defp json_safe(term) when is_boolean(term), do: term
  defp json_safe(term) when is_number(term), do: term
  defp json_safe(nil), do: nil
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe(%Time{} = t), do: Time.to_iso8601(t)
  defp json_safe(atom) when is_atom(atom), do: to_string(atom)

  defp json_safe(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&json_safe/1)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(%{__struct__: struct_name} = struct) do
    base = Map.delete(struct, :__struct__)

    Map.put(
      Enum.map(base, fn {k, v} -> {json_key(k), json_safe(v)} end) |> Map.new(),
      "__struct__",
      to_string(struct_name)
    )
  end

  defp json_safe(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {json_key(k), json_safe(v)} end) |> Map.new()
  end

  defp json_safe(other), do: inspect(other)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_key(%Date{} = d), do: Date.to_iso8601(d)
  defp json_key(%Time{} = t), do: Time.to_iso8601(t)
  defp json_key(key) when is_number(key), do: to_string(key)
  defp json_key(key), do: inspect(key)

  # -- Diagnostics payload (minimal, no MuseWeb deps) -------------------------

  defp build_diagnostics_payload(context) do
    workspace = Map.get(context, :workspace, "unknown")
    reload_status = Map.get(context, :reload_status, %{status: :unknown})
    state = Map.get(context, :state, %{events: []})
    diagnostics = Map.get(context, :diagnostics, [])
    beam_stats = Map.get(context, :beam_stats, %{})
    logs = Map.get(context, :logs, [])
    agent_runtime = Map.get(context, :agent_runtime, nil)

    events = if is_map(state) and Map.has_key?(state, :events), do: state.events, else: []

    log_sample =
      logs
      |> Enum.take(20)
      |> Enum.map(&log_entry_to_safe_map/1)
      |> Enum.reject(&is_nil/1)

    %{
      "app" => "Muse",
      "version" => Application.spec(:muse, :vsn) |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "workspace" => workspace,
      "backend_status" => "connected",
      "reload_status" => to_string(reload_status[:status]),
      "events_count" => length(events),
      "logs_count" => length(logs),
      "logs_sample" => log_sample,
      "agent_runtime" => json_safe(agent_runtime || %{}),
      "diagnostics_count" => length(diagnostics),
      "diagnostics" =>
        Enum.map(diagnostics, fn d ->
          %{
            "id" => Map.get(d, :id),
            "level" => to_string(Map.get(d, :level, :unknown)),
            "message" => Map.get(d, :message, ""),
            "timestamp" =>
              case Map.get(d, :timestamp) do
                %DateTime{} = ts -> DateTime.to_iso8601(ts)
                nil -> nil
                other -> to_string(other)
              end,
            "metadata" => json_safe(Map.get(d, :metadata, %{}))
          }
        end),
      "beam_stats" => json_safe(beam_stats)
    }
  end

  defp log_entry_to_safe_map(log) when is_map(log) do
    %{
      "id" => Map.get(log, :id),
      "timestamp" =>
        case Map.get(log, :timestamp) do
          %DateTime{} = ts -> DateTime.to_iso8601(ts)
          nil -> nil
          other -> to_string(other)
        end,
      "level" => to_string(Map.get(log, :level, :info)),
      "source" => to_string(Map.get(log, :source, :unknown)),
      "message" => Map.get(log, :message, ""),
      "metadata" => json_safe(Map.get(log, :metadata, %{}))
    }
  end

  defp log_entry_to_safe_map(_), do: nil

  # -- DevReloader safe rollback (no MuseWeb deps) ----------------------------

  defp safe_dev_rollback do
    case Process.whereis(Muse.DevReloader) do
      nil ->
        {:error, :not_running}

      pid ->
        if Process.alive?(pid) do
          try do
            Muse.DevReloader.rollback()
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, "exit: #{inspect(reason)}"}
          end
        else
          {:error, :not_alive}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :process_exit}
  end
end
