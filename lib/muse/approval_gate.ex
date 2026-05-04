defmodule Muse.ApprovalGate do
  @moduledoc """
  Captures and validates approval bindings for plan lifecycle actions.

  An approval binding is a deterministic snapshot of the plan's identity,
  content, and session context captured when a plan enters `:awaiting_approval`.
  The binding is used to detect stale or mismatched approval/rejection requests.

  Delegates content hashing to `Muse.PlanBinding` for consistency.

  ## Stale cases covered

    1. **Content change** — objective/tasks changed under the same id/version.
    2. **Wrong session** — approval from a different session.
    3. **Wrong workspace** — approval from a different workspace (when bound).
    4. **Expired** — the binding has expired (default 24h).
    5. **Idempotent approval** — re-approving an already-approved plan is
       idempotent *only* when the binding matches.

  ## Timestamp injection

  All timestamp-dependent checks accept a `:now` option so tests can inject
  deterministic times instead of relying on wall-clock `DateTime.utc_now/0`.
  """

  alias Muse.{Plan, PlanBinding}

  @default_expiry_seconds 86_400

  @type binding :: %{
          kind: String.t(),
          session_id: String.t() | nil,
          plan_id: String.t() | nil,
          plan_version: non_neg_integer(),
          plan_hash: String.t(),
          workspace: String.t() | nil,
          bound_at: DateTime.t()
        }

  # -- Public API ---------------------------------------------------------------

  @doc """
  Capture an approval binding when a plan enters `:awaiting_approval`.

  Wraps `Muse.PlanBinding.approval_binding/2` and adds a `:bound_at`
  timestamp for expiry tracking.

  Options:
    * `:workspace`    — the workspace path (defaults to `nil`)
    * `:now`          — deterministic timestamp for tests

  Returns a binding map suitable for storing in session state and
  validating later with `validate_approval/3` or `validate_rejection/3`.
  """
  @spec capture_binding(Plan.t(), keyword()) :: binding()
  def capture_binding(%Plan{} = plan, opts \\ []) do
    base = PlanBinding.approval_binding(plan, Keyword.take(opts, [:workspace]))
    Map.put(base, :bound_at, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  @doc """
  Validate that an approval request is fresh and matches the stored binding.

  Returns `:ok` when all checks pass, or `{:error, reason}` with a specific
  reason.

  ## Checks (in order)

    1. **Binding exists** — `nil` binding means no approval was ever requested.
    2. **Content hash** — current plan content matches the binding's `plan_hash`.
    3. **Session identity** — the requesting session matches the binding.
    4. **Workspace identity** — the requesting workspace matches (when bound).
    5. **Expiry** — the binding has not expired.

  Options:
    * `:session_id`  — session making the request
    * `:workspace`   — workspace making the request
    * `:now`         — deterministic timestamp for tests
    * `:expiry_seconds` — seconds after which a binding expires
      (default `#{@default_expiry_seconds}`)
  """
  @spec validate_approval(Plan.t(), binding() | nil, keyword()) ::
          :ok | {:error, term()}
  def validate_approval(_plan, nil, _opts) do
    {:error, :no_approval_binding}
  end

  def validate_approval(%Plan{} = plan, binding, opts) do
    with :ok <- check_content_hash(plan, binding),
         :ok <- check_session(binding, opts),
         :ok <- check_workspace(binding, opts),
         :ok <- check_expiry(binding, opts) do
      :ok
    end
  end

  @doc """
  Validate that a rejection request is fresh and matches the stored binding.

  Same checks as `validate_approval/3` minus workspace (rejection from any
  workspace is acceptable).  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_rejection(Plan.t(), binding() | nil, keyword()) ::
          :ok | {:error, term()}
  def validate_rejection(_plan, nil, _opts) do
    {:error, :no_approval_binding}
  end

  def validate_rejection(%Plan{} = plan, binding, opts) do
    with :ok <- check_content_hash(plan, binding),
         :ok <- check_session(binding, opts),
         :ok <- check_expiry(binding, opts) do
      :ok
    end
  end

  @doc """
  Check whether a plan that is already `:approved` can be considered
  idempotently approved under the given binding.

  Returns `{:ok, :idempotent}` when the current plan's content hash matches
  the binding's `plan_hash` (safe to return `{:ok, plan}` to the caller).
  Returns `{:error, :stale_approval}` when the binding doesn't match the
  plan that was originally approved.
  """
  @spec check_idempotent_approval(Plan.t(), binding()) ::
          {:ok, :idempotent} | {:error, :stale_approval}
  def check_idempotent_approval(%Plan{} = plan, binding) do
    if PlanBinding.content_hash(plan) == binding.plan_hash do
      {:ok, :idempotent}
    else
      {:error, :stale_approval}
    end
  end

  @doc """
  Return the default expiry duration in seconds.
  """
  @spec default_expiry_seconds :: non_neg_integer()
  def default_expiry_seconds, do: @default_expiry_seconds

  # -- Internal -----------------------------------------------------------------

  defp check_content_hash(plan, binding) do
    current = PlanBinding.content_hash(plan)

    if current == binding.plan_hash do
      :ok
    else
      {:error,
       {:stale_content,
        %{
          plan_id: plan.id,
          expected: binding.plan_hash,
          actual: current
        }}}
    end
  end

  defp check_session(binding, opts) do
    request_session = Keyword.get(opts, :session_id)
    bound_session = binding.session_id

    cond do
      is_nil(bound_session) -> :ok
      is_nil(request_session) -> :ok
      request_session == bound_session -> :ok
      true -> {:error, {:wrong_session, %{expected: bound_session, actual: request_session}}}
    end
  end

  defp check_workspace(binding, opts) do
    request_workspace = Keyword.get(opts, :workspace)
    bound_workspace = binding.workspace

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
    now = Keyword.get(opts, :now, DateTime.utc_now())
    expiry_seconds = Keyword.get(opts, :expiry_seconds, @default_expiry_seconds)

    bound_at = Map.get(binding, :bound_at)

    if is_nil(bound_at) do
      :ok
    else
      diff = DateTime.diff(now, bound_at, :second)

      if diff <= expiry_seconds do
        :ok
      else
        {:error, {:expired, %{bound_at: bound_at, now: now, expiry_seconds: expiry_seconds}}}
      end
    end
  end
end
