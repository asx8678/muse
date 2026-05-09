defmodule Muse.Tools.RepoSearch do
  @moduledoc """
  Read-only tool: search for text patterns across workspace files.

  Uses a pure-Elixir scanner baseline (no external ripgrep dependency).
  Avoids searching ignored, secret, and hidden paths. Every directory/file
  path is validated via `Muse.Workspace.safe_resolve!/3` before FS access
  to prevent symlink escapes. Output is capped.

  ## Output format

      %{
        pattern: "defmodule",
        results: [%{file: "lib/muse.ex", line: 1, excerpt: "defmodule Muse do"}, ...],
        truncated: false,
        backend: :elixir,
        total_matches: 5
      }
  """

  alias Muse.Tool.Result

  @default_max_results 50
  @max_per_file_bytes 100_000

  @doc """
  Execute the repo_search tool.

  ## Arguments

    * `"pattern"` — text pattern to search for (required)
    * `"max_results"` — max number of results (default: 50)
    * `"file_pattern"` — glob to filter files (e.g. `"*.ex"`)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.get(context, :workspace, "")

    if not is_binary(workspace) or workspace == "" do
      Result.error("repo_search", "workspace is required in context")
    else
      do_execute(args, workspace)
    end
  end

  defp do_execute(args, workspace) do
    with {:ok, pattern} <- require_pattern(args) do
      max_results = Map.get(args, "max_results", @default_max_results)
      file_pattern = Map.get(args, "file_pattern")

      {results, more_exist?} = scan_workspace(workspace, pattern, file_pattern, max_results)
      {visible, cap_truncated?} = cap_results(results, max_results)

      output = %{
        pattern: pattern,
        results: visible,
        truncated: more_exist? or cap_truncated?,
        backend: :elixir,
        total_matches: length(visible)
      }

      Result.ok("repo_search", output)
    else
      {:error, reason} ->
        Result.error("repo_search", reason)
    end
  end

  defp require_pattern(args) do
    case Map.get(args, "pattern") do
      nil -> {:error, "pattern is required"}
      "" -> {:error, "pattern is required"}
      pattern when is_binary(pattern) -> {:ok, pattern}
      _ -> {:error, "pattern must be a string"}
    end
  end

  # -- Workspace scanning with early termination ---------------------------------

  defp scan_workspace(workspace, pattern, file_pattern, max_results) do
    workspace
    |> walk_workspace(workspace)
    |> Enum.reduce_while({[], false}, fn rel, {results, _} ->
      if not file_pattern_match?(rel, file_pattern) do
        {:cont, {results, false}}
      else
        full = Path.join(workspace, rel)
        file_results = search_file(full, rel, pattern)
        new_results = results ++ file_results

        if length(new_results) >= max_results do
          {:halt, {new_results, true}}
        else
          {:cont, {new_results, false}}
        end
      end
    end)
  end

  # -- Symlink-safe directory traversal ------------------------------------------

  defp walk_workspace(dir, workspace) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&hidden_entry?/1)
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)
          rel = Path.relative_to(full, workspace)

          # Validate every path before FS access to prevent symlink escapes
          if not safe_to_access?(full, workspace) do
            []
          else
            case File.lstat(full) do
              {:ok, %File.Stat{type: :symlink}} ->
                # Symlink was validated by safe_to_access? — resolve target type
                if File.dir?(full) do
                  walk_workspace(full, workspace)
                else
                  [rel]
                end

              {:ok, %File.Stat{type: :directory}} ->
                walk_workspace(full, workspace)

              {:ok, %File.Stat{type: :regular}} ->
                [rel]

              _ ->
                []
            end
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Validate path resolves safely inside workspace (catches symlink escapes,
  # secret paths, ignored dirs like .git/_build/deps)
  defp safe_to_access?(full_path, workspace) do
    rel = Path.relative_to(full_path, workspace)

    try do
      # allow_hidden: true so hidden filtering is done by our own hidden_entry? check
      # NOT allow_git_contents — repo_search never searches .git
      Muse.Workspace.safe_resolve!(rel, workspace, allow_hidden: true)
      true
    rescue
      ArgumentError -> false
    end
  end

  defp hidden_entry?(<<".", rest::binary>>) when rest != "", do: true
  defp hidden_entry?(_), do: false

  defp file_pattern_match?(_rel, nil), do: true

  defp file_pattern_match?(rel, pattern) do
    case pattern do
      "*" <> ext -> String.ends_with?(rel, ext)
      _ -> String.contains?(rel, pattern)
    end
  end

  # -- Bounded per-file search ---------------------------------------------------

  defp search_file(full_path, rel_path, pattern) do
    case File.open(full_path, [:read, :binary, :raw]) do
      {:ok, io_dev} ->
        try do
          data = IO.binread(io_dev, @max_per_file_bytes + 1)

          case data do
            bin when is_binary(bin) ->
              # Binary detection on first 8KB
              sample_size = min(byte_size(bin), 8192)
              <<sample::binary-size(sample_size), _::binary>> = bin

              if :binary.match(sample, <<0>>) != :nomatch do
                # Binary file — skip
                []
              else
                content =
                  if byte_size(bin) > @max_per_file_bytes do
                    binary_part(bin, 0, @max_per_file_bytes)
                  else
                    bin
                  end

                search_lines(content, rel_path, pattern)
              end

            _ ->
              []
          end
        after
          File.close(io_dev)
        end

      {:error, _} ->
        []
    end
  end

  defp search_lines(content, rel_path, pattern) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} -> String.contains?(line, pattern) end)
    |> Enum.map(fn {line, idx} ->
      %{file: rel_path, line: idx, excerpt: String.slice(line, 0, 200)}
    end)
  end

  defp cap_results(results, max) when length(results) <= max do
    {results, false}
  end

  defp cap_results(results, max) do
    {Enum.take(results, max), true}
  end
end
