defmodule Muse.Tools.PatchPropose do
  @moduledoc """
  Safe tool: create and store a patch proposal without applying it.

  This tool accepts a unified diff and optional metadata, validates it
  via `Muse.Patch.Validator`, creates a `Muse.Patch` struct with stable
  hash and canonical diff, and returns a proposal result. It NEVER writes
  files, applies patches, or modifies the workspace.

  ## Input

    * `"diff"` (required) — unified diff string
    * `"summary"` (optional) — human-readable summary of the changes
    * `"affected_files"` (optional) — list of affected file paths

  ## Validation

    * Diff must be a non-empty string
    * Diff must pass `Muse.Patch.Validator.validate_proposal/3` (path safety,
      size limits, no binary patches, no secrets)
    * Summary and affected_files are optional but validated if present

  ## Output

    * `patch_id` — stable identifier derived from diff content
    * `hash` — SHA-256 hash of the normalized diff
    * `diff_size` — byte size of the received diff
    * `affected_files` — list of affected files (from input or parsed from diff)
    * `summary` — provided summary or auto-generated first line
    * `approval_required` — true (patch needs approval before apply)
    * `message` — guidance text instructing user to approve before apply

  ## PR17 invariants

    * No file under workspace affected by proposed diff is modified.
    * `patch_apply` remains blocked/unregistered/denied until PR18.
    * No `String.to_atom` on client/model input.
  """

  alias Muse.{Patch, Patch.Validator}
  alias Muse.Patch.DiffParser
  alias Muse.Tool.Result

  @max_diff_bytes 500_000

  @doc """
  Execute the patch_propose tool.

  ## Arguments

    * `"diff"` (required) — unified diff string
    * `"summary"` (optional) — description of changes
    * `"affected_files"` (optional) — list of file paths

  ## Context

    * `:workspace` — workspace root path (required for validation)
    * `:session_id` — session identifier
    * `:turn_id` — turn identifier
    * `:plan_id` — active plan ID
    * `:plan_version` — active plan version
    * `:plan_hash` — active plan content hash
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    diff = Map.get(args, "diff", "")

    with {:ok, diff} <- validate_diff_input(diff),
         {:ok, _paths} <- validate_with_validator(diff, context) do
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

      # Compute stable hash via the authoritative Muse.Patch model
      hash =
        Patch.content_hash(%Patch{
          id: nil,
          session_id: to_string(Map.get(context, :session_id, "")),
          plan_id: to_string(Map.get(context, :plan_id, "")),
          plan_version: Map.get(context, :plan_version, 1),
          plan_hash: to_string(Map.get(context, :plan_hash, "")),
          diff: diff,
          hash: nil,
          affected_files: affected_files,
          status: :proposed
        })

      patch_id = "patch_#{String.slice(hash, 0, 12)}"

      proposal = %{
        diff: diff,
        patch_id: patch_id,
        hash: hash,
        affected_files: affected_files,
        summary: summary,
        plan_id: Map.get(context, :plan_id),
        plan_version: Map.get(context, :plan_version),
        plan_hash: Map.get(context, :plan_hash)
      }

      Result.ok(
        "patch_propose",
        %{
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
        },
        %{patch_proposal: proposal}
      )
    else
      {:error, %{} = validation_error} ->
        reason =
          Map.get(
            validation_error,
            :message,
            Map.get(validation_error, :reason, "validation failed")
          )

        Result.error("patch_propose", to_string(reason))

      {:error, reason} ->
        Result.error("patch_propose", to_string(reason))
    end
  end

  # -- Validation ---------------------------------------------------------------

  defp validate_diff_input(diff) when is_binary(diff) and diff == "" do
    {:error, "diff is required and cannot be empty"}
  end

  defp validate_diff_input(diff) when is_binary(diff) and byte_size(diff) > @max_diff_bytes do
    {:error, "diff exceeds maximum size of #{@max_diff_bytes} bytes"}
  end

  defp validate_diff_input(diff) when is_binary(diff) do
    {:ok, diff}
  end

  defp validate_diff_input(_diff) do
    {:error, "diff must be a string"}
  end

  defp validate_with_validator(diff, context) do
    workspace = Map.get(context, :workspace) || Map.get(context, "workspace")

    if is_binary(workspace) and workspace != "" do
      Validator.validate_proposal(diff, workspace, %{})
    else
      # Without a workspace, do basic parse validation only
      DiffParser.validate(diff)
    end
  end

  # -- Parsing ------------------------------------------------------------------

  defp parse_affected_files(diff) do
    case DiffParser.affected_paths(diff) do
      {:ok, paths} ->
        paths

      {:error, _} ->
        # Fallback: simple regex extraction
        diff
        |> String.split("\n")
        |> Enum.filter(fn line ->
          String.starts_with?(line, "+++ ") or String.starts_with?(line, "--- ")
        end)
        |> Enum.map(fn line ->
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
  end

  defp auto_summary(diff) do
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
end
