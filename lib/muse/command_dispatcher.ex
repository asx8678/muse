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

  alias Muse.Auth.Status
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

  # -- Plan --------------------------------------------------------------------

  def dispatch(:plan, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /plan", []}
    else
      case Muse.PlanHistory.query(context).active_plan do
        nil ->
          {:ok, "No Muse Plan is available yet. Ask Planning Muse to create one!", []}

        %Muse.Plan{} = plan ->
          {:ok, render_plan_with_identity(plan), []}
      end
    end
  end

  def dispatch(:plans, args, context) do
    dispatch_plan_history(args, context, "/plans")
  end

  def dispatch(:plan_history, args, context) do
    dispatch_plan_history(args, context, "/plan history")
  end

  def dispatch(:plan_status, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /plan status", []}
    else
      query = Muse.PlanHistory.query(context)

      case query.active_plan do
        nil ->
          {:ok, "No active Muse Plan is available yet. Use /plans to view Muse Plan history.", []}

        %Muse.Plan{} = plan ->
          {:ok, Muse.PlanHistory.render_active_status(plan, query), []}
      end
    end
  end

  def dispatch(:plan_show, args, context) do
    with {:ok, id} <- parse_plan_show_args(args),
         %Muse.Plan{} = plan <-
           Muse.PlanHistory.find_plan_by_id(Muse.PlanHistory.query(context).plans, id) do
      {:ok, plan_show_heading(plan) <> "\n\n" <> Muse.Plan.render(plan), []}
    else
      :usage ->
        {:error, "Error: usage: /plan show <id>", []}

      nil ->
        {:error, "Error: Muse Plan #{String.trim(to_string(args || ""))} was not found.", []}
    end
  end

  def dispatch(:approve_plan, args, context) do
    dispatch_plan_lifecycle_command(:approve_plan, args, context)
  end

  def dispatch(:reject_plan, args, context) do
    dispatch_plan_lifecycle_command(:reject_plan, args, context)
  end

  def dispatch(:approve_patch, args, context) do
    dispatch_patch_lifecycle_command(:approve_patch, args, context)
  end

  def dispatch(:reject_patch, args, context) do
    dispatch_patch_lifecycle_command(:reject_patch, args, context)
  end

  # Phase B: Remote execution approval commands
  def dispatch(:approve_remote, args, context) do
    dispatch_remote_lifecycle_command(:approve_remote, args, context)
  end

  def dispatch(:reject_remote, args, context) do
    dispatch_remote_lifecycle_command(:reject_remote, args, context)
  end

  # PR18: /apply patch and /rollback checkpoint
  def dispatch(:apply_patch, args, context) do
    dispatch_apply_patch_command(args, context)
  end

  def dispatch(:rollback_checkpoint, args, context) do
    dispatch_rollback_checkpoint_command(args, context)
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

  # -- Muses -------------------------------------------------------------------

  @doc """
  Dispatches the `/muses` command, listing all registered Muse profiles.

  Prefers `Muse.MuseRegistry.summaries/0` for profile discovery; falls back
  to `agent_snapshot` from context, or a static fallback listing the two
  canonical PR04 Muses (Planning, Coding) if neither source is available.
  """
  def dispatch(:muses, _args, context) do
    profiles = resolve_muse_profiles(context)

    case profiles do
      [] ->
        {:ok, "Muse registry unavailable.", []}

      profiles when is_list(profiles) ->
        count = length(profiles)
        label = if count == 1, do: "Muse", else: "Muses"

        lines =
          Enum.map(profiles, fn p ->
            id = Map.get(p, :id, "?")
            display = Map.get(p, :display_name, to_string(id))
            role = Map.get(p, :role, "")
            desc = Map.get(p, :description, "")
            role_part = if role != "", do: " (#{role})", else: ""
            desc_part = if desc != "", do: " — #{desc}", else: ""
            "- #{display}#{role_part}#{desc_part}"
          end)

        {:ok, "Muse registry: #{count} #{label} available.\n" <> Enum.join(lines, "\n"), []}
    end
  end

  # Keep `:agents` as a compatibility alias — both `/muses` and `/agents` parse
  # to `:muses`, but external code may still dispatch `:agents` directly.
  def dispatch(:agents, _args, context) do
    dispatch(:muses, nil, context)
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

  # -- Auth status -------------------------------------------------------------

  def dispatch(:auth_status, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /auth status", []}
    else
      {:ok, Status.render(context), []}
    end
  end

  # -- Prompt preview ----------------------------------------------------------

  def dispatch(:prompt_preview, args, context) do
    bundle =
      case Map.get(context, :prompt_bundle) do
        %Muse.Prompt.Bundle{} = b -> b
        nil -> build_preview_bundle(args, context)
      end

    output = Muse.Prompt.DebugPreview.render(bundle)

    {:ok, output, []}
  rescue
    e -> {:error, "Prompt preview error: #{Exception.message(e)}", []}
  end

  # -- Session status ----------------------------------------------------------

  # dispatch(:session_status, args, context)
  # Shows the current Muse session status, active plan, and pending patch.
  # Returns `{:ok, summary, effects}` where effects include `{:refresh, :session}`
  # so callers can update their session state panel.
  def dispatch(:session_status, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /session", []}
    else
      session_id = context_session_id(context)

      case Muse.SessionRouter.status(session_id) do
        {:ok, status} ->
          output = format_session_status(status)
          {:ok, output, [{:refresh, :session}]}

        {:error, :not_found} ->
          {:ok, "No active Muse session. Start a conversation to create one.", []}
      end
    end
  end

  # -- Memory commands ---------------------------------------------------------

  def dispatch(:memory, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /memory", []}
    else
      session_id = context_session_id(context)

      case Muse.SessionRouter.get_memory(session_id) do
        {:ok, nil} ->
          {:ok, "No session memory. Use /memory compact to create one.", []}

        {:ok, memory} when is_map(memory) ->
          output = format_memory(memory)
          {:ok, output, []}

        {:ok, other_memory} ->
          # Non-map memory (binary, list, etc.) — redact and display safely.
          output = format_memory_safely(other_memory)
          {:ok, output, []}

        {:error, :not_found} ->
          {:ok, "No active Muse session.", []}
      end
    end
  end

  def dispatch(:memory_compact, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /memory compact", []}
    else
      session_id = context_session_id(context)

      case Muse.SessionRouter.status(session_id) do
        {:ok, session_status} when is_map(session_status) ->
          session = build_session_from_status(session_status)

          # Use compact_safe for fail-closed validation
          case Muse.Memory.compact_safe(session) do
            {:ok, memory} ->
              # Persist via SessionRouter so it's available for future turns
              Muse.SessionRouter.set_memory(session_id, memory)

              output = "Memory compacted successfully.\n\n" <> Muse.Memory.render(memory)
              {:ok, output, [{:refresh, :session}]}

            {:error, :secrets_detected, reasons} ->
              {:error, "Memory compaction blocked: secrets detected. #{inspect(reasons)}", []}
          end

        {:error, :not_found} ->
          {:ok, "No active Muse session to compact.", []}
      end
    end
  end

  def dispatch(:memory_clear, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /memory clear", []}
    else
      session_id = context_session_id(context)

      case Muse.SessionRouter.clear_memory(session_id) do
        :ok ->
          {:ok, "Session memory cleared. Future turns will not have memory context.",
           [{:refresh, :session}]}

        {:error, :not_found} ->
          {:ok, "No active Muse session.", []}
      end
    end
  end

  # -- Handoff commands ---------------------------------------------------------

  def dispatch(:handoff, args, context) do
    case parse_handoff_args(args) do
      {:error, :usage} ->
        {:error, "Error: usage: /handoff <muse_id> (e.g., /handoff coding)", []}

      {:error, :not_found} ->
        {:error,
         "Error: unknown Muse target. Available: #{Enum.join(Muse.MuseRegistry.ids(), ", ")}", []}

      {:ok, target_muse_id} ->
        session_id = context_session_id(context)

        case Muse.SessionRouter.status(session_id) do
          {:ok, session_status} when is_map(session_status) ->
            current_muse_id =
              session_status[:active_muse] || session_status["active_muse"] || :planning

            current_muse = Muse.MuseRegistry.get(current_muse_id)
            session = build_session_from_status(session_status)

            if current_muse == nil do
              {:error, "Error: current Muse not found: #{current_muse_id}", []}
            else
              case Muse.Conductor.can_handoff_to?(current_muse, target_muse_id, session) do
                true ->
                  target_muse = Muse.MuseRegistry.get(target_muse_id)

                  # 1. Call Conductor.request_handoff to get the event spec
                  #    (reason and context are redacted by Conductor)
                  case Muse.Conductor.request_handoff(current_muse, target_muse_id, session,
                         reason: "explicit user handoff",
                         context: %{source: "command"}
                       ) do
                    {:ok, _handoff_spec} ->
                      # 2. Complete the handoff via Conductor
                      case Muse.Conductor.complete_handoff(session, target_muse_id) do
                        {:ok, _updated_session} ->
                          # 3. Persist the active_muse change on the SessionServer
                          target_muse_str = Atom.to_string(target_muse_id)
                          Muse.SessionRouter.set_active_muse(session_id, target_muse_str)

                          output =
                            "Handoff completed: #{current_muse.display_name} → #{target_muse.display_name}.\n" <>
                              "Next message will route to #{target_muse.display_name}."

                          {:ok, output, [{:refresh, :session}]}

                        {:error, reason} ->
                          {:error, "Error completing handoff: #{inspect(reason)}", []}
                      end

                    {:error, reason} ->
                      {:error, "Error requesting handoff: #{inspect(reason)}", []}
                  end

                false ->
                  {:error,
                   "Error: #{current_muse.display_name} cannot hand off to #{target_muse_id}. Handoffs must be explicit and in the allowed targets list.",
                   []}
              end
            end

          {:error, :not_found} ->
            {:ok, "No active Muse session.", []}
        end
    end
  end

  # -- Checkpoint/Restoration commands -----------------------------------------

  def dispatch(:checkpoints, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /checkpoints", []}
    else
      session_id = context_session_id(context)

      case Muse.SessionRouter.status(session_id) do
        {:ok, %{checkpoints: checkpoints}} when is_list(checkpoints) and checkpoints != [] ->
          output = format_checkpoints(checkpoints)
          {:ok, output, []}

        {:ok, _} ->
          {:ok, "No checkpoints available for this session.", []}

        {:error, :not_found} ->
          {:ok, "No active Muse session.", []}
      end
    end
  end

  def dispatch(:restore, args, context) do
    case parse_restore_args(args) do
      {:error, :usage} ->
        {:error, "Error: usage: /restore <checkpoint_id>", []}

      {:ok, checkpoint_id} ->
        session_id = context_session_id(context)

        case Muse.SessionRouter.status(session_id) do
          {:ok, _} ->
            # Load checkpoint from store — this is a query-only, no file mutation
            case Muse.Checkpoint.Store.load(session_id, checkpoint_id) do
              {:ok, checkpoint} ->
                summary = Muse.Checkpoint.event_summary(checkpoint)

                output =
                  "Restore requested for checkpoint #{checkpoint_id}.\n" <>
                    "  Session: #{summary.session_id}\n" <>
                    "  Patch: #{summary.patch_id || "unknown"}\n" <>
                    "  Files affected: #{summary.file_count}\n" <>
                    "  Status: #{summary.status}\n" <>
                    "Restoration requires explicit approval before files are modified.\n" <>
                    "Use /approve restore to confirm."

                {:ok, output, [{:refresh, :session}]}

              {:error, reason} ->
                {:error,
                 "Error: checkpoint #{checkpoint_id} not found or could not be loaded: #{inspect(reason)}",
                 []}
            end

          {:error, :not_found} ->
            {:ok, "No active Muse session.", []}
        end
    end
  end

  # -- Catch-all ---------------------------------------------------------------

  def dispatch(action, _args, _context) do
    {:error, "Unknown command action: #{inspect(action)}. Type /help for available commands.", []}
  end

  # -- Prompt preview bundle builder -------------------------------------------

  @static_blocked_tools ["shell_command", "network_call", "patch_apply", "delete_file"]

  defp build_preview_bundle(args, context) do
    workspace = Map.get(context, :workspace) || Backend.safe_workspace_root()

    # Resolve the active Muse profile — default to Planning Muse
    muse_id = Map.get(context, :active_muse, :planning)

    muse_profile =
      case Muse.MuseRegistry.get(muse_id) do
        %Muse.MuseProfile{} = p -> p
        nil -> Muse.MuseRegistry.get(:planning)
      end

    # Minimal session for the assembler — sparse context is safe
    session =
      Muse.Session.new(
        workspace: workspace,
        id: Map.get(context, :session_id, "preview"),
        status: :idle
      )

    # User text: prefer args, fall back to current_text from context
    user_message = args || Map.get(context, :current_text, "")

    # Assembler opts — sparse-safe, each key is optional
    assembler_opts =
      [
        model: Map.get(context, :model),
        blocked_tools: @static_blocked_tools,
        project_rules?: Map.get(context, :project_rules?, true),
        project_rules_home: Map.get(context, :project_rules_home)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Muse.Prompt.Assembler.build(session, muse_profile, user_message, assembler_opts)
  end

  # -- Muse profile resolution -------------------------------------------------

  defp resolve_muse_profiles(context) do
    # 1. Try MuseRegistry (PR04 core module)
    with {:module, Muse.MuseRegistry} <- Code.ensure_loaded(Muse.MuseRegistry),
         true <- function_exported?(Muse.MuseRegistry, :summaries, 0) do
      Muse.MuseRegistry.summaries()
    else
      _ ->
        # 2. Fall back to runtime agent_snapshot from context
        case Map.get(context, :agent_snapshot, :unavailable) do
          %{agents: agents} when is_list(agents) and agents != [] ->
            Enum.map(agents, fn a ->
              %{
                id: a[:id] || a[:name],
                display_name: a[:name] || to_string(a[:id] || "?"),
                role: a[:kind],
                description: Map.get(a, :task, "")
              }
            end)

          _ ->
            # 3. Static fallback — canonical PR04 Muses
            [
              %{
                id: :planning,
                display_name: "Planning Muse",
                role: :planning,
                description: "Inspects the workspace, creates approval-gated plans"
              },
              %{
                id: :coding,
                display_name: "Coding Muse",
                role: :coding,
                description: "Implements approved changes via patches"
              }
            ]
        end
    end
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
      inspect(Muse.EventDisplay.safe_data(event.data))
    ]

    searchable = searchable_parts |> Enum.join(" ") |> String.downcase()
    String.contains?(searchable, query)
  end

  defp event_display_text(%Muse.Event{} = event), do: Muse.EventDisplay.summary(event)

  defp event_to_map(%Muse.Event{} = event) do
    %{
      "id" => event.id,
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "source" => Atom.to_string(event.source),
      "type" => Atom.to_string(event.type),
      "data" => event.data |> Muse.EventDisplay.safe_data() |> json_safe()
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

  # -- Plan lifecycle ----------------------------------------------------------

  defp dispatch_plan_lifecycle_command(action, args, context) do
    if present_args?(args) do
      {:error, no_args_usage_error(plan_lifecycle_usage(action), args), []}
    else
      session_id = context_session_id(context)
      source = context_source(context)

      action
      |> call_plan_lifecycle_router(session_id, source)
      |> format_plan_lifecycle_result(action)
    end
  end

  defp call_plan_lifecycle_router(:approve_plan, session_id, source) do
    Muse.SessionRouter.approve_plan(session_id, source)
  end

  defp call_plan_lifecycle_router(:reject_plan, session_id, source) do
    Muse.SessionRouter.reject_plan(session_id, source)
  end

  defp format_plan_lifecycle_result({:ok, %Muse.Plan{} = plan}, :approve_plan) do
    {:ok, Muse.ApprovalAudit.approval_message(plan), [{:refresh, :events}, {:refresh, :session}]}
  end

  defp format_plan_lifecycle_result({:ok, %Muse.Plan{} = plan}, :reject_plan) do
    {:ok, Muse.ApprovalAudit.rejection_message(plan), [{:refresh, :events}, {:refresh, :session}]}
  end

  defp format_plan_lifecycle_result({:error, :turn_running}, action) do
    verb = plan_lifecycle_verb(action)

    {:error, "Error: cannot #{verb} a plan while a turn is running.", []}
  end

  defp format_plan_lifecycle_result({:error, reason}, _action)
       when reason in [:not_found, :no_active_plan] do
    {:error, "Error: no Muse Plan is awaiting approval.", []}
  end

  defp format_plan_lifecycle_result(
         {:error, {:plan_not_awaiting_approval, status}},
         _action
       ) do
    {:error, "Error: active Muse Plan is #{status}, not awaiting approval.", []}
  end

  defp format_plan_lifecycle_result({:error, reason}, _action) do
    {:error, "Error: unable to update Muse Plan (#{safe_plan_lifecycle_reason(reason)}).", []}
  end

  defp present_args?(nil), do: false
  defp present_args?(args) when is_binary(args), do: String.trim(args) != ""
  defp present_args?(_args), do: true

  defp plan_lifecycle_usage(:approve_plan), do: "/approve plan"
  defp plan_lifecycle_usage(:reject_plan), do: "/reject plan"

  defp plan_lifecycle_verb(:approve_plan), do: "approve"
  defp plan_lifecycle_verb(:reject_plan), do: "reject"

  defp no_args_usage_error(usage, args) do
    unexpected =
      args
      |> safe_to_string()
      |> String.trim()

    if unexpected == "" do
      "Error: usage: #{usage}"
    else
      "Error: usage: #{usage} (no arguments). Unexpected arguments: #{unexpected}"
    end
  end

  defp safe_plan_lifecycle_reason(%Muse.Plan{} = plan) do
    "plan #{Muse.PlanHistory.display_plan_id(plan)} status #{plan.status}"
  end

  defp safe_plan_lifecycle_reason({tag, %Muse.Plan{} = plan}) when is_atom(tag) do
    "#{tag}: plan #{Muse.PlanHistory.display_plan_id(plan)} status #{plan.status}"
  end

  defp safe_plan_lifecycle_reason({tag, status}) when is_atom(tag) and is_atom(status) do
    "#{tag}: #{status}"
  end

  defp safe_plan_lifecycle_reason({:stale_approval, details}) when is_map(details) do
    approval_id = Map.get(details, :approval_id) || Map.get(details, "approval_id") || "unknown"
    "stale approval #{approval_id}: plan binding changed"
  end

  defp safe_plan_lifecycle_reason({:stale_content, _details}),
    do: "stale approval: plan content changed"

  defp safe_plan_lifecycle_reason({:expired, _details}), do: "expired approval binding"
  defp safe_plan_lifecycle_reason({:wrong_session, _details}), do: "wrong approval session"
  defp safe_plan_lifecycle_reason({:wrong_workspace, _details}), do: "wrong approval workspace"
  defp safe_plan_lifecycle_reason(:approval_expired), do: "expired approval"
  defp safe_plan_lifecycle_reason(:no_approval_binding), do: "missing approval binding"

  defp safe_plan_lifecycle_reason(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp safe_plan_lifecycle_reason(binary) when is_binary(binary) do
    Muse.Prompt.Redactor.preview_text(binary, max_length: 120)
  end

  defp safe_plan_lifecycle_reason(_reason), do: "unexpected approval error"

  # -- Patch lifecycle ---------------------------------------------------------

  defp dispatch_patch_lifecycle_command(action, args, context) do
    if present_args?(args) do
      {:error, no_args_usage_error(patch_lifecycle_usage(action), args), []}
    else
      session_id = context_session_id(context)
      source = context_source(context)

      action
      |> call_patch_lifecycle_router(session_id, source)
      |> format_patch_lifecycle_result(action)
    end
  end

  defp call_patch_lifecycle_router(:approve_patch, session_id, source) do
    Muse.SessionRouter.approve_patch(session_id, source)
  end

  defp call_patch_lifecycle_router(:reject_patch, session_id, source) do
    Muse.SessionRouter.reject_patch(session_id, source)
  end

  defp format_patch_lifecycle_result({:ok, patch}, :approve_patch) do
    {:ok, format_patch_approval_message(patch), [{:refresh, :events}, {:refresh, :session}]}
  end

  defp format_patch_lifecycle_result({:ok, patch}, :reject_patch) do
    {:ok, format_patch_rejection_message(patch), [{:refresh, :events}, {:refresh, :session}]}
  end

  defp format_patch_lifecycle_result({:error, :turn_running}, action) do
    verb = patch_lifecycle_verb(action)
    {:error, "Error: cannot #{verb} a patch while a turn is running.", []}
  end

  defp format_patch_lifecycle_result({:error, reason}, _action)
       when reason in [:not_found, :no_session, :no_pending_patch] do
    {:error, "Error: no pending patch proposal is awaiting approval.", []}
  end

  defp format_patch_lifecycle_result({:error, {:patch_not_awaiting_approval, status}}, _action) do
    {:error, "Error: pending patch proposal status is #{status}, not awaiting approval.", []}
  end

  defp format_patch_lifecycle_result({:error, reason}, _action) do
    {:error, "Error: unable to process patch approval (#{safe_patch_lifecycle_reason(reason)}).",
     []}
  end

  defp format_patch_approval_message(patch) do
    patch_id = Map.get(patch, :patch_id, Map.get(patch, :id, "unknown"))
    patch_hash = Map.get(patch, :hash, Map.get(patch, :content_hash, "n/a"))
    plan_id = Map.get(patch, :plan_id, "n/a")

    [
      "Patch proposal approved.",
      "",
      "- Patch id: #{patch_id}",
      "- Patch hash: #{patch_hash}",
      "- Plan id: #{plan_id}",
      "- Approval status: approved",
      "- PR18: approval recorded; use /apply patch to apply the approved patch with checkpoint protection."
    ]
    |> Enum.join("\n")
  end

  defp format_patch_rejection_message(patch) do
    patch_id = Map.get(patch, :patch_id, Map.get(patch, :id, "unknown"))
    patch_hash = Map.get(patch, :hash, Map.get(patch, :content_hash, "n/a"))
    plan_id = Map.get(patch, :plan_id, "n/a")

    [
      "Patch proposal rejected.",
      "",
      "- Patch id: #{patch_id}",
      "- Patch hash: #{patch_hash}",
      "- Plan id: #{plan_id}",
      "- Rejection status: rejected",
      "- PR17: rejection recorded the decision only; no files were modified and no rollback is needed.",
      "- Next: ask Coding Muse for a revised patch proposal."
    ]
    |> Enum.join("\n")
  end

  defp patch_lifecycle_usage(:approve_patch), do: "/approve patch"
  defp patch_lifecycle_usage(:reject_patch), do: "/reject patch"

  defp patch_lifecycle_verb(:approve_patch), do: "approve"
  defp patch_lifecycle_verb(:reject_patch), do: "reject"

  defp safe_patch_lifecycle_reason(%_{} = patch) do
    id = Map.get(patch, :patch_id, Map.get(patch, :id, "?"))
    status = Map.get(patch, :status, "?")
    "patch #{id} status #{status}"
  end

  defp safe_patch_lifecycle_reason({tag, patch}) when is_atom(tag) and is_map(patch) do
    id = Map.get(patch, :patch_id, Map.get(patch, :id, "?"))
    "#{tag}: patch #{id}"
  end

  defp safe_patch_lifecycle_reason(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_patch_lifecycle_reason(binary) when is_binary(binary), do: binary
  defp safe_patch_lifecycle_reason(_reason), do: "unexpected patch approval error"

  # -- Remote execution lifecycle (Phase B) -------------------------------------

  defp dispatch_remote_lifecycle_command(action, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /#{remote_lifecycle_verb(action)} remote", []}
    else
      session_id = context_session_id(context)
      source = context_source(context)

      action
      |> call_remote_lifecycle_router(session_id, source)
      |> format_remote_lifecycle_result(action)
    end
  end

  defp call_remote_lifecycle_router(:approve_remote, session_id, source) do
    Muse.SessionRouter.approve_remote(session_id, source)
  end

  defp call_remote_lifecycle_router(:reject_remote, session_id, source) do
    Muse.SessionRouter.reject_remote(session_id, source)
  end

  defp format_remote_lifecycle_result({:ok, %Muse.Approval{} = approval}, :approve_remote) do
    msg =
      "Remote execution approved (audit-only, no execution granted).\n" <>
        "  Approval: #{approval.id}\n" <>
        "  Target: #{approval.target_id || "unknown"}\n" <>
        "  Command hash: #{approval.command_hash || "unknown"}"

    {:ok, msg, [{:refresh, :events}, {:refresh, :session}]}
  end

  defp format_remote_lifecycle_result({:ok, %Muse.Approval{} = approval}, :reject_remote) do
    msg =
      "Remote execution rejected.\n" <>
        "  Approval: #{approval.id}\n" <>
        "  Target: #{approval.target_id || "unknown"}"

    {:ok, msg, [{:refresh, :events}, {:refresh, :session}]}
  end

  defp format_remote_lifecycle_result({:error, :turn_running}, action) do
    verb = remote_lifecycle_verb(action)
    {:error, "Error: cannot #{verb} remote execution while a turn is running.", []}
  end

  defp format_remote_lifecycle_result({:error, reason}, _action)
       when reason in [:not_found, :no_pending_remote_approval] do
    {:error, "Error: no pending remote execution approval is awaiting decision.", []}
  end

  defp format_remote_lifecycle_result({:error, :pending_remote_approval_exists}, _action) do
    {:error, "Error: a pending remote execution approval already exists. Reject it first.", []}
  end

  defp format_remote_lifecycle_result({:error, {:invalid_transition, status, _target}}, _action) do
    {:error, "Error: remote approval status is #{status}, not pending.", []}
  end

  defp format_remote_lifecycle_result({:error, :approval_expired}, _action) do
    {:error, "Error: remote execution approval has expired.", []}
  end

  defp format_remote_lifecycle_result({:error, {:missing_field, field}}, _action) do
    {:error, "Error: remote execution request missing required field: #{field}.", []}
  end

  defp format_remote_lifecycle_result({:error, reason}, _action) do
    {:error, "Error: remote approval failed: #{inspect(reason)}.", []}
  end

  defp remote_lifecycle_verb(:approve_remote), do: "approve"
  defp remote_lifecycle_verb(:reject_remote), do: "reject"

  defp context_session_id(context) do
    case map_get_any(context, [:session_id, "session_id"]) do
      nil -> "default"
      session_id -> to_string(session_id)
    end
  end

  defp context_source(context) do
    case map_get_any(context, [:source, "source"]) do
      source when is_atom(source) -> source
      _ -> :system
    end
  end

  # -- Session status formatting ------------------------------------------------

  defp format_session_status(status) when is_map(status) do
    session_id = Map.get(status, :session_id, "default")
    session_status = Map.get(status, :status, :idle)
    active_muse = Map.get(status, :active_muse)
    active_plan_id = Map.get(status, :active_plan_id)
    plan = Map.get(status, :plan)
    pending_patch = Map.get(status, :pending_patch)
    active_turn_id = Map.get(status, :active_turn_id)
    event_count = Map.get(status, :event_count, 0)

    lines = [
      "Muse Session: #{session_id}",
      "Status: #{format_session_state(session_status)}"
    ]

    lines =
      if active_muse do
        lines ++ ["Active Muse: #{active_muse}"]
      else
        lines
      end

    lines =
      if active_turn_id do
        lines ++ ["Turn: #{active_turn_id}"]
      else
        lines
      end

    lines =
      case plan do
        %Muse.Plan{} = p ->
          plan_line =
            "Active plan: #{Muse.PlanHistory.display_plan_id(p)} (v#{p.version}, #{p.status})"

          lines ++ [plan_line]

        %{"id" => id, "version" => v, "status" => s} ->
          lines ++ ["Active plan: #{id} (v#{v}, #{s})"]

        _ ->
          if active_plan_id do
            lines ++ ["Active plan: #{active_plan_id}"]
          else
            lines
          end
      end

    lines =
      case pending_patch do
        %Muse.Patch{} = patch ->
          lines ++ ["Pending patch: #{patch.id} (#{patch.status})"]

        %{"id" => id, "status" => s} ->
          lines ++ ["Pending patch: #{id} (#{s})"]

        _ ->
          lines
      end

    pending_remote_approval = Map.get(status, :pending_remote_approval)

    lines =
      case pending_remote_approval do
        %Muse.Approval{} = approval ->
          lines ++
            ["Pending remote approval: #{approval.target_id || "?"} " <>
               "(#{approval.command_hash || "?"}, expires: #{format_remote_expiry(approval)})"]

        %{"target_id" => tid, "command_hash" => ch} ->
          lines ++ ["Pending remote approval: #{tid} (#{ch})"]

        _ ->
          lines
      end

    lines ++ ["Events: #{event_count}"]
  end

  defp format_session_state(status) when is_atom(status), do: Atom.to_string(status)
  defp format_session_state(status), do: to_string(status)

  defp format_remote_expiry(%Muse.Approval{expires_at: %DateTime{} = dt}),
    do: DateTime.to_iso8601(dt)

  defp format_remote_expiry(%{"expires_at" => dt}) when is_binary(dt), do: dt
  defp format_remote_expiry(_), do: "unknown"

  defp render_plan_with_identity(%Muse.Plan{} = plan) do
    plan_show_heading(plan) <> "\n\n" <> Muse.Plan.render(plan)
  end

  defp plan_show_heading(%Muse.Plan{} = plan) do
    "Muse Plan #{Muse.PlanHistory.display_plan_id(plan)} (version #{plan.version})"
  end

  # -- Read-only plan command helpers -----------------------------------------

  defp dispatch_plan_history(args, context, usage) do
    if present_args?(args) do
      {:error, "Error: usage: #{usage}", []}
    else
      query = Muse.PlanHistory.query(context)

      case query.plans do
        [] ->
          {:ok, "No Muse Plan history is available yet. Ask Planning Muse to create a Muse Plan.",
           []}

        plans ->
          {:ok, Muse.PlanHistory.render_history(plans, query.active_plan_id), []}
      end
    end
  end

  defp parse_plan_show_args(args) when is_binary(args) do
    case String.split(String.trim(args), ~r/\s+/, trim: true) do
      [id] -> {:ok, id}
      _ -> :usage
    end
  end

  defp parse_plan_show_args(_args), do: :usage

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp map_get_any(_map, _keys), do: nil

  # -- PR18: Apply patch command -------------------------------------------------

  defp dispatch_apply_patch_command(args, context) do
    session_id = context_session_id(context)

    # Optional: extract patch_id from args
    patch_id = parse_patch_id_arg(args)

    case Muse.SessionRouter.apply_patch(session_id, patch_id) do
      {:ok, result} ->
        message = format_apply_patch_result(result)
        {:ok, message, [{:refresh, :events}, {:refresh, :session}]}

      {:error, reason} ->
        {:error, format_apply_patch_error(reason), []}
    end
  end

  defp parse_patch_id_arg(nil), do: nil
  defp parse_patch_id_arg(""), do: nil

  defp parse_patch_id_arg(args) when is_binary(args) do
    String.trim(args)
  end

  defp parse_patch_id_arg(_), do: nil

  defp format_apply_patch_result(result) do
    checkpoint_id = Map.get(result, :checkpoint_id, "unknown")
    patch_id = Map.get(result, :patch_id, Map.get(result, "patch_id", "unknown"))
    patch_hash = Map.get(result, :patch_hash, Map.get(result, "patch_hash", "n/a"))
    affected = Map.get(result, :affected_files, Map.get(result, "affected_files", []))
    diff_preview = Map.get(result, :git_diff_preview, Map.get(result, "git_diff_preview", ""))

    lines = [
      "Patch applied successfully.",
      "",
      "- Checkpoint id: #{checkpoint_id}",
      "- Patch id: #{patch_id}",
      "- Patch hash: #{patch_hash}",
      "- Affected files: #{Enum.join(affected, ", ")}",
      "- Status: applied",
      "- Use /rollback checkpoint #{checkpoint_id} to restore if needed"
    ]

    lines =
      if is_binary(diff_preview) and diff_preview != "" do
        lines ++ ["", "Post-apply diff stat:", diff_preview]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp format_apply_patch_error(:not_found), do: "Error: session not found"

  defp format_apply_patch_error(:turn_running),
    do: "Error: cannot apply patch while a turn is running"

  defp format_apply_patch_error(:no_approved_patch),
    do: "Error: no approved patch is available to apply"

  defp format_apply_patch_error(:no_active_plan),
    do: "Error: no active approved plan for this session"

  defp format_apply_patch_error(:apply_failed),
    do: "Error: patch apply failed; checkpoint preserved for rollback"

  defp format_apply_patch_error(reason) when is_binary(reason), do: "Error: #{reason}"
  defp format_apply_patch_error(reason), do: "Error: unable to apply patch (#{inspect(reason)})"

  # -- PR18: Rollback checkpoint command ----------------------------------------

  defp dispatch_rollback_checkpoint_command(args, context) do
    session_id = context_session_id(context)

    case parse_checkpoint_id_arg(args) do
      {:ok, checkpoint_id} ->
        case Muse.SessionRouter.rollback_checkpoint(session_id, checkpoint_id) do
          {:ok, result} ->
            message = format_rollback_result(result)
            {:ok, message, [{:refresh, :events}, {:refresh, :session}]}

          {:error, reason} ->
            {:error, format_rollback_error(reason), []}
        end

      :missing ->
        {:error, "Error: usage: /rollback checkpoint <checkpoint_id>", []}
    end
  end

  defp parse_checkpoint_id_arg(nil), do: :missing
  defp parse_checkpoint_id_arg(""), do: :missing

  defp parse_checkpoint_id_arg(args) when is_binary(args) do
    id = String.trim(args)
    if id != "", do: {:ok, id}, else: :missing
  end

  defp parse_checkpoint_id_arg(_), do: :missing

  defp format_rollback_result(result) do
    checkpoint_id = Map.get(result, :checkpoint_id, Map.get(result, "checkpoint_id", "unknown"))
    patch_id = Map.get(result, :patch_id, Map.get(result, "patch_id", "unknown"))
    affected = Map.get(result, :affected_files, Map.get(result, "affected_files", []))
    file_count = Map.get(result, :file_count, Map.get(result, "file_count", length(affected)))

    [
      "Checkpoint rolled back successfully.",
      "",
      "- Checkpoint id: #{checkpoint_id}",
      "- Patch id: #{patch_id}",
      "- Files restored: #{file_count}",
      "- Status: rolled_back"
    ]
    |> Enum.join("\n")
  end

  defp format_rollback_error(:not_found), do: "Error: session not found"
  defp format_rollback_error(:turn_running), do: "Error: cannot rollback while a turn is running"
  defp format_rollback_error(reason) when is_binary(reason), do: "Error: #{reason}"

  defp format_rollback_error(reason),
    do: "Error: unable to rollback checkpoint (#{inspect(reason)})"

  # -- Memory helpers ----------------------------------------------------------

  defp format_memory(memory) when is_map(memory) do
    # Memory.render/1 redacts secrets by default; additionally wrap in
    # rescue for malformed structures that might crash rendering.
    # muse-zgm: Do NOT include Exception.message(e) in user-visible output
    # to avoid leaking raw terms from malformed memory.
    Muse.Memory.render(memory)
  rescue
    _ ->
      # Generic withheld message; do not expose exception details
      "Memory display unavailable (render error). " <>
        "Stored memory may contain unsafe data and has been withheld."
  end

  defp format_memory(_), do: "No memory available."

  defp format_memory_safely(memory) when is_binary(memory) do
    # Redact binary memory through full pipeline before display.
    memory
    |> Muse.EventPayloadRedactor.redact_string()
    |> Muse.Prompt.Redactor.redact_text()
  rescue
    _ -> "Memory display unavailable (redaction error). Content withheld."
  end

  defp format_memory_safely(memory) do
    # Non-map, non-binary memory (lists, tuples, etc.) — apply structural
    # redaction first to catch sensitive-key values in nested terms, then
    # convert to string and apply string-level pattern redaction.
    memory
    |> Muse.EventPayloadRedactor.redact()
    |> Muse.Prompt.Redactor.redact_term()
    |> inspect(limit: 20, printable_limit: 500)
    |> Muse.EventPayloadRedactor.redact_string()
    |> Muse.Prompt.Redactor.redact_text()
  rescue
    _ -> "Memory display unavailable (render error). Content withheld."
  end

  defp build_session_from_status(status) when is_map(status) do
    Muse.Session.new(
      workspace: Map.get(status, :workspace) || Map.get(status, "workspace", "/tmp"),
      id: Map.get(status, :id) || Map.get(status, "session_id"),
      status: Map.get(status, :status) || Map.get(status, "status", :idle),
      active_plan_id: Map.get(status, :active_plan_id) || Map.get(status, "active_plan_id"),
      active_muse: Map.get(status, :active_muse) || Map.get(status, "active_muse"),
      plans: Map.get(status, :plans) || Map.get(status, "plans", %{}),
      approvals: Map.get(status, :approvals) || Map.get(status, "approvals", []),
      checkpoints: Map.get(status, :checkpoints) || Map.get(status, "checkpoints", []),
      artifacts: Map.get(status, :artifacts) || Map.get(status, "artifacts", [])
    )
  end

  defp build_session_from_status(_), do: Muse.Session.new(workspace: "/tmp")

  # -- Handoff helpers ---------------------------------------------------------

  defp parse_handoff_args(nil), do: {:error, :usage}
  defp parse_handoff_args(""), do: {:error, :usage}

  defp parse_handoff_args(args) when is_binary(args) do
    muse_id_str = String.trim(args)

    if muse_id_str == "" do
      {:error, :usage}
    else
      # Security: resolve via registry only — never String.to_atom on user input.
      # Muse.MuseRegistry.fetch/1 uses String.to_existing_atom/1 internally,
      # so unknown targets cannot create new atoms in the BEAM atom table.
      case Muse.MuseRegistry.fetch(muse_id_str) do
        {:ok, profile} -> {:ok, profile.id}
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  defp parse_handoff_args(_), do: {:error, :usage}

  # -- Checkpoint/restore helpers ----------------------------------------------

  defp format_checkpoints(checkpoints) when is_list(checkpoints) do
    if checkpoints == [] do
      "No checkpoints available."
    else
      lines = ["Available checkpoints:"]

      lines =
        lines ++
          Enum.map(checkpoints, fn checkpoint ->
            id = Map.get(checkpoint, :id) || Map.get(checkpoint, "id", "unknown")
            status = Map.get(checkpoint, :status) || Map.get(checkpoint, "status", "unknown")
            created = Map.get(checkpoint, :created_at) || Map.get(checkpoint, "created_at")

            created_str =
              case created do
                %DateTime{} = dt -> DateTime.to_iso8601(dt)
                s when is_binary(s) -> s
                _ -> "unknown"
              end

            "  - #{id}: #{status} (created: #{created_str})"
          end)

      Enum.join(lines, "\n")
    end
  end

  defp format_checkpoints(_), do: "No checkpoints available."

  defp parse_restore_args(nil), do: {:error, :usage}
  defp parse_restore_args(""), do: {:error, :usage}

  defp parse_restore_args(args) when is_binary(args) do
    checkpoint_id = String.trim(args)
    if checkpoint_id != "", do: {:ok, checkpoint_id}, else: {:error, :usage}
  end

  defp parse_restore_args(_), do: {:error, :usage}
end
