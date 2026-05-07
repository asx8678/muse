defmodule Muse.ApprovalGate do
  @moduledoc """
  Pure approval helpers for Muse approval-gated actions.

  PR09 uses this module for content-bound plan approval/rejection and for a
  deny-by-default tool authorization facade. The module is intentionally
  side-effect free: callers own persistence, state transitions, and event
  emission. Approval records do **not** execute tools, write files, run shell
  commands, or hand off to Coding Muse.
  """

  alias Muse.{Approval, Plan, PlanBinding}
  alias Muse.Tool.Spec

  @default_expiry_seconds 86_400
  @plan_scope :plan

  @denied_scopes MapSet.new([
                   :write,
                   :shell,
                   :shell_command,
                   :network,
                   :delete,
                   :restore,
                   :remote_execution,
                   :unknown
                 ])

  # PR09: Remote execution is ALWAYS denied regardless of approval data.
  # This is enforced by Execution.Policy and cannot be overridden by approvals.

  # PR18: :patch and :restore_checkpoint scopes are now gated by
  # patch_apply_allowed?/2 and rollback_checkpoint_allowed?/2 above,
  # so they are removed from the blanket deny set.

  @safe_tool_permissions MapSet.new([:read, :interactive])

  @approval_scoped_tool_permissions MapSet.new([
                                      :write,
                                      :shell,
                                      :shell_command,
                                      :network,
                                      :patch,
                                      :delete,
                                      :restore,
                                      :restore_checkpoint,
                                      :remote_execution
                                    ])

  # :test is not a generic safe permission. Only the registered test_runner
  # handler is allowed without an approval record, and it enforces preset-only,
  # bounded execution internally. Future tools cannot gain shell authority just
  # by setting permission: :test.

  @type approval :: Approval.t() | map()
  @type binding :: map()
  @type stale_error ::
          {:stale_approval,
           %{
             approval_id: String.t() | nil,
             plan_id: String.t() | nil,
             expected_plan_version: non_neg_integer() | nil,
             actual_plan_version: non_neg_integer() | nil,
             expected_content_hash: String.t() | nil,
             actual_content_hash: String.t() | nil
           }}

  @type reason ::
          :invalid_session_or_plan
          | :missing_session_id
          | :missing_plan_id
          | :missing_plan_version
          | :missing_plan_approval
          | :approval_not_pending
          | :approval_not_approved
          | :approval_expired
          | :approval_rejected
          | :session_mismatch
          | :active_plan_mismatch
          | :plan_id_mismatch
          | :plan_version_mismatch
          | :plan_hash_mismatch
          | :workspace_mismatch
          | :no_active_plan
          | :no_approval_binding
          | :stale_approval
          | {:scope_denied, atom()}
          | stale_error()
          | term()

  # -- Content-bound plan bindings --------------------------------------------

  @doc """
  Capture an approval binding when a plan enters `:awaiting_approval`.

  The binding wraps `Muse.PlanBinding.approval_binding/2` with timestamps used
  for expiry tracking. Options:

    * `:workspace` — workspace path to bind, when present
    * `:now` — deterministic timestamp for tests
    * `:ttl_seconds` / `:expires_at` — optional expiry metadata
  """
  @spec capture_binding(Plan.t(), keyword()) :: binding()
  def capture_binding(%Plan{} = plan, opts \\ []) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())
    ttl = Keyword.get(opts, :ttl_seconds)

    expires_at =
      cond do
        match?(%DateTime{}, Keyword.get(opts, :expires_at)) -> Keyword.get(opts, :expires_at)
        is_integer(ttl) and ttl > 0 -> DateTime.add(now, ttl, :second)
        true -> nil
      end

    plan
    |> PlanBinding.approval_binding(Keyword.take(opts, [:workspace]))
    |> Map.put(:bound_at, now)
    |> maybe_put(:expires_at, expires_at)
  end

  @doc "Validate that a plan approval request is fresh and matches its binding."
  @spec validate_approval(Plan.t(), binding() | nil, keyword()) :: :ok | {:error, reason()}
  def validate_approval(_plan, nil, _opts), do: {:error, :no_approval_binding}

  def validate_approval(%Plan{} = plan, binding, opts) when is_map(binding) do
    with :ok <- check_content_hash(plan, binding),
         :ok <- check_session(binding, opts),
         :ok <- check_workspace(binding, opts),
         :ok <- check_expiry(binding, opts) do
      :ok
    end
  end

  @doc "Validate that a plan rejection request is fresh and matches its binding."
  @spec validate_rejection(Plan.t(), binding() | nil, keyword()) :: :ok | {:error, reason()}
  def validate_rejection(_plan, nil, _opts), do: {:error, :no_approval_binding}

  def validate_rejection(%Plan{} = plan, binding, opts) when is_map(binding) do
    with :ok <- check_content_hash(plan, binding),
         :ok <- check_session(binding, opts),
         :ok <- check_workspace(binding, opts),
         :ok <- check_expiry(binding, opts) do
      :ok
    end
  end

  @doc "Return `{:ok, :idempotent}` only when an already-approved plan still matches."
  @spec check_idempotent_approval(Plan.t(), binding() | nil) ::
          {:ok, :idempotent} | {:error, :stale_approval}
  def check_idempotent_approval(%Plan{} = plan, binding) when is_map(binding) do
    if PlanBinding.content_hash(plan) == binding_hash(binding) do
      {:ok, :idempotent}
    else
      {:error, :stale_approval}
    end
  end

  def check_idempotent_approval(%Plan{}, _binding), do: {:error, :stale_approval}

  @doc "Return the default approval binding expiry duration in seconds."
  @spec default_expiry_seconds() :: non_neg_integer()
  def default_expiry_seconds, do: @default_expiry_seconds

  # -- Pure/map-compatible plan approval API -----------------------------------

  @doc """
  Requests a plan approval and appends it to the session/context approvals list.

  Returns `{:ok, approval, updated_session}` when binding validation succeeds.
  """
  @spec request_plan_approval(map(), map(), keyword()) ::
          {:ok, Approval.t(), map()} | {:error, reason()}
  def request_plan_approval(session, plan, opts \\ [])

  def request_plan_approval(session, %Plan{} = plan, opts) when is_map(session) do
    session_id = session_id(session) || plan.session_id
    plan = put_plan_session_if_blank(plan, session_id)

    with {:ok, _session_id} <- require_session_id(session_id),
         {:ok, _plan_id} <- require_plan_id(plan.id),
         {:ok, _version} <- require_plan_version(plan.version) do
      approval =
        new_pending_plan_approval(plan_binding(session_id, plan, opts),
          requested_by: Keyword.get(opts, :requested_by, Keyword.get(opts, :actor)),
          source: Keyword.get(opts, :source),
          expires_at: Keyword.get(opts, :expires_at),
          metadata: Keyword.get(opts, :metadata, %{})
        )

      {:ok, approval, append_approval(session, approval)}
    end
  end

  def request_plan_approval(session, plan, opts) when is_map(session) and is_map(plan) do
    request_plan_approval(session, Plan.from_map(plan), opts)
  rescue
    _ -> {:error, :invalid_session_or_plan}
  end

  def request_plan_approval(_session, _plan, _opts), do: {:error, :invalid_session_or_plan}

  @doc """
  Approves a pending plan approval.

  Supported call forms:

    * `approve_plan(session_or_context, plan, approver, opts)` — pure/map core
    * `approve_plan(session_id, plan, approvals, opts)` — compatibility helper
      returning `{:ok, approval, approvals, plan}` for `SessionServer`
  """
  @spec approve_plan(map() | String.t(), map() | Plan.t(), term(), keyword()) ::
          {:ok, approval()} | {:ok, Approval.t(), [Approval.t()], Plan.t()} | {:error, reason()}
  def approve_plan(session_or_id, plan, approver_or_approvals, opts \\ [])

  def approve_plan(session_id, %Plan{} = plan, approvals, opts)
      when (is_binary(session_id) or is_atom(session_id)) and is_list(approvals) do
    transition_plan_approval(to_string(session_id), plan, approvals, :approved, opts)
  end

  def approve_plan(session, %Plan{} = plan, approver, opts) when is_map(session) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    with {:ok, approval} <- resolve_approval(session, plan, opts),
         :ok <- ensure_pending(approval),
         :ok <- validate_plan_approval_binding(session, plan, approval, now),
         {:ok, approved} <- Approval.approve(approval, approved_by: approver, approved_at: now) do
      {:ok, approved}
    end
  end

  def approve_plan(session, plan, approver, opts) when is_map(session) and is_map(plan) do
    approve_plan(session, Plan.from_map(plan), approver, opts)
  rescue
    _ -> {:error, :invalid_session_or_plan}
  end

  def approve_plan(_session, _plan, _approver, _opts), do: {:error, :invalid_session_or_plan}

  @doc "Rejects a pending plan approval. See `approve_plan/4` for supported forms."
  @spec reject_plan(map() | String.t(), map() | Plan.t(), term(), keyword()) ::
          {:ok, approval()} | {:ok, Approval.t(), [Approval.t()], Plan.t()} | {:error, reason()}
  def reject_plan(session_or_id, plan, rejector_or_approvals, opts \\ [])

  def reject_plan(session_id, %Plan{} = plan, approvals, opts)
      when (is_binary(session_id) or is_atom(session_id)) and is_list(approvals) do
    transition_plan_approval(to_string(session_id), plan, approvals, :rejected, opts)
  end

  def reject_plan(session, %Plan{} = plan, rejector, opts) when is_map(session) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    with {:ok, approval} <- resolve_approval(session, plan, opts),
         :ok <- ensure_pending(approval),
         :ok <- validate_plan_approval_binding(session, plan, approval, now),
         {:ok, rejected} <-
           Approval.reject(approval,
             rejected_by: rejector,
             rejected_at: now,
             reason: Keyword.get(opts, :reason)
           ) do
      {:ok, rejected}
    end
  end

  def reject_plan(session, plan, rejector, opts) when is_map(session) and is_map(plan) do
    reject_plan(session, Plan.from_map(plan), rejector, opts)
  rescue
    _ -> {:error, :invalid_session_or_plan}
  end

  def reject_plan(_session, _plan, _rejector, _opts), do: {:error, :invalid_session_or_plan}

  @doc """
  Returns `:ok` when the requested plan scope is currently allowed.

  Scope behavior in PR09:

    * `:plan` uses content-bound plan approval validation.
    * Patch/write/shell/network/delete/restore/remote scopes are denied by
      default. Plan approval never unlocks tools or implementation.
  """
  @spec allowed?(map(), map() | atom() | String.t()) :: :ok | {:error, reason()}
  def allowed?(session_or_context, approval)
      when is_map(session_or_context) and is_map(approval) do
    case normalize_scope(approval_scope(approval)) do
      :plan -> allowed_with_explicit_approval(session_or_context, approval)
      scope -> {:error, {:scope_denied, scope}}
    end
  end

  def allowed?(session_or_context, scope) when is_map(session_or_context) do
    case normalize_scope(scope) do
      :plan -> allowed_for_plan_scope(session_or_context)
      denied_scope -> {:error, {:scope_denied, denied_scope}}
    end
  end

  def allowed?(_session_or_context, _approval_or_scope), do: {:error, :invalid_session_or_plan}

  @doc "Returns true when a plan approval has gone stale for the supplied plan/session."
  @spec stale_plan_approval?(map(), map()) :: boolean()
  def stale_plan_approval?(approval, plan_or_session)
      when is_map(approval) and is_map(plan_or_session) do
    now = DateTime.utc_now()

    case normalize_scope(approval_scope(approval)) do
      :plan -> stale_for_plan_scope?(approval, plan_or_session, now)
      _other -> true
    end
  end

  def stale_plan_approval?(_approval, _plan_or_session), do: true

  # -- SessionServer compatibility helpers -------------------------------------

  @doc "Ensures an awaiting plan exposes a pending content-bound approval."
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
    binding = plan_binding(session_id, plan, opts)

    {approval, approvals} =
      case find_pending_plan_approval(approvals, binding) do
        {:ok, %Approval{} = existing} ->
          {existing, approvals}

        {:stale, %Approval{} = stale} ->
          stale = mark_stale_plan_approval(stale, binding, opts)
          approval = new_pending_plan_approval(binding, opts)
          {approval, approvals |> upsert_approval(stale) |> upsert_approval(approval)}

        :none ->
          approval = new_pending_plan_approval(binding, opts)
          {approval, upsert_approval(approvals, approval)}
      end

    plan = put_plan_approval(plan, approval)

    {:ok, approval, approvals, plan}
  end

  def ensure_pending_plan_approval(_session_id, %Plan{} = plan, approvals, _opts) do
    {:ok, nil, normalize_approvals(approvals), plan}
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
    Approval.event_payload(%{
      approval_id: approval.id,
      kind: approval.kind,
      status: approval.status,
      plan_id: approval.plan_id,
      plan_version: approval.plan_version,
      plan_hash: approval.plan_hash,
      content_hash: approval.content_hash
    })
  end

  # -- Tool authorization facade ----------------------------------------------

  @type tool_decision :: :ok | {:blocked, String.t()}

  @doc """
  Authorizes a tool spec for execution.

  In PR09, only specs that do **not** require approval and use a safe permission
  category (`:read` or `:interactive`) are allowed. Plan approval or any other
  current context field is deliberately not treated as a tool grant.

  In PR17, tools with permission `:patch` and `requires_approval: true` (e.g.
  `patch_propose`) are authorized when the requesting muse is `:coding`.
  This tool records a patch proposal without applying it, so it is
  side-effect free and safe for Coding Muse after plan approval.
  """
  @spec authorize_tool(Spec.t(), map()) :: tool_decision()
  def authorize_tool(%Spec{} = spec, context) when is_map(context) do
    cond do
      # PR24: Always block remote execution tools regardless of approval context
      remote_execution_tool?(spec, context) ->
        {:blocked, "remote execution is denied by policy (PR24)"}

      safe_without_approval?(spec) ->
        :ok

      patch_propose_allowed?(spec, context) ->
        :ok

      patch_apply_allowed?(spec, context) ->
        :ok

      rollback_checkpoint_allowed?(spec, context) ->
        :ok

      spec.requires_approval ->
        {:blocked, requires_approval_reason(spec)}

      approval_scoped_permission?(spec) ->
        {:blocked, approval_scoped_permission_reason(spec)}

      true ->
        {:blocked, unmatched_policy_reason(spec)}
    end
  end

  def authorize_tool(%Spec{} = spec, _context), do: authorize_tool(spec, %{})
  def authorize_tool(_spec, _context), do: {:blocked, "invalid tool approval request"}

  # -- Patch tool authorization (PR17/PR18) --------------------------------------

  # patch_propose is allowed for Coding Muse ONLY when there is an approved
  # plan in the context. This prevents direct Runner calls from bypassing
  # plan approval. Planning Muse and other muses are always denied.
  defp patch_propose_allowed?(%Spec{name: "patch_propose"}, %{muse_id: :coding} = context) do
    approved_plan_context?(context)
  end

  defp patch_propose_allowed?(_, _), do: false

  # PR18: patch_apply is allowed for Coding Muse when:
  #   1. There is an approved plan in context
  #   2. There is an approved patch approval in the context
  #   3. The session_id is present
  defp patch_apply_allowed?(%Spec{name: "patch_apply"}, %{muse_id: :coding} = context) do
    approved_plan_context?(context) and approved_patch_context?(context)
  end

  defp patch_apply_allowed?(_, _), do: false

  # PR18: rollback_checkpoint is allowed for Coding Muse when:
  #   1. There is an approved plan in context
  #   2. The session_id is present
  defp rollback_checkpoint_allowed?(
         %Spec{name: "rollback_checkpoint"},
         %{muse_id: :coding} = context
       ) do
    approved_plan_context?(context) and
      is_binary(Map.get(context, :session_id)) and Map.get(context, :session_id) != "" and
      is_binary(Map.get(context, :plan_id)) and Map.get(context, :plan_id) != "" and
      is_binary(Map.get(context, :plan_hash)) and Map.get(context, :plan_hash) != ""
  end

  defp rollback_checkpoint_allowed?(_, _), do: false

  # Coding Muse may only call patch tools when bound to an approved plan.
  # This prevents direct Runner invocations without plan approval metadata.
  defp approved_plan_context?(context) when is_map(context) do
    Map.get(context, :plan_status) == :approved and
      is_binary(Map.get(context, :plan_id)) and Map.get(context, :plan_id) != "" and
      is_binary(Map.get(context, :plan_hash)) and Map.get(context, :plan_hash) != ""
  end

  # PR18: verify there is an approved patch approval in the context.
  # The approvals list must contain a matching approved patch approval
  # with non-blank patch_id and patch_hash matching the session + plan.
  defp approved_patch_context?(context) when is_map(context) do
    session_id = Map.get(context, :session_id)
    plan_id = Map.get(context, :plan_id)
    plan_hash = Map.get(context, :plan_hash)
    approvals = Approval.normalize_list(Map.get(context, :approvals, []))

    is_binary(session_id) and session_id != "" and
      is_binary(plan_id) and plan_id != "" and
      is_binary(plan_hash) and plan_hash != "" and
      Enum.any?(approvals, fn a ->
        a.kind == :patch and
          a.status == :approved and
          a.session_id == session_id and
          is_binary(a.patch_id) and a.patch_id != "" and
          is_binary(a.patch_hash) and a.patch_hash != "" and
          a.plan_id == plan_id and
          is_binary(a.plan_hash) and a.plan_hash != "" and
          a.plan_hash == plan_hash
      end)
  end

  # -- Internal plan approval transitions --------------------------------------

  defp transition_plan_approval(
         session_id,
         %Plan{status: :awaiting_approval} = plan,
         approvals,
         status,
         opts
       ) do
    approvals = merge_approvals(approvals, plan.approvals)
    binding = plan_binding(session_id, plan, opts)

    with :ok <- validate_requested_plan_binding(plan, status, opts),
         {:ok, pending} <- pending_or_new_plan_approval(approvals, binding, opts),
         {:ok, approval} <- transition_approval(pending, status, opts) do
      approvals = upsert_approval(approvals, approval)
      plan = put_plan_approval(plan, approval)
      {:ok, approval, approvals, plan}
    end
  end

  defp transition_plan_approval(_session_id, %Plan{status: status}, approvals, _status, _opts) do
    {:error, {:plan_not_awaiting_approval, status, normalize_approvals(approvals)}}
  end

  defp validate_requested_plan_binding(plan, status, opts) do
    case Keyword.fetch(opts, :binding) do
      :error ->
        :ok

      {:ok, nil} ->
        {:error, :no_approval_binding}

      {:ok, binding} when status == :approved ->
        validate_approval(plan, binding,
          session_id: Keyword.get(opts, :session_id),
          workspace: Keyword.get(opts, :workspace),
          now: Keyword.get(opts, :now),
          expiry_seconds: Keyword.get(opts, :expiry_seconds, @default_expiry_seconds)
        )

      {:ok, binding} when status == :rejected ->
        validate_rejection(plan, binding,
          session_id: Keyword.get(opts, :session_id),
          workspace: Keyword.get(opts, :workspace),
          now: Keyword.get(opts, :now),
          expiry_seconds: Keyword.get(opts, :expiry_seconds, @default_expiry_seconds)
        )
    end
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

  defp transition_approval(%Approval{} = approval, :approved, opts) do
    Approval.approve(approval,
      approved_by: Keyword.get(opts, :approved_by, Keyword.get(opts, :actor)),
      approved_at: Keyword.get(opts, :approved_at, Keyword.get(opts, :now)),
      source: Keyword.get(opts, :source)
    )
  end

  defp transition_approval(%Approval{} = approval, :rejected, opts) do
    Approval.reject(approval,
      rejected_by: Keyword.get(opts, :rejected_by, Keyword.get(opts, :actor)),
      rejected_at: Keyword.get(opts, :rejected_at, Keyword.get(opts, :now)),
      reason: Keyword.get(opts, :reason),
      source: Keyword.get(opts, :source)
    )
  end

  defp new_pending_plan_approval(binding, opts) do
    created_at = keyword_datetime(opts, :now, DateTime.utc_now())

    Approval.new(%{
      kind: :plan,
      type: :plan,
      status: :pending,
      session_id: binding.session_id,
      plan_id: binding.plan_id,
      plan_version: binding.plan_version,
      plan_hash: binding.plan_hash,
      content_hash: binding.content_hash || binding.plan_hash,
      workspace: binding.workspace,
      scope: :plan,
      requested_by: Keyword.get(opts, :requested_by, :planning),
      source: Keyword.get(opts, :source),
      expires_at: pending_expires_at(created_at, opts),
      created_at: created_at,
      metadata: Map.merge(%{hash_algorithm: "sha256"}, Keyword.get(opts, :metadata, %{}))
    })
  end

  defp pending_expires_at(created_at, opts) do
    cond do
      match?(%DateTime{}, Keyword.get(opts, :expires_at)) ->
        Keyword.get(opts, :expires_at)

      is_integer(Keyword.get(opts, :ttl_seconds)) and Keyword.get(opts, :ttl_seconds) >= 0 ->
        DateTime.add(created_at, Keyword.get(opts, :ttl_seconds), :second)

      true ->
        DateTime.add(created_at, @default_expiry_seconds, :second)
    end
  end

  defp mark_stale_plan_approval(%Approval{} = stale, binding, opts) do
    metadata = %{
      superseded_by_plan_version: binding.plan_version,
      superseded_by_plan_hash: binding.plan_hash
    }

    {:ok, approval} =
      Approval.transition(stale, :stale,
        source: Keyword.get(opts, :source),
        metadata: metadata
      )

    approval
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
      approval.session_id == binding.session_id and approval.plan_id == binding.plan_id
  end

  defp plan_binding_matches?(%Approval{} = approval, binding) do
    approval.plan_version == binding.plan_version and
      approval_hash(approval) == binding.plan_hash and
      workspace_matches?(approval.workspace, binding.workspace)
  end

  defp stale_plan_metadata(%Approval{} = approval, binding) do
    %{
      approval_id: approval.id,
      plan_id: binding.plan_id,
      expected_plan_version: approval.plan_version,
      actual_plan_version: binding.plan_version,
      expected_content_hash: approval_hash(approval),
      actual_content_hash: binding.plan_hash
    }
  end

  defp plan_binding(session_id, %Plan{} = plan, opts) do
    workspace = Keyword.get(opts, :workspace) || plan_workspace(plan)

    plan
    |> put_plan_session_if_blank(session_id)
    |> PlanBinding.approval_binding(workspace: workspace)
    |> Map.put(:session_id, to_string(session_id))
  end

  defp put_plan_session_if_blank(%Plan{session_id: nil} = plan, session_id),
    do: %{plan | session_id: session_id && to_string(session_id)}

  defp put_plan_session_if_blank(%Plan{session_id: ""} = plan, session_id),
    do: %{plan | session_id: session_id && to_string(session_id)}

  defp put_plan_session_if_blank(%Plan{} = plan, _session_id), do: plan

  # -- Internal validation ------------------------------------------------------

  defp validate_plan_approval_binding(session, %Plan{} = plan, approval, now) do
    with :ok <- ensure_plan_scope(approval),
         :ok <- ensure_not_rejected(approval),
         :ok <- ensure_not_expired(approval, now),
         :ok <- validate_session_binding(session, plan, approval),
         :ok <- validate_plan_id_binding(session, plan, approval),
         :ok <- validate_plan_version_binding(plan, approval),
         :ok <- validate_plan_hash_binding(plan, approval),
         :ok <- validate_workspace_binding(session, plan, approval) do
      :ok
    end
  end

  defp check_content_hash(plan, binding) do
    current = PlanBinding.content_hash(plan)

    if current == binding_hash(binding) do
      :ok
    else
      {:error,
       {:stale_content,
        %{
          plan_id: plan.id,
          expected: binding_hash(binding),
          actual: current
        }}}
    end
  end

  defp check_session(binding, opts) do
    request_session = Keyword.get(opts, :session_id)
    bound_session = binding_session_id(binding)

    cond do
      is_nil(bound_session) -> :ok
      is_nil(request_session) -> {:error, :missing_session_id}
      to_string(request_session) == to_string(bound_session) -> :ok
      true -> {:error, {:wrong_session, %{expected: bound_session, actual: request_session}}}
    end
  end

  defp check_workspace(binding, opts) do
    request_workspace = Keyword.get(opts, :workspace)
    bound_workspace = binding_workspace(binding)

    cond do
      is_nil(bound_workspace) ->
        :ok

      request_workspace == bound_workspace ->
        :ok

      true ->
        {:error, {:wrong_workspace, %{expected: bound_workspace, actual: request_workspace}}}
    end
  end

  defp check_expiry(binding, opts) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())
    expiry_seconds = Keyword.get(opts, :expiry_seconds, @default_expiry_seconds)

    cond do
      match?(%DateTime{}, binding_expires_at(binding)) and
          DateTime.compare(binding_expires_at(binding), now) != :gt ->
        {:error, {:expired, %{expires_at: binding_expires_at(binding), now: now}}}

      match?(%DateTime{}, binding_bound_at(binding)) ->
        diff = DateTime.diff(now, binding_bound_at(binding), :second)

        if diff <= expiry_seconds do
          :ok
        else
          {:error,
           {:expired,
            %{bound_at: binding_bound_at(binding), now: now, expiry_seconds: expiry_seconds}}}
        end

      true ->
        :ok
    end
  end

  defp ensure_plan_scope(approval) do
    scope = normalize_scope(approval_scope(approval))

    if scope == :plan do
      :ok
    else
      {:error, {:scope_denied, scope}}
    end
  end

  defp ensure_not_expired(approval, now) do
    if expired_approval?(approval, now), do: {:error, :approval_expired}, else: :ok
  end

  defp ensure_not_rejected(approval) do
    if rejected?(approval), do: {:error, :approval_rejected}, else: :ok
  end

  defp validate_session_binding(session, plan, approval) do
    resolved_session_id = session_id(session) || plan.session_id
    approval_bound_session_id = approval_session_id(approval)

    cond do
      resolved_session_id == nil ->
        {:error, :missing_session_id}

      approval_bound_session_id == nil ->
        {:error, :session_mismatch}

      to_string(approval_bound_session_id) != to_string(resolved_session_id) ->
        {:error, :session_mismatch}

      true ->
        :ok
    end
  end

  defp validate_plan_id_binding(session, plan, approval) do
    resolved_plan_id = plan.id || active_plan_id(session)
    approval_bound_plan_id = approval_plan_id(approval)
    current_active_plan_id = active_plan_id(session)

    cond do
      resolved_plan_id == nil ->
        {:error, :missing_plan_id}

      current_active_plan_id != nil and
          to_string(resolved_plan_id) != to_string(current_active_plan_id) ->
        {:error, :active_plan_mismatch}

      approval_bound_plan_id == nil ->
        {:error, :plan_id_mismatch}

      to_string(approval_bound_plan_id) != to_string(resolved_plan_id) ->
        {:error, :plan_id_mismatch}

      true ->
        :ok
    end
  end

  defp validate_plan_version_binding(plan, approval) do
    current_version = normalize_integer(plan.version)
    approval_version = approval_plan_version(approval)

    cond do
      not (is_integer(current_version) and current_version >= 0) ->
        {:error, :plan_version_mismatch}

      not (is_integer(approval_version) and approval_version >= 0) ->
        {:error, :plan_version_mismatch}

      approval_version != current_version ->
        {:error, :plan_version_mismatch}

      true ->
        :ok
    end
  end

  defp validate_plan_hash_binding(plan, approval) do
    current_plan_hash = PlanBinding.content_hash(plan)
    approval_bound_hash = approval_plan_hash(approval)

    cond do
      is_nil(approval_bound_hash) or approval_bound_hash == "" -> {:error, :plan_hash_mismatch}
      approval_bound_hash != current_plan_hash -> {:error, :plan_hash_mismatch}
      true -> :ok
    end
  end

  defp validate_workspace_binding(session, plan, approval) do
    approval_bound_workspace = approval_workspace(approval)

    if is_nil(approval_bound_workspace) do
      :ok
    else
      current_workspace = plan_workspace(plan) || session_workspace(session)

      cond do
        current_workspace == nil -> {:error, :workspace_mismatch}
        approval_bound_workspace != current_workspace -> {:error, :workspace_mismatch}
        true -> :ok
      end
    end
  end

  defp resolve_approval(session, plan, opts) do
    case Keyword.get(opts, :approval) do
      nil ->
        case latest_plan_approval(session, plan, [:pending, :approved, :rejected]) do
          nil -> {:error, :missing_plan_approval}
          approval -> {:ok, approval}
        end

      %Approval{} = approval ->
        {:ok, approval}

      approval when is_map(approval) ->
        {:ok, Approval.from_map(approval)}

      _other ->
        {:error, :missing_plan_approval}
    end
  end

  defp latest_plan_approval(session, plan, statuses) do
    expected_plan_id = plan.id || active_plan_id(session)

    session_approvals(session)
    |> Enum.reverse()
    |> Enum.find(fn approval ->
      normalize_scope(approval_scope(approval)) == :plan and
        approval_plan_id(approval) == expected_plan_id and approval_status(approval) in statuses
    end)
  end

  defp ensure_pending(approval) do
    case normalize_status(approval_status(approval)) do
      :pending -> :ok
      :rejected -> {:error, :approval_rejected}
      _other -> {:error, :approval_not_pending}
    end
  end

  defp ensure_approved(approval) do
    case normalize_status(approval_status(approval)) do
      :approved -> :ok
      :rejected -> {:error, :approval_rejected}
      _other -> {:error, :approval_not_approved}
    end
  end

  defp stale_for_plan_scope?(approval, plan_or_session, now) do
    cond do
      rejected?(approval) ->
        true

      expired_approval?(approval, now) ->
        true

      session_like?(plan_or_session) ->
        case active_plan(plan_or_session) do
          nil ->
            true

          plan ->
            match?(
              {:error, _},
              validate_plan_approval_binding(plan_or_session, plan, approval, now)
            )
        end

      match?(%Plan{}, plan_or_session) ->
        pseudo_session = %{
          id: plan_or_session.session_id,
          active_plan_id: plan_or_session.id,
          workspace: plan_workspace(plan_or_session)
        }

        match?(
          {:error, _},
          validate_plan_approval_binding(pseudo_session, plan_or_session, approval, now)
        )

      true ->
        true
    end
  end

  defp allowed_with_explicit_approval(session_or_context, approval) do
    case active_plan(session_or_context) do
      nil ->
        {:error, :no_active_plan}

      %Plan{} = plan ->
        now = DateTime.utc_now()

        with :ok <- ensure_approved(approval),
             :ok <- validate_plan_approval_binding(session_or_context, plan, approval, now) do
          :ok
        end
    end
  end

  defp allowed_for_plan_scope(session_or_context) do
    case active_plan(session_or_context) do
      nil ->
        {:error, :no_active_plan}

      %Plan{} = plan ->
        case latest_plan_approval(session_or_context, plan, [:approved]) do
          nil ->
            {:error, :missing_plan_approval}

          approval ->
            now = DateTime.utc_now()

            with :ok <- ensure_approved(approval),
                 :ok <- validate_plan_approval_binding(session_or_context, plan, approval, now) do
              :ok
            end
        end
    end
  end

  # -- Tool internals -----------------------------------------------------------

  defp safe_without_approval?(%Spec{
         name: "test_runner",
         permission: :test,
         requires_approval: false
       }),
       do: true

  defp safe_without_approval?(%Spec{requires_approval: false} = spec) do
    MapSet.member?(@safe_tool_permissions, tool_scope(spec))
  end

  defp safe_without_approval?(%Spec{}), do: false

  defp approval_scoped_permission?(%Spec{} = spec) do
    MapSet.member?(@approval_scoped_tool_permissions, tool_scope(spec))
  end

  defp tool_scope(%Spec{permission: permission, kind: kind}) do
    permission_scope = normalize_scope(permission)

    if permission_scope == :unknown do
      normalize_scope(kind)
    else
      permission_scope
    end
  end

  defp requires_approval_reason(%Spec{} = spec) do
    "#{spec.name} requires explicit #{format_scope(tool_scope(spec))} approval which has not been granted; plan approval does not authorize tool execution"
  end

  defp approval_scoped_permission_reason(%Spec{} = spec) do
    "#{spec.name} uses #{format_scope(tool_scope(spec))} permission and is denied by default; plan approval does not authorize tool execution"
  end

  defp unmatched_policy_reason(%Spec{} = spec) do
    "#{spec.name} is denied by default because no approval policy matches #{format_scope(tool_scope(spec))} permission"
  end

  # PR24: Remote execution is ALWAYS denied regardless of approval data.
  # This check runs before any other authorization logic.
  defp remote_execution_tool?(%Spec{name: name}, _context) do
    name == "remote_execution" or
      Muse.Execution.Policy.remote_tool_blocked?(name)
  end

  # -- Generic data helpers -----------------------------------------------------

  defp append_approval(session, approval) do
    approvals = session_approvals(session) ++ [approval]
    put_existing_or_new(session, :approvals, "approvals", approvals)
  end

  defp active_plan(session_or_context) when is_map(session_or_context) do
    direct = map_get_any(session_or_context, [:plan, "plan", :active_plan, "active_plan"])

    cond do
      match?(%Plan{}, direct) ->
        direct

      is_map(direct) ->
        Plan.from_map(direct)

      true ->
        plans = map_get_any(session_or_context, [:plans, "plans"])
        current_active_plan_id = active_plan_id(session_or_context)
        fetch_plan(plans, current_active_plan_id)
    end
  rescue
    _ -> nil
  end

  defp fetch_plan(plans, plan_id) when is_map(plans) and not is_nil(plan_id) do
    case Map.get(plans, plan_id) || Map.get(plans, to_string(plan_id)) do
      %Plan{} = plan -> plan
      plan when is_map(plan) -> Plan.from_map(plan)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_plan(_plans, _plan_id), do: nil

  defp session_like?(map) when is_map(map) do
    map_get_any(map, [:plans, "plans", :active_plan_id, "active_plan_id", :plan, "plan"]) != nil
  end

  defp session_approvals(session) when is_map(session) do
    session
    |> map_get_any([:approvals, "approvals"], [])
    |> normalize_approvals()
  end

  defp session_approvals(_), do: []

  defp approval_scope(approval) do
    map_get_any(approval, [:scope, "scope", :kind, "kind", :type, "type"])
  end

  defp approval_status(%Approval{status: status}), do: status
  defp approval_status(approval), do: map_get_any(approval, [:status, "status"])
  defp approval_session_id(%Approval{session_id: session_id}), do: session_id
  defp approval_session_id(approval), do: map_get_any(approval, [:session_id, "session_id"])
  defp approval_plan_id(%Approval{plan_id: plan_id}), do: plan_id
  defp approval_plan_id(approval), do: map_get_any(approval, [:plan_id, "plan_id"])
  defp approval_plan_hash(%Approval{} = approval), do: approval.plan_hash || approval.content_hash

  defp approval_plan_hash(approval),
    do:
      map_get_any(approval, [
        :plan_hash,
        "plan_hash",
        :content_hash,
        "content_hash",
        :hash,
        "hash"
      ])

  defp approval_workspace(%Approval{workspace: workspace}), do: workspace
  defp approval_workspace(approval), do: map_get_any(approval, [:workspace, "workspace"])

  defp approval_plan_version(%Approval{plan_version: version}), do: normalize_integer(version)

  defp approval_plan_version(approval) do
    approval
    |> map_get_any([:plan_version, "plan_version", :version, "version"])
    |> normalize_integer()
  end

  defp rejected?(approval), do: normalize_status(approval_status(approval)) == :rejected

  defp expired_approval?(%Approval{} = approval, now), do: Approval.expired?(approval, now)

  defp expired_approval?(approval, now) do
    case map_get_any(approval, [:expires_at, "expires_at"]) do
      %DateTime{} = expires_at ->
        DateTime.compare(expires_at, now) != :gt

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires_at, _offset} -> DateTime.compare(expires_at, now) != :gt
          _ -> false
        end

      _other ->
        false
    end
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "pending" -> :pending
      "approved" -> :approved
      "rejected" -> :rejected
      "expired" -> :expired
      "stale" -> :stale
      "superseded" -> :superseded
      _other -> :unknown
    end
  end

  defp normalize_status(_status), do: :unknown

  defp normalize_scope(scope) when is_atom(scope) do
    cond do
      scope == @plan_scope -> :plan
      scope in [:read, :interactive, :test] -> scope
      scope == :shell_command -> :shell
      MapSet.member?(@denied_scopes, scope) -> scope
      true -> :unknown
    end
  end

  defp normalize_scope(scope) when is_binary(scope) do
    case String.downcase(scope) |> String.replace("-", "_") do
      "plan" -> :plan
      "patch" -> :patch
      "patch_apply" -> :patch
      "patch_propose" -> :patch
      "write" -> :write
      "write_file" -> :write
      "shell" -> :shell
      "shell_command" -> :shell
      "network" -> :network
      "network_call" -> :network
      "delete" -> :delete
      "delete_file" -> :delete
      "restore" -> :restore
      "restore_checkpoint" -> :restore_checkpoint
      "remote_execution" -> :remote_execution
      "read" -> :read
      "interactive" -> :interactive
      "test" -> :test
      _other -> :unknown
    end
  end

  defp normalize_scope(_scope), do: :unknown

  defp format_scope(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp format_scope(scope) when is_binary(scope), do: scope
  defp format_scope(_scope), do: "unknown"

  defp session_id(session_or_context),
    do: map_get_any(session_or_context, [:id, "id", :session_id, "session_id"])

  defp active_plan_id(session_or_context),
    do: map_get_any(session_or_context, [:active_plan_id, "active_plan_id"])

  defp session_workspace(session_or_context),
    do: map_get_any(session_or_context, [:workspace, "workspace"])

  defp plan_workspace(%Plan{metadata: metadata}) do
    map_get_any(metadata || %{}, [:workspace, "workspace"])
  end

  defp plan_workspace(plan) when is_map(plan) do
    map_get_any(plan, [:workspace, "workspace"]) ||
      map_get_any(map_get_any(plan, [:metadata, "metadata"], %{}), [:workspace, "workspace"])
  end

  defp plan_workspace(_), do: nil

  defp require_session_id(nil), do: {:error, :missing_session_id}
  defp require_session_id(""), do: {:error, :missing_session_id}
  defp require_session_id(session_id), do: {:ok, session_id}

  defp require_plan_id(nil), do: {:error, :missing_plan_id}
  defp require_plan_id(""), do: {:error, :missing_plan_id}
  defp require_plan_id(plan_id), do: {:ok, plan_id}

  defp require_plan_version(version) when is_integer(version) and version >= 0, do: {:ok, version}
  defp require_plan_version(_), do: {:error, :missing_plan_version}

  defp binding_hash(binding),
    do: map_get_any(binding, [:plan_hash, "plan_hash", :content_hash, "content_hash"])

  defp binding_session_id(binding), do: map_get_any(binding, [:session_id, "session_id"])
  defp binding_workspace(binding), do: map_get_any(binding, [:workspace, "workspace"])

  defp binding_bound_at(binding),
    do: normalize_datetime(map_get_any(binding, [:bound_at, "bound_at"]))

  defp binding_expires_at(binding),
    do: normalize_datetime(map_get_any(binding, [:expires_at, "expires_at"]))

  defp approval_hash(%Approval{} = approval), do: approval.plan_hash || approval.content_hash

  defp workspace_matches?(nil, _binding_workspace), do: true
  defp workspace_matches?(_approval_workspace, nil), do: true
  defp workspace_matches?(left, right), do: left == right

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp normalize_datetime(_), do: nil

  defp keyword_datetime(opts, key, default) do
    case Keyword.get(opts, key) do
      %DateTime{} = datetime -> datetime
      value when is_binary(value) -> normalize_datetime(value) || default
      _other -> default
    end
  end

  defp map_get_any(map, keys, default \\ nil)

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp put_existing_or_new(map, atom_key, string_key, value) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.put(map, atom_key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, atom_key, value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- Remote execution approval (Phase B) ------------------------------------

  @default_remote_expiry_seconds 300

  @doc """
  Request a pending remote execution approval.

  Creates a `%Muse.Approval{kind: :remote_execution}` record bound to the
  given `session_id`, `target_id`, and `command_hash`. The approval has a
  single-command scope and defaults to a 5-minute expiry.

  **Critical invariant:** This approval is auditable metadata only. It does
  NOT grant actual runner/tool execution. Remote execution tools remain
  denied by `authorize_tool/2` and `Muse.Execution.Policy`.

  ## Options

    * `:session_id`    — the session requesting remote execution (required)
    * `:target_id`    — the remote target identifier (required)
    * `:command_hash` — SHA-256 hash of the command to execute (required)
    * `:argv_preview` — short, safe preview of the command argv (no credentials)
    * `:ttl_seconds`  — approval time-to-live in seconds (default: 300 / 5 min)
    * `:expires_at`   — explicit expiry DateTime (overrides :ttl_seconds)
    * `:now`          — deterministic timestamp for tests
    * `:requested_by` — actor requesting the approval
    * `:source`       — source of the request
    * `:metadata`     — additional metadata map

  Returns `{:ok, approval}` on success or `{:error, reason}` on failure.
  """
  @spec request_remote_execution_approval(keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def request_remote_execution_approval(opts) when is_list(opts) do
    with {:ok, session_id} <- require_remote_field(opts, :session_id),
         {:ok, target_id} <- require_remote_field(opts, :target_id),
         {:ok, command_hash} <- require_remote_field(opts, :command_hash) do
      now = keyword_datetime(opts, :now, DateTime.utc_now())
      ttl = Keyword.get(opts, :ttl_seconds, @default_remote_expiry_seconds)

      expires_at =
        cond do
          match?(%DateTime{}, Keyword.get(opts, :expires_at)) -> Keyword.get(opts, :expires_at)
          is_integer(ttl) and ttl > 0 -> DateTime.add(now, ttl, :second)
          true -> DateTime.add(now, @default_remote_expiry_seconds, :second)
        end

      argv_preview =
        case Keyword.get(opts, :argv_preview) do
          nil -> nil
          preview when is_binary(preview) -> String.slice(preview, 0, 200)
          other -> inspect(other, printable_limit: 200)
        end

      approval =
        Approval.new(%{
          kind: :remote_execution,
          type: :remote_execution,
          status: :pending,
          session_id: session_id,
          target_id: target_id,
          command_hash: command_hash,
          argv_preview: argv_preview,
          scope: :single_command,
          requested_by: Keyword.get(opts, :requested_by),
          source: Keyword.get(opts, :source),
          created_at: now,
          expires_at: expires_at,
          metadata:
            Map.merge(
              %{hash_algorithm: "sha256", approval_phase: "B"},
              Keyword.get(opts, :metadata, %{})
            )
        })

      {:ok, approval}
    end
  end

  @doc """
  Approve a pending remote execution approval.

  Returns `{:ok, approval}` when the approval is pending and not expired.
  Returns `{:error, reason}` otherwise.

  **Critical invariant:** Approval does NOT grant runner/tool execution.
  """
  @spec approve_remote_execution(Approval.t(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def approve_remote_execution(%Approval{} = approval, opts \\ []) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    cond do
      Approval.expired?(approval, now) ->
        {:error, :approval_expired}

      approval.kind != :remote_execution ->
        {:error, {:wrong_kind, approval.kind}}

      approval.status != :pending ->
        {:error, {:invalid_transition, approval.status, :approved}}

      true ->
        Approval.approve(approval,
          approved_by: Keyword.get(opts, :approved_by, Keyword.get(opts, :actor)),
          approved_at: now,
          source: Keyword.get(opts, :source)
        )
    end
  end

  @doc """
  Reject a pending remote execution approval.

  Returns `{:ok, approval}` when the approval is pending and not expired.
  Returns `{:error, reason}` otherwise.
  """
  @spec reject_remote_execution(Approval.t(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def reject_remote_execution(%Approval{} = approval, opts \\ []) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    cond do
      Approval.expired?(approval, now) ->
        {:error, :approval_expired}

      approval.kind != :remote_execution ->
        {:error, {:wrong_kind, approval.kind}}

      approval.status != :pending ->
        {:error, {:invalid_transition, approval.status, :rejected}}

      true ->
        Approval.reject(approval,
          rejected_by: Keyword.get(opts, :rejected_by, Keyword.get(opts, :actor)),
          rejected_at: now,
          reason: Keyword.get(opts, :reason, "rejected by user"),
          source: Keyword.get(opts, :source)
        )
    end
  end

  @doc """
  Validate a remote execution approval against expected binding.

  Checks that the approval matches the expected `session_id`, `target_id`,
  `command_hash`, and is not expired. Returns `:ok` when all checks pass.

  **Critical invariant:** Even a validated remote execution approval does
  NOT grant actual execution. Use this for audit/metadata only.
  """
  @spec validate_remote_execution_approval(Approval.t(), keyword()) ::
          :ok | {:error, term()}
  def validate_remote_execution_approval(%Approval{} = approval, opts) when is_list(opts) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    with :ok <- ensure_remote_kind(approval),
         :ok <- ensure_approved_status(approval),
         :ok <- ensure_not_expired(approval, now),
         :ok <- match_remote_field(approval.session_id, Keyword.get(opts, :session_id), :session_mismatch),
         :ok <- match_remote_field(approval.target_id, Keyword.get(opts, :target_id), :target_mismatch),
         :ok <- match_remote_field(approval.command_hash, Keyword.get(opts, :command_hash), :command_hash_mismatch) do
      :ok
    end
  end

  @doc """
  Build safe event metadata for remote execution approval events.

  No credentials, connection details, or sensitive target info are included.
  Only `approval_id`, `kind`, `status`, `target_id`, `command_hash`, and
  `argv_preview` are exposed.
  """
  @spec remote_approval_event_data(Approval.t()) :: map()
  def remote_approval_event_data(%Approval{} = approval) do
    Approval.event_payload(%{
      approval_id: approval.id,
      kind: approval.kind,
      status: approval.status,
      target_id: approval.target_id,
      command_hash: approval.command_hash,
      argv_preview: approval.argv_preview
    })
  end

  @doc """
  Return the default remote execution approval expiry in seconds (300 = 5 min).
  """
  @spec default_remote_expiry_seconds() :: non_neg_integer()
  def default_remote_expiry_seconds, do: @default_remote_expiry_seconds

  # -- Remote execution approval internals --------------------------------------

  defp require_remote_field(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:missing_field, key}}
      value -> {:ok, to_string(value)}
    end
  end

  defp ensure_remote_kind(%Approval{kind: :remote_execution}), do: :ok
  defp ensure_remote_kind(%Approval{kind: kind}), do: {:error, {:wrong_kind, kind}}

  defp ensure_approved_status(%Approval{status: :approved}), do: :ok
  defp ensure_approved_status(%Approval{status: status}),
    do: {:error, {:approval_not_approved, status}}

  defp match_remote_field(_actual, nil, _error), do: :ok
  defp match_remote_field(_actual, "", _error), do: :ok
  defp match_remote_field(actual, expected, _error) when actual == expected, do: :ok
  defp match_remote_field(actual, expected, error),
    do: {:error, {error, %{expected: expected, actual: actual}}}
end
