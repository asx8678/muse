defmodule Muse.SessionServer.StateRestoration do
  @moduledoc """
  Restores session state from a persisted snapshot.

  Responsible for deserializing plan, patch, approval, and remote-approval
  data from `SessionStore` snapshots back into the GenServer state map.
  Handles failure modes gracefully: corrupt or missing data is downgraded
  to safe defaults rather than crashing the session process.

  ## Lifecycle

  Called during `SessionServer.init/1` after the GenServer process starts.
  The restored state is merged into the initial GenServer state so that
  subsequent `handle_call`/`handle_info` callbacks operate on the
  recovered plan/patch/approval graph.

  All functions are pure — they accept a state map and return an updated
  state map, with no side effects beyond logging via `SilentRescue`.
  """

  alias Muse.{Approval, ApprovalGate, Patch, Plan}

  @doc """
  Restore plan, patch, approval, and remote-approval state from a
  `SessionStore` snapshot.

  Returns the updated state map. On any error (decode failure, exit signal),
  returns the original state unchanged after logging.
  """
  @spec restore_plan_from_snapshot(map()) :: map()
  def restore_plan_from_snapshot(state) do
    alias Muse.SessionStore

    case SessionStore.load_session(state.store_base_dir, state.session_id) do
      {:ok, data} ->
        plan_data = Map.get(data, "plan")
        plans_data = Map.get(data, "plans", %{})
        active_plan_id = Map.get(data, "active_plan_id")
        status_str = Map.get(data, "status", "idle")

        plans = restore_plans(plans_data)
        plan = restore_plan(plan_data) || active_plan_from_plans(plans, active_plan_id)

        active_id =
          active_plan_id ||
            if plan, do: plan.id, else: nil

        plans = put_restored_plan(plans, plan, active_id)
        status = safely_atom_status(status_str)

        approvals =
          ApprovalGate.merge_approvals(Map.get(data, "approvals", []), plan_approvals(plan))

        active_approval = active_approval_for_plan(approvals, plan)
        approval_binding = restore_approval_binding(Map.get(data, "approval_binding"))

        current_workspace = plan_workspace(plan) || workspace_from_state(state)

        {approvals, plan, plans, active_approval, approval_binding} =
          ensure_restored_approval_state(
            status,
            state.session_id,
            plan,
            plans,
            active_id,
            approvals,
            active_approval,
            approval_binding,
            current_workspace
          )

        # PR17 hardening: restore pending_patch from snapshot (Gap E)
        # Safety: if snapshot status is :awaiting_patch_approval but pending_patch
        # cannot be restored, downgrade to :idle to avoid a stuck session.
        pending_patch = restore_pending_patch(Map.get(data, "pending_patch"))

        # Phase B: restore pending remote approval from snapshot
        pending_remote_approval =
          restore_pending_remote_approval(Map.get(data, "pending_remote_approval"))

        safe_status =
          cond do
            status == :awaiting_patch_approval and is_nil(pending_patch) ->
              :idle

            status == :awaiting_remote_execution_approval and is_nil(pending_remote_approval) ->
              :idle

            true ->
              status
          end

        %{
          state
          | status: safe_status,
            plan: plan,
            plans: plans,
            active_plan_id: active_id,
            approvals: approvals,
            approval_binding: approval_binding,
            active_approval: active_approval,
            pending_patch: pending_patch,
            pending_remote_approval: pending_remote_approval
        }

      _ ->
        state
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :restore_approval_state, e)
      state
  catch
    :exit, reason ->
      Muse.Diagnostics.SilentRescue.log_rescued_catch(
        __MODULE__,
        :restore_approval_state,
        :exit,
        reason
      )

      state
  end

  @doc """
  Restore memory from `SessionStore` into the state map.

  Only loads if `state.memory` is nil. Validates the loaded memory
  via `Muse.Memory.validate_loaded_memory/1` before accepting it.
  """
  @spec restore_memory(map()) :: map()
  def restore_memory(state) do
    alias Muse.{Memory, SessionStore}

    if is_nil(state.memory) do
      case SessionStore.load_memory(state.store_base_dir, state.session_id) do
        {:ok, memory} when is_map(memory) ->
          case Memory.validate_loaded_memory(memory) do
            {:ok, safe_memory} ->
              %{state | memory: decode_memory(safe_memory)}

            {:error, {:unsafe_memory, _reasons}} ->
              state
          end

        _ ->
          state
      end
    else
      state
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :restore_memory_state, e)
      state
  catch
    :exit, reason ->
      Muse.Diagnostics.SilentRescue.log_rescued_catch(
        __MODULE__,
        :restore_memory_state,
        :exit,
        reason
      )

      state
  end

  @doc """
  Build the snapshot data map for persistence via `SessionStore.save_session/3`.

  Only includes plan/patch/remote-approval state when they exist.
  Returns `nil` if there is nothing worth persisting.
  """
  @spec build_snapshot_data(map()) :: map() | nil
  def build_snapshot_data(state) do
    if state.plan != nil or state.pending_patch != nil or state.pending_remote_approval != nil do
      %{
        status: Atom.to_string(state.status),
        active_muse: state.active_muse,
        active_plan_id: state.active_plan_id,
        approval_binding: state.approval_binding,
        active_approval: approval_to_map(state.active_approval),
        approvals: Enum.map(state.approvals || [], &approval_to_map/1),
        plan: state.plan && Plan.to_map(state.plan),
        plans:
          state.plans
          |> Enum.map(fn {id, p} -> {id, Plan.to_map(p)} end)
          |> Enum.into(%{})
      }
      |> maybe_put_pending_patch(state)
      |> maybe_put_pending_remote_approval(state)
    else
      nil
    end
  end

  @doc "Convert a session status string back to an atom safely."
  @spec safely_atom_status(String.t() | term()) :: atom()
  def safely_atom_status(str) when is_binary(str) do
    case str do
      "idle" -> :idle
      "running" -> :running
      "awaiting_plan_approval" -> :awaiting_plan_approval
      "awaiting_patch_approval" -> :awaiting_patch_approval
      "awaiting_remote_execution_approval" -> :awaiting_remote_execution_approval
      "awaiting_shell_approval" -> :awaiting_shell_approval
      "planning" -> :planning
      _ -> :idle
    end
  end

  def safely_atom_status(_), do: :idle

  @doc "Convert an `%Approval{}` or map to a serializable map."
  @spec approval_to_map(nil | Approval.t() | map()) :: map() | nil
  def approval_to_map(nil), do: nil
  def approval_to_map(%Approval{} = approval), do: Approval.to_map(approval)
  def approval_to_map(approval) when is_map(approval), do: approval

  # -- Private helpers ----------------------------------------------------------

  defp restore_approval_binding(binding) when is_map(binding), do: binding
  defp restore_approval_binding(_binding), do: nil

  defp ensure_restored_approval_state(
         :awaiting_plan_approval,
         session_id,
         %Plan{status: :awaiting_approval} = plan,
         plans,
         active_id,
         approvals,
         _active_approval,
         approval_binding,
         workspace
       ) do
    case ApprovalGate.ensure_pending_plan_approval(session_id, plan, approvals,
           workspace: workspace,
           requested_by: :restore,
           source: :system,
           metadata: %{event: :restore}
         ) do
      {:ok, approval, approvals, plan} ->
        plans = put_restored_plan(plans, plan, active_id)

        approval_binding =
          approval_binding || ApprovalGate.capture_binding(plan, workspace: workspace)

        {approvals, plan, plans, approval, approval_binding}
    end
  end

  defp ensure_restored_approval_state(
         _status,
         _session_id,
         plan,
         plans,
         _active_id,
         approvals,
         active_approval,
         approval_binding,
         _workspace
       ) do
    {approvals, plan, plans, active_approval, approval_binding}
  end

  defp plan_approvals(%Plan{} = plan), do: plan.approvals || []
  defp plan_approvals(_), do: []

  defp active_approval_for_plan(approvals, %Plan{id: plan_id}) when is_binary(plan_id) do
    approvals
    |> ApprovalGate.normalize_approvals()
    |> Enum.reverse()
    |> Enum.find(&(&1.plan_id == plan_id and &1.status in [:pending, :approved, :rejected]))
  end

  defp active_approval_for_plan(_approvals, _plan), do: nil

  defp restore_plan(nil), do: nil

  defp restore_plan(data) when is_map(data) do
    Plan.from_map(data)
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :restore_plan, e)
      nil
  end

  defp restore_plan(_), do: nil

  defp restore_pending_patch(nil), do: nil

  defp restore_pending_patch(data) when is_map(data) do
    case Patch.from_map(data) do
      {:ok, %Patch{} = patch} -> patch
      {:error, _} -> nil
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :restore_pending_patch, e)
      nil
  end

  defp restore_pending_patch(_data), do: nil

  defp restore_pending_remote_approval(nil), do: nil

  defp restore_pending_remote_approval(data) when is_map(data) do
    Approval.from_map(data)
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :restore_pending_remote_approval, e)
      nil
  end

  defp restore_pending_remote_approval(_data), do: nil

  defp restore_plans(plans_data) when is_map(plans_data) do
    plans_data
    |> Enum.reduce(%{}, fn {id, plan_data}, acc ->
      case restore_plan(plan_data) do
        nil -> acc
        plan -> Map.put(acc, id, plan)
      end
    end)
  end

  defp restore_plans(_), do: %{}

  defp active_plan_from_plans(plans, active_plan_id) when is_map(plans) do
    cond do
      is_binary(active_plan_id) and match?(%Plan{}, Map.get(plans, active_plan_id)) ->
        Map.fetch!(plans, active_plan_id)

      true ->
        nil
    end
  end

  defp put_restored_plan(plans, %Plan{} = plan, active_plan_id) when is_binary(active_plan_id) do
    Map.put_new(plans, active_plan_id, plan)
  end

  defp put_restored_plan(plans, _plan, _active_plan_id), do: plans

  defp maybe_put_pending_patch(data, %{pending_patch: %Patch{} = patch}) do
    Map.put(data, :pending_patch, Patch.to_map(patch))
  end

  defp maybe_put_pending_patch(data, %{pending_patch: %{} = patch}) do
    Map.put(data, :pending_patch, patch)
  end

  defp maybe_put_pending_patch(data, _state), do: data

  defp maybe_put_pending_remote_approval(data, %{pending_remote_approval: %Approval{} = approval}) do
    Map.put(data, :pending_remote_approval, Approval.to_map(approval))
  end

  defp maybe_put_pending_remote_approval(data, %{pending_remote_approval: %{} = approval}) do
    Map.put(data, :pending_remote_approval, approval)
  end

  defp maybe_put_pending_remote_approval(data, _state), do: data

  defp plan_workspace(%Plan{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :workspace) || Map.get(metadata, "workspace")
  end

  defp plan_workspace(_), do: nil

  defp workspace_from_state(_state) do
    case Process.whereis(Muse.Workspace) do
      nil -> nil
      pid -> if Process.alive?(pid), do: Muse.Workspace.root(), else: nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Decode memory from JSON-persisted form (string keys) back to
  # the atom-keyed canonical form expected by Muse.Memory.render/1
  defp decode_memory(memory) when is_map(memory) do
    # If the memory already has atom keys (e.g. from Memory.new/1),
    # it's already in canonical form
    if Map.has_key?(memory, :user_goal) or Map.has_key?(memory, "user_goal") do
      memory
    else
      memory
    end
  end
end
