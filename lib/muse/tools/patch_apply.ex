defmodule Muse.Tools.PatchApply do
  @moduledoc """
  Safe tool: apply an approved patch to the workspace with checkpoint protection.

  This tool applies a previously approved patch diff to the workspace. It:

    1. Validates the caller is Coding Muse with an approved plan context.
    2. Validates an approved `%Muse.Approval{kind: :patch, status: :approved}`
       exists for the patch.
    3. Loads the approved patch from persisted patches (never trusts model-supplied
       raw diff for apply).
    4. Re-validates the patch with `Muse.Patch.Validator`.
    5. Creates a `Muse.Checkpoint` BEFORE any write.
    6. Applies via `git apply --check` then `git apply` using LocalRunner (PR24).
    7. On failure, leaves checkpoint with failure metadata; no partial writes.
    8. On success, marks patch `:applied` and returns bounded git diff preview.

  ## Authorization (runtime-enforced)

    * Must be called by Coding Muse (`muse_id: :coding`).
    * Must have an active approved plan in context.
    * Must have a matching `%Muse.Approval{kind: :patch, status: :approved}`.
    * The patch must belong to the current session and active plan.

  ## Input

    * `"patch_id"` (optional) — the patch to apply
    * `"patch_hash"` (optional) — alternative lookup by content hash

  At least one of `patch_id` or `patch_hash` must be provided.

  ## Safety

    * Binary patches, unsafe paths, secret paths, absolute paths, traversal,
      and delete operations without explicit approval are blocked.
    * `git apply --check` is run before actual apply.
    * Checkpoint is created BEFORE any write; if checkpoint creation fails,
      apply is aborted.
    * On apply failure, the checkpoint persists with failure metadata and
      the workspace is left in a recoverable state.
  """

  alias Muse.{Approval, Checkpoint, Checkpoint.Store, Patch, Patch.Validator, SessionStore}
  alias Muse.Execution.{Command, LocalRunner}
  alias Muse.Execution.Result, as: ExecutionResult
  alias Muse.Patch.DiffParser
  alias Muse.Tool.Result

  @max_git_diff_output 20_000

  @doc """
  Execute the patch_apply tool.

  ## Context

    * `:workspace` — workspace root path (required)
    * `:session_id` — session identifier (required)
    * `:muse_id` — must be `:coding`
    * `:plan_id` — active plan ID
    * `:plan_version` — active plan version
    * `:plan_hash` — active plan content hash
    * `:plan_status` — must be `:approved`
    * `:approvals` — list of approval records for this session
    * `:pending_patch` — the current pending patch (if in-memory)
    * `:patches` — loaded persisted patches for the session
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = to_string(Map.get(context, :workspace, ""))

    with :ok <- require_coding_muse(context),
         :ok <- require_approved_plan(context),
         {:ok, patch_id, patch_hash} <- resolve_patch_identity(args),
         {:ok, patch} <- load_approved_patch(patch_id, patch_hash, context),
         :ok <- verify_patch_binding(patch, context),
         :ok <- verify_approval(patch, context),
         :ok <- revalidate_patch(patch, workspace),
         :ok <- reject_deletes(patch),
         {:ok, checkpoint} <- create_checkpoint(patch, context, workspace),
         :ok <- apply_via_git(patch, workspace, checkpoint) do
      # Mark patch as applied
      {:ok, applied_patch} = Patch.transition(patch, :applied)

      # Mark checkpoint as active
      {:ok, checkpoint} = Checkpoint.transition(checkpoint, :active)

      manifest_result = Store.update_manifest(checkpoint)

      # Persist auditable apply record to session patches.jsonl
      audit_result =
        persist_apply_audit(context, applied_patch, checkpoint)

      # Get bounded post-apply diff preview
      diff_preview = bounded_git_diff(workspace)

      base_output = %{
        checkpoint_id: checkpoint.id,
        patch_id: applied_patch.id,
        patch_hash: applied_patch.hash,
        affected_files: applied_patch.affected_files,
        status: :applied,
        git_diff_preview: diff_preview,
        message:
          "Patch #{applied_patch.id} applied successfully. Checkpoint #{checkpoint.id} created."
      }

      # If manifest update failed, add audit warning but don't crash.
      # Workspace WAS modified; checkpoint exists but manifest may be stale.
      output =
        case manifest_result do
          {:ok, _} ->
            base_output

          {:error, reason} ->
            Map.put(
              base_output,
              :audit_warning,
              "checkpoint manifest update failed: #{inspect(reason)}; workspace was modified"
            )
        end

      # If apply audit persistence failed, surface warning
      output =
        case audit_result do
          :ok ->
            output

          {:error, reason} ->
            Map.put(
              output,
              :audit_warning,
              output[:audit_warning] ||
                "apply audit persistence failed: #{inspect(reason)}"
            )
        end

      Result.ok(
        "patch_apply",
        output,
        %{
          checkpoint: Checkpoint.event_summary(checkpoint),
          patch: %{id: applied_patch.id, hash: applied_patch.hash, status: :applied}
        }
      )
    else
      {:error, %Result{} = r} ->
        r

      {:error, {:checkpoint_failed, reason}} ->
        Result.error(
          "patch_apply",
          "checkpoint creation failed: #{inspect(reason)}; patch was NOT applied"
        )

      {:error, {:apply_check_failed, reason}} ->
        Result.error("patch_apply", "git apply --check failed: #{reason}; patch was NOT applied")

      {:error, {:apply_failed, reason, checkpoint}} ->
        # Mark checkpoint as failed
        {:ok, failed} = Checkpoint.transition(checkpoint, :failed, failure_reason: reason)
        _ = Store.update_manifest(failed)

        Result.error(
          "patch_apply",
          "git apply failed: #{reason}; checkpoint #{failed.id} preserved for rollback"
        )

      {:error, reason} ->
        Result.error("patch_apply", format_error(reason))
    end
  end

  # -- Runtime authorization ---------------------------------------------------

  defp require_coding_muse(context) do
    if Map.get(context, :muse_id) == :coding do
      :ok
    else
      {:error, "patch_apply requires Coding Muse context"}
    end
  end

  defp require_approved_plan(context) do
    cond do
      Map.get(context, :plan_status) != :approved ->
        {:error,
         "patch_apply requires an approved plan (got plan_status: #{inspect(Map.get(context, :plan_status))})"}

      blank?(Map.get(context, :plan_id)) ->
        {:error, "patch_apply requires plan_id in context"}

      blank?(Map.get(context, :plan_hash)) ->
        {:error, "patch_apply requires plan_hash in context"}

      blank?(Map.get(context, :session_id)) ->
        {:error, "patch_apply requires session_id in context"}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Verify patch belongs to same session + active plan with matching hashes.
  defp verify_patch_binding(%Patch{} = patch, context) do
    session_id = to_string(Map.get(context, :session_id, ""))
    plan_id = Map.get(context, :plan_id)
    plan_version = Map.get(context, :plan_version)
    plan_hash = Map.get(context, :plan_hash)

    cond do
      patch.session_id != nil and patch.session_id != session_id ->
        {:error,
         "patch session_id #{inspect(patch.session_id)} does not match context session_id #{inspect(session_id)}"}

      patch.plan_id != nil and patch.plan_id != plan_id ->
        {:error,
         "patch plan_id #{inspect(patch.plan_id)} does not match active plan #{inspect(plan_id)}"}

      patch.plan_version != nil and patch.plan_version != plan_version ->
        {:error,
         "patch plan_version #{inspect(patch.plan_version)} does not match active plan version #{inspect(plan_version)}"}

      patch.plan_hash != nil and patch.plan_hash != "" and patch.plan_hash != plan_hash ->
        {:error, "patch plan_hash does not match active plan hash (stale plan binding)"}

      true ->
        :ok
    end
  end

  # -- Patch identity resolution ------------------------------------------------

  defp resolve_patch_identity(args) do
    patch_id = Map.get(args, "patch_id")
    patch_hash = Map.get(args, "patch_hash")

    cond do
      is_binary(patch_id) and patch_id != "" -> {:ok, patch_id, patch_hash}
      is_binary(patch_hash) and patch_hash != "" -> {:ok, nil, patch_hash}
      true -> {:error, "patch_id or patch_hash is required"}
    end
  end

  # -- Load approved patch ------------------------------------------------------

  defp load_approved_patch(patch_id, patch_hash, context) do
    # Try in-memory pending patch first
    pending = Map.get(context, :pending_patch)

    cond do
      pending != nil and patch_matches?(pending, patch_id, patch_hash) ->
        {:ok, pending}

      true ->
        # Try persisted patches (status may still be :proposed if persisted before approval)
        load_persisted_patch(patch_id, patch_hash, context)
    end
  end

  defp patch_matches?(%Patch{} = patch, patch_id, patch_hash) do
    (is_nil(patch_id) or patch.id == patch_id) and
      (is_nil(patch_hash) or patch.hash == patch_hash)
  end

  defp load_persisted_patch(patch_id, patch_hash, context) do
    session_id = to_string(Map.get(context, :session_id, ""))

    if session_id == "" do
      {:error, "session_id is required to locate the approved patch"}
    else
      case Muse.SessionStore.load_patches(session_id) do
        {:ok, patches, _meta} ->
          # Patches may be persisted at propose time (status: proposed)
          # and updated later; accept any status since approval is verified separately.
          found =
            patches
            |> Enum.find(fn p ->
              (is_nil(patch_id) or Map.get(p, "id") == patch_id or
                 Map.get(p, "patch_id") == patch_id) and
                (is_nil(patch_hash) or Map.get(p, "hash") == patch_hash)
            end)

          case found do
            nil -> {:error, "no approved patch found matching the given id/hash"}
            map -> Patch.from_map(map)
          end

        {:error, reason} ->
          {:error, "failed to load persisted patches: #{inspect(reason)}"}
      end
    end
  end

  # -- Approval verification ----------------------------------------------------

  defp verify_approval(%Patch{} = patch, context) do
    session_id = to_string(Map.get(context, :session_id, ""))
    plan_id = Map.get(context, :plan_id)
    plan_hash = Map.get(context, :plan_hash)
    approvals = Map.get(context, :approvals, [])

    # plan_hash must be non-blank in context for strict matching
    if blank?(plan_hash) do
      {:error, "patch_apply requires non-blank plan_hash in context for approval verification"}
    else
      matching =
        approvals
        |> Approval.normalize_list()
        |> Enum.any?(fn a ->
          a.kind == :patch and
            a.status == :approved and
            a.session_id == session_id and
            a.patch_id == patch.id and
            a.patch_hash == patch.hash and
            a.plan_id == plan_id and
            is_binary(a.plan_hash) and a.plan_hash != "" and
            a.plan_hash == plan_hash
        end)

      if matching do
        :ok
      else
        {:error,
         "no matching approved patch approval for patch #{patch.id} in session #{session_id} plan #{plan_id}"}
      end
    end
  end

  # -- Re-validation ------------------------------------------------------------

  defp revalidate_patch(%Patch{} = patch, workspace) do
    case Validator.validate(patch.diff, workspace) do
      {:ok, _} ->
        :ok

      {:error, %{reason: reason, message: msg}} ->
        {:error, "patch re-validation failed (#{reason}): #{msg}"}

      {:error, reason} ->
        {:error, "patch re-validation failed: #{inspect(reason)}"}
    end
  end

  # -- Delete rejection ---------------------------------------------------------

  defp reject_deletes(%Patch{} = patch) do
    case DiffParser.parse(patch.diff) do
      {:ok, entries} ->
        has_deletes =
          Enum.any?(entries, fn entry ->
            entry.new_path == nil and entry.old_path != nil
          end)

        if has_deletes do
          {:error,
           "patch contains file deletion diffs; delete operations require explicit approval (not implemented in MVP)"}
        else
          :ok
        end

      {:error, _reason} ->
        # If we can't parse the diff, reject it
        {:error, "failed to parse diff for deletion check"}
    end
  end

  # -- Checkpoint creation ------------------------------------------------------

  defp create_checkpoint(%Patch{} = patch, context, workspace) do
    session_id = to_string(Map.get(context, :session_id, ""))

    checkpoint =
      Checkpoint.new(%{
        session_id: session_id,
        plan_id: Map.get(context, :plan_id) || patch.plan_id,
        plan_version: Map.get(context, :plan_version) || patch.plan_version,
        plan_hash: Map.get(context, :plan_hash) || patch.plan_hash,
        patch_id: patch.id,
        patch_hash: patch.hash,
        workspace: workspace,
        strategy: :git_apply,
        affected_files: patch.affected_files,
        metadata: %{diff: patch.diff}
      })

    case Store.create(checkpoint) do
      {:ok, created} -> {:ok, created}
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
    end
  end

  # -- Git apply ----------------------------------------------------------------

  defp apply_via_git(%Patch{} = _patch, workspace, checkpoint) do
    chk_dir = Store.checkpoint_dir(".muse/sessions", checkpoint.session_id, checkpoint.id)
    diff_file = Path.join(chk_dir, "patch.diff")

    # Resolve to absolute path so git apply works regardless of workspace CWD
    diff_file_abs = Path.expand(diff_file)

    # Step 1: git apply --check (dry run) using LocalRunner (PR24)
    case run_git_command(workspace, ["apply", "--check", diff_file_abs]) do
      {:ok, _} ->
        # Step 2: git apply (actual)
        case run_git_command(workspace, ["apply", diff_file_abs]) do
          {:ok, _} ->
            :ok

          {:error, error_output} ->
            {:error, {:apply_failed, String.slice(error_output, 0, 500), checkpoint}}
        end

      {:error, error_output} ->
        {:error, {:apply_check_failed, String.slice(error_output, 0, 500)}}
    end
  rescue
    e ->
      {:error, {:apply_failed, Exception.message(e), checkpoint}}
  end

  defp run_git_command(workspace, args) do
    case Command.new("git", args: args, cwd: workspace, timeout_ms: 60_000) do
      {:ok, cmd} ->
        case LocalRunner.run(cmd) do
          {:ok, %ExecutionResult{status: :ok}} -> {:ok, ""}
          {:ok, %ExecutionResult{output: output}} -> {:ok, output || ""}
          {:ok, %ExecutionResult{error: error}} -> {:error, to_string(error)}
          {:error, %ExecutionResult{error: error}} -> {:error, to_string(error)}
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        {:error, "command validation failed: #{reason}"}
    end
  end

  # -- Post-apply diff ----------------------------------------------------------

  defp bounded_git_diff(workspace) do
    case Command.new("git", args: ["diff", "--stat"], cwd: workspace, timeout_ms: 30_000) do
      {:ok, cmd} ->
        case LocalRunner.run(cmd) do
          {:ok, %ExecutionResult{status: :ok, output: output}} when is_binary(output) ->
            String.slice(output, 0, @max_git_diff_output)

          _ ->
            nil
        end

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  # -- Error formatting ---------------------------------------------------------

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "patch apply failed: #{inspect(reason)}"

  # -- Audit persistence --------------------------------------------------------

  defp persist_apply_audit(context, %Patch{} = patch, %Checkpoint{} = checkpoint) do
    session_id = to_string(Map.get(context, :session_id, ""))

    audit_record = %{
      event: :patch_applied,
      patch_id: patch.id,
      patch_hash: patch.hash,
      plan_id: Map.get(context, :plan_id),
      plan_hash: Map.get(context, :plan_hash),
      checkpoint_id: checkpoint.id,
      session_id: session_id,
      source: "coding_muse",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: :applied
    }

    case SessionStore.append_patch(session_id, audit_record) do
      :ok -> :ok
      {:error, reason} -> {:error, {:audit_persist_failed, reason}}
    end
  end
end
