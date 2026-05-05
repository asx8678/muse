defmodule Muse.Patch.DiffParser do
  @moduledoc """
  Pure unified-diff parser for PR17 patch proposals.

  Parses text unified diffs into a structured list of file entries, each
  containing the old/new paths and a list of hunks. Rejects binary patches
  at the model layer.

  ## Supported syntax

    * `--- a/path/to/file` / `+++ b/path/to/file` file headers
    * `@@ -l,s +l,s @@` hunk headers (optional trailing text)
    * Context lines (space-prefixed or empty)
    * Added lines (`+`-prefixed)
    * Removed lines (`-`-prefixed)
    * `\ No newline at end of file` markers (preserved but not treated as content)

  ## Rejected at model layer

    * `GIT binary patch` markers — returned as `{:error, :binary_patch}`

  ## Limitations

  This parser is intentionally lightweight for PR17: it does not handle
  rename-only diffs, mode changes, or git index lines beyond recognition.
  """

  @type line_type :: :context | :add | :remove | :no_newline

  @type hunk :: %{
          header: String.t(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          lines: [{line_type(), String.t()}]
        }

  @type file_entry :: %{
          old_path: String.t() | nil,
          new_path: String.t() | nil,
          hunks: [hunk()]
        }

  @type parse_error :: {:error, :binary_patch | {:malformed_header, String.t()}}

  # -- Public API ---------------------------------------------------------------

  @doc """
  Parse a unified diff string into a list of file entries.

  Returns `{:ok, entries}` on success or `{:error, reason}` if the diff
  contains binary patches or has fatally malformed structure.

  ## Examples

      iex> diff = "diff --git a/foo.ex b/foo.ex\\n--- a/foo.ex\\n+++ b/foo.ex\\n@@ -1,3 +1,4 @@\\n line1\\n-old\\n+new\\n+extra\\n"
      iex> {:ok, [entry]} = Muse.Patch.DiffParser.parse(diff)
      iex> entry.old_path
      "foo.ex"
      iex> entry.new_path
      "foo.ex"
      iex> length(entry.hunks)
      1
  """
  @spec parse(String.t()) :: {:ok, [file_entry()]} | parse_error()
  def parse(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> parse_lines([], nil)
  end

  @doc """
  Extract the list of affected file paths from a unified diff.

  Returns the "new" path (b/path) for each file entry. Falls back to the
  old path for deletion-only diffs.

  ## Examples

      iex> diff = "diff --git a/foo.ex b/foo.ex\\n--- a/foo.ex\\n+++ b/foo.ex\\n@@ -1 +1 @@\\n-old\\n+new\\n"
      iex> {:ok, _entries} = Muse.Patch.DiffParser.parse(diff)
      iex> {:ok, paths} = Muse.Patch.DiffParser.affected_paths(diff)
      iex> paths
      ["foo.ex"]
  """
  @spec affected_paths(String.t()) :: {:ok, [String.t()]} | parse_error()
  def affected_paths(diff) when is_binary(diff) do
    case parse(diff) do
      {:ok, entries} ->
        paths =
          Enum.map(entries, fn entry ->
            entry.new_path || entry.old_path
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, paths}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check whether a unified diff string contains a binary patch marker.

  ## Examples

      iex> Muse.Patch.DiffParser.binary_patch?("GIT binary patch\\n")
      true

      iex> Muse.Patch.DiffParser.binary_patch?("diff --git a/foo.ex b/foo.ex\\n")
      false
  """
  @spec binary_patch?(String.t()) :: boolean()
  def binary_patch?(diff) when is_binary(diff) do
    String.contains?(diff, "GIT binary patch")
  end

  @doc """
  Validate a unified diff string without full parsing.

  Returns `:ok` if the diff is parseable and contains no binary patches,
  or `{:error, reason}` otherwise.

  ## Examples

      iex> Muse.Patch.DiffParser.validate("--- a/foo.ex\\n+++ b/foo.ex\\n@@ -1 +1 @@\\n-old\\n+new\\n")
      :ok

      iex> Muse.Patch.DiffParser.validate("GIT binary patch\\n")
      {:error, :binary_patch}
  """
  @spec validate(String.t()) :: :ok | parse_error()
  def validate(diff) when is_binary(diff) do
    cond do
      binary_patch?(diff) -> {:error, :binary_patch}
      true -> validate_structure(diff)
    end
  end

  # -- Canonicalize -------------------------------------------------------------

  @doc """
  Canonicalize a unified diff string for stable hashing.

  Normalizes line endings to `\n`, trims trailing whitespace from each line
  (but preserves leading whitespace as it is semantically significant in diffs),
  removes trailing blank lines, and ensures a final newline.

  Does **not** reorder hunks or file entries — those must remain in their
  original order.
  """
  @spec canonicalize(String.t()) :: String.t()
  def canonicalize(diff) when is_binary(diff) do
    diff
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> drop_trailing_blanks()
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  # -- Parse implementation -----------------------------------------------------

  defp parse_lines([], acc, current) do
    entries = finalize_current(acc, current)
    {:ok, Enum.reverse(entries)}
  end

  defp parse_lines([line | rest], acc, current) do
    cond do
      String.starts_with?(line, "GIT binary patch") ->
        {:error, :binary_patch}

      # New diff entry (git-style header)
      String.starts_with?(line, "diff --git ") ->
        entries = finalize_current(acc, current)
        new_current = new_file_entry(line)
        parse_lines(rest, entries, new_current)

      # Old file header
      String.starts_with?(line, "--- ") ->
        old_path = extract_path(line, "--- ")
        current = put_old_path(current, old_path)
        parse_lines(rest, acc, current)

      # New file header
      String.starts_with?(line, "+++ ") ->
        new_path = extract_path(line, "+++ ")
        current = put_new_path(current, new_path)
        parse_lines(rest, acc, current)

      # Hunk header
      String.starts_with?(line, "@@") ->
        case parse_hunk_header(line) do
          {:ok, hunk_info} ->
            # Auto-create a file entry if we see a hunk without headers
            current = if current == nil, do: new_file_entry(""), else: current
            current = add_hunk(current, hunk_info)
            parse_lines(rest, acc, current)

          {:error, _} = err ->
            err
        end

      # No-newline marker
      String.starts_with?(line, "\\ ") ->
        current = add_line_to_current_hunk(current, :no_newline, String.trim_leading(line, "\\ "))
        parse_lines(rest, acc, current)

      # Added line
      String.starts_with?(line, "+") ->
        content = String.slice(line, 1..-1//1)
        current = add_line_to_current_hunk(current, :add, content)
        parse_lines(rest, acc, current)

      # Removed line
      String.starts_with?(line, "-") ->
        content = String.slice(line, 1..-1//1)
        current = add_line_to_current_hunk(current, :remove, content)
        parse_lines(rest, acc, current)

      # Context line (space-prefixed line within a hunk)
      # Empty strings (from trailing newlines) are NOT valid hunk content.
      current != nil and current.hunks != [] and line != "" ->
        current = add_line_to_current_hunk(current, :context, line)
        parse_lines(rest, acc, current)

      # Ignore unrecognised lines outside hunks (e.g., git index lines)
      true ->
        parse_lines(rest, acc, current)
    end
  end

  defp new_file_entry(diff_line) do
    %{old_path: nil, new_path: nil, hunks: [], _diff_line: diff_line}
  end

  defp put_old_path(nil, path), do: %{old_path: path, new_path: nil, hunks: []}
  defp put_old_path(entry, path), do: %{entry | old_path: path}

  defp put_new_path(nil, path), do: %{old_path: nil, new_path: path, hunks: []}
  defp put_new_path(entry, path), do: %{entry | new_path: path}

  defp add_hunk(entry, hunk_info) do
    hunk = Map.merge(hunk_info, %{lines: []})
    %{entry | hunks: entry.hunks ++ [hunk]}
  end

  defp add_line_to_current_hunk(nil, _type, _content), do: nil

  defp add_line_to_current_hunk(%{hunks: []} = entry, _type, _content), do: entry

  defp add_line_to_current_hunk(%{hunks: hunks} = entry, type, content) do
    [last | rest] = Enum.reverse(hunks)
    last = %{last | lines: last.lines ++ [{type, content}]}
    %{entry | hunks: Enum.reverse([last | rest])}
  end

  defp finalize_current(acc, nil), do: acc

  defp finalize_current(acc, entry) do
    cleaned = %{
      old_path: entry.old_path,
      new_path: entry.new_path,
      hunks: entry.hunks
    }

    [cleaned | acc]
  end

  # Extract path from `--- a/path` or `+++ b/path`.
  # Strips the `a/` or `b/` prefix. Handles `/dev/null` for new/deleted files.
  defp extract_path(line, prefix) do
    raw = String.trim_leading(line, prefix)

    cond do
      raw == "/dev/null" -> nil
      String.starts_with?(raw, "a/") -> String.slice(raw, 2..-1//1)
      String.starts_with?(raw, "b/") -> String.slice(raw, 2..-1//1)
      true -> raw
    end
  end

  # Parse `@@ -l,s +l,s @@` hunk headers.
  @hunk_header_regex ~r/^@@\s+-(?<old_start>\d+)(?:,(?<old_count>\d+))?\s+\+(?<new_start>\d+)(?:,(?<new_count>\d+))?\s+@@/

  defp parse_hunk_header(line) do
    case Regex.named_captures(@hunk_header_regex, line) do
      nil ->
        {:error, {:malformed_header, line}}

      captures ->
        old_start = String.to_integer(captures["old_start"])
        old_count = parse_optional_int(captures["old_count"], 1)
        new_start = String.to_integer(captures["new_start"])
        new_count = parse_optional_int(captures["new_count"], 1)

        {:ok,
         %{
           header: line,
           old_start: old_start,
           old_count: old_count,
           new_start: new_start,
           new_count: new_count
         }}
    end
  end

  defp parse_optional_int(nil, default), do: default
  defp parse_optional_int("", default), do: default
  defp parse_optional_int(str, _default), do: String.to_integer(str)

  defp validate_structure(diff) do
    case parse(diff) do
      {:ok, _entries} -> :ok
      {:error, _} = err -> err
    end
  end

  defp drop_trailing_blanks(lines) do
    Enum.reverse(lines)
    |> Enum.drop_while(fn line -> line == "" end)
    |> Enum.reverse()
  end

  defp ensure_trailing_newline(""), do: ""
  defp ensure_trailing_newline(canonical), do: canonical <> "\n"
end
