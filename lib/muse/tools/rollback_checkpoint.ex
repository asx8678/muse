defmodule Muse.Tools.RollbackCheckpoint do
  @moduledoc """
  Safe tool: rollback a checkpoint to restore the workspace to its pre-apply state.

  This tool restores the workspace to the state captured in a checkpoint by
  re-reading file snapshots and restoring affected files exactly:

    - Files that existed before the patch get their content restored.
    - Files that did not exist before the patch get deleted.

  ## Authorization (runtime-enforced)

    * Must be called by Coding Muse (`muse_id: :coding`).
    * The checkpoint must belong to the same session and active approved plan.
    * Cross-session and cross-workspace restores are denied.
    * User must have explicit approval or the checkpoint must be in a
      failed/active state belonging to the current session context.

  ## Input

    * `"checkpoint_id"` (required) — the checkpoint to rollback

  ## Safety

    * Workspace path validation on every restore operation.
    * Secret paths are never written or deleted.
    * Symlink escapes are blocked.
    * All operations are auditable via checkpoint manifest updates.
  """

  alias Muse.{Checkpoint, Checkpoint.Store, SessionStore}
  alias Muse.Tool.Result

  @doc """
  Execute the rollback_checkpoint tool.

  ## Context

    * `:workspace` — workspace root path (required)
    * `:session_id` — session identifier (required)
    * `:muse_id` — must be `:coding`
    * `:plan_id` — active plan ID for cross-validation
    * `:store_base_dir` — workspace-scoped sessions directory for persisted checkpoints/audit
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    checkpoint_id = Map.get(args, "checkpoint_id")
    workspace = to_string(Map.get(context, :workspace, ""))
    session_id = to_string(Map.get(context, :session_id, ""))

    with :ok <- require_coding_muse(context),
         :ok <- require_approved_plan(context),
         {:ok, checkpoint_id} <- require_checkpoint_id(checkpoint_id),
         {:ok, checkpoint} <- load_checkpoint(checkpoint_id, session_id, context),
         :ok <- verify_checkpoint_ownership(checkpoint, context),
         :ok <- verify_workspace_match(checkpoint, workspace),
         :ok <- verify_plan_binding(checkpoint, context),
         {:ok, rolled_back} <-
           Store.rollback(checkpoint, base_dir: context_store_base_dir(context)) do
      # Persist rollback audit record
      _ = persist_rollback_audit(context, rolled_back, :completed)

      Result.ok(
        "rollback_checkpoint",
        %{
          checkpoint_id: rolled_back.id,
          patch_id: rolled_back.patch_id,
          patch_hash: rolled_back.patch_hash,
          affected_files: rolled_back.affected_files,
          file_count: length(rolled_back.affected_files),
          status: :rolled_back,
          message:
            "Checkpoint #{rolled_back.id} rolled back successfully. Workspace restored to pre-apply state."
        },
        %{
          checkpoint: Checkpoint.event_summary(rolled_back)
        }
      )
    else
      {:error, reason} ->
        # Attempt to persist rollback failure audit if we have enough context
        _ = persist_rollback_audit(context, nil, :failed)
        Result.error("rollback_checkpoint", format_error(reason))
    end
  end

  # -- Runtime authorization ---------------------------------------------------

  defp require_coding_muse(context) do
    if Map.get(context, :muse_id) == :coding do
      :ok
    else
      {:error, "rollback_checkpoint requires Coding Muse context"}
    end
  end

  defp require_approved_plan(context) do
    cond do
      Map.get(context, :plan_status) != :approved ->
        {:error,
         "rollback_checkpoint requires an approved plan (got plan_status: #{inspect(Map.get(context, :plan_status))})"}

      blank?(Map.get(context, :plan_id)) ->
        {:error, "rollback_checkpoint requires plan_id in context"}

      blank?(Map.get(context, :plan_hash)) ->
        {:error, "rollback_checkpoint requires plan_hash in context"}

      blank?(Map.get(context, :session_id)) ->
        {:error, "rollback_checkpoint requires session_id in context"}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # -- Input validation ---------------------------------------------------------

  defp require_checkpoint_id(nil), do: {:error, "checkpoint_id is required"}
  defp require_checkpoint_id(""), do: {:error, "checkpoint_id is required"}
  defp require_checkpoint_id(id) when is_binary(id), do: {:ok, id}
  defp require_checkpoint_id(_), do: {:error, "checkpoint_id must be a string"}

  # -- Checkpoint loading -------------------------------------------------------

  defp context_store_base_dir(context) do
    case Map.get(context, :store_base_dir) || Map.get(context, "store_base_dir") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> ".muse/sessions"
    end
  end

  defp load_checkpoint(checkpoint_id, session_id, context) do
    case Store.load(session_id, checkpoint_id, base_dir: context_store_base_dir(context)) do
      {:ok, checkpoint} ->
        {:ok, checkpoint}

      {:error, :checkpoint_not_found} ->
        {:error, "checkpoint #{checkpoint_id} not found in session #{session_id}"}

      {:error, reason} ->
        {:error, "failed to load checkpoint: #{inspect(reason)}"}
    end
  end

  # -- Ownership verification ---------------------------------------------------

  defp verify_checkpoint_ownership(%Checkpoint{} = checkpoint, context) do
    session_id = to_string(Map.get(context, :session_id, ""))
    plan_id = Map.get(context, :plan_id)

    cond do
      checkpoint.session_id != session_id ->
        {:error,
         "checkpoint belongs to session #{checkpoint.session_id}, not current session #{session_id}"}

      plan_id != nil and checkpoint.plan_id != plan_id ->
        {:error, "checkpoint belongs to plan #{checkpoint.plan_id}, not active plan #{plan_id}"}

      checkpoint.status not in [:active, :failed] ->
        {:error,
         "checkpoint status is #{checkpoint.status}; only active or failed checkpoints can be rolled back"}

      true ->
        :ok
    end
  end

  # -- Workspace match ----------------------------------------------------------

  defp verify_workspace_match(%Checkpoint{} = checkpoint, workspace) do
    if checkpoint.workspace != nil and checkpoint.workspace != workspace do
      {:error,
       "checkpoint workspace #{checkpoint.workspace} does not match current workspace #{workspace}"}
    else
      :ok
    end
  end

  # -- Plan binding verification ------------------------------------------------

  defp verify_plan_binding(%Checkpoint{} = checkpoint, context) do
    plan_id = Map.get(context, :plan_id)
    plan_hash = Map.get(context, :plan_hash)

    cond do
      checkpoint.plan_id != nil and checkpoint.plan_id != plan_id ->
        {:error,
         "checkpoint plan_id #{inspect(checkpoint.plan_id)} does not match active plan #{inspect(plan_id)}"}

      # PR18 strict: checkpoint must have non-blank plan_hash that matches context
      blank?(checkpoint.plan_hash) ->
        {:error, "checkpoint has missing or blank plan_hash; cannot verify plan binding"}

      checkpoint.plan_hash != plan_hash ->
        {:error,
         "checkpoint plan_hash does not match active plan hash (stale or tampered plan binding)"}

      true ->
        :ok
    end
  end

  # -- Error formatting ---------------------------------------------------------

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "rollback failed: #{inspect(reason)}"

  # -- Audit persistence ---------------------------------------------------------

  defp persist_rollback_audit(context, checkpoint, status) do
    session_id = to_string(Map.get(context, :session_id, ""))

    audit_record =
      %{
        event: if(status == :completed, do: :rollback_completed, else: :rollback_failed),
        checkpoint_id: if(checkpoint, do: checkpoint.id, else: nil),
        patch_id: if(checkpoint, do: checkpoint.patch_id, else: nil),
        patch_hash: if(checkpoint, do: checkpoint.patch_hash, else: nil),
        plan_id: Map.get(context, :plan_id),
        plan_hash: Map.get(context, :plan_hash),
        session_id: session_id,
        source: "coding_muse",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        status: status
      }

    case SessionStore.append_patch(context_store_base_dir(context), session_id, audit_record) do
      :ok -> :ok
      # non-fatal for rollback audit
      {:error, _reason} -> :ok
    end
  end
end
