defmodule Muse.SessionServer.Telemetry do
  @moduledoc """
  Telemetry helpers for `Muse.SessionServer` lifecycle events.

  Emits `:telemetry` events for session creation, loading, and
  termination. All functions are side-effecting but crash-safe —
  `terminate/2` must never crash since the process is already shutting down.

  ## Lifecycle

  - `emit_session_lifecycle_telemetry/3` — called during `init/1` to
    distinguish new sessions from restored sessions.
  - `emit_session_ended_telemetry/2` — called from `terminate/2` to
    record session duration and exit status.
  """

  alias Muse.Telemetry, as: MuseTelemetry

  @doc """
  Emit telemetry for session creation or restoration.

  `snapshot_exists?` controls which event is emitted:
  - `true`  → `[:muse, :session, :loaded]`
  - `false` → `[:muse, :session, :created]`
  """
  @spec emit_session_lifecycle_telemetry(String.t(), String.t() | nil, boolean()) :: :ok
  def emit_session_lifecycle_telemetry(session_id, _workspace, true = _snapshot_exists?) do
    try do
      :telemetry.execute(
        MuseTelemetry.session_loaded(),
        %{},
        MuseTelemetry.session_loaded_metadata(session_id: session_id)
      )
    catch
      _kind, _reason -> :ok
    end
  end

  def emit_session_lifecycle_telemetry(session_id, workspace, false = _snapshot_exists?) do
    try do
      :telemetry.execute(
        MuseTelemetry.session_created(),
        %{},
        MuseTelemetry.session_created_metadata(session_id: session_id, workspace: workspace)
      )
    catch
      _kind, _reason -> :ok
    end
  end

  @doc """
  Emit telemetry for session termination.

  Records session duration and exit reason (shutdown vs. crash).
  Crash-safe: never raises, since this is called from `terminate/2`.
  """
  @spec emit_session_ended_telemetry(term(), map()) :: :ok
  def emit_session_ended_telemetry(reason, state) do
    try do
      session_id = state.session_id
      session_start = Map.get(state, :session_start_time)

      duration =
        if session_start do
          max(System.monotonic_time(:millisecond) - session_start, 0)
        else
          0
        end

      status = session_ended_status(reason)

      :telemetry.execute(
        MuseTelemetry.session_ended(),
        MuseTelemetry.session_ended_measurements(duration),
        MuseTelemetry.session_ended_metadata(
          session_id: session_id,
          status: status,
          reason: reason
        )
      )
    catch
      # terminate/2 must never crash — the process is already shutting down.
      _kind, _reason -> :ok
    end
  end

  @doc "Classify a termination reason as :shutdown or :crashed."
  @spec session_ended_status(term()) :: :shutdown | :crashed
  def session_ended_status(:normal), do: :shutdown
  def session_ended_status(:shutdown), do: :shutdown
  def session_ended_status({:shutdown, _}), do: :shutdown
  def session_ended_status(_), do: :crashed
end
