defmodule Muse.Tools.GitDiffReadonly do
  @moduledoc """
  Read-only tool: show git diff output.

  Supports an optional workspace-relative path and cached flag.
  No write commands; output is capped and redacted. Uses
  Execution.LocalRunner (PR24) for safe argv-vector execution.
  """

  alias Muse.Execution.{Command, LocalRunner}
  alias Muse.Execution.Result, as: ExecutionResult
  alias Muse.Tool.Result

  @max_output_bytes 100_000

  @doc """
  Execute the git_diff_readonly tool.

  ## Arguments

    * `"path"` — workspace-relative path to diff (optional)
    * `"cached"` — show staged changes (default: false)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.fetch!(context, :workspace)
    cached = Map.get(args, "cached", false)
    rel_path = Map.get(args, "path")

    with {:ok, validated_path} <- validate_path(rel_path, workspace),
         {:ok, output} <- run_git_diff(workspace, validated_path, cached) do
      Result.ok("git_diff_readonly", %{
        path: validated_path,
        cached: cached,
        diff: cap_output(output),
        truncated: byte_size(output) > @max_output_bytes,
        byte_size: byte_size(output)
      })
    else
      {:error, reason} ->
        Result.error("git_diff_readonly", reason)
    end
  end

  defp validate_path(nil, _workspace), do: {:ok, nil}

  defp validate_path(path, workspace) when is_binary(path) do
    # Validate the path is workspace-relative and doesn't escape
    try do
      _resolved = Muse.Workspace.safe_resolve!(path, workspace, allow_git_contents: true)
      {:ok, path}
    rescue
      ArgumentError -> {:error, "path escapes workspace or violates safety rules"}
    end
  end

  defp validate_path(_, _), do: {:error, "path must be a string"}

  defp run_git_diff(workspace, nil, false) do
    run_cmd(workspace, ["diff"])
  end

  defp run_git_diff(workspace, nil, true) do
    run_cmd(workspace, ["diff", "--cached"])
  end

  defp run_git_diff(workspace, rel_path, false) do
    # Path is validated above; pass as a fixed arg to avoid shell interpolation
    run_cmd(workspace, ["diff", "--", rel_path])
  end

  defp run_git_diff(workspace, rel_path, true) do
    run_cmd(workspace, ["diff", "--cached", "--", rel_path])
  end

  defp run_cmd(workspace, args) do
    # Use Execution.LocalRunner (PR24) for safe argv-vector execution
    case Command.new("git",
           args: args,
           cwd: workspace,
           timeout_ms: 60_000,
           max_output_bytes: @max_output_bytes
         ) do
      {:ok, cmd} ->
        case LocalRunner.run(cmd) do
          {:ok, %ExecutionResult{status: :ok, output: output}} ->
            {:ok, output}

          {:ok, %ExecutionResult{status: status, error: error}} ->
            {:error, "git diff failed (#{status}): #{String.slice(to_string(error), 0, 200)}"}

          {:error, %ExecutionResult{error: error}} ->
            {:error, "git diff failed: #{String.slice(to_string(error), 0, 200)}"}

          {:error, reason} ->
            {:error, "git command error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "command validation failed: #{reason}"}
    end
  end

  defp cap_output(output) when byte_size(output) > @max_output_bytes do
    String.slice(output, 0, @max_output_bytes)
  end

  defp cap_output(output), do: output
end
