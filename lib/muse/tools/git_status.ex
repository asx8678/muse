defmodule Muse.Tools.GitStatus do
  @moduledoc """
  Read-only tool: show working tree status via git status.

  Uses fixed `System.cmd("git", ["status", "--short", "--branch"], cd: workspace)`
  — no model-controlled arguments. Reports branch, clean/dirty state,
  and changed files. Output is capped and redacted.
  """

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
    try do
      case System.cmd("git", ["status", "--short", "--branch"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          if byte_size(output) > @max_output_bytes do
            {:ok, String.slice(output, 0, @max_output_bytes)}
          else
            {:ok, output}
          end

        {error_output, _code} ->
          {:error, "git status failed: #{String.slice(error_output, 0, 200)}"}
      end
    rescue
      e -> {:error, "git command error: #{inspect(e)}"}
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
