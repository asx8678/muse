defmodule Muse.SessionServer do
  @moduledoc """
  Per-session `GenServer` that owns session state and handles synchronous
  operations (`submit`, `status`, `cancel`).

  ## Lifecycle

  Started by `Muse.SessionRouter` via `DynamicSupervisor.start_child/2`.
  `start_link/1` uses a `{:via, Registry, ...}` name so registration in
  `Muse.SessionRegistry` is atomic. The registry key is
  `{store_base_dir, session_id}`: concurrent starts for the same session id in
  the same workspace resolve to the same process, while the same id can run in
  different workspace profiles without colliding.

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

  alias Muse.{
    Approval,
    ApprovalGate,
    Event,
    EventPayloadRedactor,
    Memory,
    MetadataSanitizer,
    Patch,
    PlanBinding,
    Prompt.Redactor,
    Session,
    State,
    Turn,
    Plan,
    SessionStore
  }

  alias Muse.Conductor.TurnRunner

  # -- Public API ---------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, {:invalid_session_id, term()}}
  def start_link(opts) do
    session_id = Keyword.get(opts, :session_id)

    # Validate session ID before attempting GenServer.start_link so invalid
    # IDs cannot register in the Registry or trigger persistence calls.
    case SessionStore.validate_session_id(session_id) do
      :ok ->
        do_start_link(session_id, opts)

      {:error, _} = error ->
        error
    end
  end

  defp do_start_link(session_id, opts) do
    runtime_context = current_runtime_context()
    store_base_dir = Keyword.get(opts, :store_base_dir) || runtime_context.store_base_dir
    workspace = Keyword.get(opts, :workspace) || runtime_context.workspace
    registry_key = registry_key(session_id, store_base_dir)

    # Use :via tuple for atomic registration. The key includes the captured
    # store_base_dir so the same session_id can run concurrently in different
    # workspace profiles without colliding, while duplicate starts in the same
    # workspace still resolve to {:error, {:already_started, pid}}.
    GenServer.start_link(
      __MODULE__,
      %{session_id: session_id, store_base_dir: store_base_dir, workspace: workspace},
      name: {:via, Registry, {Muse.SessionRegistry, registry_key}}
    )
  end

  @doc false
  @spec registry_key(String.t(), String.t()) :: {String.t(), String.t()}
  def registry_key(session_id, store_base_dir) do
    {to_string(store_base_dir), to_string(session_id)}
  end

  @doc false
  @spec current_runtime_context() :: %{store_base_dir: String.t(), workspace: String.t()}
  def current_runtime_context do
    case Process.whereis(Muse.ActiveWorkspace) do
      nil ->
        default_runtime_context()

      pid ->
        if Process.alive?(pid) do
          active = Muse.ActiveWorkspace.get()

          %{
            store_base_dir:
              active.store_base_dir || store_base_dir_for_workspace(active.root_path),
            workspace: active.root_path || workspace_agent_root()
          }
        else
          default_runtime_context()
        end
    end
  rescue
    _ -> default_runtime_context()
  catch
    :exit, _ -> default_runtime_context()
  end

  @doc false
  @spec current_store_base_dir() :: String.t()
  def current_store_base_dir, do: current_runtime_context().store_base_dir

  @doc false
  @spec current_workspace_root() :: String.t()
  def current_workspace_root, do: current_runtime_context().workspace

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

  Approval is a lifecycle transition only: it records that the active plan was
  accepted. It does not start turn execution, shell commands, file writes, patch
  application, or any implementation handoff.
  """
  @spec approve_plan(pid(), atom()) ::
          {:ok, Plan.t()}
          | {:error,
             :turn_running | :no_active_plan | {:plan_not_awaiting_approval, Plan.status()}}
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
             :turn_running | :no_active_plan | {:plan_not_awaiting_approval, Plan.status()}}
  def reject_plan(pid, source \\ :system) do
    GenServer.call(pid, {:reject_plan, source})
  end

  @doc """
  Proposes a patch for the session's active approved plan.

  The patch proposal is persisted to `patches.jsonl` and the session snapshot.
  The session transitions to `:awaiting_patch_approval`. No workspace files
  are modified.

  Options:
    * `:diff`           — unified diff content (required)
    * `:summary`        — short description of the patch
    * `:affected_files`  — list of file paths affected
  """
  @spec propose_patch(pid(), keyword()) ::
          {:ok, Patch.t()}
          | {:error,
             :turn_running
             | :no_active_plan
             | :plan_not_approved
             | :missing_plan_binding
             | {:patch_creation_failed, term()}}
  def propose_patch(pid, opts \\ []) do
    GenServer.call(pid, {:propose_patch, opts})
  end

  @doc """
  Approves the active pending patch proposal.

  Approval records the decision but does NOT apply the patch, write files,
  or modify the workspace. PR17: approval is lifecycle-only.
  """
  @spec approve_patch(pid(), atom()) ::
          {:ok, Patch.t()}
          | {:error,
             :turn_running | :no_pending_patch | {:patch_not_awaiting_approval, Patch.status()}}
  def approve_patch(pid, source \\ :system) do
    GenServer.call(pid, {:approve_patch, source})
  end

  @doc """
  Rejects the active pending patch proposal.

  Rejection records the decision and clears the pending patch so a new
  proposal can be made. PR17: rejection is lifecycle-only.
  """
  @spec reject_patch(pid(), atom()) ::
          {:ok, Patch.t()}
          | {:error,
             :turn_running | :no_pending_patch | {:patch_not_awaiting_approval, Patch.status()}}
  def reject_patch(pid, source \\ :system) do
    GenServer.call(pid, {:reject_patch, source})
  end

  @doc """
  Applies the latest approved patch, creating a checkpoint first.

  PR18: If patch_id is given, applies that specific patch; otherwise
  applies the most recently approved patch in the session.
  """
  @spec apply_patch(pid(), String.t() | nil) ::
          {:ok, map()}
          | {:error,
             :turn_running | :no_approved_patch | :no_active_plan | :apply_failed | term()}
  def apply_patch(pid, patch_id \\ nil) do
    GenServer.call(pid, {:apply_patch, patch_id})
  end

  @doc """
  Rolls back a checkpoint, restoring the workspace to pre-apply state.

  PR18: Only checkpoints belonging to the current session may be rolled back.
  """
  @spec rollback_checkpoint(pid(), String.t()) ::
          {:ok, map()} | {:error, :turn_running | term()}
  def rollback_checkpoint(pid, checkpoint_id) do
    GenServer.call(pid, {:rollback_checkpoint, checkpoint_id})
  end

  @doc """
  Returns the session's memory artifact, or `nil` if none exists.
  """
  @spec get_memory(pid()) :: term() | nil
  def get_memory(pid) do
    GenServer.call(pid, :get_memory)
  end

  @doc """
  Sets the session's memory artifact.

  The memory is validated through `Muse.Memory.validate_and_persist/3`
  before being persisted to disk or updated in process state. If the
  memory contains secrets, or if the disk write fails, neither the
  in-memory state nor the durable state is updated.

  Returns:
    - `:ok` on success
    - `{:error, {:unsafe_memory, reasons}}` if secrets are detected
    - `{:error, reason}` if the disk write fails
  """
  @spec set_memory(pid(), term()) ::
          :ok | {:error, {:unsafe_memory, [String.t()]} | tuple()}
  def set_memory(pid, memory) do
    GenServer.call(pid, {:set_memory, memory})
  end

  @doc """
  Clears the session's memory artifact.
  """
  @spec clear_memory(pid()) :: :ok
  def clear_memory(pid) do
    GenServer.call(pid, :clear_memory)
  end

  @doc """
  Sets the session's active Muse to the given muse id.

  This affects routing: the next turn will use the specified Muse
  instead of the default plan-status-based selection.
  """
  @spec set_active_muse(pid(), String.t()) :: :ok
  def set_active_muse(pid, muse_id) do
    GenServer.call(pid, {:set_active_muse, muse_id})
  end

  @doc """
  Requests a pending remote execution approval for this session.

  The session transitions to `:awaiting_remote_execution_approval` and a
  `%Muse.Approval{kind: :remote_execution}` record is created. No remote
  execution is actually granted — this is auditable metadata only.

  ## Options

    * `:target_id`    — remote target identifier (required)
    * `:command_hash` — SHA-256 hash of the command to execute (required)
    * `:argv_preview` — short, safe preview of the command argv
    * `:ttl_seconds`  — approval time-to-live (default: 300 / 5 min)
    * `:requested_by` — actor requesting the approval
  """
  @spec request_remote_execution_approval(pid(), keyword()) ::
          {:ok, Approval.t()}
          | {:error,
             :turn_running
             | :pending_remote_approval_exists
             | {:missing_field, atom()}
             | term()}
  def request_remote_execution_approval(pid, opts \\ []) do
    GenServer.call(pid, {:request_remote_execution_approval, opts})
  end

  @doc """
  Approves the pending remote execution approval for this session.

  The session transitions back to `:idle`. No remote execution is actually
  granted — approval is auditable metadata only.
  """
  @spec approve_remote(pid(), atom()) ::
          {:ok, Approval.t()}
          | {:error, :turn_running | :no_pending_remote_approval | term()}
  def approve_remote(pid, source \\ :system) do
    GenServer.call(pid, {:approve_remote, source})
  end

  @doc """
  Rejects the pending remote execution approval for this session.

  The session transitions back to `:idle`. The rejection is recorded for audit.
  """
  @spec reject_remote(pid(), atom()) ::
          {:ok, Approval.t()}
          | {:error, :turn_running | :no_pending_remote_approval | term()}
  def reject_remote(pid, source \\ :system) do
    GenServer.call(pid, {:reject_remote, source})
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(session_id) when is_binary(session_id) do
    %{store_base_dir: store_base_dir, workspace: workspace} = current_runtime_context()

    init(%{session_id: session_id, store_base_dir: store_base_dir, workspace: workspace})
  end

  @impl true
  def init(%{session_id: session_id, store_base_dir: store_base_dir, workspace: workspace}) do
    # Defense-in-depth: reject invalid session IDs even if they somehow
    # bypass start_link validation (e.g. direct DynamicSupervisor use).
    case SessionStore.validate_session_id(session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        {:stop, reason}
    end
    |> case do
      :ok ->
        do_init(session_id, store_base_dir, workspace)

      {:stop, _} = stop ->
        stop
    end
  end

  defp do_init(session_id, store_base_dir, workspace) do
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
      approval_binding: nil,
      active_approval: nil,
      pending_patch: nil,
      pending_remote_approval: nil,
      memory: nil,
      checkpoints: [],
      artifacts: [],
      workspace: workspace,
      store_base_dir: store_base_dir,
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

    # Attempt to restore memory from persisted artifact (non-fatal on failure)
    state = restore_memory(state)
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
      approval_binding: state.approval_binding,
      active_approval: state.active_approval,
      seq: state.seq,
      event_count: length(state.events),
      active_turn_id: state.active_turn_id,
      runner_pid: state.runner_pid,
      cancellation_requested: state.cancellation_requested,
      pending_patch: state.pending_patch,
      pending_remote_approval: state.pending_remote_approval,
      memory: state.memory,
      checkpoints: state.checkpoints,
      artifacts: state.artifacts,
      workspace: state.workspace,
      store_base_dir: state.store_base_dir
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

  @impl true
  def handle_call({:propose_patch, opts}, _from, state) do
    {reply, state} = handle_propose_patch(state, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:approve_patch, source}, _from, state) do
    {reply, state} = handle_patch_lifecycle_command(state, source, :approved)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:reject_patch, source}, _from, state) do
    {reply, state} = handle_patch_lifecycle_command(state, source, :rejected)
    {:reply, reply, state}
  end

  # PR18: Apply an approved patch with checkpoint protection
  @impl true
  def handle_call({:apply_patch, patch_id}, _from, state) do
    {reply, state} = handle_apply_patch(state, patch_id)
    {:reply, reply, state}
  end

  # PR18: Rollback a checkpoint
  @impl true
  def handle_call({:rollback_checkpoint, checkpoint_id}, _from, state) do
    {reply, state} = handle_rollback_checkpoint(state, checkpoint_id)
    {:reply, reply, state}
  end

  @impl true
  # Test-only handler to store a pending patch in session state.
  def handle_call({:store_pending_patch, patch}, _from, state) do
    state_with_patch = %{
      state
      | pending_patch: patch,
        status: :awaiting_patch_approval
    }

    {:reply, :ok, state_with_patch}
  end

  # Test-only handler to store an approved plan directly for patch proposal E2E tests.
  @impl true
  def handle_call({:store_approved_plan, %Plan{} = plan}, _from, state) do
    active_plan_id = plan.id || state.active_plan_id

    plans =
      if active_plan_id do
        Map.put(state.plans || %{}, active_plan_id, plan)
      else
        state.plans || %{}
      end

    state = %{
      state
      | active_plan_id: active_plan_id,
        plan: plan,
        plans: plans,
        status: :idle
    }

    {:reply, :ok, state}
  end

  # -- Memory API handlers -----------------------------------------------------

  @impl true
  def handle_call(:get_memory, _from, state) do
    {:reply, state.memory, state}
  end

  @impl true
  def handle_call({:set_memory, memory}, _from, state) do
    # Fail-closed: validate and persist before updating in-memory state.
    # If validation or disk write fails, neither state is updated.
    case Memory.validate_and_persist(state.store_base_dir, state.session_id, memory) do
      :ok ->
        {:reply, :ok, %{state | memory: memory}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:clear_memory, _from, state) do
    # Remove persisted memory when cleared
    clear_persisted_memory(state.store_base_dir, state.session_id)
    {:reply, :ok, %{state | memory: nil}}
  end

  # -- Active Muse handler -----------------------------------------------------

  @impl true
  def handle_call({:set_active_muse, muse_id}, _from, state) do
    {:reply, :ok, %{state | active_muse: muse_id}}
  end

  # Phase B: Remote execution approval lifecycle
  @impl true
  def handle_call({:request_remote_execution_approval, opts}, _from, state) do
    {reply, state} = handle_request_remote_approval(state, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:approve_remote, source}, _from, state) do
    {reply, state} = handle_remote_lifecycle_command(state, source, :approved)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:reject_remote, source}, _from, state) do
    {reply, state} = handle_remote_lifecycle_command(state, source, :rejected)
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
        workspace: Keyword.get(opts, :workspace, state.workspace || get_workspace()),
        status: state.status
      )
      | active_muse: state.active_muse,
        active_plan_id: state.active_plan_id,
        plans: turn_session_plans(state),
        approvals: state.approvals || [],
        memory: state.memory,
        checkpoints: state.checkpoints || [],
        artifacts: state.artifacts || []
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

    # PR17 hardening: carry pending_patch from Conductor result into SessionServer
    # state so that /approve patch and /reject patch can operate on it.
    pending_patch = Map.get(result.session, :pending_patch) || state.pending_patch

    # PR17 hardening: persist pending_patch to patches.jsonl when it arrives
    # via the Conductor/ToolLoop path. The direct propose_patch path already
    # appends in create_patch_proposal/2. Guard against duplicate appends
    # by only persisting if pending_patch is new (was not in the prior state).
    had_pending_patch_before = state.pending_patch != nil

    state = %{
      state
      | status: session_status,
        active_muse: Atom.to_string(result.selected_muse.id),
        pending_patch: pending_patch
    }

    state =
      if pending_patch != nil and not had_pending_patch_before and
           match?(%Patch{}, pending_patch) do
        :ok =
          SessionStore.append_patch(
            state.store_base_dir,
            state.session_id,
            Patch.to_map(pending_patch)
          )

        state
      else
        state
      end

    # Store plan if present in the result and create a content-bound pending
    # approval record for plans awaiting approval. This approval is persisted in
    # the session snapshot and embedded in the plan for audit display.
    state =
      if Map.has_key?(result, :plan) and not is_nil(result.plan) do
        store_result_plan(state, result.plan, result.session)
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

    state =
      state
      |> Map.put(:events, updated_events)
      |> maybe_persist_snapshot()

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

  defp handle_task_result({:error, %{event_specs: event_specs, reason: reason}}, state) do
    turn_id = state.active_turn_id
    session_events = state.session_events_before_turn

    # Fold partial event specs collected before the error
    {conductor_events, state} = emit_event_specs(state, event_specs, turn_id)
    session_events = session_events ++ conductor_events

    # Emit a user-visible assistant_message so CLI/State consumers
    # see the failure in the event stream (not just the return value).
    # Include a safe summary of the error reason for actionable debugging.
    # The reason is already redacted by the provider layer, but we apply
    # additional sanitization here as defense-in-depth.
    error_text = format_provider_error(reason)

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

  # -- Provider error formatting -----------------------------------------------

  # Format a provider error reason into a safe, user-visible error message.
  # The reason is already redacted by the provider layer, but we apply
  # additional sanitization as defense-in-depth to ensure no secrets leak.
  @spec format_provider_error(term()) :: String.t()
  defp format_provider_error(reason) do
    error = Muse.LLM.ProviderError.classify(reason)

    details =
      case error.category do
        :unknown ->
          "#{safe_error_summary(reason)} — #{error.hint}"

        _ ->
          Muse.LLM.ProviderError.render_compact(error)
      end

    "Error: provider error occurred — #{details}"
  rescue
    _ ->
      "Error: provider error occurred — #{safe_error_summary(reason)}"
  end

  # Generate a safe, bounded string summary of an error term.
  # Applies redaction and sanitization to prevent secret leakage.
  @spec safe_error_summary(term()) :: String.t()
  defp safe_error_summary(reason) when is_binary(reason) do
    reason
    |> EventPayloadRedactor.redact_string()
    |> MetadataSanitizer.sanitize(max_string_len: 200)
    |> String.slice(0, 200)
  end

  defp safe_error_summary(reason) do
    reason
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize(
      max_depth: 4,
      max_map_keys: 20,
      max_list_length: 10,
      max_string_len: 200
    )
    |> inspect(limit: 5, printable_limit: 200)
  rescue
    _ ->
      "(error details unavailable)"
  end

  defp store_result_plan(state, %Plan{} = raw_plan, result_session) do
    workspace = result_workspace(result_session) || state.workspace || current_workspace()
    plan = put_plan_workspace(raw_plan, workspace)
    active_plan_id = plan.id || state.active_plan_id

    {approval, approvals, plan} =
      if plan.status == :awaiting_approval do
        case ApprovalGate.ensure_pending_plan_approval(
               state.session_id,
               plan,
               state.approvals || [],
               workspace: workspace,
               requested_by: :planning,
               source: :conductor,
               metadata: %{event: :plan_created}
             ) do
          {:ok, approval, approvals, plan} -> {approval, approvals, plan}
        end
      else
        {nil, ApprovalGate.merge_approvals(state.approvals || [], plan.approvals), plan}
      end

    approval_binding =
      if plan.status == :awaiting_approval do
        ApprovalGate.capture_binding(plan, workspace: workspace)
      else
        nil
      end

    plans =
      if active_plan_id do
        Map.put(state.plans || %{}, active_plan_id, plan)
      else
        state.plans || %{}
      end

    %{
      state
      | active_plan_id: active_plan_id,
        plan: plan,
        plans: plans,
        approvals: approvals,
        approval_binding: approval_binding,
        active_approval: approval
    }
    |> maybe_persist_snapshot()
  end

  defp result_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace
  defp result_workspace(_), do: nil

  defp current_workspace, do: get_workspace()

  defp put_plan_workspace(%Plan{} = plan, nil), do: plan

  defp put_plan_workspace(%Plan{} = plan, workspace) when is_binary(workspace) do
    metadata = Map.put(plan.metadata || %{}, :workspace, workspace)
    %{plan | metadata: metadata}
  end

  defp plan_workspace(%Plan{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :workspace) || Map.get(metadata, "workspace")
  end

  defp plan_workspace(_), do: nil

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
      actor = Atom.to_string(source || :system)
      workspace = plan_workspace(plan) || current_workspace()

      gate_result =
        case target_status do
          :approved ->
            ApprovalGate.approve_plan(state.session_id, plan, state.approvals || [],
              actor: actor,
              approved_by: actor,
              source: source,
              session_id: state.session_id,
              workspace: workspace,
              binding: state.approval_binding
            )

          :rejected ->
            ApprovalGate.reject_plan(state.session_id, plan, state.approvals || [],
              actor: actor,
              rejected_by: actor,
              source: source,
              session_id: state.session_id,
              workspace: workspace,
              binding: state.approval_binding,
              reason: "rejected by #{actor}"
            )
        end

      case gate_result do
        {:ok, approval, approvals, gated_plan} ->
          {:ok, transitioned_plan} = Plan.transition(gated_plan, target_status)
          transitioned_plan = ApprovalGate.put_plan_approval(transitioned_plan, approval)
          approvals = ApprovalGate.upsert_approval(approvals, approval)

          state =
            state
            |> put_active_plan(transitioned_plan, active_plan_id)
            |> Map.put(:approvals, approvals)
            |> Map.put(:approval_binding, nil)
            |> Map.put(:active_approval, nil)
            |> Map.put(:status, :idle)

          {approval_event, state} =
            emit_session_event(
              state,
              source,
              approval_lifecycle_event_type(target_status),
              ApprovalGate.approval_event_data(approval),
              visibility: :user
            )

          {plan_event, state} =
            emit_session_event(
              state,
              source,
              plan_lifecycle_event_type(target_status),
              plan_lifecycle_event_data(transitioned_plan, approval),
              visibility: :user
            )

          {status_event, state} = maybe_emit_plan_lifecycle_status_event(state, previous_status)

          events = [approval_event, plan_event, status_event] |> Enum.reject(&is_nil/1)

          state =
            state
            |> append_session_events(events)
            |> maybe_persist_snapshot()

          {{:ok, transitioned_plan}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end
  end

  defp turn_running?(state), do: state.status == :running or not is_nil(state.runner_pid)

  # -- Phase B: Remote execution approval handlers ----------------------------

  defp handle_request_remote_approval(state, opts) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      state.pending_remote_approval != nil ->
        {{:error, :pending_remote_approval_exists}, state}

      true ->
        opts_with_session = Keyword.put(opts, :session_id, state.session_id)

        case ApprovalGate.request_remote_execution_approval(opts_with_session) do
          {:ok, approval} ->
            previous_status = state.status

            # Emit remote_execution_requested event
            {requested_event, state} =
              emit_session_event(
                state,
                :conductor,
                :remote_execution_requested,
                ApprovalGate.remote_approval_event_data(approval),
                visibility: :user
              )

            # Emit session status change event
            {status_event, state} =
              if previous_status != :awaiting_remote_execution_approval do
                emit_session_event(
                  state,
                  :conductor,
                  :session_status_changed,
                  %{from: previous_status, to: :awaiting_remote_execution_approval},
                  visibility: :internal
                )
              else
                {nil, state}
              end

            events = [requested_event, status_event] |> Enum.reject(&is_nil/1)

            state =
              state
              |> Map.put(:pending_remote_approval, approval)
              |> Map.put(
                :approvals,
                ApprovalGate.upsert_approval(state.approvals || [], approval)
              )
              |> Map.put(:status, :awaiting_remote_execution_approval)
              |> append_session_events(events)
              |> maybe_persist_snapshot()

            {{:ok, approval}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  defp handle_remote_lifecycle_command(state, source, target_status) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      state.pending_remote_approval == nil ->
        {{:error, :no_pending_remote_approval}, state}

      true ->
        do_transition_remote_approval(state, source, target_status)
    end
  end

  defp do_transition_remote_approval(state, source, target_status) do
    approval = state.pending_remote_approval
    actor = Atom.to_string(source || :system)

    gate_result =
      case target_status do
        :approved ->
          ApprovalGate.approve_remote_execution(approval,
            approved_by: actor,
            source: source
          )

        :rejected ->
          ApprovalGate.reject_remote_execution(approval,
            rejected_by: actor,
            reason: "rejected by #{actor}",
            source: source
          )
      end

    case gate_result do
      {:ok, transitioned_approval} ->
        previous_status = state.status

        # Upsert approval in session approvals list
        approvals =
          ApprovalGate.upsert_approval(state.approvals || [], transitioned_approval)

        # Emit lifecycle event
        event_type = remote_lifecycle_event_type(target_status)

        {lifecycle_event, state} =
          emit_session_event(
            state,
            source,
            event_type,
            ApprovalGate.remote_approval_event_data(transitioned_approval),
            visibility: :user
          )

        # Emit session status change
        {status_event, state} =
          if previous_status == :awaiting_remote_execution_approval do
            emit_session_event(
              state,
              :conductor,
              :session_status_changed,
              %{from: :awaiting_remote_execution_approval, to: :idle},
              visibility: :internal
            )
          else
            {nil, state}
          end

        events = [lifecycle_event, status_event] |> Enum.reject(&is_nil/1)

        state =
          state
          |> Map.put(:pending_remote_approval, nil)
          |> Map.put(:approvals, approvals)
          |> Map.put(:status, :idle)
          |> append_session_events(events)
          |> maybe_persist_snapshot()

        {{:ok, transitioned_approval}, state}

      {:error, :approval_expired} ->
        handle_expired_remote_approval(state, approval, source)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # When the gate returns :approval_expired, the session would otherwise be
  # stuck in :awaiting_remote_execution_approval with an un-actionable
  # pending_remote_approval. We transition the approval to :expired, upsert
  # it for audit, clear pending state, emit audit events, and persist the
  # snapshot — all without executing anything.
  defp handle_expired_remote_approval(state, approval, source) do
    {:ok, expired_approval} = Approval.transition(approval, :expired)
    approvals = ApprovalGate.upsert_approval(state.approvals || [], expired_approval)

    previous_status = state.status

    {expiry_event, state} =
      emit_session_event(
        state,
        source,
        :remote_execution_approval_expired,
        ApprovalGate.remote_approval_event_data(expired_approval),
        visibility: :internal
      )

    {status_event, state} =
      if previous_status == :awaiting_remote_execution_approval do
        emit_session_event(
          state,
          :conductor,
          :session_status_changed,
          %{from: :awaiting_remote_execution_approval, to: :idle},
          visibility: :internal
        )
      else
        {nil, state}
      end

    events = [expiry_event, status_event] |> Enum.reject(&is_nil/1)

    state =
      state
      |> Map.put(:pending_remote_approval, nil)
      |> Map.put(:approvals, approvals)
      |> Map.put(:status, :idle)
      |> append_session_events(events)
      |> maybe_persist_snapshot()

    {{:error, :approval_expired}, state}
  end

  defp remote_lifecycle_event_type(:approved), do: :remote_execution_approved
  defp remote_lifecycle_event_type(:rejected), do: :remote_execution_rejected

  # -- Patch proposal handlers (PR17) ------------------------------------------

  defp handle_propose_patch(state, opts) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      state.plan == nil ->
        {{:error, :no_active_plan}, state}

      state.plan.status != :approved ->
        {{:error, :plan_not_approved}, state}

      true ->
        create_patch_proposal(state, opts)
    end
  end

  defp create_patch_proposal(state, opts) do
    plan = state.plan
    _workspace = plan_workspace(plan) || current_workspace()
    plan_hash = PlanBinding.content_hash(plan)

    diff = Keyword.get(opts, :diff, "")

    patch_attrs =
      [
        session_id: state.session_id,
        plan_id: plan.id || state.active_plan_id,
        plan_version: plan.version,
        plan_hash: plan_hash,
        diff: diff
      ] ++
        Keyword.take(opts, [:id, :affected_files])

    case Patch.new(patch_attrs) do
      {:ok, patch} ->
        # Emit events (Gap G: avoid unrestricted raw diff in event payloads;
        # user-facing diff display is through the pending_patch / patch display
        # mechanism, not through event data)
        {patch_proposed_event, state} =
          emit_session_event(
            state,
            :conductor,
            :patch_proposed,
            %{
              patch_id: patch.id,
              plan_id: patch.plan_id,
              hash: patch.hash,
              affected_files: patch.affected_files,
              diff_ref: patch.hash
            },
            visibility: :user
          )

        {approval_event, state} =
          emit_session_event(
            state,
            :conductor,
            :patch_approval_requested,
            %{
              patch_id: patch.id,
              plan_id: patch.plan_id,
              hash: patch.hash,
              affected_files: patch.affected_files
            },
            visibility: :user
          )

        previous_status = state.status

        {status_event, state} =
          if previous_status != :awaiting_patch_approval do
            emit_session_event(
              state,
              :conductor,
              :session_status_changed,
              %{from: previous_status, to: :awaiting_patch_approval},
              visibility: :internal
            )
          else
            {nil, state}
          end

        events = [patch_proposed_event, approval_event, status_event] |> Enum.reject(&is_nil/1)

        # Persist to patches.jsonl
        :ok =
          SessionStore.append_patch(state.store_base_dir, state.session_id, Patch.to_map(patch))

        state =
          state
          |> Map.put(:pending_patch, patch)
          |> Map.put(:status, :awaiting_patch_approval)
          |> append_session_events(events)
          |> maybe_persist_snapshot()

        {{:ok, patch}, state}

      {:error, reason} ->
        {{:error, {:patch_creation_failed, reason}}, state}
    end
  end

  # -- Patch lifecycle commands (PR17) ------------------------------------------

  defp handle_patch_lifecycle_command(state, source, target_status) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      true ->
        case resolve_pending_patch(state) do
          nil ->
            {{:error, :no_pending_patch}, state}

          %Patch{} = patch ->
            transition_pending_patch(state, source, patch, target_status)

          %{} = patch ->
            # Legacy map-based patch — include status for error reporting
            if Map.get(patch, :status) != :proposed do
              {{:error, {:patch_not_awaiting_approval, Map.get(patch, :status)}}, state}
            else
              transition_pending_patch(state, source, patch, target_status)
            end
        end
    end
  end

  defp resolve_pending_patch(%{pending_patch: %Patch{status: :proposed} = patch}), do: patch
  defp resolve_pending_patch(%{pending_patch: %Patch{} = patch}), do: patch
  defp resolve_pending_patch(%{pending_patch: %{} = patch}), do: patch
  defp resolve_pending_patch(_state), do: nil

  defp transition_pending_patch(state, source, %Patch{} = patch, target_status) do
    if patch.status != :proposed do
      {{:error, {:patch_not_awaiting_approval, patch.status}}, state}
    else
      {:ok, transitioned_patch} = Patch.transition(patch, target_status)

      {patch_event_type, approval_event_type} =
        case target_status do
          :approved -> {:patch_approved, :approval_approved}
          :rejected -> {:patch_rejected, :approval_rejected}
        end

      # PR17 hardening: create a content-bound %Muse.Approval{kind: :patch}
      # record for audit. This is persisted in the session snapshot and
      # survives pending_patch clearing (Gap D/F).
      approval_attrs =
        build_patch_approval_attrs(
          patch,
          target_status,
          source,
          state.session_id
        )

      approval_record = Approval.new(approval_attrs)

      # Emit patch lifecycle event
      {patch_event, state} =
        emit_session_event(
          state,
          source,
          patch_event_type,
          %{
            patch_id: transitioned_patch.id,
            patch_hash: transitioned_patch.hash,
            plan_id: transitioned_patch.plan_id,
            status: Atom.to_string(target_status)
          },
          visibility: :user
        )

      # Emit approval event for the patch decision
      {approval_event, state} =
        emit_session_event(
          state,
          source,
          approval_event_type,
          %{
            approval_id: approval_record.id,
            kind: :patch,
            patch_id: transitioned_patch.id,
            patch_hash: transitioned_patch.hash,
            plan_id: transitioned_patch.plan_id,
            plan_version: transitioned_patch.plan_version,
            status: Atom.to_string(target_status)
          },
          visibility: :internal
        )

      # Emit session status change if coming from awaiting_patch_approval
      {status_event, state} =
        if state.status == :awaiting_patch_approval do
          emit_session_event(
            state,
            :conductor,
            :session_status_changed,
            %{from: :awaiting_patch_approval, to: :idle},
            visibility: :internal
          )
        else
          {nil, state}
        end

      events = [patch_event, approval_event, status_event] |> Enum.reject(&is_nil/1)

      # Persist approval record in session approvals list before clearing pending_patch
      approvals = state.approvals || []
      approvals = approvals ++ [approval_record]

      # Reset patch state and transition session back to idle
      # PR18: approved patches can now be applied via /apply patch or patch_apply tool
      state =
        state
        |> Map.put(:pending_patch, nil)
        |> Map.put(:status, :idle)
        |> Map.put(:approvals, approvals)
        |> append_session_events(events)
        |> maybe_persist_snapshot()

      {{:ok, transitioned_patch}, state}
    end
  end

  defp transition_pending_patch(state, source, %{} = patch, target_status) do
    # Legacy map-based patch handling (for compatibility)
    actor = Atom.to_string(source || :system)
    now = DateTime.utc_now()

    transitioned_patch =
      patch
      |> Map.put(:status, target_status)
      |> Map.put(:decided_by, actor)
      |> Map.put(:decided_at, now)

    {patch_event_type, _approval_event_type} =
      case target_status do
        :approved -> {:patch_approved, :approval_approved}
        :rejected -> {:patch_rejected, :approval_rejected}
      end

    {patch_event, state} =
      emit_session_event(
        state,
        source,
        patch_event_type,
        %{
          patch_id: Map.get(transitioned_patch, :patch_id) || Map.get(transitioned_patch, :id),
          patch_hash: Map.get(transitioned_patch, :hash),
          plan_id: Map.get(transitioned_patch, :plan_id),
          status: Atom.to_string(target_status)
        },
        visibility: :user
      )

    {status_event, state} =
      if state.status == :awaiting_patch_approval do
        emit_session_event(
          state,
          :conductor,
          :session_status_changed,
          %{from: :awaiting_patch_approval, to: :idle},
          visibility: :internal
        )
      else
        {nil, state}
      end

    events = [patch_event, status_event] |> Enum.reject(&is_nil/1)

    state =
      state
      |> Map.put(:pending_patch, nil)
      |> Map.put(:status, :idle)
      |> append_session_events(events)
      |> maybe_persist_snapshot()

    {{:ok, transitioned_patch}, state}
  end

  defp build_patch_approval_attrs(%Patch{} = patch, target_status, source, session_id) do
    actor = if is_atom(source), do: Atom.to_string(source), else: to_string(source)

    base = %{
      kind: :patch,
      session_id: session_id,
      patch_id: patch.id,
      patch_hash: patch.hash,
      plan_id: patch.plan_id,
      plan_version: patch.plan_version,
      plan_hash: patch.plan_hash,
      source: actor,
      metadata: %{patch_status: patch.status}
    }

    case target_status do
      :approved ->
        Map.merge(base, %{
          status: :approved,
          approved_by: actor,
          approved_at: DateTime.utc_now()
        })

      :rejected ->
        Map.merge(base, %{
          status: :rejected,
          rejected_by: actor,
          rejected_at: DateTime.utc_now()
        })
    end
  end

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

  # -- PR18: Apply patch with checkpoint ------------------------------------------

  defp handle_apply_patch(state, patch_id) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      true ->
        do_apply_patch(state, patch_id)
    end
  end

  defp do_apply_patch(state, patch_id) do
    workspace = plan_workspace(state.plan) || state.workspace || current_workspace()

    with {:ok, plan} <- resolve_active_plan_for_apply(state),
         {:ok, patch} <- resolve_approved_patch(state, patch_id) do
      context = build_patch_apply_context(state, plan, patch, workspace)

      result =
        Muse.Tools.PatchApply.execute(
          %{"patch_id" => patch.id, "patch_hash" => patch.hash},
          context
        )

      {reply, state} =
        if result.success do
          # Emit success events
          state = emit_apply_success_events(state, result)
          # Update session state
          state = %{state | status: :idle}
          {{:ok, result.output}, state}
        else
          # Emit failure event
          state = emit_apply_failure_event(state, result)
          {{:error, :apply_failed}, state}
        end

      {reply, state}
    else
      {:error, :no_active_plan} ->
        {{:error, :no_active_plan}, state}

      {:error, {:plan_not_approved, status}} ->
        {{:error, {:plan_not_approved, status}}, state}

      {:error, :no_approved_patch} ->
        {{:error, :no_approved_patch}, state}
    end
  end

  defp resolve_active_plan_for_apply(state) do
    case resolve_active_plan_state(state) do
      {%Plan{status: :approved} = plan, _id} -> {:ok, plan}
      {%Plan{status: status}, _id} -> {:error, {:plan_not_approved, status}}
      nil -> {:error, :no_active_plan}
    end
  end

  defp resolve_approved_patch(state, nil) do
    # Find most recently approved patch from approvals
    approved_patch_approval =
      (state.approvals || [])
      |> Approval.normalize_list()
      |> Enum.filter(&(&1.kind == :patch and &1.status == :approved))
      |> List.last()

    case approved_patch_approval do
      nil -> {:error, :no_approved_patch}
      approval -> find_patch_by_approval(state, approval)
    end
  end

  defp resolve_approved_patch(state, patch_id) do
    # Try in-memory first, then persisted
    case find_patch_in_state(state, patch_id) do
      {:ok, patch} -> {:ok, patch}
      :not_found -> find_patch_in_store(state.store_base_dir, state.session_id, patch_id)
    end
  end

  defp find_patch_by_approval(state, approval) do
    # Try to find the patch by approval's patch_id
    patch_id = approval.patch_id

    case find_patch_in_state(state, patch_id) do
      {:ok, patch} -> {:ok, patch}
      :not_found -> find_patch_in_store(state.store_base_dir, state.session_id, patch_id)
    end
  end

  defp find_patch_in_state(state, patch_id) do
    # Check pending_patch if it matches and is approved
    case state.pending_patch do
      %Patch{id: ^patch_id, status: :approved} = patch -> {:ok, patch}
      %Patch{hash: hash, status: :approved} = patch when hash == patch_id -> {:ok, patch}
      _ -> :not_found
    end
  end

  defp find_patch_in_store(store_base_dir, session_id, patch_id) do
    case SessionStore.load_patches(store_base_dir, session_id) do
      {:ok, patches, _meta} ->
        case Enum.find(patches, fn p ->
               Map.get(p, "id") == patch_id or Map.get(p, "patch_id") == patch_id
             end) do
          nil ->
            {:error, :no_approved_patch}

          map ->
            case Patch.from_map(map) do
              {:ok, patch} -> {:ok, patch}
              {:error, _} -> {:error, :no_approved_patch}
            end
        end

      {:error, _} ->
        {:error, :no_approved_patch}
    end
  end

  defp build_patch_apply_context(state, plan, patch, workspace) do
    %{
      workspace: workspace,
      session_id: state.session_id,
      muse_id: :coding,
      plan_id: plan.id,
      plan_version: plan.version,
      plan_hash: PlanBinding.content_hash(plan),
      plan_status: plan.status,
      approvals: state.approvals || [],
      pending_patch: patch,
      store_base_dir: state.store_base_dir
    }
  end

  defp emit_apply_success_events(state, result) do
    checkpoint_id = get_in(result.output, [:checkpoint_id]) || "unknown"
    patch_id = get_in(result.output, [:patch_id]) || "unknown"

    {_event, state} =
      emit_session_event(
        state,
        :conductor,
        :patch_applied,
        %{
          patch_id: patch_id,
          checkpoint_id: checkpoint_id,
          status: :applied
        },
        visibility: :user
      )

    {_event, state} =
      emit_session_event(
        state,
        :conductor,
        :checkpoint_created,
        %{
          checkpoint_id: checkpoint_id,
          patch_id: patch_id,
          status: :active
        },
        visibility: :internal
      )

    state
  end

  defp emit_apply_failure_event(state, result) do
    # Strip raw diff from error to avoid leaking in events
    safe_error = truncate_and_redact(result.error, 300)

    {_event, state} =
      emit_session_event(
        state,
        :conductor,
        :patch_apply_failed,
        %{error: safe_error},
        visibility: :user
      )

    state
  end

  defp truncate_and_redact(text, max) when is_binary(text) do
    text
    |> String.slice(0, max)
    |> String.replace(~r/\n---\s+a\//, "\n[diff redacted]")
  end

  defp truncate_and_redact(text, _max), do: inspect(text)

  # -- PR18: Rollback checkpoint ---------------------------------------------------

  defp handle_rollback_checkpoint(state, checkpoint_id) do
    cond do
      turn_running?(state) ->
        {{:error, :turn_running}, state}

      true ->
        do_rollback_checkpoint(state, checkpoint_id)
    end
  end

  defp do_rollback_checkpoint(state, checkpoint_id) do
    workspace = plan_workspace(state.plan) || state.workspace || current_workspace()

    # Build full approved plan context for runtime auth
    {plan_id, plan_version, plan_hash, plan_status} =
      case resolve_active_plan_state(state) do
        {%Plan{} = plan, _id} ->
          {plan.id, plan.version, PlanBinding.content_hash(plan), plan.status}

        nil ->
          {state.active_plan_id, nil, nil, nil}
      end

    context = %{
      workspace: workspace,
      session_id: state.session_id,
      muse_id: :coding,
      plan_id: plan_id,
      plan_version: plan_version,
      plan_hash: plan_hash,
      plan_status: plan_status,
      store_base_dir: state.store_base_dir
    }

    result =
      Muse.Tools.RollbackCheckpoint.execute(
        %{"checkpoint_id" => checkpoint_id},
        context
      )

    {reply, state} =
      if result.success do
        # Emit rollback success events
        state = emit_rollback_success_events(state, result)
        {{:ok, result.output}, state}
      else
        # Emit rollback failure event
        state = emit_rollback_failure_event(state, result)
        {{:error, result.error}, state}
      end

    {reply, state}
  end

  defp emit_rollback_success_events(state, result) do
    checkpoint_id =
      get_in(result.output, [:checkpoint_id]) ||
        get_in(result.output, ["checkpoint_id"]) || "unknown"

    {_event, state} =
      emit_session_event(
        state,
        :conductor,
        :rollback_completed,
        %{
          checkpoint_id: checkpoint_id,
          status: :rolled_back
        },
        visibility: :user
      )

    state
  end

  defp emit_rollback_failure_event(state, result) do
    safe_error = truncate_and_redact(result.error, 300)

    {_event, state} =
      emit_session_event(
        state,
        :conductor,
        :rollback_failed,
        %{error: safe_error},
        visibility: :user
      )

    state
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
      approval_id: approval.id,
      plan_hash: approval.plan_hash,
      content_hash: approval.content_hash,
      task_count: length(plan.tasks)
    }
  end

  defp append_session_events(state, events) do
    %{state | events: state.events ++ events}
  end

  # -- Plan persistence --------------------------------------------------------

  defp restore_plan_from_snapshot(state) do
    case SessionStore.load_session(state.store_base_dir, state.session_id) do
      {:ok, data} ->
        plan_data = Map.get(data, "plan")
        plans_data = Map.get(data, "plans", %{})
        active_plan_id = Map.get(data, "active_plan_id")
        status_str = Map.get(data, "status", "idle")

        plans = restore_plans(plans_data)
        plan = restore_plan(plan_data) || active_plan_from_plans(plans, active_plan_id)

        active_id =
          active_plan_id ||
            if plan, do: plan.id, else: nil

        plans = put_restored_plan(plans, plan, active_id)
        status = safely_atom_status(status_str)

        approvals =
          ApprovalGate.merge_approvals(Map.get(data, "approvals", []), plan_approvals(plan))

        active_approval = active_approval_for_plan(approvals, plan)
        approval_binding = restore_approval_binding(Map.get(data, "approval_binding"))

        {approvals, plan, plans, active_approval, approval_binding} =
          ensure_restored_approval_state(
            status,
            state.session_id,
            plan,
            plans,
            active_id,
            approvals,
            active_approval,
            approval_binding
          )

        # PR17 hardening: restore pending_patch from snapshot (Gap E)
        # Safety: if snapshot status is :awaiting_patch_approval but pending_patch
        # cannot be restored, downgrade to :idle to avoid a stuck session.
        pending_patch = restore_pending_patch(Map.get(data, "pending_patch"))

        # Phase B: restore pending remote approval from snapshot
        pending_remote_approval =
          restore_pending_remote_approval(Map.get(data, "pending_remote_approval"))

        safe_status =
          cond do
            status == :awaiting_patch_approval and is_nil(pending_patch) ->
              :idle

            status == :awaiting_remote_execution_approval and is_nil(pending_remote_approval) ->
              :idle

            true ->
              status
          end

        %{
          state
          | status: safe_status,
            plan: plan,
            plans: plans,
            active_plan_id: active_id,
            approvals: approvals,
            approval_binding: approval_binding,
            active_approval: active_approval,
            pending_patch: pending_patch,
            pending_remote_approval: pending_remote_approval
        }

      _ ->
        state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  defp restore_approval_binding(binding) when is_map(binding), do: binding
  defp restore_approval_binding(_binding), do: nil

  defp ensure_restored_approval_state(
         :awaiting_plan_approval,
         session_id,
         %Plan{status: :awaiting_approval} = plan,
         plans,
         active_id,
         approvals,
         _active_approval,
         approval_binding
       ) do
    workspace = plan_workspace(plan) || current_workspace()

    case ApprovalGate.ensure_pending_plan_approval(session_id, plan, approvals,
           workspace: workspace,
           requested_by: :restore,
           source: :system,
           metadata: %{event: :restore}
         ) do
      {:ok, approval, approvals, plan} ->
        plans = put_restored_plan(plans, plan, active_id)

        approval_binding =
          approval_binding || ApprovalGate.capture_binding(plan, workspace: workspace)

        {approvals, plan, plans, approval, approval_binding}
    end
  end

  defp ensure_restored_approval_state(
         _status,
         _session_id,
         plan,
         plans,
         _active_id,
         approvals,
         active_approval,
         approval_binding
       ) do
    {approvals, plan, plans, active_approval, approval_binding}
  end

  defp plan_approvals(%Plan{} = plan), do: plan.approvals || []
  defp plan_approvals(_), do: []

  defp active_approval_for_plan(approvals, %Plan{id: plan_id}) when is_binary(plan_id) do
    approvals
    |> ApprovalGate.normalize_approvals()
    |> Enum.reverse()
    |> Enum.find(&(&1.plan_id == plan_id and &1.status in [:pending, :approved, :rejected]))
  end

  defp active_approval_for_plan(_approvals, _plan), do: nil

  defp approval_to_map(nil), do: nil
  defp approval_to_map(%Muse.Approval{} = approval), do: Muse.Approval.to_map(approval)
  defp approval_to_map(approval) when is_map(approval), do: approval

  defp restore_plan(nil), do: nil

  defp restore_plan(data) when is_map(data) do
    Plan.from_map(data)
  rescue
    _ -> nil
  end

  defp restore_plan(_), do: nil

  defp restore_pending_patch(nil), do: nil

  defp restore_pending_patch(data) when is_map(data) do
    case Patch.from_map(data) do
      {:ok, %Patch{} = patch} -> patch
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp restore_pending_patch(_data), do: nil

  defp restore_pending_remote_approval(nil), do: nil

  defp restore_pending_remote_approval(data) when is_map(data) do
    Approval.from_map(data)
  rescue
    _ -> nil
  end

  defp restore_pending_remote_approval(_data), do: nil

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

  defp maybe_persist_snapshot(state) do
    # Persist plan/patch/remote-approval-related state as a session snapshot.
    # Only writes when a plan, pending_patch, or pending_remote_approval exists
    # to avoid unnecessary I/O.
    if state.plan != nil or state.pending_patch != nil or state.pending_remote_approval != nil do
      data =
        %{
          status: Atom.to_string(state.status),
          active_muse: state.active_muse,
          active_plan_id: state.active_plan_id,
          approval_binding: state.approval_binding,
          active_approval: approval_to_map(state.active_approval),
          approvals: Enum.map(state.approvals || [], &approval_to_map/1),
          plan: state.plan && Plan.to_map(state.plan),
          plans:
            state.plans
            |> Enum.map(fn {id, p} -> {id, Plan.to_map(p)} end)
            |> Enum.into(%{})
        }
        |> maybe_put_pending_patch(state)
        |> maybe_put_pending_remote_approval(state)

      case SessionStore.save_session(state.store_base_dir, state.session_id, data) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end

    state
  end

  defp maybe_put_pending_patch(data, %{pending_patch: %Patch{} = patch}) do
    Map.put(data, :pending_patch, Patch.to_map(patch))
  end

  defp maybe_put_pending_patch(data, %{pending_patch: %{} = patch}) do
    Map.put(data, :pending_patch, patch)
  end

  defp maybe_put_pending_patch(data, _state), do: data

  defp maybe_put_pending_remote_approval(data, %{pending_remote_approval: %Approval{} = approval}) do
    Map.put(data, :pending_remote_approval, Approval.to_map(approval))
  end

  defp maybe_put_pending_remote_approval(data, %{pending_remote_approval: %{} = approval}) do
    Map.put(data, :pending_remote_approval, approval)
  end

  defp maybe_put_pending_remote_approval(data, _state), do: data

  defp safely_atom_status(str) when is_binary(str) do
    case str do
      "idle" -> :idle
      "running" -> :running
      "awaiting_plan_approval" -> :awaiting_plan_approval
      "awaiting_patch_approval" -> :awaiting_patch_approval
      "awaiting_remote_execution_approval" -> :awaiting_remote_execution_approval
      "awaiting_shell_approval" -> :awaiting_shell_approval
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

  defp get_workspace, do: current_workspace_root()

  defp default_runtime_context do
    root_path = workspace_agent_root_or_nil()

    %{
      store_base_dir: store_base_dir_for_workspace(root_path),
      workspace: root_path || default_workspace()
    }
  end

  defp workspace_agent_root do
    workspace_agent_root_or_nil() || default_workspace()
  end

  defp workspace_agent_root_or_nil do
    case Process.whereis(Muse.Workspace) do
      nil -> nil
      pid -> if Process.alive?(pid), do: Muse.Workspace.root(), else: nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp store_base_dir_for_workspace(nil), do: default_store_base_dir()

  defp store_base_dir_for_workspace(root_path),
    do: Muse.WorkspaceProfile.sessions_dir_from_root(root_path)

  defp default_workspace, do: "/tmp/muse_workspace"
  defp default_store_base_dir, do: ".muse/sessions"

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

  # -- Memory persistence helpers ----------------------------------------------

  defp clear_persisted_memory(store_base_dir, session_id) do
    _ = SessionStore.delete_memory(store_base_dir, session_id)
    :ok
  end

  defp restore_memory(state) do
    if is_nil(state.memory) do
      case SessionStore.load_memory(state.store_base_dir, state.session_id) do
        {:ok, memory} when is_map(memory) ->
          # Fail-closed: validate loaded memory before trusting it.
          # Unsafe legacy memory is rejected (set to nil) rather than used.
          case Memory.validate_loaded_memory(memory) do
            {:ok, safe_memory} ->
              %{state | memory: decode_memory(safe_memory)}

            {:error, {:unsafe_memory, _reasons}} ->
              # Log a warning but don't crash; treat as no valid memory.
              # The unsafe memory is NOT loaded into process state.
              state
          end

        _ ->
          state
      end
    else
      state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  # Decode memory from JSON-persisted form (string keys) back to
  # the atom-keyed canonical form expected by Muse.Memory.render/1
  defp decode_memory(memory) when is_map(memory) do
    # If the memory already has atom keys (e.g. from Memory.new/1),
    # it's already in canonical form
    if Map.has_key?(memory, :user_goal) or Map.has_key?(memory, "user_goal") do
      memory
    else
      memory
    end
  end
end
