defmodule Muse.Patch.Validator do
  @moduledoc """
  Security validator for PR17 patch proposals.

  This module validates a proposed unified/git diff before any patch workflow
  stores, displays, or routes it for approval. It is intentionally validation
  only: it never executes shell commands, never invokes `git apply`, and never
  writes affected files.

  The validator fails closed on unsafe paths and binary patches:

    * absolute paths, Windows drive/UNC paths, backslash separators
    * `..` traversal components
    * paths outside the workspace, including symlink escapes through existing
      path prefixes
    * `.git` internals and other ignored directories enforced by
      `Muse.Workspace.safe_resolve!/3`
    * secret/sensitive paths such as `.env`, private keys, credentials files,
      auth files, and cloud credential directories
    * `GIT binary patch`, `Binary files ... differ`, NUL bytes, and invalid
      UTF-8 diff payloads
    * oversized diffs, too many affected files, and oversized lines

  Successful validation returns safe metadata only. The raw diff is **not**
  returned; callers get a capped/redacted `:diff_preview` suitable for events,
  logs, or external envelopes.
  """

  @default_max_diff_bytes 200_000
  @default_max_files 50
  @default_max_line_bytes 4_000
  @default_preview_bytes 8_000
  @preview_truncated_marker "\n[diff preview truncated]"

  @type validation :: %{
          affected_files: [String.t()],
          file_count: non_neg_integer(),
          diff_bytes: non_neg_integer(),
          diff_preview: String.t(),
          preview_truncated: boolean()
        }

  @type validation_error :: %{
          required(:reason) => atom(),
          required(:message) => String.t(),
          optional(:path) => String.t(),
          optional(:line) => pos_integer(),
          optional(:limit) => pos_integer()
        }

  @doc """
  Validate a raw patch proposal diff against a workspace.

  Options:

    * `:max_diff_bytes` — maximum accepted diff byte size (default: 200 KB)
    * `:max_files` — maximum unique affected files (default: 50)
    * `:max_line_bytes` — maximum single diff line byte size (default: 4 KB)
    * `:max_preview_bytes` — cap for the redacted preview (default: 8 KB)

  Returns `{:ok, validation}` or `{:error, validation_error}`. Error messages
  do not include raw diff lines.
  """
  @spec validate(String.t(), String.t(), keyword()) ::
          {:ok, validation()} | {:error, validation_error()}
  def validate(diff, workspace, opts \\ [])

  def validate(diff, workspace, opts) when is_binary(diff) and is_binary(workspace) do
    limits = limits(opts)

    with :ok <- validate_workspace(workspace),
         :ok <- validate_diff_text(diff),
         :ok <- validate_diff_size(diff, limits.max_diff_bytes),
         :ok <- reject_binary_patch(diff),
         :ok <- validate_line_lengths(diff, limits.max_line_bytes),
         {:ok, raw_paths} <- extract_raw_paths(diff),
         {:ok, affected_files} <- validate_paths(raw_paths, workspace),
         :ok <- validate_file_count(affected_files, limits.max_files) do
      {diff_preview, preview_truncated?} = safe_preview(diff, max_bytes: limits.max_preview_bytes)

      {:ok,
       %{
         affected_files: affected_files,
         file_count: length(affected_files),
         diff_bytes: byte_size(diff),
         diff_preview: diff_preview,
         preview_truncated: preview_truncated?
       }}
    end
  end

  def validate(_diff, _workspace, _opts) do
    error(:invalid_input, "patch diff and workspace must both be strings")
  end

  @doc """
  Validate patch-proposal style tool arguments.

  Accepts either `"diff"`/`:diff` or `"patch"`/`:patch` in `args`, and
  `:workspace` or `"workspace"` in `context`. This helper is provided for the
  eventual `patch_propose` tool integration; it still performs validation only.
  """
  @spec validate_proposal(map(), map(), keyword()) ::
          {:ok, validation()} | {:error, validation_error()}
  def validate_proposal(args, context, opts \\ [])

  def validate_proposal(args, context, opts) when is_map(args) and is_map(context) do
    with {:ok, diff} <- fetch_diff(args),
         {:ok, workspace} <- fetch_workspace(context) do
      validate(diff, workspace, opts)
    end
  end

  def validate_proposal(_args, _context, _opts) do
    error(:invalid_input, "patch proposal args and context must both be maps")
  end

  @doc """
  Return a capped and redacted preview suitable for events/logs/envelopes.

  This helper is safe for display but is not a substitute for `validate/3`.
  """
  @spec safe_preview(String.t(), keyword()) :: {String.t(), boolean()}
  def safe_preview(diff, opts \\ []) when is_binary(diff) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_preview_bytes)

    diff
    |> redact_preview_text()
    |> cap_preview(max_bytes)
  end

  # -- Top-level validation -----------------------------------------------------

  defp limits(opts) do
    %{
      max_diff_bytes: Keyword.get(opts, :max_diff_bytes, @default_max_diff_bytes),
      max_files: Keyword.get(opts, :max_files, @default_max_files),
      max_line_bytes: Keyword.get(opts, :max_line_bytes, @default_max_line_bytes),
      max_preview_bytes: Keyword.get(opts, :max_preview_bytes, @default_preview_bytes)
    }
  end

  defp validate_workspace(workspace) do
    cond do
      workspace == "" ->
        error(:invalid_workspace, "workspace is required")

      not File.dir?(workspace) ->
        error(:invalid_workspace, "workspace does not exist or is not a directory")

      true ->
        :ok
    end
  end

  defp validate_diff_text(diff) do
    cond do
      diff == "" ->
        error(:empty_diff, "patch diff is empty")

      not String.valid?(diff) ->
        error(:binary_patch, "patch proposals must be valid UTF-8 text")

      true ->
        :ok
    end
  end

  defp validate_diff_size(diff, max_diff_bytes) when byte_size(diff) > max_diff_bytes do
    error(:diff_too_large, "patch diff exceeds maximum byte size", %{limit: max_diff_bytes})
  end

  defp validate_diff_size(_diff, _max_diff_bytes), do: :ok

  defp reject_binary_patch(diff) do
    cond do
      :binary.match(diff, <<0>>) != :nomatch ->
        error(:binary_patch, "binary patch payloads are not allowed")

      String.contains?(diff, "GIT binary patch") ->
        error(:binary_patch, "Git binary patch payloads are not allowed")

      diff
      |> String.split("\n")
      |> Enum.any?(&binary_files_marker?/1) ->
        error(:binary_patch, "binary file diffs are not allowed")

      true ->
        :ok
    end
  end

  defp binary_files_marker?(line) do
    line
    |> trim_cr()
    |> String.starts_with?("Binary files ")
  end

  defp validate_line_lengths(diff, max_line_bytes) do
    diff
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find(fn {line, _line_no} -> byte_size(line) > max_line_bytes end)
    |> case do
      nil ->
        :ok

      {_line, line_no} ->
        error(:line_too_long, "patch diff contains a line exceeding maximum byte size", %{
          line: line_no,
          limit: max_line_bytes
        })
    end
  end

  defp validate_file_count(files, max_files) when length(files) > max_files do
    error(:too_many_files, "patch proposal affects too many files", %{limit: max_files})
  end

  defp validate_file_count(_files, _max_files), do: :ok

  # -- Patch path extraction ----------------------------------------------------

  defp extract_raw_paths(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case paths_from_line(trim_cr(line)) do
        {:ok, paths} -> {:cont, {:ok, [paths | acc]}}
        :none -> {:cont, {:ok, acc}}
        {:error, validation_error} -> {:halt, {:error, validation_error}}
      end
    end)
    |> case do
      {:ok, []} ->
        error(:no_paths, "patch proposal does not contain any affected file paths")

      {:ok, path_groups} ->
        {:ok, path_groups |> Enum.reverse() |> List.flatten()}

      {:error, _} = err ->
        err
    end
  end

  defp paths_from_line("diff --git " <> rest), do: parse_diff_git_paths(rest)
  defp paths_from_line("--- " <> rest), do: {:ok, [header_path(rest)]}
  defp paths_from_line("+++ " <> rest), do: {:ok, [header_path(rest)]}
  defp paths_from_line("rename from " <> rest), do: {:ok, [header_path(rest)]}
  defp paths_from_line("rename to " <> rest), do: {:ok, [header_path(rest)]}
  defp paths_from_line("copy from " <> rest), do: {:ok, [header_path(rest)]}
  defp paths_from_line("copy to " <> rest), do: {:ok, [header_path(rest)]}
  defp paths_from_line(_line), do: :none

  defp parse_diff_git_paths(rest) do
    rest = String.trim(rest)

    cond do
      rest == "" ->
        error(:malformed_diff, "malformed diff --git header")

      String.starts_with?(rest, "\"") ->
        error(:malformed_diff, "quoted diff --git paths are not supported by validator")

      true ->
        parse_unquoted_diff_git_paths(rest)
    end
  end

  defp parse_unquoted_diff_git_paths(rest) do
    case String.split(rest, " b/") do
      ["a/" <> old_path, new_path] when old_path != "" and new_path != "" ->
        {:ok, ["a/" <> old_path, "b/" <> new_path]}

      [old_path, new_path] when old_path != "" and new_path != "" ->
        {:ok, [old_path, "b/" <> new_path]}

      [_single] ->
        parse_two_token_diff_git_paths(rest)

      _ambiguous ->
        error(:malformed_diff, "ambiguous diff --git path header")
    end
  end

  defp parse_two_token_diff_git_paths(rest) do
    case String.split(rest, ~r/\s+/, parts: 3) do
      [old_path, new_path] ->
        {:ok, [old_path, new_path]}

      _ ->
        error(:malformed_diff, "malformed diff --git path header")
    end
  end

  defp header_path(raw) do
    raw
    |> String.trim()
    |> String.split("\t", parts: 2)
    |> hd()
  end

  # -- Patch path validation ----------------------------------------------------

  defp validate_paths(raw_paths, workspace) do
    raw_paths
    |> Enum.reduce_while({:ok, []}, fn raw_path, {:ok, acc} ->
      case validate_raw_path(raw_path, workspace) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, rel_path} -> {:cont, {:ok, [rel_path | acc]}}
        {:error, validation_error} -> {:halt, {:error, validation_error}}
      end
    end)
    |> case do
      {:ok, paths} ->
        paths = paths |> Enum.reverse() |> unique_preserve_order()

        if paths == [] do
          error(:no_paths, "patch proposal does not contain any affected file paths")
        else
          {:ok, paths}
        end

      {:error, _} = err ->
        err
    end
  end

  defp validate_raw_path(raw_path, workspace) do
    path = header_path(raw_path)

    cond do
      path == "/dev/null" ->
        {:ok, nil}

      path == "" ->
        unsafe_path(raw_path, "empty path")

      String.starts_with?(path, "\"") ->
        unsafe_path(raw_path, "quoted paths are not supported")

      true ->
        path
        |> strip_diff_prefix()
        |> validate_relative_path(raw_path, workspace)
    end
  end

  defp validate_relative_path(path, raw_path, workspace) do
    with :ok <- reject_absolute_path(path, raw_path),
         :ok <- reject_backslash_path(path, raw_path),
         :ok <- reject_traversal(path, raw_path),
         {:ok, rel_path} <- resolve_safe_path(path, raw_path, workspace) do
      {:ok, rel_path}
    end
  end

  defp strip_diff_prefix("a/" <> rest), do: rest
  defp strip_diff_prefix("b/" <> rest), do: rest
  defp strip_diff_prefix(path), do: path

  defp reject_absolute_path(path, raw_path) do
    cond do
      Path.type(path) == :absolute ->
        unsafe_path(raw_path, "absolute paths are not allowed")

      Regex.match?(~r/^[A-Za-z]:[\\\/]/, path) ->
        unsafe_path(raw_path, "Windows absolute paths are not allowed")

      String.starts_with?(path, "\\") ->
        unsafe_path(raw_path, "Windows absolute paths are not allowed")

      true ->
        :ok
    end
  end

  defp reject_backslash_path(path, raw_path) do
    if String.contains?(path, "\\") do
      unsafe_path(raw_path, "backslash path separators are not allowed")
    else
      :ok
    end
  end

  defp reject_traversal(path, raw_path) do
    cond do
      path in ["", "."] ->
        unsafe_path(raw_path, "path must reference a file")

      ".." in Path.split(path) ->
        unsafe_path(raw_path, ".. traversal is not allowed")

      true ->
        :ok
    end
  end

  defp resolve_safe_path(path, raw_path, workspace) do
    expanded_workspace = Path.expand(workspace)

    try do
      resolved = Muse.Workspace.safe_resolve!(path, expanded_workspace, allow_hidden: true)
      {:ok, Path.relative_to(resolved, expanded_workspace)}
    rescue
      ArgumentError ->
        unsafe_path(raw_path, "path violates workspace safety rules")
    end
  end

  defp unique_preserve_order(paths) do
    {reversed, _seen} =
      Enum.reduce(paths, {[], MapSet.new()}, fn path, {acc, seen} ->
        if MapSet.member?(seen, path) do
          {acc, seen}
        else
          {[path | acc], MapSet.put(seen, path)}
        end
      end)

    Enum.reverse(reversed)
  end

  # -- Tool-style proposal helpers ---------------------------------------------

  defp fetch_diff(args) do
    case Map.get(args, "diff") || Map.get(args, :diff) || Map.get(args, "patch") ||
           Map.get(args, :patch) do
      diff when is_binary(diff) and diff != "" ->
        {:ok, diff}

      "" ->
        error(:empty_diff, "patch diff is empty")

      nil ->
        error(:invalid_input, "patch proposal requires a diff or patch string")

      _ ->
        error(:invalid_input, "patch diff must be a string")
    end
  end

  defp fetch_workspace(context) do
    case Map.get(context, :workspace) || Map.get(context, "workspace") do
      workspace when is_binary(workspace) and workspace != "" ->
        {:ok, workspace}

      _ ->
        error(:invalid_workspace, "workspace is required")
    end
  end

  # -- Safe display -------------------------------------------------------------

  defp redact_preview_text(binary) do
    if String.valid?(binary) do
      Muse.Prompt.Redactor.redact_text(binary)
    else
      "[binary patch redacted]"
    end
  end

  defp cap_preview(binary, max_bytes) when byte_size(binary) <= max_bytes do
    {binary, false}
  end

  defp cap_preview(_binary, max_bytes) when max_bytes <= 0 do
    {"", true}
  end

  defp cap_preview(binary, max_bytes) do
    marker = @preview_truncated_marker
    marker_bytes = byte_size(marker)

    if max_bytes <= marker_bytes do
      {binary |> binary_part(0, max_bytes) |> trim_to_valid_utf8(), true}
    else
      body_bytes = max_bytes - marker_bytes

      body =
        binary
        |> binary_part(0, body_bytes)
        |> trim_to_valid_utf8()

      {body <> marker, true}
    end
  end

  defp trim_to_valid_utf8(binary) do
    cond do
      binary == "" -> ""
      String.valid?(binary) -> binary
      true -> binary |> binary_part(0, byte_size(binary) - 1) |> trim_to_valid_utf8()
    end
  end

  defp trim_cr(line), do: String.trim_trailing(line, "\r")

  # -- Errors -------------------------------------------------------------------

  defp unsafe_path(raw_path, detail) do
    safe_path = safe_path_for_message(raw_path)

    error(:unsafe_path, "unsafe patch path #{safe_path}: #{detail}", %{path: safe_path})
  end

  defp safe_path_for_message(path) do
    path
    |> to_string()
    |> Muse.Prompt.Redactor.preview_text(max_length: 200)
  end

  defp error(reason, message, extra \\ %{}) do
    {:error,
     extra
     |> Map.merge(%{
       reason: reason,
       message: Muse.Prompt.Redactor.redact_text(message)
     })}
  end
end
