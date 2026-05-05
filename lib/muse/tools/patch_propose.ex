defmodule Muse.Tools.PatchPropose do
  @moduledoc """
  Safe tool: create and store a patch proposal without applying it.

  This tool accepts a unified diff and optional metadata, validates it,
  computes a stable hash, and returns a proposal result. It NEVER writes
  files, applies patches, or modifies the workspace.

  ## Input

    * `"diff"` (required) — unified diff string
    * `"summary"` (optional) — human-readable summary of the changes
    * `"affected_files"` (optional) — list of affected file paths

  ## Validation

    * Diff must be a non-empty string
    * Diff must not contain dangerous shell patterns
    * Diff must not exceed size limits
    * Summary and affected_files are optional but validated if present

  ## Output

    * `patch_id` — stable identifier derived from diff content
    * `hash` — SHA-256 hash of the normalized diff
    * `diff_size` — byte size of the received diff
    * `affected_files` — list of affected files (from input or parsed from diff)
    * `summary` — provided summary or auto-generated first line
    * `approval_required` — true (patch needs approval before apply)
    * `message` — guidance text instructing user to approve before apply
  """

  alias Muse.Tool.Result

  @max_diff_bytes 500_000

  @dangerous_patterns [
    ~r/\bsudo\b/,
    ~r/\brm\s+-rf\s+\/\b/,
    ~r/\bchmod\s+777\b/,
    ~r/\bcurl\s+.*\||\bwget\s+.*\|/,
    ~r/`[^`]*`/,
    ~r/\$\(/
  ]

  @doc """
  Execute the patch_propose tool.

  ## Arguments

    * `"diff"` (required) — unified diff string
    * `"summary"` (optional) — description of changes
    * `"affected_files"` (optional) — list of file paths

  ## Context

    * `:workspace` — workspace root path
    * `:session_id` — session identifier
    * `:turn_id` — turn identifier
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, _context) do
    diff = Map.get(args, "diff", "")

    with {:ok, diff} <- validate_diff(diff),
         :ok <- validate_no_dangerous_patterns(diff) do
      # Parse affected files from diff if not provided
      affected_files =
        case Map.get(args, "affected_files") do
          files when is_list(files) and files != [] -> files
          _ -> parse_affected_files(diff)
        end

      summary =
        case Map.get(args, "summary") do
          s when is_binary(s) and s != "" -> s
          _ -> auto_summary(diff)
        end

      # Compute stable hash
      hash = compute_hash(diff)
      patch_id = "patch_#{String.slice(hash, 0, 12)}"

      Result.ok("patch_propose", %{
        patch_id: patch_id,
        hash: hash,
        diff_size: byte_size(diff),
        affected_files: affected_files,
        summary: summary,
        approval_required: true,
        message:
          "Patch proposal #{patch_id} created. " <>
            "Review the diff and use `/approve patch` to authorize application. " <>
            "No files have been modified."
      })
    else
      {:error, reason} ->
        Result.error("patch_propose", reason)
    end
  end

  # -- Validation ---------------------------------------------------------------

  defp validate_diff(diff) when is_binary(diff) and diff == "" do
    {:error, "diff is required and cannot be empty"}
  end

  defp validate_diff(diff) when is_binary(diff) and byte_size(diff) > @max_diff_bytes do
    {:error, "diff exceeds maximum size of #{@max_diff_bytes} bytes"}
  end

  defp validate_diff(diff) when is_binary(diff) do
    # Check it looks like a unified diff (starts with --- or diff --git)
    first_line = String.split(diff, "\n") |> List.first() |> String.trim()

    if String.starts_with?(first_line, "---") or
         String.starts_with?(first_line, "diff --git") or
         String.contains?(diff, "\n--- ") or
         String.contains?(diff, "\n+++ ") do
      {:ok, diff}
    else
      {:error,
       "diff does not appear to be a valid unified diff format (expected ---/+++ markers)"}
    end
  end

  defp validate_diff(_diff) do
    {:error, "diff must be a string"}
  end

  defp validate_no_dangerous_patterns(diff) do
    matching =
      Enum.find(@dangerous_patterns, fn pattern ->
        Regex.run(pattern, diff)
      end)

    case matching do
      nil -> :ok
      _pattern -> {:error, "diff contains potentially dangerous patterns and was rejected"}
    end
  end

  # -- Parsing ------------------------------------------------------------------

  defp parse_affected_files(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.starts_with?(line, "+++ ") or String.starts_with?(line, "--- ")
    end)
    |> Enum.map(fn line ->
      # Extract path after "+++ b/" or "--- a/"
      line
      |> String.trim_leading("+++ ")
      |> String.trim_leading("--- ")
      |> String.trim_leading("a/")
      |> String.trim_leading("b/")
      |> String.trim()
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "" or &1 == "/dev/null"))
  end

  defp auto_summary(diff) do
    # Use the diff header line for auto-summary
    diff
    |> String.split("\n")
    |> Enum.find(fn line ->
      String.starts_with?(line, "diff --git")
    end)
    |> case do
      nil ->
        lines = String.split(diff, "\n") |> length()
        "Patch proposal with #{lines} lines"

      header ->
        header
    end
  end

  # -- Hashing ------------------------------------------------------------------

  defp compute_hash(diff) do
    diff
    |> normalize_diff()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_diff(diff) do
    # Normalize: trim trailing whitespace per line, drop trailing newline
    diff
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reverse()
    |> drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp drop_while(list, predicate) do
    Enum.drop_while(list, predicate)
  end
end
