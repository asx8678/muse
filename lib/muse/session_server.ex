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

  This server is intentionally **thin**:

    * It appends user/assistant events to the global `Muse.State` log for
      backward compatibility.
    * It does **not** run model calls, tool loops, or any long-blocking
      work — those belong in a `Muse.Conductor.TurnRunner` Task that will
      be introduced by a later PR.
    * It remains responsive for `status` queries even while a turn is
      notionally "in progress".
  """

  use GenServer, restart: :temporary

  alias Muse.Event
  alias Muse.State

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
    {:ok, %{session_id: session_id, status: :idle, events: []}}
  end

  @impl true
  def handle_call({:submit, source, text}, _from, state) do
    # Append user event to global state
    user_event = Event.new(source, :user_message, %{text: text})
    :ok = safe_append_state(user_event)

    # Track all session-local events in order
    session_events = [user_event]

    # Atomically claim queued self-healing issues
    claimed_issues = safe_claim_queued()

    self_healing_event =
      if claimed_issues != [] do
        event = build_self_healing_event(claimed_issues)
        safe_append_state(event)
        event
      end

    session_events =
      if self_healing_event, do: session_events ++ [self_healing_event], else: session_events

    assistant_text =
      if claimed_issues != [] do
        count = length(claimed_issues)

        "Placeholder response: received #{inspect(text)} " <>
          "(#{count} self-healing issue#{if count != 1, do: "s", else: ""} attached)"
      else
        "Placeholder response: received #{inspect(text)}"
      end

    assistant_event = Event.new(:muse, :assistant_message, %{text: assistant_text})
    :ok = safe_append_state(assistant_event)

    session_events = session_events ++ [assistant_event]
    updated_events = state.events ++ session_events
    {:reply, {:ok, assistant_text}, %{state | events: updated_events}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      session_id: state.session_id,
      status: state.status,
      event_count: length(state.events)
    }

    {:reply, reply, state}
  end

  # -- Private helpers ----------------------------------------------------------

  defp safe_append_state(event) do
    State.append(event)
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

  defp build_self_healing_event(issues) do
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

    Event.new(:self_healing, :queued_issues_attached, %{issues: sanitized})
  end
end
