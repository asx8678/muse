defmodule Muse.Plan do
  @moduledoc """
  Struct representing a Muse Plan — the approval-gated implementation
  plan produced by the Planning Muse.

  A plan captures the objective, tasks, risks, validation steps, and
  approval lifecycle. The Planning Muse creates a plan, the user reviews
  it, and the Coding Muse executes it after approval.

  ## Status lifecycle

      :draft → :awaiting_approval → :approved → :in_progress → :executing → :completed
                                        ↘ :rejected → :needs_revision → :draft
                                        ↘ :superseded
                  :cancelled (from any status)

  ## Construction

      iex> plan = Muse.Plan.new(objective: "Add a /version command.")
      iex> plan.status
      :draft
      iex> plan.id
      nil

  For deterministic tests, pass `id:` and timestamps:

      iex> plan = Muse.Plan.new(id: "plan_1", objective: "Test", session_id: "s1",
      ...>   created_at: ~U[2025-01-01 00:00:00Z])
      iex> plan.id
      "plan_1"

  ## Adding tasks

      iex> plan = Muse.Plan.new(objective: "Add feature")
      iex> task = Muse.Task.new(title: "Implement", description: "Write code")
      iex> plan = Muse.Plan.put_task(plan, task)
      iex> length(plan.tasks)
      1
  """

  @enforce_keys [:id, :session_id, :objective, :status, :version]

  defstruct [
    :id,
    :session_id,
    :version,
    :status,
    :title,
    :objective,
    :summary,
    :created_by,
    :created_at,
    :updated_at,
    :approved_at,
    :rejected_at,
    :completed_at,
    tasks: [],
    steps: [],
    inspected_files: [],
    likely_changed_files: [],
    files_expected: [],
    commands_expected: [],
    risks: [],
    alternatives: [],
    validation: [],
    approvals: [],
    metadata: %{}
  ]

  @type status ::
          :draft
          | :awaiting_approval
          | :approved
          | :rejected
          | :superseded
          | :in_progress
          | :executing
          | :completed
          | :cancelled
          | :needs_revision

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          version: non_neg_integer(),
          status: status(),
          title: String.t() | nil,
          objective: String.t(),
          summary: String.t() | nil,
          created_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          approved_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          tasks: [Muse.Task.t()],
          steps: [map()],
          inspected_files: [String.t()],
          likely_changed_files: [String.t()],
          files_expected: [String.t()],
          commands_expected: [String.t()],
          risks: [String.t()],
          alternatives: [map()],
          validation: [String.t()],
          approvals: [map()],
          metadata: map()
        }

  # -- Valid statuses -----------------------------------------------------------

  @statuses [
    :draft,
    :awaiting_approval,
    :approved,
    :rejected,
    :superseded,
    :in_progress,
    :executing,
    :completed,
    :cancelled,
    :needs_revision
  ]

  @doc """
  Return the canonical list of plan statuses.

      iex> Muse.Plan.statuses()
      [:draft, :awaiting_approval, :approved, :rejected, :superseded,
       :in_progress, :executing, :completed, :cancelled, :needs_revision]
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Check whether the given status is valid.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  # -- Construction ------------------------------------------------------------

  @doc """
  Create a new `%Muse.Plan{}` from a keyword list or map.

  Accepts both atom and string keys.

  Defaults:
    - `:id`          → `nil` (assigned by session/persistence layer)
    - `:session_id`  → `nil`
    - `:version`     → `1`
    - `:status`      → `:draft`
    - `:tasks`       → `[]`
    - `:risks`       → `[]`
    - `:metadata`    → `%{}`
    - All other list fields → `[]`

  ## Options

    * `:id`                 — plan identifier
    * `:session_id`         — owning session ID
    * `:version`            — plan version number
    * `:status`             — initial status (default `:draft`)
    * `:title`              — short plan title
    * `:objective`          — **required** one-sentence goal
    * `:summary`            — longer summary
    * `:created_by`         — Muse or user that created the plan
    * `:created_at`         — override timestamp (for deterministic tests)
    * `:updated_at`         — override timestamp (for deterministic tests)
    * `:tasks`              — list of `%Muse.Task{}` or raw maps (converted via `Muse.Task.from_map/1`)
    * `:risks`              — list of risk strings
    * `:alternatives`       — list of alternative approach maps
    * `:validation`         — list of validation step strings
    * `:approvals`          — list of approval records
    * `:metadata`           — arbitrary metadata map

  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)

    now = DateTime.utc_now()
    raw_status = Map.get(normalized, :status, :draft)
    status = normalize_status(raw_status)
    version = Map.get(normalized, :version, 1)
    tasks = normalize_tasks(Map.get(normalized, :tasks, []))

    %__MODULE__{
      id: Map.get(normalized, :id),
      session_id: Map.get(normalized, :session_id),
      version: version,
      status: if(valid_status?(status), do: status, else: :draft),
      title: Map.get(normalized, :title),
      objective: Map.get(normalized, :objective, ""),
      summary: Map.get(normalized, :summary),
      created_by: Map.get(normalized, :created_by),
      created_at: Map.get(normalized, :created_at, now),
      updated_at: Map.get(normalized, :updated_at, now),
      approved_at: Map.get(normalized, :approved_at),
      rejected_at: Map.get(normalized, :rejected_at),
      completed_at: Map.get(normalized, :completed_at),
      tasks: tasks,
      steps: Map.get(normalized, :steps, []),
      inspected_files: Map.get(normalized, :inspected_files, []),
      likely_changed_files: Map.get(normalized, :likely_changed_files, []),
      files_expected: Map.get(normalized, :files_expected, []),
      commands_expected: Map.get(normalized, :commands_expected, []),
      risks: Map.get(normalized, :risks, []),
      alternatives: Map.get(normalized, :alternatives, []),
      validation: Map.get(normalized, :validation, []),
      approvals: Map.get(normalized, :approvals, []),
      metadata: Map.get(normalized, :metadata, %{})
    }
  end

  # -- Transition --------------------------------------------------------------

  @doc """
  Transition a plan to a new status.

  Returns `{:ok, plan}` when the status is valid, or
  `{:error, {:invalid_status, status}}` when it is not.

  The `updated_at` field is always set to the current time unless
  overridden via the `:updated_at` option (useful for deterministic tests).

  When transitioning to `:approved`, `approved_at` is set automatically.
  When transitioning to `:rejected`, `rejected_at` is set automatically.
  When transitioning to `:completed`, `completed_at` is set automatically.
  """
  @spec transition(t(), status(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = plan, new_status, opts \\ []) do
    if valid_status?(new_status) do
      now = Keyword.get(opts, :updated_at, DateTime.utc_now())

      plan =
        plan
        |> Map.put(:status, new_status)
        |> Map.put(:updated_at, now)

      plan = apply_status_timestamp(plan, new_status, opts)
      {:ok, plan}
    else
      {:error, {:invalid_status, new_status}}
    end
  end

  defp apply_status_timestamp(plan, :approved, opts) do
    Map.put(plan, :approved_at, Keyword.get(opts, :approved_at, DateTime.utc_now()))
  end

  defp apply_status_timestamp(plan, :rejected, opts) do
    Map.put(plan, :rejected_at, Keyword.get(opts, :rejected_at, DateTime.utc_now()))
  end

  defp apply_status_timestamp(plan, :completed, opts) do
    Map.put(plan, :completed_at, Keyword.get(opts, :completed_at, DateTime.utc_now()))
  end

  defp apply_status_timestamp(plan, _status, _opts), do: plan

  # -- Task management ----------------------------------------------------------

  @doc """
  Add a task to the plan, appending it to the `tasks` list.

  Accepts a `%Muse.Task{}` or a raw map (converted via `Muse.Task.from_map/1`).
  """
  @spec put_task(t(), Muse.Task.t() | map()) :: t()
  def put_task(%__MODULE__{} = plan, %Muse.Task{} = task) do
    %{plan | tasks: plan.tasks ++ [task], updated_at: DateTime.utc_now()}
  end

  def put_task(%__MODULE__{} = plan, task_attrs) when is_map(task_attrs) do
    put_task(plan, Muse.Task.from_map(task_attrs))
  end

  # -- Conversion helpers -------------------------------------------------------

  @doc """
  Convert a `%Muse.Plan{}` to a plain map suitable for JSON serialization.

  Tasks are serialized via `Muse.Task.to_map/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = plan) do
    plan
    |> Map.from_struct()
    |> Map.update!(:tasks, fn tasks -> Enum.map(tasks, &Muse.Task.to_map/1) end)
    |> drop_nil_values()
  end

  @doc """
  Construct a `%Muse.Plan{}` from a plain map (e.g. decoded JSON).

  This is the inverse of `to_map/1`. Tasks are converted from raw maps
  via `Muse.Task.from_map/1`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    map
    |> Map.update(:tasks, [], fn tasks ->
      Enum.map(tasks, &Muse.Task.from_map/1)
    end)
    |> new()
  end

  # -- Rendering ----------------------------------------------------------------

  @doc """
  Render the plan as a user-friendly string for CLI/TUI display.

  Includes the objective, numbered task titles, risks, and
  `/approve plan` / `/reject plan` guidance.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = plan) do
    parts = [
      render_header(plan),
      render_objective(plan),
      render_tasks(plan),
      render_risks(plan),
      render_footer()
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp render_header(plan) do
    if plan.status == :awaiting_approval do
      "Planning Muse prepared a plan."
    else
      "Muse Plan (#{plan.status})"
    end
  end

  defp render_objective(plan) do
    "Objective:\n#{plan.objective}"
  end

  defp render_tasks(%__MODULE__{tasks: []}), do: nil

  defp render_tasks(%__MODULE__{tasks: tasks}) do
    task_lines =
      tasks
      |> Enum.with_index(1)
      |> Enum.map(fn {task, i} -> "#{i}. #{task.title}" end)

    "Tasks:\n" <> Enum.join(task_lines, "\n")
  end

  defp render_risks(%__MODULE__{risks: []}), do: nil

  defp render_risks(%__MODULE__{risks: risks}) do
    risk_lines = Enum.map(risks, &("- " <> &1))
    "Risks:\n" <> Enum.join(risk_lines, "\n")
  end

  defp render_footer do
    "Approve this plan with: /approve plan\nReject this plan with: /reject plan"
  end

  # -- Private ------------------------------------------------------------------

  # Map known string statuses to atoms for safe JSON deserialization.
  # Prevents string statuses like "awaiting_approval" from defaulting to :draft.
  @status_map %{
    "draft" => :draft,
    "awaiting_approval" => :awaiting_approval,
    "approved" => :approved,
    "rejected" => :rejected,
    "superseded" => :superseded,
    "in_progress" => :in_progress,
    "executing" => :executing,
    "completed" => :completed,
    "cancelled" => :cancelled,
    "needs_revision" => :needs_revision
  }

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_map, status, :draft)
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  # Only convert known string keys to atoms — prevents atom table exhaustion
  # from arbitrary user/LLM JSON. Uses String.to_existing_atom which is safe
  # since all known keys are compile-time atoms.
  @known_keys MapSet.new([
                :id,
                :session_id,
                :version,
                :status,
                :title,
                :objective,
                :summary,
                :created_by,
                :created_at,
                :updated_at,
                :approved_at,
                :rejected_at,
                :completed_at,
                :tasks,
                :steps,
                :inspected_files,
                :likely_changed_files,
                :files_expected,
                :commands_expected,
                :risks,
                :alternatives,
                :validation,
                :approvals,
                :metadata,
                # Task keys that may appear at plan level
                :recommended_muse,
                :workspace
              ])

  defp safe_atom(key) when is_binary(key) do
    if MapSet.member?(@known_keys, String.to_existing_atom(key)) do
      String.to_existing_atom(key)
    else
      # Return the binary — it won't match any struct field and will be ignored
      key
    end
  rescue
    ArgumentError -> key
  end

  defp normalize_tasks(tasks) when is_list(tasks) do
    Enum.map(tasks, fn
      %Muse.Task{} = task -> task
      attrs when is_map(attrs) -> Muse.Task.from_map(attrs)
    end)
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
