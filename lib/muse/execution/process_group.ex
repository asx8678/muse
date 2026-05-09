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
    * **Windows** — no process-group cleanup. Only the port is closed.
      Children may survive. The caller receives a diagnostic note so
      operators know the limitation applies.

  ## Safety

    * Only kills process groups identified by a PID obtained from
      `Port.info/2`. The PID is resolved *before* closing the port
      to avoid TOCTOU races.
    * All kill operations are best-effort. If the process group has
      already exited, the kill is a no-op.
    * This module never spawns new processes or makes network calls.

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
        terminate_unix_group(pid, force_after_ms)
    end
  end

  defp terminate_unix_group(pid, force_after_ms) do
    case read_pgid(pid) do
      {:ok, pgid} ->
        # Send SIGTERM to the whole process group
        term_result = kill_group(pgid, "TERM")

        Logger.info("Process group terminated on timeout",
          pgid: pgid,
          os_pid: pid,
          kill_result: term_result
        )

        # Wait briefly, then SIGKILL any survivors
        if force_after_ms > 0 do
          Process.sleep(force_after_ms)
          kill_group(pgid, "KILL")
        end

        %{
          platform: :unix,
          pgid_available: true,
          os_pid: pid,
          pgid: pgid,
          kill_result: term_result
        }

      {:error, reason} ->
        # PGID unavailable (process may have just exited)
        # Best-effort: try killing just the leader PID
        term_result = kill_pid(pid, "TERM")

        Logger.warning("Process group cleanup incomplete on timeout",
          os_pid: pid,
          fallback_reason: reason,
          kill_result: term_result
        )

        if force_after_ms > 0 do
          Process.sleep(force_after_ms)
          kill_pid(pid, "KILL")
        end

        %{
          platform: :unix,
          pgid_available: false,
          os_pid: pid,
          pgid: nil,
          kill_result: term_result,
          fallback_reason: "pgid unavailable (#{reason}); killed leader only"
        }
    end
  end

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
