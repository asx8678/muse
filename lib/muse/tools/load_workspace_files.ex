defmodule Muse.Tools.LoadWorkspaceFiles do
  @moduledoc """
  Read-only tool: load specific files into the in-memory VFS for editing.

  For each file path, calls `Muse.ActiveVFS.read/1` which triggers a
  lazy load from disk into memory. Returns the loaded content and
  summaries to the agent.

  ## Idempotency

  Loading the same file twice is safe — if the VFS already has the file
  in memory, `read/1` simply returns the cached content.

  ## Output format

      %{
        loaded_count: 3,
        files: [
          %{path: "lib/foo.ex", lines: 42, status: :loaded},
          %{path: "lib/missing.ex", lines: 0, status: :not_found},
          ...
        ],
        errors: ["lib/missing.ex: not_found"]
      }
  """

  alias Muse.Tool.Result

  @doc """
  Execute the load_workspace_files tool.

  ## Arguments

    * `"files"` — list of relative file paths to load (required)
    * `"purpose"` — why these files are needed (optional, for observability)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, _context) do
    with {:ok, files} <- require_files(args) do
      _purpose = Map.get(args, "purpose")
      do_load(files)
    else
      {:error, reason} -> Result.error("load_workspace_files", reason)
    end
  end

  defp require_files(args) do
    case Map.get(args, "files") do
      nil ->
        {:error, "files is required"}

      files when is_list(files) ->
        if Enum.all?(files, &is_binary/1) do
          {:ok, files}
        else
          {:error, "files must be a list of strings"}
        end

      _ ->
        {:error, "files must be a list of strings"}
    end
  end

  defp do_load(files) do
    case Process.whereis(Muse.ActiveVFS) do
      nil ->
        Result.error("load_workspace_files", "VFS not available")

      _pid ->
        {file_results, errors} =
          Enum.reduce(files, {[], []}, fn path, {results, errs} ->
            case Muse.ActiveVFS.read(path) do
              {:ok, content} ->
                line_count = content |> String.split("\n") |> length()
                entry = %{path: path, lines: line_count, status: :loaded}
                {[entry | results], errs}

              {:error, :not_found} ->
                entry = %{path: path, lines: 0, status: :not_found}
                {[entry | results], ["#{path}: not_found" | errs]}

              {:error, reason} ->
                entry = %{path: path, lines: 0, status: :error}
                {[entry | results], ["#{path}: #{inspect(reason)}" | errs]}
            end
          end)

        # Reverse to preserve input order
        file_results = Enum.reverse(file_results)
        errors = Enum.reverse(errors)
        loaded_count = Enum.count(file_results, &(&1.status == :loaded))

        Result.ok("load_workspace_files", %{
          loaded_count: loaded_count,
          files: file_results,
          errors: errors
        })
    end
  end
end
