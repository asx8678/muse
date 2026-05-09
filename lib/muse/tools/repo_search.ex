defmodule Muse.Tools.RepoSearch do
  @moduledoc """
  Read-only tool: search for text patterns across workspace files.

  Uses a lazy stream-based scanner that discovers files incrementally and
  stops as soon as `max_results` matches are found. Memory is bounded:
  the file tree is never fully materialized, and per-file search respects
  remaining capacity so only needed matches are extracted.

  Uses SafeText for binary/UTF-8 detection. Every path is validated via
  `Muse.Workspace.safe_resolve!/3` to prevent symlink escapes. Output is
  capped.

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
  alias Muse.Tool.SafeText

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

  # -- Streaming workspace scan with early termination --------------------------

  # Scans the workspace lazily: files are discovered directory-by-directory
  # via Stream.resource and consumed only until max_results matches are
  # found. The full file tree is never materialized in memory.
  #
  # Accumulator uses prepend-with-reverse for O(1) per-step cost
  # (vs the old `results ++ file_results` which was O(n²)). A single
  # `Enum.reverse` at the end restores result order.
  defp scan_workspace(workspace, pattern, file_pattern, max_results) do
    workspace
    |> stream_workspace_files()
    |> Enum.reduce_while({[], false}, fn rel, {results, _} ->
      if not file_pattern_match?(rel, file_pattern) do
        {:cont, {results, false}}
      else
        full = Path.join(workspace, rel)
        remaining = max_results - length(results)
        file_results = search_file_bounded(full, rel, pattern, remaining)
        # Prepend file results in reverse order — O(1) per step.
        # Final Enum.reverse at the end restores ascending file/line order.
        new_results = Enum.reverse(file_results, results)

        if length(new_results) >= max_results do
          {:halt, {new_results, true}}
        else
          {:cont, {new_results, false}}
        end
      end
    end)
    |> then(fn {results, truncated?} ->
      {Enum.reverse(results), truncated?}
    end)
  end

  # -- Lazy stream-based directory walker ---------------------------------------

  # Uses Stream.resource to walk the directory tree incrementally.
  # Only lists one directory at a time; never materializes the full tree.
  # Inaccessible directories are silently skipped (no crash).
  #
  # Internally maintains a stack of directories to visit. Each call to
  # next_directory/1 pops one directory, lists it, categorizes entries
  # into files (emitted) and subdirs (pushed onto stack). The stack is
  # LIFO so subdirs are visited in DFS order matching the old recursive
  # walker — but only when the consumer requests more elements.
  defp stream_workspace_files(workspace) do
    Stream.resource(
      fn -> {:dirs, [workspace], workspace} end,
      &next_directory/1,
      fn _ -> :ok end
    )
  end

  defp next_directory({:dirs, [], _root}) do
    {:halt, :done}
  end

  defp next_directory({:dirs, [dir | rest], root}) do
    case File.ls(dir) do
      {:ok, entries} ->
        {files, subdirs} = categorize_entries(dir, entries, root)

        # Reverse files to preserve File.ls order within this directory.
        # Reverse subdirs so that first-listed subdir is on top of the
        # stack (visited first), matching the DFS order of the old
        # recursive walker.
        {Enum.reverse(files), {:dirs, Enum.reverse(subdirs) ++ rest, root}}

      {:error, _} ->
        # Skip inaccessible directories — no crash, just continue
        {[], {:dirs, rest, root}}
    end
  end

  defp next_directory(:done) do
    {:halt, :done}
  end

  # Categorize directory entries into files (relative paths) and
  # subdirectories (absolute paths for further traversal).
  defp categorize_entries(dir, entries, root) do
    entries
    |> Enum.reject(&hidden_entry?/1)
    |> Enum.reduce({[], []}, fn entry, {files, subdirs} ->
      full = Path.join(dir, entry)
      rel = Path.relative_to(full, root)

      if not safe_to_access?(full, root) do
        {files, subdirs}
      else
        case File.lstat(full) do
          {:ok, %File.Stat{type: :symlink}} ->
            # Symlink was validated by safe_to_access? — resolve target type
            if File.dir?(full) do
              {files, [full | subdirs]}
            else
              {[rel | files], subdirs}
            end

          {:ok, %File.Stat{type: :directory}} ->
            {files, [full | subdirs]}

          {:ok, %File.Stat{type: :regular}} ->
            {[rel | files], subdirs}

          _ ->
            {files, subdirs}
        end
      end
    end)
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

  # -- Bounded per-file search -------------------------------------------------

  # Search a single file, stopping after `remaining` matches.
  # Returns results in ascending line order.
  # When `remaining <= 0`, skips the file entirely (capacity exhausted).
  defp search_file_bounded(_full_path, _rel_path, _pattern, remaining)
       when remaining <= 0 do
    []
  end

  defp search_file_bounded(full_path, rel_path, pattern, remaining) do
    case File.open(full_path, [:read, :binary, :raw]) do
      {:ok, io_dev} ->
        try do
          data = IO.binread(io_dev, @max_per_file_bytes + 1)

          case data do
            bin when is_binary(bin) ->
              case SafeText.classify(bin) do
                :text ->
                  content = safe_content(bin)
                  search_lines_bounded(content, rel_path, pattern, remaining)

                _classification ->
                  # Binary, invalid UTF-8, or unsafe text — skip
                  []
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

  defp safe_content(bin) do
    if byte_size(bin) > @max_per_file_bytes do
      {:ok, safe} = SafeText.safe_truncate(bin, @max_per_file_bytes)
      safe
    else
      bin
    end
  end

  # Search lines in content, stopping after max_matches results.
  # Uses reduce_while for early termination — no need to scan every line
  # when only a few more matches are needed.
  # Returns results in ascending line order.
  defp search_lines_bounded(content, rel_path, pattern, max_matches) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({[], 0}, fn {line, idx}, {acc, count} ->
      if count >= max_matches do
        {:halt, {acc, count}}
      else
        if String.contains?(line, pattern) do
          match = %{file: rel_path, line: idx, excerpt: SafeText.safe_slice(line, 200)}
          {:cont, {[match | acc], count + 1}}
        else
          {:cont, {acc, count}}
        end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp cap_results(results, max) when length(results) <= max do
    {results, false}
  end

  defp cap_results(results, max) do
    {Enum.take(results, max), true}
  end
end
