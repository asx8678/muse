defmodule Muse.Session do
  @moduledoc """
  Struct representing a Muse session — the top-level container for a
  conversational workflow with one or more Muses.

  A session owns the workspace path, tracks the active Muse and plan,
  and accumulates messages, plans, approvals, checkpoints, tool calls,
  artifacts, and an optional pending patch.

  ## Status lifecycle

  Sessions progress through well-defined statuses:

      :idle → :running → :planning → :awaiting_plan_approval → :executing
            → :awaiting_patch_approval → :verifying → :reviewing
            → :done | :failed | :error | :cancelled

  `Muse.Session.statuses/0` returns the canonical list.

  ## Construction

      iex> session = Muse.Session.new(workspace: "/tmp/project")
      iex> session.status
      :idle
      iex> session.id
      nil

  For deterministic tests, pass `id:` and `created_at:` / `updated_at:`:

      iex> session = Muse.Session.new(workspace: "/tmp", id: "sess_1", created_at: ~U[2025-01-01 00:00:00Z])
      iex> session.id
      "sess_1"
  """

  @enforce_keys [:workspace, :status, :created_at, :updated_at]
  defstruct [
    :id,
    :workspace,
    :status,
    :active_muse,
    :active_plan_id,
    :active_task_id,
    :provider_state,
    :created_at,
    :updated_at,
    messages: [],
    memory: nil,
    plans: %{},
    approvals: [],
    checkpoints: [],
    tool_calls: [],
    artifacts: [],
    pending_patch: nil
  ]

  @type status ::
          :idle
          | :running
          | :planning
          | :awaiting_plan_approval
          | :executing
          | :awaiting_patch_approval
          | :awaiting_shell_approval
          | :verifying
          | :reviewing
          | :repairing
          | :done
          | :failed
          | :error
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t() | nil,
          workspace: String.t(),
          status: status(),
          active_muse: String.t() | nil,
          active_plan_id: String.t() | nil,
          active_task_id: String.t() | nil,
          provider_state: map() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          messages: list(),
          memory: term() | nil,
          plans: map(),
          approvals: list(),
          checkpoints: list(),
          tool_calls: list(),
          artifacts: list(),
          pending_patch: Muse.Patch.t() | nil
        }

  @doc """
  Return the canonical list of session statuses.

      iex> Muse.Session.statuses()
      [:idle, :running, :planning, :awaiting_plan_approval, :executing,
       :awaiting_patch_approval, :awaiting_shell_approval, :verifying,
       :reviewing, :repairing, :done, :failed, :error, :cancelled]
  """
  @spec statuses() :: [status()]
  def statuses do
    [
      :idle,
      :running,
      :planning,
      :awaiting_plan_approval,
      :executing,
      :awaiting_patch_approval,
      :awaiting_shell_approval,
      :verifying,
      :reviewing,
      :repairing,
      :done,
      :failed,
      :error,
      :cancelled
    ]
  end

  @doc """
  Check whether the given status is valid.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in statuses()

  @doc """
  Create a new session struct.

  ## Options

    * `:id`          — session identifier (defaults to `nil`; SessionStore will assign)
    * `:status`      — initial status (default `:idle`)
    * `:active_muse` — the currently active Muse profile ID
    * `:created_at`  — override timestamp (for deterministic tests)
    * `:updated_at`  — override timestamp (for deterministic tests)

  All other struct fields default to their zero values (`nil`, `[]`, `%{}`).
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get(opts, :id),
      workspace: Keyword.fetch!(opts, :workspace),
      status: Keyword.get(opts, :status, :idle),
      active_muse: Keyword.get(opts, :active_muse),
      active_plan_id: Keyword.get(opts, :active_plan_id),
      active_task_id: Keyword.get(opts, :active_task_id),
      provider_state: Keyword.get(opts, :provider_state),
      created_at: Keyword.get(opts, :created_at, now),
      updated_at: Keyword.get(opts, :updated_at, now)
    }
  end

  @doc """
  Transition a session to a new status.

  Returns `{:ok, session}` when the status is valid, or
  `{:error, {:invalid_status, status}}` when it is not.

  The `updated_at` field is always set to the current time unless
  overridden via the `:updated_at` option (useful for deterministic tests).
  """
  @spec transition(t(), status(), keyword()) :: {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = session, new_status, opts \\ []) do
    if valid_status?(new_status) do
      {:ok,
       %{
         session
         | status: new_status,
           updated_at: Keyword.get(opts, :updated_at, DateTime.utc_now())
       }}
    else
      {:error, {:invalid_status, new_status}}
    end
  end
end
