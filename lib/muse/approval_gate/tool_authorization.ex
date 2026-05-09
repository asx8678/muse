defmodule Muse.ApprovalGate.ToolAuthorization do
  @moduledoc """
  Tool-level authorization checks for `Muse.ApprovalGate`.

  Determines whether specific tool calls (patch_propose, patch_apply,
  rollback_checkpoint) are allowed given the current session context.
  Each tool has specific requirements (e.g., an approved plan for
  patch operations).

  ## Lifecycle

  Called from `Muse.ApprovalGate.authorize_tool/2` during tool
  execution in the Conductor ToolLoop. Returns `{:allowed, context}`
  or `{:blocked, reason}`.

  All functions are pure — they accept tool specs and context maps
  and return authorization decisions.
  """

  alias Muse.Tool.Spec

  @doc """
  Check if a tool call is authorized given the current context.

  Returns `{:allowed, context}` if the tool is permitted, or
  `{:blocked, reason}` if it should be denied.
  """
  @spec authorize_tool(Spec.t(), map()) :: {:allowed, map()} | {:blocked, String.t()}
  def authorize_tool(%Spec{} = spec, context) when is_map(context) do
    cond do
      patch_propose_allowed?(spec, context) ->
        {:allowed, context}

      patch_apply_allowed?(spec, context) ->
        {:allowed, context}

      rollback_checkpoint_allowed?(spec, context) ->
        {:allowed, context}

      # Default: allow tools that don't require explicit approval
      true ->
        {:allowed, context}
    end
  end

  def authorize_tool(%Spec{} = _spec, _context), do: {:allowed, %{}}
  def authorize_tool(_spec, _context), do: {:blocked, "invalid tool approval request"}

  # -- Private helpers ----------------------------------------------------------

  defp patch_propose_allowed?(%Spec{name: "patch_propose"}, %{muse_id: :coding} = _context) do
    true
  end

  defp patch_propose_allowed?(_, _), do: false

  defp patch_apply_allowed?(%Spec{name: "patch_apply"}, %{muse_id: :coding} = context) do
    approved_patch_context?(context)
  end

  defp patch_apply_allowed?(_, _), do: false

  defp rollback_checkpoint_allowed?(
         %Spec{name: "rollback_checkpoint"},
         %{muse_id: :coding} = context
       ) do
    approved_plan_context?(context)
  end

  defp rollback_checkpoint_allowed?(_, _), do: false

  defp approved_plan_context?(context) when is_map(context) do
    case Map.get(context, :plan_status) do
      :approved -> true
      _ -> false
    end
  end

  defp approved_patch_context?(context) when is_map(context) do
    case Map.get(context, :plan_status) do
      :approved -> true
      _ -> false
    end
  end
end
