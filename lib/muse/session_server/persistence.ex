defmodule Muse.SessionServer.Persistence do
  @moduledoc """
  Persistence helpers for `Muse.SessionServer`.

  Provides explicit-failure wrappers around `SessionStore` write
  operations (patch, memory, snapshot). All failures are logged via
  `Logger.warning/1` and an internal `:persistence_failed` event is
  emitted so downstream consumers can observe degradation without
  the GenServer crashing.

  ## Lifecycle

  Called from `SessionServer` `handle_call`/`handle_info` callbacks
  whenever a patch, memory, or snapshot needs to be written to disk.
  These are fire-and-forget from the GenServer perspective — a
  persistence failure does not crash the session process.

  All functions are side-effecting (I/O) and return `:ok`.
  """

  require Logger

  alias Muse.{Event, Patch, SessionStore}

  @doc """
  Append a patch to the session's JSONL patches file.

  Logs and emits a diagnostic event on failure instead of crashing.
  """
  @spec persist_patch(String.t(), String.t(), Patch.t()) :: :ok
  def persist_patch(store_base_dir, session_id, %Patch{} = patch) do
    case SessionStore.append_patch(store_base_dir, session_id, Patch.to_map(patch)) do
      :ok ->
        :ok

      {:error, reason} ->
        log_persistence_failure(:append_patch, session_id, reason)
    end
  end

  @doc """
  Delete the persisted memory file for a session.

  Logs and emits a diagnostic event on failure instead of crashing.
  """
  @spec clear_persisted_memory(String.t(), String.t()) :: :ok
  def clear_persisted_memory(store_base_dir, session_id) do
    case SessionStore.delete_memory(store_base_dir, session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        log_persistence_failure(:delete_memory, session_id, reason)
    end
  end

  @doc """
  Persist session state snapshot via `SessionStore.save_session/3`.

  Takes the full GenServer state and a pre-built snapshot data map
  (from `StateRestoration.build_snapshot_data/1`). No-op if `data` is `nil`.
  """
  @spec persist_snapshot(String.t(), String.t(), map() | nil) :: :ok
  def persist_snapshot(_store_base_dir, _session_id, nil), do: :ok

  def persist_snapshot(store_base_dir, session_id, data) when is_map(data) do
    case SessionStore.save_session(store_base_dir, session_id, data) do
      :ok ->
        :ok

      {:error, reason} ->
        log_persistence_failure(:save_session, session_id, reason)
    end
  end

  @doc """
  Log a persistence failure and emit an internal diagnostic event.

  The reason is reduced to a short, safe, bounded string that never
  includes full event/session payloads or secrets.
  """
  @spec log_persistence_failure(atom(), String.t(), term()) :: :ok
  def log_persistence_failure(operation, session_id, reason) do
    safe_reason = safe_persistence_reason(reason)

    Logger.warning("Persistence failure",
      operation: operation,
      session_id: session_id,
      reason: safe_reason
    )

    # Emit an internal diagnostic event so consumers can observe failures.
    safe_append_state(
      Event.new(:system, :persistence_failed, %{operation: operation, reason: safe_reason},
        session_id: session_id,
        visibility: :internal
      )
    )

    :ok
  end

  # -- Private helpers ----------------------------------------------------------

  # Reduce persistence error reasons to a short, safe, bounded string
  # that never includes full event/session payloads or secrets.
  defp safe_persistence_reason({:mkdir_failed, posix, _dir}),
    do: "mkdir_failed:#{posix}"

  defp safe_persistence_reason({:write_failed, posix}) when is_atom(posix),
    do: "write_failed:#{posix}"

  defp safe_persistence_reason({:encode_failed, _reason}),
    do: "encode_failed"

  defp safe_persistence_reason({:invalid_session_id, _id}),
    do: "invalid_session_id"

  defp safe_persistence_reason({:delete_failed, posix}) when is_atom(posix),
    do: "delete_failed:#{posix}"

  defp safe_persistence_reason(reason) when is_atom(reason),
    do: Atom.to_string(reason)

  defp safe_persistence_reason(reason) when is_binary(reason),
    do: String.slice(reason, 0, 80)

  defp safe_persistence_reason(_),
    do: "unknown"

  defp safe_append_state(event) do
    case Process.whereis(Muse.State) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: Muse.State.append(event), else: :ok
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :safe_append_state, e)
      :ok
  catch
    :exit, reason ->
      Muse.Diagnostics.SilentRescue.log_rescued_catch(
        __MODULE__,
        :safe_append_state,
        :exit,
        reason
      )

      :ok
  end
end
