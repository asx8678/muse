defmodule Muse.Tools.ListFiles do
  @moduledoc """
  Read-only tool: list files and directories in the workspace.

  Returns sorted entries with paths relative to workspace root.
  Respects ignored and secret path rules. Hidden files are blocked
  by default unless `allow_hidden` is true.

  ## Output format

      %{
        root: "/path/to/workspace",
        entries: ["lib/muse.ex", "lib/muse/workspace.ex", ...],
        truncated: false
      }
  """

  alias Muse.Tool.Result

  @default_max_entries 500

  @doc """
  Execute the list_files tool.

  ## Arguments

    * `"path"` — relative directory within workspace (default: root)
    * `"max_entries"` — cap on number of entries (default: 500)
    * `"allow_hidden"` — include hidden files (default: false)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.fetch!(context, :workspace)
    rel_path = Map.get(args, "path", ".")
    max_entries = Map.get(args, "max_entries", @default_max_entries)
    allow_hidden = Map.get(args, "allow_hidden", false)

    # NOT allow_git_contents — list_files never exposes .git contents;
    # allow_git_contents is reserved for dedicated git tools only
    opts = [allow_hidden: allow_hidden]

    with {:ok, resolved} <- safe_resolve(rel_path, workspace, opts),
         {:ok, _} <- ensure_directory(resolved) do
      entries =
        resolved
        |> do_list(workspace, allow_hidden)
        |> Enum.sort()

      {visible, truncated?} = cap_entries(entries, max_entries)

      Result.ok("list_files", %{
        root: workspace,
        entries: visible,
        truncated: truncated?
      })
    else
      {:error, reason} ->
        Result.error("list_files", reason)
    end
  end

  defp safe_resolve(rel_path, workspace, opts) do
    try do
      {:ok, Muse.Workspace.safe_resolve!(rel_path, workspace, opts)}
    rescue
      ArgumentError -> {:error, "path escapes workspace or violates safety rules"}
    end
  end

  defp ensure_directory(path) do
    if File.dir?(path) do
      {:ok, path}
    else
      {:error, "path is not a directory"}
    end
  end

  defp do_list(resolved, workspace, allow_hidden) do
    resolved
    |> File.ls!()
    |> Enum.reject(fn entry ->
      full = Path.join(resolved, entry)

      cond do
        not allow_hidden and hidden?(entry) -> true
        Muse.Workspace.secret_path?(full, workspace) -> true
        Muse.Workspace.ignored_path?(full, workspace, []) -> true
        true -> false
      end
    end)
    |> Enum.flat_map(fn entry ->
      full = Path.join(resolved, entry)
      rel = Path.relative_to(full, workspace)

      # Validate each entry resolves safely (catches symlinks that
      # point outside the workspace even after the above checks).
      if safe_entry?(rel, workspace, allow_hidden) do
        if File.dir?(full) do
          [rel <> "/"]
        else
          [rel]
        end
      else
        []
      end
    end)
  end

  defp safe_entry?(rel, workspace, allow_hidden) do
    try do
      Muse.Workspace.safe_resolve!(rel, workspace, allow_hidden: allow_hidden)
      true
    rescue
      ArgumentError -> false
    end
  end

  defp hidden?(<<".", rest::binary>>) when rest != "", do: true
  defp hidden?(_), do: false

  defp cap_entries(entries, max) when length(entries) <= max do
    {entries, false}
  end

  defp cap_entries(entries, max) do
    {Enum.take(entries, max), true}
  end
end
