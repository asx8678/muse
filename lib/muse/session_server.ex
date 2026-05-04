defmodule Muse.SessionServer do
  @moduledoc """
  Per-session `GenServer` that owns session state and handles synchronous
  operations (`submit`, `status`, `cancel`).

  ## Lifecycle

  Started by `Muse.SessionRouter` via `DynamicSupervisor.start_child/2`.
  `start_link/1` uses a `{:via, Registry, ...}` name so registration in
  `Muse.SessionRegistry` is atomic and concurrent starts for the same
  session id resolve to the same process.

  ## Turn execution

  PR07b: Turn execution now runs via `Muse.Conductor.TurnRunner` as an
  async Task under `Muse.TaskSupervisor`. This keeps the GenServer
  responsive for `status` queries during long provider/tool-loop turns.

  When a submit arrives:
    1. User/self-heal/turn_started events are emitted synchronously
    2. State transitions to `:running`
    3. A TurnRunner Task is spawned
    4. `handle_call` returns `{:noreply, state}` — no blocking

  When the task completes:
    1. The task result is received as a message
    2. Event specs are folded through `emit_event_specs/3`
    3. `:turn_completed` is emitted
    4. The original caller is replied with `{:ok, assistant_text}`

  On error/crash:
    1. Partial events are preserved
    2. A safe `:assistant_message` is emitted
    3. `:turn_failed` is emitted
    4. The caller is replied with safe text or error

  On cancellation:
    1. A cancellation message is sent to the runner task
    2. `:turn_cancelled` and safe assistant message are emitted
    3. The caller is replied with `{:ok, "Turn cancelled."}`
  """

  use GenServer, restart: :temporary

  alias Muse.{ApprovalGate, Event, Prompt.Redactor, Session, State, Turn, Plan, SessionStore}
  alias Muse.Conductor.TurnRunner

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

  The actual turn execution happens asynchronously via TurnRunner.
  The caller blocks until the turn completes (or fails/is cancelled),
  but the GenServer itself remains responsive for `status` queries.
  """
  @spec submit(pid(), atom(), String.t(), keyword()) :: {:ok, String.t()}
  def submit(pid, source, text, opts \\ []) do
    GenServer.call(pid, {:submit, source, text, opts}, :infinity)
  end

  @doc """
  Returns the current status of the session server.
  """
  @spec status(pid()) :: map()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Cancels the currently running turn, if any.

  Returns `:ok` if a cancellation signal was sent, or `{:error, :no_active_turn}`
  if no turn is currently running.
  """
  @spec cancel(pid()) :: :ok | {:error, :no_active_turn}
  def cancel(pid) do
    GenServer.call(pid, :cancel)
  end

  @doc """
  Approves the active plan for later implementation.

  Approval is a lifecycle transition only: it records that the active plan is
  accepted and ready for a future implementation phase. It does not start turn
  execution, shell commands, file writes, or patch application.
  """
  @spec approve_plan(pid(), atom()) ::
          {:ok, Plan.t()}
          | {:error,
             :turn_running
             | :no_active_plan
             | {:plan_not_awaiting_approval, Plan.status()}
             | {:stale_approval, map()}}
  def approve_plan(pid, source \\ :system) do
    GenServer.call(pid, {:approve_plan, source})
  end

  @doc """
  Rejects the active plan.

  Rejection is safe and non-executing: it records that the current active plan
  was rejected so a revised plan can be requested.
  """
  @spec reject_plan(pid(), atom()) ::
          {:ok, Plan.t()}
          | {:error,
             :turn_running
             | :no_active_plan
             | {:plan_not_awaiting_approval, Plan.status()}
             | {:stale_approval, map()}}
  def reject_plan(pid, source \\ :system) do
    GenServer.call(pid, {:reject_plan, source})
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(session_id) do
    # Registration is handled atomically by the :via tuple in start_link.
    # If we reach init, the name was successfully registered.
    # `seq` is a session-local monotonic counter starting at 0; each
    # emitted event increments it, so the first event gets seq=1.
    initial = %{
      session_id: session_id,
      status: :idle,
      seq: 0,
      events: [],
      active_muse: nil,
      active_plan_id: nil,
      plan: nil,
      plans: %{},
      approvals: [],
      # TurnRunner state
      active_turn_id: nil,
      runner_pid: nil,
      runner_task: nil,
      from: nil,
      turn_start_time: nil,
      session_events_before_turn: [],
      cancellation_requested: false
    }

    # Attempt to restore plan from persisted snapshot (non-fatal on failure)
    state = restore_plan_from_snapshot(initial)
    {:ok, state}
  end

  @impl true
  def handle_call({:submit, source, text, opts}, from, state) do
    do_submit(source, text, opts, from, state)
  end

  # Backward-compatible 3-tuple form for callers using submit/3
  def handle_call({:submit, source, text}, from, state) do
    do_submit(source, text, [], from, state)
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      session_id: state.session_id,
      status: state.status,
      active_muse: state.active_muse,
      active_plan_id: state.active_plan_id,
      plan: state.plan,
      plans: state.plans,
      approvals: state.approvals,
      seq: state.seq,
      event_count: length(state.events),
      active_turn_id: state.active_turn_id,
      runner_pid: state.runner_pid,
      cancellation_requested: state.cancellation_requested
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    cond do
      state.status != :running or state.runner_pid == nil ->
        {:reply, {:error, :no_active_turn}, state}

      state.cancellation_requested ->
        {:reply, :ok, state}

      true ->
        TurnRunner.cancel(state.runner_pid, state.active_turn_id)
        {:reply, :ok, %{state | cancellation_requested: true}}
    end
  end

  @impl true
  def handle_call({:approve_plan, source}, _from, state) do
    {reply, state} = handle_plan_lifecycle_command(state, source, :approved)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:reject_plan, source}, _from, state) do
    {reply, state} = handle_plan_lifecycle_command(state, source, :rejected)
    {:reply, reply, state}
  end

  defp do_submit(source, text, opts, from, state) do
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

    # 3. Spawn TurnRunner task for async Conductor execution
    # Pass the pre-transition status (:idle) so the Conductor can emit
    # the correct session_status_changed event (idle → running). Tests may
    # provide a deterministic workspace/provider script through opts; default
    # callers keep the production-safe workspace and fake provider behavior.
    session = build_turn_session(state, opts)

    task = TurnRunner.async(session, turn, Keyword.delete(opts, :workspace))

    # Store the task ref and runner pid for result handling
    runner_pid = task.pid
    task_ref = task.ref

    # No extra Process.monitor needed — Task.Supervisor.async_nolink/2
    # already creates a monitor (ref) that sends {:DOWN, ref, :process, pid, reason}
    # on task exit. We handle both {ref, result} and {:DOWN, ref, ...} below.

    # Transition state to running
    state = %{
      state
      | status: :running,
        active_turn_id: turn_id,
        runner_pid: runner_pid,
        runner_task: task_ref,
        from: from,
        turn_start_time: turn_start_time,
        session_events_before_turn: session_events,
        cancellation_requested: false
    }

    {:noreply, state}
  end

  defp build_turn_session(state, opts) do
    %{
      Session.new(
        id: state.session_id,
        workspace: Keyword.get(opts, :workspace, get_workspace()),
        status: state.status
      )
      | active_muse: state.active_muse,
        active_plan_id: state.active_plan_id,
        plans: turn_session_plans(state),
        approvals: state.approvals
    }
  end

  defp turn_session_plans(%{plan: %Plan{} = plan} = state) do
    plan_id = plan.id || state.active_plan_id

    if plan_id do
      Map.put(state.plans || %{}, plan_id, plan)
    else
      state.plans || %{}
    end
  end

  defp turn_session_plans(state), do: state.plans || %{}

  # -- Task result handling ----------------------------------------------------

  @impl true
  def handle_info({ref, result}, state) when state.runner_task == ref do
    # Task completed normally — demonitor and flush the pending DOWN
    Process.demonitor(ref, [:flush])

    {_assistant_text, state} = handle_task_result(result, state)

    {:noreply, state}
  end

  # Task exited with :normal reason — the {ref, result} message was either
  # already handled (and demonitor flushed this DOWN) or will arrive next.
  # Safely ignore; the result handler will process it.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state)
      when state.runner_task == ref do
    {:noreply, state}
  end

  # Task crashed — no result message will arrive; handle the failure.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when state.runner_task == ref do
    {_assistant_text, state} = handle_task_crash(inspect(reason), state)
    {:noreply, state}
  end

  # Ignore task results for stale refs (e.g. after crash recovery)
  @impl true
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Ignore stale DOWN messages (for non-current tasks)
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Defensive: ignore stale custom-tagged monitor messages from prior
  # implementation that used Process.monitor(tag: {:runner_down, turn_id}).
  # Those messages have shape {{:runner_down, turn_id}, ref, :process, pid, reason}.
  @impl true
  def handle_info({{:runner_down, _}, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Ignore any other messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Task result handlers -----------------------------------------------------

  defp handle_task_result({:ok, result}, state) do
    turn_id = state.active_turn_id
    session_events = state.session_events_before_turn

    # Fold Conductor event specs through emit_session_event
    {conductor_events, state} = emit_event_specs(state, result.event_specs, turn_id)
    session_events = session_events ++ conductor_events

    # Use the session status from the Conductor result (may be :awaiting_plan_approval)
    session_status = result.session.status

    state = %{
      state
      | status: session_status,
        active_muse: Atom.to_string(result.selected_muse.id)
    }

    # Store plan if present in the result and expose its pending approval.
    state =
      if Map.has_key?(result, :plan) and not is_nil(result.plan) do
        state
        |> put_active_plan(result.plan, result.plan.id || state.active_plan_id)
        |> ensure_pending_plan_approval()
        |> maybe_persist_snapshot()
      else
        state
      end

    # Emit turn_completed
    delta_count = Enum.count(session_events, &(&1.type == :assistant_delta))
    duration_ms = System.monotonic_time(:millisecond) - state.turn_start_time

    turn_completed_data = %{
      streamed?: true,
      delta_count: delta_count,
      duration_ms: duration_ms
    }

    {turn_completed_event, state} =
      emit_session_event(state, :conductor, :turn_completed, turn_completed_data,
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [turn_completed_event]

    updated_events = state.events ++ session_events
    state = %{state | events: updated_events}

    # Reply to the original caller
    GenServer.reply(state.from, {:ok, result.assistant_text})

    # Clear turn state
    state = clear_turn_state(state)

    {result.assistant_text, state}
  end

  defp handle_task_result({:cancelled, {:ok, result}}, state) do
    turn_id = state.active_turn_id
    session_events = state.session_events_before_turn

    # Fold any partial event specs
    {conductor_events, state} = emit_event_specs(state, result.event_specs, turn_id)
    session_events = session_events ++ conductor_events

    # Emit tool_loop_cancelled if not already in specs
    {cancel_event, state} =
      emit_session_event(
        state,
        :conductor,
        :turn_cancelled,
        %{iterations: result[:iterations] || 0},
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [cancel_event]

    # Emit safe assistant message
    cancel_text = result.assistant_text || "Turn cancelled."

    {assistant_msg_event, state} =
      emit_session_event(
        state,
        :system,
        :assistant_message,
        %{text: cancel_text, streamed?: false},
        turn_id: turn_id,
        visibility: :user
      )

    session_events = session_events ++ [assistant_msg_event]

    state = %{state | status: :idle}

    # Emit turn_completed
    delta_count = Enum.count(session_events, &(&1.type == :assistant_delta))
    duration_ms = System.monotonic_time(:millisecond) - state.turn_start_time

    turn_completed_data = %{
      streamed?: false,
      delta_count: delta_count,
      duration_ms: duration_ms,
      cancelled: true
    }

    {turn_completed_event, state} =
      emit_session_event(state, :conductor, :turn_completed, turn_completed_data,
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [turn_completed_event]

    updated_events = state.events ++ session_events
    state = %{state | events: updated_events}

    GenServer.reply(state.from, {:ok, cancel_text})

    state = clear_turn_state(state)

    {cancel_text, state}
  end

  defp handle_task_result({:error, %{event_specs: event_specs}}, state) do
    turn_id = state.active_turn_id
    session_events = state.session_events_before_turn

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

    # Emit turn_failed
    duration_ms = System.monotonic_time(:millisecond) - state.turn_start_time

    {turn_failed_event, state} =
      emit_session_event(state, :conductor, :turn_failed, %{duration_ms: duration_ms},
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [turn_failed_event]

    state = %{state | status: :idle}
    updated_events = state.events ++ session_events
    state = %{state | events: updated_events}

    GenServer.reply(state.from, {:ok, error_text})

    state = clear_turn_state(state)

    {error_text, state}
  end

  # Catch-all for unexpected result shapes
  defp handle_task_result(_other, state) do
    handle_task_crash("unexpected task result", state)
  end

  defp handle_task_crash(reason, state) do
    turn_id = state.active_turn_id
    session_events = state.session_events_before_turn

    error_text = "Error: turn failed (#{reason})"

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

    # Emit turn_failed
    duration_ms =
      if state.turn_start_time,
        do: System.monotonic_time(:millisecond) - state.turn_start_time,
        else: 0

    {turn_failed_event, state} =
      emit_session_event(
        state,
        :conductor,
        :turn_failed,
        %{duration_ms: duration_ms, reason: reason},
        turn_id: turn_id,
        visibility: :internal
      )

    session_events = session_events ++ [turn_failed_event]

    state = %{state | status: :idle}
    updated_events = state.events ++ session_events
    state = %{state | events: updated_events}

    if state.from do
      GenServer.reply(state.from, {:ok, error_text})
    end

    state = clear_turn_state(state)

    {error_text, state}
  end

  defp clear_turn_state(state) do
    %{
      state
      | active_turn_id: nil,
        runner_pid: nil,
        runner_task: nil,
        from: nil,
        turn_start_time: nil,
        session_events_before_turn: [],
        cancellation_requested: false
    }
  end

  # -- Plan lifecycle commands -------------------------------------------------

  defp handle_plan_lifecycle_command(state, source, target_status) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      true ->
        case resolve_active_plan_state(state) do
          nil ->
            {{:error, :no_active_plan}, state}

          {plan, active_plan_id} ->
            transition_active_plan(state, source, plan, active_plan_id, target_status)
        end
    end
  end

  defp transition_active_plan(state, source, plan, active_plan_id, target_status) do
    if plan.status != :awaiting_approval do
      {{:error, {:plan_not_awaiting_approval, plan.status}}, state}
    else
      previous_status = state.status
      approvals = session_plan_approvals(state, plan)

      case transition_plan_approval_record(
             target_status,
             state.session_id,
             plan,
             approvals,
             source
           ) do
        {:ok, approval, approvals, plan} ->
          {:ok, plan} = Plan.transition(plan, target_status)
          plan = ApprovalGate.put_plan_approval(plan, approval)

          state =
            state
            |> Map.put(:approvals, approvals)
            |> put_active_plan(plan, active_plan_id)
            |> Map.put(:status, :idle)

          {approval_event, state} =
            emit_session_event(
              state,
              source,
              approval_lifecycle_event_type(target_status),
              ApprovalGate.approval_event_data(approval),
              visibility: :internal
            )

          {plan_event, state} =
            emit_session_event(
              state,
              source,
              plan_lifecycle_event_type(target_status),
              plan_lifecycle_event_data(plan, approval),
              visibility: :user
            )

          {status_event, state} = maybe_emit_plan_lifecycle_status_event(state, previous_status)

          events = [approval_event, plan_event, status_event] |> Enum.reject(&is_nil/1)

          state =
            state
            |> append_session_events(events)
            |> maybe_persist_snapshot()

          {{:ok, plan}, state}

        {:error, {:stale_approval, metadata}} ->
          {{:error, {:stale_approval, metadata}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end
  end

  defp turn_running?(state), do: state.status == :running or not is_nil(state.runner_pid)

  defp transition_plan_approval_record(:approved, session_id, plan, approvals, source) do
    ApprovalGate.approve_plan(session_id, plan, approvals, approved_by: source, actor: source)
  end

  defp transition_plan_approval_record(:rejected, session_id, plan, approvals, source) do
    ApprovalGate.reject_plan(session_id, plan, approvals,
      rejected_by: source,
      actor: source,
      reason: "Plan rejected by #{source}"
    )
  end

  defp session_plan_approvals(state, %Plan{} = plan) do
    ApprovalGate.merge_approvals(state.approvals || [], plan.approvals || [])
  end

  defp ensure_pending_plan_approval(%{plan: %Plan{status: :awaiting_approval} = plan} = state) do
    approvals = session_plan_approvals(state, plan)

    case ApprovalGate.ensure_pending_plan_approval(state.session_id, plan, approvals,
           requested_by: :planning
         ) do
      {:ok, _approval, approvals, plan} ->
        state
        |> Map.put(:approvals, approvals)
        |> put_active_plan(plan, plan.id || state.active_plan_id)

      _ ->
        state
    end
  end

  defp ensure_pending_plan_approval(state), do: state

  defp resolve_active_plan_state(state) do
    cond do
      state.active_plan_id && match?(%Plan{}, Map.get(state.plans, state.active_plan_id)) ->
        {Map.fetch!(state.plans, state.active_plan_id), state.active_plan_id}

      match?(%Plan{}, state.plan) ->
        {state.plan, state.plan.id || state.active_plan_id}

      true ->
        nil
    end
  end

  defp put_active_plan(state, plan, resolved_active_plan_id) do
    active_plan_id = plan.id || resolved_active_plan_id || state.active_plan_id

    plans =
      if active_plan_id do
        Map.put(state.plans, active_plan_id, plan)
      else
        state.plans
      end

    %{state | plan: plan, plans: plans, active_plan_id: active_plan_id}
  end

  defp maybe_emit_plan_lifecycle_status_event(state, :awaiting_plan_approval) do
    emit_session_event(
      state,
      :conductor,
      :session_status_changed,
      %{from: :awaiting_plan_approval, to: :idle},
      visibility: :internal
    )
  end

  defp maybe_emit_plan_lifecycle_status_event(state, _previous_status), do: {nil, state}

  defp approval_lifecycle_event_type(:approved), do: :approval_approved
  defp approval_lifecycle_event_type(:rejected), do: :approval_rejected

  defp plan_lifecycle_event_type(:approved), do: :plan_approved
  defp plan_lifecycle_event_type(:rejected), do: :plan_rejected

  defp plan_lifecycle_event_data(plan, approval) do
    %{
      plan_id: plan.id,
      version: plan.version,
      status: plan.status,
      objective: plan.objective,
      task_count: length(plan.tasks),
      approval_id: approval.id,
      approval_status: approval.status,
      content_hash: approval.content_hash
    }
  end

  defp append_session_events(state, events) do
    %{state | events: state.events ++ events}
  end

  # -- Plan persistence --------------------------------------------------------

  defp restore_plan_from_snapshot(state) do
    case SessionStore.load_session(state.session_id) do
      {:ok, data} ->
        plan_data = Map.get(data, "plan")
        plans_data = Map.get(data, "plans", %{})
        active_plan_id = Map.get(data, "active_plan_id")
        status_str = Map.get(data, "status", "idle")
        active_muse = Map.get(data, "active_muse")
        approvals_data = Map.get(data, "approvals", [])

        plans = restore_plans(plans_data)
        plan = restore_plan(plan_data) || active_plan_from_plans(plans, active_plan_id)

        active_id =
          active_plan_id ||
            if plan, do: plan.id, else: nil

        plans = put_restored_plan(plans, plan, active_id)
        approvals = restore_approvals(approvals_data, plan, plans)
        status = safely_atom_status(status_str)

        %{
          state
          | status: status,
            active_muse: active_muse,
            plan: plan,
            plans: plans,
            active_plan_id: active_id,
            approvals: approvals
        }
        |> ensure_pending_plan_approval()
        |> maybe_persist_snapshot()

      _ ->
        state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  defp restore_plan(nil), do: nil

  defp restore_plan(data) when is_map(data) do
    Plan.from_map(data)
  rescue
    _ -> nil
  end

  defp restore_plan(_), do: nil

  defp restore_plans(plans_data) when is_map(plans_data) do
    plans_data
    |> Enum.reduce(%{}, fn {id, plan_data}, acc ->
      case restore_plan(plan_data) do
        nil -> acc
        plan -> Map.put(acc, id, plan)
      end
    end)
  end

  defp restore_plans(_), do: %{}

  defp restore_approvals(approvals_data, plan, plans) do
    plan_approvals =
      [plan | Map.values(plans || %{})]
      |> Enum.flat_map(fn
        %Plan{} = p -> p.approvals || []
        _ -> []
      end)

    ApprovalGate.merge_approvals(approvals_data, plan_approvals)
  end

  defp active_plan_from_plans(plans, active_plan_id) when is_map(plans) do
    cond do
      is_binary(active_plan_id) and match?(%Plan{}, Map.get(plans, active_plan_id)) ->
        Map.fetch!(plans, active_plan_id)

      true ->
        nil
    end
  end

  defp put_restored_plan(plans, %Plan{} = plan, active_plan_id) when is_binary(active_plan_id) do
    Map.put_new(plans, active_plan_id, plan)
  end

  defp put_restored_plan(plans, _plan, _active_plan_id), do: plans

  defp approval_maps(approvals) do
    approvals
    |> ApprovalGate.normalize_approvals()
    |> Enum.map(&Muse.Approval.to_map/1)
  end

  defp maybe_persist_snapshot(state) do
    # Persist plan-related state as a session snapshot.
    # Only writes when a plan exists to avoid unnecessary I/O.
    if state.plan do
      data = %{
        status: Atom.to_string(state.status),
        active_muse: state.active_muse,
        active_plan_id: state.active_plan_id,
        approvals: approval_maps(state.approvals),
        plan: Plan.to_map(state.plan),
        plans:
          state.plans
          |> Enum.map(fn {id, p} -> {id, Plan.to_map(p)} end)
          |> Enum.into(%{})
      }

      case SessionStore.save_session(state.session_id, data) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end

    state
  end

  defp safely_atom_status(str) when is_binary(str) do
    case str do
      "idle" -> :idle
      "running" -> :running
      "awaiting_plan_approval" -> :awaiting_plan_approval
      "planning" -> :planning
      _ -> :idle
    end
  end

  defp safely_atom_status(_), do: :idle

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
