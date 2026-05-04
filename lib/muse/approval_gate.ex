defmodule Muse.ApprovalGate do
  @moduledoc """
  Content-bound approval helpers for gated Muse actions.

  PR09 uses this module for plan approvals only.  The gate binds every pending
  plan approval to the exact `session_id`, `plan_id`, `plan_version`, and a
  canonical SHA-256 hash of the plan content.  If any binding field changes
  before the user runs `/approve plan`, the stale pending approval is rejected
  and the plan is left untouched.
  """

  alias Muse.{Approval, Plan}

  @plan_hash_algorithm "sha256"
  @plan_hash_prefix "sha256:"

  @type stale_error ::
          {:stale_approval,
           %{
             approval_id: String.t(),
             plan_id: String.t() | nil,
             expected_plan_version: non_neg_integer() | nil,
             actual_plan_version: non_neg_integer() | nil,
             expected_content_hash: String.t() | nil,
             actual_content_hash: String.t()
           }}

  @doc """
  Returns a stable content hash for a plan.

  The hash intentionally excludes lifecycle-only fields (`status`, approvals,
  and timestamps) so approving/rejecting a plan does not invalidate the binding
  it just consumed.  Semantic plan content (objective, tasks, risks,
  validation, expected files/commands, metadata, etc.) remains bound.
  """
  @spec plan_content_hash(Plan.t()) :: String.t()
  def plan_content_hash(%Plan{} = plan) do
    payload =
      plan
      |> Plan.to_map()
      |> drop_lifecycle_fields()
      |> canonicalize()
      |> Jason.encode!()

    digest =
      :sha256
      |> :crypto.hash(payload)
      |> Base.encode16(case: :lower)

    @plan_hash_prefix <> digest
  end

  @doc """
  Ensures an awaiting plan exposes a pending content-bound approval.

  If a matching pending approval already exists, it is reused.  If a pending
  approval exists for the same session/plan id but a different version or hash,
  it is exposed unchanged rather than silently replacing it; a later approval
  command will fail with `{:stale_approval, safe_metadata}`.
  """
  @spec ensure_pending_plan_approval(String.t(), Plan.t(), list(), keyword()) ::
          {:ok, Approval.t() | nil, [Approval.t()], Plan.t()} | {:error, term()}
  def ensure_pending_plan_approval(session_id, plan, approvals, opts \\ [])

  def ensure_pending_plan_approval(
        session_id,
        %Plan{status: :awaiting_approval} = plan,
        approvals,
        opts
      ) do
    approvals = merge_approvals(approvals, plan.approvals)
    binding = plan_binding(session_id, plan)

    approval =
      case find_pending_plan_approval(approvals, binding) do
        {:ok, %Approval{} = existing} ->
          existing

        {:stale, %Approval{} = stale} ->
          stale

        :none ->
          new_pending_plan_approval(binding, opts)
      end

    approvals = upsert_approval(approvals, approval)
    plan = put_plan_approval(plan, approval)

    {:ok, approval, approvals, plan}
  end

  def ensure_pending_plan_approval(_session_id, %Plan{} = plan, approvals, _opts) do
    {:ok, nil, normalize_approvals(approvals), plan}
  end

  @doc "Approves the pending plan approval if its binding still matches the plan."
  @spec approve_plan(String.t(), Plan.t(), list(), keyword()) ::
          {:ok, Approval.t(), [Approval.t()], Plan.t()} | {:error, stale_error() | term()}
  def approve_plan(session_id, %Plan{} = plan, approvals, opts \\ []) do
    transition_plan_approval(session_id, plan, approvals, :approved, opts)
  end

  @doc "Rejects the pending plan approval if its binding still matches the plan."
  @spec reject_plan(String.t(), Plan.t(), list(), keyword()) ::
          {:ok, Approval.t(), [Approval.t()], Plan.t()} | {:error, stale_error() | term()}
  def reject_plan(session_id, %Plan{} = plan, approvals, opts \\ []) do
    transition_plan_approval(session_id, plan, approvals, :rejected, opts)
  end

  @doc "Normalizes approval maps/structs."
  @spec normalize_approvals(term()) :: [Approval.t()]
  def normalize_approvals(values), do: Approval.normalize_list(values)

  @doc "Merges approvals by id, preserving newest records from right-most lists."
  @spec merge_approvals(term(), term()) :: [Approval.t()]
  def merge_approvals(left, right) do
    [left, right]
    |> Enum.flat_map(&normalize_approvals/1)
    |> Enum.reduce([], fn approval, acc -> upsert_approval(acc, approval) end)
  end

  @doc "Upserts an approval record by id."
  @spec upsert_approval([Approval.t()], Approval.t() | nil) :: [Approval.t()]
  def upsert_approval(approvals, nil), do: normalize_approvals(approvals)

  def upsert_approval(approvals, %Approval{} = approval) do
    approvals = normalize_approvals(approvals)

    if Enum.any?(approvals, &(&1.id == approval.id)) do
      Enum.map(approvals, fn
        %Approval{id: id} when id == approval.id -> approval
        existing -> existing
      end)
    else
      approvals ++ [approval]
    end
  end

  @doc "Upserts an approval into a plan's embedded approval list."
  @spec put_plan_approval(Plan.t(), Approval.t() | nil) :: Plan.t()
  def put_plan_approval(%Plan{} = plan, nil),
    do: %{plan | approvals: normalize_approvals(plan.approvals)}

  def put_plan_approval(%Plan{} = plan, %Approval{} = approval) do
    %{plan | approvals: upsert_approval(plan.approvals, approval)}
  end

  @doc "Safe event metadata for approval lifecycle events."
  @spec approval_event_data(Approval.t()) :: map()
  def approval_event_data(%Approval{} = approval) do
    %{
      approval_id: approval.id,
      kind: approval.kind,
      status: approval.status,
      plan_id: approval.plan_id,
      plan_version: approval.plan_version,
      content_hash: approval.content_hash
    }
  end

  # -- Private -----------------------------------------------------------------

  defp transition_plan_approval(
         session_id,
         %Plan{status: :awaiting_approval} = plan,
         approvals,
         status,
         opts
       ) do
    approvals = merge_approvals(approvals, plan.approvals)
    binding = plan_binding(session_id, plan)

    with {:ok, pending} <- pending_or_new_plan_approval(approvals, binding, opts),
         {:ok, approval} <- Approval.transition(pending, status, transition_opts(status, opts)) do
      approvals = upsert_approval(approvals, approval)
      plan = put_plan_approval(plan, approval)
      {:ok, approval, approvals, plan}
    end
  end

  defp transition_plan_approval(_session_id, %Plan{status: status}, approvals, _status, _opts) do
    {:error, {:plan_not_awaiting_approval, status, normalize_approvals(approvals)}}
  end

  defp pending_or_new_plan_approval(approvals, binding, opts) do
    case find_pending_plan_approval(approvals, binding) do
      {:ok, %Approval{} = approval} ->
        {:ok, approval}

      {:stale, %Approval{} = approval} ->
        {:error, {:stale_approval, stale_plan_metadata(approval, binding)}}

      :none ->
        {:ok, new_pending_plan_approval(binding, opts)}
    end
  end

  defp new_pending_plan_approval(binding, opts) do
    Approval.new(%{
      kind: :plan,
      type: :plan,
      status: :pending,
      session_id: binding.session_id,
      plan_id: binding.plan_id,
      plan_version: binding.plan_version,
      content_hash: binding.content_hash,
      scope: :plan,
      requested_by: Keyword.get(opts, :requested_by, :planning),
      metadata: %{
        hash_algorithm: @plan_hash_algorithm
      }
    })
  end

  defp transition_opts(:approved, opts) do
    [
      actor: Keyword.get(opts, :approved_by, Keyword.get(opts, :actor)),
      approved_by: Keyword.get(opts, :approved_by, Keyword.get(opts, :actor))
    ]
  end

  defp transition_opts(:rejected, opts) do
    [
      actor: Keyword.get(opts, :rejected_by, Keyword.get(opts, :actor)),
      rejected_by: Keyword.get(opts, :rejected_by, Keyword.get(opts, :actor)),
      reason: Keyword.get(opts, :reason)
    ]
  end

  defp find_pending_plan_approval(approvals, binding) do
    pending =
      approvals
      |> normalize_approvals()
      |> Enum.filter(&pending_plan_approval_for_binding_subject?(&1, binding))

    cond do
      match = Enum.find(pending, &plan_binding_matches?(&1, binding)) ->
        {:ok, match}

      stale = List.first(pending) ->
        {:stale, stale}

      true ->
        :none
    end
  end

  defp pending_plan_approval_for_binding_subject?(%Approval{} = approval, binding) do
    approval.kind == :plan and approval.status == :pending and
      approval.session_id == binding.session_id and
      approval.plan_id == binding.plan_id
  end

  defp plan_binding_matches?(%Approval{} = approval, binding) do
    approval.plan_version == binding.plan_version and
      approval.content_hash == binding.content_hash
  end

  defp plan_binding(session_id, %Plan{} = plan) do
    %{
      session_id: to_string(session_id),
      plan_id: plan.id,
      plan_version: plan.version,
      content_hash: plan_content_hash(plan)
    }
  end

  defp stale_plan_metadata(%Approval{} = approval, binding) do
    %{
      approval_id: approval.id,
      plan_id: binding.plan_id,
      expected_plan_version: approval.plan_version,
      actual_plan_version: binding.plan_version,
      expected_content_hash: approval.content_hash,
      actual_content_hash: binding.content_hash
    }
  end

  defp drop_lifecycle_fields(plan_map) when is_map(plan_map) do
    Map.drop(plan_map, [
      :status,
      "status",
      :approvals,
      "approvals",
      :created_at,
      "created_at",
      :updated_at,
      "updated_at",
      :approved_at,
      "approved_at",
      :rejected_at,
      "rejected_at",
      :completed_at,
      "completed_at"
    ])
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> canonical_key(key) end)
    |> Enum.map(fn {key, nested} -> [canonical_key(key), canonicalize(nested)] end)
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp canonicalize(value) when is_atom(value), do: Atom.to_string(value)
  defp canonicalize(value), do: value

  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key), do: inspect(key, printable_limit: 100)
end
