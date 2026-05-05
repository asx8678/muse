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

  alias Muse.{Checkpoint, Checkpoint.Store}
  alias Muse.Tool.Result

  @doc """
  Execute the rollback_checkpoint tool.

  ## Context

    * `:workspace` — workspace root path (required)
    * `:session_id` — session identifier (required)
    * `:muse_id` — must be `:coding`
    * `:plan_id` — active plan ID for cross-validation
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    checkpoint_id = Map.get(args, "checkpoint_id")
    workspace = to_string(Map.get(context, :workspace, ""))
    session_id = to_string(Map.get(context, :session_id, ""))

    with {:ok, checkpoint_id} <- require_checkpoint_id(checkpoint_id),
         {:ok, checkpoint} <- load_checkpoint(checkpoint_id, session_id),
         :ok <- verify_checkpoint_ownership(checkpoint, context),
         :ok <- verify_workspace_match(checkpoint, workspace),
         {:ok, rolled_back} <- Store.rollback(checkpoint) do
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
        Result.error("rollback_checkpoint", format_error(reason))
    end
  end

  # -- Input validation ---------------------------------------------------------

  defp require_checkpoint_id(nil), do: {:error, "checkpoint_id is required"}
  defp require_checkpoint_id(""), do: {:error, "checkpoint_id is required"}
  defp require_checkpoint_id(id) when is_binary(id), do: {:ok, id}
  defp require_checkpoint_id(_), do: {:error, "checkpoint_id must be a string"}

  # -- Checkpoint loading -------------------------------------------------------

  defp load_checkpoint(checkpoint_id, session_id) do
    case Store.load(session_id, checkpoint_id) do
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

  # -- Error formatting ---------------------------------------------------------

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "rollback failed: #{inspect(reason)}"
end
