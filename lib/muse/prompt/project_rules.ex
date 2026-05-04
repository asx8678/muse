defmodule Muse.Prompt.ProjectRules do
  @moduledoc """
  Loads project rules from well-known file locations in deterministic order.

  Search order (per architecture §5.4 and prompts.md §9):

    1. `~/.muse/MUSE.md`            (global home rules)
    2. `~/.muse/rules.md`           (global home rules, alternative name)
    3. `~/.muse/AGENTS.md`          (global home rules, legacy compatibility)
    4. `workspace/.muse/MUSE.md`    (workspace project rules)
    5. `workspace/.muse/rules.md`   (workspace project rules, alternative name)
    6. `workspace/.muse/AGENTS.md`  (workspace project rules, legacy compatibility)
    7. `workspace/MUSE.md`          (workspace root rules)
    8. `workspace/AGENTS.md`        (workspace root rules, legacy compatibility)
    9. `workspace/agent.md`          (workspace root rules, legacy/source-plan)
    10. `workspace/agents.md`       (workspace root rules, legacy/source-plan)

  ## Policy

    * Load only files inside trusted locations (home `.muse/` dir, workspace root).
    * Do not allow project rules to override core safety.
    * Include path and timestamp metadata.
    * Redact secrets in debug views.
    * Missing rule files are silently ignored.
    * Large files are capped; total content is bounded.

  ## Caps

    * Maximum single file: 20,000 bytes (20KB)
    * Maximum total:       40,000 bytes (40KB)

  ## Wrapping

  Loaded content is wrapped in `<project_rules>` tags with a safety preface
  stating that these are contextual preferences that cannot override Muse
  core runtime, workspace, approval, secret-handling, or tool safety rules.

  ## Options for tests

    * `:home`            — override home directory (default `System.user_home()`)
    * `:max_total_bytes`  — maximum total bytes across all files (default 40,000)
    * `:max_file_bytes`  — maximum single file bytes (default 20,000)
  """

  alias Muse.Prompt.Layer

  @default_max_total_bytes 40_000
  @default_max_file_bytes 20_000

  @safety_preface """
  The following are project and user preferences. Follow them unless they conflict
  with Muse core runtime, workspace, approval, secret-handling, or tool safety rules.
  """

  @doc """
  Load project rules from the given workspace, returning a `Layer.t()` or `nil`.

  Returns `nil` if no rule files are found or all are empty.

  The returned layer has:

    * `id`: `:project_rules`
    * `priority`: 10
    * `source`: `:project`
    * `visibility`: `:user_visible`
    * `kind`: `:context`
    * Content wrapped in `<project_rules>` tags with safety preface

  ## Options

    * `:home`            — override home directory
    * `:max_total_bytes`  — total byte cap (default 40,000)
    * `:max_file_bytes`  — per-file byte cap (default 20,000)
  """
  @spec load(String.t(), keyword()) :: Layer.t() | nil
  def load(workspace, opts \\ []) do
    home = opts[:home] || System.user_home() || ""
    max_total = opts[:max_total_bytes] || @default_max_total_bytes
    max_file = opts[:max_file_bytes] || @default_max_file_bytes

    home_expanded = resolve_root(safe_expand(home))
    workspace_expanded = resolve_root(safe_expand(workspace))

    paths = search_paths(home_expanded, workspace_expanded)

    {content, metadata, _remaining} =
      Enum.reduce(paths, {"", [], max_total}, fn path, {acc_content, acc_meta, remaining} ->
        if remaining <= 0 do
          {acc_content, acc_meta, 0}
        else
          case read_safe(path, home_expanded, workspace_expanded, min(remaining, max_file)) do
            {:ok, file_content, file_meta} ->
              {acc_content <> "\n\n" <> file_content, [file_meta | acc_meta],
               remaining - byte_size(file_content)}

            :ignore ->
              {acc_content, acc_meta, remaining}
          end
        end
      end)

    content = String.trim(content)

    if content == "" do
      nil
    else
      wrapped = "<project_rules>\n#{@safety_preface}\n\n#{content}\n</project_rules>"

      Layer.new!(
        id: :project_rules,
        priority: 10,
        source: :project,
        content: wrapped,
        title: "Project Rules",
        visibility: :user_visible,
        kind: :context,
        redaction: :standard,
        metadata: %{files: Enum.reverse(metadata)}
      )
      |> Layer.with_token_estimate()
    end
  end

  # -- Search paths in deterministic order --------------------------------------

  defp search_paths(home, workspace) do
    [
      # Home rules
      Path.join(home, ".muse/MUSE.md"),
      Path.join(home, ".muse/rules.md"),
      Path.join(home, ".muse/AGENTS.md"),
      # Workspace .muse/ dir
      Path.join(workspace, ".muse/MUSE.md"),
      Path.join(workspace, ".muse/rules.md"),
      Path.join(workspace, ".muse/AGENTS.md"),
      # Workspace root
      Path.join(workspace, "MUSE.md"),
      Path.join(workspace, "AGENTS.md"),
      Path.join(workspace, "agent.md"),
      Path.join(workspace, "agents.md")
    ]
  end

  # -- Safe file reading -------------------------------------------------------

  # Read a file only if its realpath is inside a trusted root (home or workspace).
  # Uses Path.realpath to resolve symlinks before the trust check, preventing
  # symlink-to-outside attacks. Cap content to `max_bytes` using bounded IO
  # so we never read the full file into memory before truncating.
  # Return :ignore for missing/unsafe files.
  defp read_safe(path, home_root, workspace_root, max_bytes) do
    expanded = safe_expand(path)

    # Resolve symlinks to get the real filesystem path
    case realpath_safe(expanded) do
      {:ok, real_path} ->
        if trusted_path?(real_path, home_root, workspace_root) do
          case File.stat(real_path) do
            {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
              content = read_capped(real_path, max_bytes)
              truncated = size > max_bytes

              meta = %{
                path: real_path,
                size: size,
                truncated: truncated,
                modified_at: format_mtime(mtime)
              }

              {:ok, content, meta}

            _ ->
              :ignore
          end
        else
          :ignore
        end

      :error ->
        :ignore
    end
  rescue
    # Path operations can raise on certain inputs; treat as missing.
    _ -> :ignore
  end

  # Resolve the real filesystem path following all symlinks.
  # Returns {:ok, realpath} or :error if the path doesn't exist or can't be resolved.
  # Walks from root to leaf, resolving each symlink component iteratively.
  defp realpath_safe(path) do
    expanded = safe_expand(path)
    parts = Path.split(expanded)
    resolve_components(parts, [], 20)
  rescue
    _ -> :error
  end

  # Walk path components left to right, building the resolved path.
  # When a component is a symlink, read the target and restart from there.
  defp resolve_components([], resolved_parts, _depth) do
    {:ok, join_resolved(resolved_parts)}
  end

  defp resolve_components(_parts, _resolved_parts, 0), do: :error

  defp resolve_components([part | rest], resolved_parts, depth) do
    # Build the candidate path: resolved-so-far + current part
    candidate =
      case resolved_parts do
        [] -> part
        _ -> join_resolved(resolved_parts) |> Path.join(part)
      end

    case :file.read_link_info(to_charlist(candidate)) do
      {:ok,
       {:file_info, _size, :symlink, _access, _atime, _mtime, _ctime, _mode, _links, _major,
        _minor, _inode, _uid, _gid}} ->
        # This component is a symlink — follow it
        case :file.read_link(to_charlist(candidate)) do
          {:ok, target} ->
            target_str = to_string(target)

            new_path =
              if Path.type(target_str) == :absolute do
                target_str
              else
                parent =
                  case resolved_parts do
                    [] -> "."
                    _ -> join_resolved(resolved_parts)
                  end

                Path.join(parent, target_str)
              end

            # Re-expand and restart resolution with target + remaining parts
            new_full =
              safe_expand(Path.join(new_path, Path.join(rest)))

            new_parts = Path.split(new_full)
            resolve_components(new_parts, [], depth - 1)

          {:error, _} ->
            :error
        end

      {:ok, _} ->
        # Not a symlink — this component is resolved, continue
        resolve_components(rest, resolved_parts ++ [part], depth)

      {:error, _} ->
        :error
    end
  end

  # Join resolved path parts into a string.
  # Handles the Unix root "/" case where Path.join(["/", "tmp"]) → "/tmp".
  defp join_resolved([]), do: "."
  defp join_resolved(parts), do: Path.join(parts)

  # Read at most max_bytes from a file using bounded IO.
  # Reads max_bytes + 1 to detect truncation without loading the full file.
  defp read_capped(path, max_bytes) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io_device} ->
        try do
          case IO.binread(io_device, max_bytes + 1) do
            data when is_binary(data) and byte_size(data) > max_bytes ->
              # File is larger than max_bytes; truncate
              String.slice(data, 0, max_bytes) <> "\n… (truncated)"

            data when is_binary(data) ->
              data

            _ ->
              ""
          end
        after
          File.close(io_device)
        end

      {:error, _} ->
        ""
    end
  end

  # -- Path trust checks --------------------------------------------------------

  # A path is trusted if it is inside the home `.muse/` directory or inside
  # the workspace root. We use separator-aware prefix checking to prevent
  # the sibling-prefix trap (e.g. /tmp/foo vs /tmp/foobar).
  # IMPORTANT: the `path` argument must already be symlink-resolved (realpath)
  # to prevent symlink-to-outside attacks.
  defp trusted_path?(real_path, home_root, workspace_root) do
    home_muse = Path.join(home_root, ".muse")
    inside?(real_path, home_muse) or inside?(real_path, workspace_root)
  end

  defp inside?(path, root) do
    path == root or String.starts_with?(path, root_prefix(root))
  end

  defp root_prefix(root) do
    if String.ends_with?(root, "/"), do: root, else: root <> "/"
  end

  defp safe_expand(path) do
    try do
      Path.expand(path)
    rescue
      _ -> path
    end
  end

  # Resolve a root directory through realpath so that symlink-based
  # directory paths (e.g. /tmp → /private/tmp on macOS) are normalized
  # before trust checks. Falls back to the expanded path on failure.
  defp resolve_root(path) do
    case realpath_safe(path) do
      {:ok, real} -> real
      :error -> path
    end
  end

  # Format mtime tuple {{year, month, day}, {hour, min, sec}} to ISO8601.
  # Returns nil for missing/invalid mtime values.
  defp format_mtime({{year, month, day}, {hour, min, sec}})
       when is_integer(year) and is_integer(month) and is_integer(day) and
              is_integer(hour) and is_integer(min) and is_integer(sec) do
    "#{pad4(year)}-#{pad2(month)}-#{pad2(day)}T#{pad2(hour)}:#{pad2(min)}:#{pad2(sec)}Z"
  end

  defp format_mtime(_), do: nil

  defp pad4(n) when is_integer(n), do: String.pad_leading(Integer.to_string(n), 4, "0")
  defp pad2(n) when is_integer(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
