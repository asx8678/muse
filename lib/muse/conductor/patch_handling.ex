defmodule Muse.Conductor.PatchHandling do
  @moduledoc """
  Patch proposal capture and construction for the Conductor.

  When the Coding Muse completes a turn with `patch_propose` tool calls,
  this module captures the proposals, builds a `%Patch{}` struct, and
  transitions the session to `:awaiting_patch_approval`.

  ## Lifecycle

  Called from `Muse.Conductor.execute_turn/4` after the ToolLoop completes.
  Only active for the Coding Muse (`muse.id == :coding`).

  All functions are pure — they accept and return data structures
  with no side effects beyond patch construction.
  """

  alias Muse.{Patch, Plan, PlanBinding, Session}

  @doc """
  Build a `%Patch{}` from a patch proposal map and the current session.

  Requires an active approved plan and a non-empty diff. Returns
  `{:error, :invalid_patch_proposal}` if the proposal is malformed.
  """
  @spec build_pending_patch(map(), Session.t()) ::
          {:ok, Patch.t()} | {:error, :invalid_patch_proposal}
  def build_pending_patch(proposal, %Session{} = session) when is_map(proposal) do
    with %Plan{status: :approved} = plan <- active_approved_plan(session),
         diff when is_binary(diff) and diff != "" <-
           proposal_get(proposal, :diff) || proposal_get(proposal, :patch_content) do
      metadata =
        %{
          summary: proposal_get(proposal, :summary) || proposal_get(proposal, :description),
          tool_call_id: proposal_get(proposal, :tool_call_id),
          proposed_at: DateTime.utc_now()
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      attrs = [
        session_id: session.id,
        plan_id: proposal_get(proposal, :plan_id) || plan.id || session.active_plan_id,
        plan_version: proposal_get(proposal, :plan_version) || plan.version,
        plan_hash: proposal_get(proposal, :plan_hash) || PlanBinding.content_hash(plan),
        diff: diff,
        metadata: metadata
      ]

      attrs =
        maybe_put_patch_id(
          attrs,
          proposal_get(proposal, :patch_id) || proposal_get(proposal, :id)
        )

      attrs = maybe_put_affected_files(attrs, proposal_files(proposal))

      Patch.new(attrs)
    else
      _ -> {:error, :invalid_patch_proposal}
    end
  end

  @doc """
  Resolve the active approved plan from a session, if any.
  """
  @spec active_approved_plan(Session.t()) :: Plan.t() | nil
  def active_approved_plan(%Session{active_plan_id: active_plan_id, plans: plans})
      when is_binary(active_plan_id) and is_map(plans) do
    case Map.get(plans, active_plan_id) do
      %Plan{status: :approved} = plan -> plan
      _ -> nil
    end
  end

  def active_approved_plan(_), do: nil

  @doc """
  Safely put a patch_id into attrs if a valid ID is provided.
  """
  @spec maybe_put_patch_id(keyword(), String.t() | nil) :: keyword()
  def maybe_put_patch_id(attrs, patch_id) when is_binary(patch_id) and patch_id != "" do
    Keyword.put(attrs, :patch_id, patch_id)
  end

  def maybe_put_patch_id(attrs, _patch_id), do: attrs

  # -- Private helpers ----------------------------------------------------------

  defp proposal_get(proposal, key) when is_atom(key) do
    Map.get(proposal, key) || Map.get(proposal, Atom.to_string(key))
  end

  defp proposal_files(proposal) when is_map(proposal) do
    proposal_get(proposal, :affected_files) || proposal_get(proposal, :files)
  end

  defp proposal_files(_), do: nil

  defp maybe_put_affected_files(attrs, nil), do: attrs

  defp maybe_put_affected_files(attrs, files) when is_list(files) do
    Keyword.put(attrs, :affected_files, files)
  end

  defp maybe_put_affected_files(attrs, _), do: attrs
end
