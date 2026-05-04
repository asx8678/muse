defmodule Muse.SessionServer do
  @moduledoc """
  Per-session `GenServer` that owns session state and handles synchronous
  operations (`submit`, `status`).

  ## Lifecycle

  Started by `Muse.SessionRouter` via `DynamicSupervisor.start_child/2`.
  `start_link/1` uses a `{:via, Registry, ...}` name so registration in
  `Muse.SessionRegistry` is atomic and concurrent starts for the same
  session id resolve to the same process.

  ## Responsibility scope

  This server currently runs `Conductor.run/3` **synchronously** inside
  `handle_call({:submit, ...})`, which means the GenServer is blocked for
  the duration of the provider call. `status` queries will **not** be
  answered until the turn completes.

  **TODO (PR07b):** Introduce a `Muse.Conductor.TurnRunner` Task that
  moves `Conductor.run/3` *outside* the GenServer process. This will
  restore responsiveness for `status` queries during a turn and provide
  crash isolation — a provider error will terminate the Task, not the
  SessionServer.

  For now, the server appends user/assistant events to the global
  `Muse.State` log and returns `{:ok, assistant_text}` synchronously.
  """

  use GenServer, restart: :temporary

  alias Muse.{Conductor, Event, Prompt.Redactor, Session, State, Turn}

  # -- Public API ---------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    # Use :via tuple for atomic registration — if another process already
    # registered this session_id, start_link returns
    # {:error, {:already_started, pid}} deterministically.
    GenServer.start_link(__MODULE__, session_id,
      name: {:via, Registry, {Muse.SessionRegistry, session_id}}
    )
  end

  @doc """
  Submits a user message to the session identified by `pid`.

  Returns `{:ok, assistant_text}` — the same shape as `Muse.submit/2`.
  """
  @spec submit(pid(), atom(), String.t()) :: {:ok, String.t()}
  def submit(pid, source, text) do
    GenServer.call(pid, {:submit, source, text})
  end

  @doc """
  Returns the current session status map.
  """
  @spec status(pid()) :: map()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(session_id) do
    # Registration is handled atomically by the :via tuple in start_link.
    # If we reach init, the name was successfully registered.
    # `seq` is a session-local monotonic counter starting at 0; each
    # emitted event increments it, so the first event gets seq=1.
    {:ok, %{session_id: session_id, status: :idle, seq: 0, events: [], active_muse: nil}}
  end

  @impl true
  def handle_call({:submit, source, text}, _from, state) do
    turn_start_time = System.monotonic_time(:millisecond)
    turn_id = generate_turn_id()

    # Build a Turn struct for this submission
    turn =
      Turn.new(
        session_id: state.session_id,
        id: turn_id,
        source: source,
        user_text: text
      )

    # 1. Emit user message event with session metadata
    {user_event, state} =
      emit_session_event(state, source, :user_message, %{text: text},
        turn_id: turn_id,
        visibility: :user
      )

    session_events = [user_event]

    # Atomically claim queued self-healing issues
    claimed_issues = safe_claim_queued()

    {self_healing_event, state} =
      if claimed_issues != [] do
        {evt, s} =
          emit_session_event(
            state,
            :self_healing,
            :queued_issues_attached,
            build_self_healing_data(claimed_issues),
            turn_id: turn_id,
            visibility: :debug
          )

        {evt, s}
      else
        {nil, state}
      end

    session_events =
      if self_healing_event, do: session_events ++ [self_healing_event], else: session_events

    # 2. Emit turn_started (internal visibility)
    turn_summary = %{
      source: source,
      user_text_length: String.length(text)
    }

    {turn_started_event, state} =
      emit_session_event(state, source, :turn_started, turn_summary,
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [turn_started_event]

    # Transition turn to running
    {:ok, turn} = Turn.transition(turn, :running)

    # 3. Delegate assistant generation to Conductor
    session = Session.new(id: state.session_id, workspace: get_workspace(), status: state.status)

    {assistant_text, state, session_events} =
      case Conductor.run(session, turn) do
        {:ok, result} ->
          # Fold Conductor event specs through emit_session_event
          {conductor_events, state} = emit_event_specs(state, result.event_specs, turn_id)
          session_events = session_events ++ conductor_events

          state = %{state | status: :idle, active_muse: Atom.to_string(result.selected_muse.id)}

          {result.assistant_text, state, session_events}

        {:error, %{event_specs: event_specs}} ->
          # Fold partial event specs collected before the error
          {conductor_events, state} = emit_event_specs(state, event_specs, turn_id)
          session_events = session_events ++ conductor_events

          # Emit a user-visible assistant_message so CLI/State consumers
          # see the failure in the event stream (not just the return value).
          error_text = "Error: provider error occurred"

          {error_event, state} =
            emit_session_event(
              state,
              :system,
              :assistant_message,
              %{text: error_text, streamed?: false},
              turn_id: turn_id,
              visibility: :user
            )

          session_events = session_events ++ [error_event]
          state = %{state | status: :idle}

          {error_text, state, session_events}
      end

    # 4. Emit turn_completed
    delta_count = Enum.count(session_events, &(&1.type == :assistant_delta))
    duration_ms = System.monotonic_time(:millisecond) - turn_start_time

    turn_completed_data = %{
      streamed?: true,
      delta_count: delta_count,
      duration_ms: duration_ms
    }

    {turn_completed_event, state} =
      emit_session_event(state, source, :turn_completed, turn_completed_data,
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [turn_completed_event]

    updated_events = state.events ++ session_events
    {:reply, {:ok, assistant_text}, %{state | events: updated_events}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      session_id: state.session_id,
      status: state.status,
      active_muse: state.active_muse,
      seq: state.seq,
      event_count: length(state.events)
    }

    {:reply, reply, state}
  end

  # -- Private helpers ----------------------------------------------------------

  defp safe_append_state(event) do
    case Process.whereis(Muse.State) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: State.append(event), else: :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp get_workspace do
    case Process.whereis(Muse.Workspace) do
      nil -> default_workspace()
      pid -> if Process.alive?(pid), do: Muse.Workspace.root(), else: default_workspace()
    end
  rescue
    _ -> default_workspace()
  end

  defp default_workspace, do: "/tmp/muse_workspace"

  defp normalize_muse_id(nil), do: nil
  defp normalize_muse_id(muse_id) when is_atom(muse_id), do: Atom.to_string(muse_id)
  defp normalize_muse_id(muse_id) when is_binary(muse_id), do: muse_id

  defp emit_event_specs(state, event_specs, turn_id) do
    {events_rev, final_state} =
      Enum.reduce(event_specs, {[], state}, fn {source, type, data, opts}, {acc, s} ->
        merged_opts = Keyword.put(opts, :turn_id, turn_id)
        {event, new_state} = emit_session_event(s, source, type, data, merged_opts)
        {[event | acc], new_state}
      end)

    {Enum.reverse(events_rev), final_state}
  end

  defp safe_claim_queued do
    case Process.whereis(Muse.SelfHealingQueue) do
      nil -> []
      pid -> if Process.alive?(pid), do: Muse.SelfHealingQueue.claim_queued(), else: []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_self_healing_data(issues) do
    sanitized =
      Enum.map(issues, fn issue ->
        %{
          id: issue.id,
          diagnostic_id: issue.diagnostic_id,
          level: issue.level,
          message: issue.message,
          source: issue.source
        }
      end)

    %{issues: sanitized}
  end

  @doc false
  # Emits an event with session-scoped metadata and increments the seq counter.
  # Data is redacted centrally via `Muse.Prompt.Redactor.redact_term/1` before
  # event creation so no secret values can leak into the event stream.
  # Returns `{event, updated_state}` so the caller can track the event.
  @spec emit_session_event(map(), atom(), atom(), map(), keyword()) :: {Event.t(), map()}
  def emit_session_event(state, source, type, data, opts) do
    seq = state.seq + 1

    # Central redaction: all event data passes through the prompt redactor
    # which applies EventPayloadRedactor plus prompt-specific patterns
    redacted_data = Redactor.redact_term(data)

    event =
      Event.new(source, type, redacted_data,
        session_id: state.session_id,
        turn_id: Keyword.get(opts, :turn_id),
        seq: seq,
        visibility: Keyword.get(opts, :visibility),
        muse_id: normalize_muse_id(Keyword.get(opts, :muse_id))
      )

    :ok = safe_append_state(event)

    {event, %{state | seq: seq}}
  end

  defp generate_turn_id do
    hex =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)

    "turn_#{hex}"
  end
end
