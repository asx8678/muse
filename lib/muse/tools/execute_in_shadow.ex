defmodule Muse.Tools.ExecuteInShadow do
  @moduledoc """
  Run arbitrary commands in an isolated shadow workspace with VFS overlay.

  Creates an ephemeral ShadowWorkspace, overlays files from the ActiveVFS
  (in-memory modifications), executes the requested command, and returns
  structured results. The shadow is always destroyed after execution.

  ## Workflow

  1. Agent edits files in VFS (in-memory)
  2. Agent calls `execute_in_shadow` → VFS content dumped to shadow → command runs → results returned
  3. If command succeeds: agent can flush VFS to disk
  4. If command fails: agent fixes code in VFS, retry

  The agent decides when to test — this is never automatic.

  ## Arguments

    * `command` — (required) shell command to execute in the shadow
    * `timeout_seconds` — (optional) max execution time (default: 60)
    * `files_to_include` — (optional) list of workspace-relative paths to
      overlay from VFS. If omitted, all modified VFS files are overlaid.

  ## Edge cases

    * Command not found → returns error with helpful message
    * Timeout → kills process, returns partial output
    * Shadow creation fails → returns error without crashing the agent
    * VFS has no modified files for requested paths → logs warning, uses originals
    * Very large output (10k+ lines) → truncated to last 200 lines with note
  """

  alias Muse.ActiveVFS
  alias Muse.Prompt.Redactor
  alias Muse.ShadowWorkspace
  alias Muse.Tool.Result

  @default_timeout_seconds 60
  @max_output_lines 10_000
  @truncated_tail_lines 200

  @doc """
  Execute a command in an isolated shadow workspace.

  Returns `%Muse.Tool.Result{}` with structured output including
  exit_code, stdout, stderr, duration_ms, and a summary.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.get(context, :workspace, "")
    command = Map.get(args, "command") || Map.get(args, :command)
    timeout_seconds = parse_timeout(args)
    files_to_include = parse_files_to_include(args)

    cond do
      is_nil(command) or command == "" ->
        Result.error("execute_in_shadow", "command is required")

      not valid_workspace?(workspace) ->
        Result.error("execute_in_shadow", "workspace is not a valid directory: #{workspace}")

      true ->
        run_in_shadow(command, workspace, timeout_seconds, files_to_include)
    end
  end

  # -- Private: shadow lifecycle ------------------------------------------------

  defp run_in_shadow(command, workspace, timeout_seconds, files_to_include) do
    start_time = System.monotonic_time(:millisecond)

    case ShadowWorkspace.create(workspace) do
      {:ok, shadow} ->
        try do
          overlay_vfs_files(shadow, files_to_include)
          timeout_ms = timeout_seconds * 1_000

          case ShadowWorkspace.run(shadow, command, timeout: timeout_ms) do
            {:ok, run_result} ->
              duration_ms = System.monotonic_time(:millisecond) - start_time
              build_result(run_result, command, duration_ms)
          end
        after
          ShadowWorkspace.destroy(shadow)
        end

      {:error, reason} ->
        Result.error("execute_in_shadow", "shadow creation failed: #{inspect(reason)}")
    end
  end

  # -- Private: VFS overlay ----------------------------------------------------

  defp overlay_vfs_files(shadow, files_to_include) do
    paths = resolve_overlay_paths(files_to_include)

    Enum.each(paths, fn path ->
      case ActiveVFS.read(path) do
        {:ok, content} ->
          case ShadowWorkspace.write_file(shadow, path, content) do
            :ok ->
              :ok

            {:error, reason} ->
              require Logger
              Logger.warning("ExecuteInShadow: failed to overlay #{path}: #{inspect(reason)}")
          end

        {:error, reason} ->
          require Logger
          Logger.warning("ExecuteInShadow: VFS read failed for #{path}: #{inspect(reason)}")
      end
    end)
  end

  # If files_to_include is explicitly provided, use that list.
  # Otherwise, overlay all modified VFS files (version > 0).
  defp resolve_overlay_paths(nil), do: safe_modified_files()
  defp resolve_overlay_paths([]), do: safe_modified_files()
  defp resolve_overlay_paths(paths) when is_list(paths), do: paths

  defp safe_modified_files do
    try do
      case Process.whereis(ActiveVFS) do
        nil -> []
        _pid -> ActiveVFS.modified_files()
      end
    rescue
      _ -> []
    end
  end

  # -- Private: result construction ---------------------------------------------

  defp build_result(run_result, command, duration_ms) do
    stdout = truncate_output(run_result.stdout)
    stderr = run_result.stderr || ""
    exit_code = run_result.exit_code
    timed_out = Map.get(run_result, :timed_out, false)

    passed = exit_code == 0 and not timed_out
    summary = build_summary(exit_code, stdout, timed_out)

    Result.ok("execute_in_shadow", %{
      exit_code: exit_code,
      stdout: redact_output(stdout),
      stderr: redact_output(stderr),
      passed: passed,
      summary: summary,
      duration_ms: duration_ms,
      timed_out: timed_out,
      command: command
    })
  end

  # -- Private: output truncation ----------------------------------------------

  defp truncate_output(output) when is_binary(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_output_lines do
      tail = Enum.take(lines, -@truncated_tail_lines)

      "[output truncated: showing last #{@truncated_tail_lines} of #{length(lines)} lines]\n" <>
        Enum.join(tail, "\n")
    else
      output
    end
  end

  defp truncate_output(output), do: output

  # -- Private: summary ---------------------------------------------------------

  defp build_summary(_exit_code, _stdout, true) do
    "command timed out"
  end

  defp build_summary(0, _stdout, false) do
    "command succeeded (exit code 0)"
  end

  defp build_summary(exit_code, _stdout, false) do
    "command failed (exit code #{exit_code})"
  end

  # -- Private: safety helpers --------------------------------------------------

  defp valid_workspace?(workspace) when is_binary(workspace) do
    File.dir?(workspace)
  end

  defp valid_workspace?(_), do: false

  defp parse_timeout(args) do
    raw = Map.get(args, "timeout_seconds") || Map.get(args, :timeout_seconds)

    case raw do
      nil ->
        @default_timeout_seconds

      n when is_integer(n) and n > 0 ->
        min(n, 600)

      n when is_binary(n) ->
        case Integer.parse(n) do
          {val, _} when val > 0 -> min(val, 600)
          _ -> @default_timeout_seconds
        end

      _ ->
        @default_timeout_seconds
    end
  end

  defp parse_files_to_include(args) do
    raw = Map.get(args, "files_to_include") || Map.get(args, :files_to_include)

    case raw do
      nil -> nil
      paths when is_list(paths) -> Enum.filter(paths, &is_binary/1)
      _ -> nil
    end
  end

  defp redact_output(text) when is_binary(text) do
    Redactor.redact_text(text)
  end

  defp redact_output(text), do: text
end
