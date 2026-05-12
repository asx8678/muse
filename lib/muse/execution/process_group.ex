defmodule Muse.Execution.ProcessGroup do
  @moduledoc """
  Process group cleanup for local command execution.

  On Unix, commands spawned via `Port.open({:spawn_executable, ...}, ...)`
  become process group leaders (PGID == PID). Children inherit the PGID
  by default. This module kills the **entire process group** on timeout,
  preventing orphaned child processes.

  On Windows, process-group cleanup is unavailable. The module falls back
  gracefully by closing the port only and returning a diagnostic indicating
  that full tree cleanup is not supported on the current platform.

  ## Platform support

    * **Unix (macOS, Linux, BSD)** — full process group termination via
      `kill -TERM -<pgid>`, followed by `kill -KILL -<pgid>` after a
      short grace period. Children that stay in the parent's process
      group are killed along with the leader.
    * **Windows** — no process-group cleanup. Windows job object support
      (`CreateJobObject` + `AssignProcessToJobObject` with
      `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) would require a Rust NIF —
      not currently implemented. Only the port is closed. Child processes
      may survive a timeout. The caller receives a diagnostic note so
      operators know the limitation applies.

  ## Safety

    * Only kills process groups identified by a PID obtained from
      `Port.info/2`. The PID is resolved *before* closing the port
      to avoid TOCTOU races.
    * All kill operations are best-effort. If the process group has
      already exited, the kill is a no-op.
    * Helper commands are invoked through argv-vector `System.cmd/3`
      with fixed executable names and integer-derived arguments; no shell
      interpolation or network calls are used.

  ## Diagnostics

    `terminate_group/2` returns a map with structured information about
    the cleanup attempt, suitable for inclusion in `Result.metadata`.
  """

  require Logger

  @type cleanup_diagnostic :: %{
          :platform => :unix | :windows | :unknown,
          :pgid_available => boolean(),
          :os_pid => non_neg_integer() | nil,
          :pgid => non_neg_integer() | nil,
          optional(:kill_result) => :ok | :enosr | :eperm | :error | {:error, term()},
          optional(:force_kill_result) => :ok | :enosr | :eperm | :error | {:error, term()},
          optional(:fallback_reason) => String.t()
        }

  @doc """
  Terminate the process group associated with a port.

  On Unix, reads the OS PID from the port, then sends SIGTERM to the
  process group (`kill -TERM -<pgid>`). After `force_after_ms`, sends
  SIGKILL to any remaining processes in the group. Returns a diagnostic
  map describing what happened.

  On Windows or when the PID is unavailable, returns a diagnostic map
  with `pgid_available: false`.

  ## Options

    * `:force_after_ms` — milliseconds to wait before sending SIGKILL
      after SIGTERM (default: `500`). Only applies on Unix.

  ## Returns

  A diagnostic map with at minimum:

    * `:platform` — `:unix`, `:windows`, or `:unknown`
    * `:pgid_available` — whether process-group kill was possible
    * `:os_pid` — the OS PID from `Port.info/2`, or `nil`
    * `:pgid` — the process group ID, or `nil`
  """
  @spec terminate_group(port(), keyword()) :: cleanup_diagnostic()
  def terminate_group(port, opts \\ []) do
    force_after_ms = Keyword.get(opts, :force_after_ms, 500)

    case :os.type() do
      {:unix, _} -> terminate_unix(port, force_after_ms)
      {:win32, _} -> terminate_windows(port)
      _ -> terminate_unknown(port)
    end
  end

  @doc """
  Return the OS PID of the process behind a port, or `nil`.

  Safe wrapper around `Port.info(port, :os_pid)` that returns `nil`
  when the port has already exited.
  """
  @spec get_os_pid(port()) :: non_neg_integer() | nil
  def get_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  @doc """
  Read the process group ID (PGID) for a given PID on Unix.

  Returns `{:ok, pgid}` or `{:error, reason}`. Only works on Unix.
  """
  @spec read_pgid(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def read_pgid(pid) when is_integer(pid) and pid > 0 do
    case :os.type() do
      {:unix, _} ->
        case System.cmd("ps", ["-o", "pgid=", "-p", to_string(pid)], stderr_to_stdout: true) do
          {output, 0} ->
            case output |> String.trim() |> String.to_integer() do
              pgid when is_integer(pgid) and pgid > 0 -> {:ok, pgid}
              _ -> {:error, "invalid pgid from ps"}
            end

          {output, _exit_code} ->
            {:error, "ps failed: #{String.trim(output)}"}
        end

      _ ->
        {:error, "pgid not available on non-Unix platform"}
    end
  rescue
    e -> {:error, "pgid read error: #{Exception.message(e)}"}
  end

  @doc """
  Check whether process-group termination is available on this platform.
  """
  @spec platform_supported?() :: boolean()
  def platform_supported? do
    match?({:unix, _}, :os.type())
  end

  # -- Unix implementation ------------------------------------------------------

  defp terminate_unix(port, force_after_ms) do
    os_pid = get_os_pid(port)

    case os_pid do
      nil ->
        # Process already exited — nothing to kill
        %{
          platform: :unix,
          pgid_available: false,
          os_pid: nil,
          pgid: nil,
          fallback_reason: "process already exited before cleanup"
        }

      pid ->
        terminate_unix_group(port, pid, force_after_ms)
    end
  end

  defp terminate_unix_group(port, pid, force_after_ms) do
    case read_pgid(pid) do
      {:ok, ^pid} ->
        # Send SIGTERM to the whole process group. Only use negative-PGID
        # signaling when the port process is the process-group leader; otherwise
        # a Unix/runtime variation could make this kill an unrelated group.
        term_result = kill_group(pid, "TERM")

        Logger.info("Process group terminated on timeout",
          pgid: pid,
          os_pid: pid,
          kill_result: term_result
        )

        force_kill_result = maybe_force_kill_group(pid, force_after_ms)

        %{
          platform: :unix,
          pgid_available: true,
          os_pid: pid,
          pgid: pid,
          kill_result: term_result
        }
        |> maybe_put_force_kill_result(force_kill_result)

      {:ok, pgid} ->
        terminate_leader_only(
          port,
          pid,
          pgid,
          force_after_ms,
          "port process is not process-group leader"
        )

      {:error, reason} ->
        terminate_leader_only(port, pid, nil, force_after_ms, "pgid unavailable (#{reason})")
    end
  end

  defp terminate_leader_only(port, pid, pgid, force_after_ms, reason) do
    term_result = kill_port_pid_if_alive(port, pid, "TERM")

    Logger.warning("Process group cleanup incomplete on timeout",
      os_pid: pid,
      pgid: pgid,
      fallback_reason: reason,
      kill_result: term_result
    )

    force_kill_result = maybe_force_kill_pid(port, pid, force_after_ms)

    %{
      platform: :unix,
      pgid_available: false,
      os_pid: pid,
      pgid: pgid,
      kill_result: term_result,
      fallback_reason: "#{reason}; killed leader only"
    }
    |> maybe_put_force_kill_result(force_kill_result)
  end

  defp maybe_force_kill_group(pgid, force_after_ms) when force_after_ms > 0 do
    Process.sleep(force_after_ms)
    {:attempted, kill_group(pgid, "KILL")}
  end

  defp maybe_force_kill_group(_pgid, _force_after_ms), do: :not_attempted

  defp maybe_force_kill_pid(port, pid, force_after_ms) when force_after_ms > 0 do
    Process.sleep(force_after_ms)
    {:attempted, kill_port_pid_if_alive(port, pid, "KILL")}
  end

  defp maybe_force_kill_pid(_port, _pid, _force_after_ms), do: :not_attempted

  defp kill_port_pid_if_alive(port, pid, signal) do
    case get_os_pid(port) do
      ^pid -> kill_pid(pid, signal)
      _ -> :enosr
    end
  end

  defp maybe_put_force_kill_result(diagnostic, {:attempted, result}) do
    Map.put(diagnostic, :force_kill_result, result)
  end

  defp maybe_put_force_kill_result(diagnostic, :not_attempted), do: diagnostic

  # Send a signal to an entire process group (negative PGID).
  # Best-effort: if the group is already gone, the kill fails silently.
  defp kill_group(pgid, signal) when is_integer(pgid) and pgid > 0 do
    case System.cmd("kill", ["-#{signal}", "-#{pgid}"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        msg = String.trim(output)

        cond do
          String.contains?(msg, "No such process") -> :enosr
          String.contains?(msg, "Operation not permitted") -> :eperm
          true -> {:error, msg}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Send a signal to a single PID (fallback when PGID is unavailable).
  defp kill_pid(pid, signal) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-#{signal}", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Windows fallback ---------------------------------------------------------

  # Windows job object support (CreateJobObject + AssignProcessToJobObject
  # with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) would require a Rust NIF —
  # not currently implemented. Only the port is closed; child processes
  # may survive timeout.
  defp terminate_windows(port) do
    os_pid = get_os_pid(port)

    # On Windows, we cannot kill process groups via Unix signals.
    # The port close (done by the caller) is the only cleanup.
    Logger.warning(
      "Process group cleanup unavailable on Windows; " <>
        "child processes may survive timeout (os_pid: #{inspect(os_pid)})"
    )

    %{
      platform: :windows,
      pgid_available: false,
      os_pid: os_pid,
      pgid: nil,
      fallback_reason: "process group termination not supported on Windows"
    }
  end

  # -- Unknown platform ---------------------------------------------------------

  defp terminate_unknown(port) do
    os_pid = get_os_pid(port)

    %{
      platform: :unknown,
      pgid_available: false,
      os_pid: os_pid,
      pgid: nil,
      fallback_reason: "unknown platform; process group termination not available"
    }
  end
end
