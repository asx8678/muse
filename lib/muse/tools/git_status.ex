defmodule Muse.Tools.GitStatus do
  @moduledoc """
  Read-only tool: show working tree status via git status.

  Uses fixed git command via Execution.LocalRunner (PR24) —
  no model-controlled arguments. Reports branch, clean/dirty state,
  and changed files. Output is capped and redacted.
  """

  alias Muse.Execution.{Command, LocalRunner}
  alias Muse.Execution.Result, as: ExecutionResult
  alias Muse.Tool.Result

  @max_output_bytes 20_000

  @doc """
  Execute the git_status tool.

  No arguments are accepted from the model — the command is fully fixed.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(_args, context) do
    workspace = Map.fetch!(context, :workspace)

    case run_git_status(workspace) do
      {:ok, output} ->
        Result.ok("git_status", parse_output(output, workspace))

      {:error, reason} ->
        Result.error("git_status", reason)
    end
  end

  defp run_git_status(workspace) do
    # Use Execution.LocalRunner (PR24) for safe argv-vector execution
    case Command.new("git",
           args: ["status", "--short", "--branch"],
           cwd: workspace,
           timeout_ms: 30_000,
           max_output_bytes: @max_output_bytes
         ) do
      {:ok, cmd} ->
        case LocalRunner.run(cmd) do
          {:ok, %ExecutionResult{status: :ok, output: output}} ->
            {:ok, output}

          {:ok, %ExecutionResult{status: status, error: error}} ->
            {:error, "git status failed (#{status}): #{error}"}

          {:error, %ExecutionResult{error: error}} ->
            {:error, "git status failed: #{error}"}

          {:error, reason} ->
            {:error, "git command error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "command validation failed: #{reason}"}
    end
  end

  defp parse_output(output, _workspace) do
    lines = String.split(output, "\n", trim: true)

    {branch, file_lines} =
      Enum.split_with(lines, &String.starts_with?(&1, "## "))

    branch_name =
      case branch do
        [line | _] ->
          line |> String.replace_prefix("## ", "") |> String.split("...") |> hd() |> String.trim()

        [] ->
          "unknown"
      end

    clean? = file_lines == []

    files =
      file_lines
      |> Enum.map(fn line ->
        # Format: "XY filename"
        line
        |> String.slice(3..-1//1)
        |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))

    %{
      branch: branch_name,
      clean: clean?,
      files: files,
      file_count: length(files)
    }
  end
end
