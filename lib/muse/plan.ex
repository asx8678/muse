defmodule Muse.Plan do
  @moduledoc """
  Struct representing a Muse Plan — the approval-gated implementation
  plan produced by the Planning Muse.

  A plan captures the objective, tasks, risks, validation steps, and
  approval lifecycle. The Planning Muse creates a plan and the user records an
  approval/rejection decision; execution still requires a later explicit gate.

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

  @default_schema_version "planning.v1"

  @enforce_keys [:id, :session_id, :objective, :status, :version, :schema_version]

  defstruct [
    :id,
    :session_id,
    :version,
    :schema_version,
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
    assumptions: [],
    required_permissions: [],
    agent_assignments: [],
    phases: [],
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
          schema_version: String.t(),
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
          assumptions: [String.t()],
          required_permissions: [String.t()],
          agent_assignments: [map()],
          phases: [map()],
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
  Return the canonical structured plan schema version for new plans.
  """
  @spec default_schema_version() :: String.t()
  def default_schema_version, do: @default_schema_version

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
    - `:id`             → `nil` (assigned by session/persistence layer)
    - `:session_id`     → `nil`
    - `:version`        → `1`
    - `:schema_version` → `"planning.v1"`
    - `:status`         → `:draft`
    - `:tasks`          → `[]`
    - `:risks`          → `[]`
    - `:metadata`       → `%{}`
    - All other list fields → `[]`

  ## Options

    * `:id`                   — plan identifier
    * `:session_id`           — owning session ID
    * `:version`              — plan revision number
    * `:schema_version`       — structured JSON schema version (default `"planning.v1"`)
    * `:status`               — initial status (default `:draft`)
    * `:title`                — short plan title
    * `:objective`            — **required** one-sentence goal
    * `:summary`              — longer summary
    * `:created_by`           — Muse or user that created the plan
    * `:created_at`           — override timestamp (for deterministic tests)
    * `:updated_at`           — override timestamp (for deterministic tests)
    * `:tasks`                — list of `%Muse.Task{}` or raw maps (converted via `Muse.Task.from_map/1`)
    * `:assumptions`          — assumptions the plan depends on
    * `:required_permissions` — coarse permissions/capabilities required to execute the plan
    * `:agent_assignments`    — structured assignment metadata for agents/tasks
    * `:phases`               — optional phase-like plan grouping metadata
    * `:risks`                — list of risk strings
    * `:alternatives`         — list of alternative approach maps
    * `:validation`           — list of validation step strings
    * `:approvals`            — list of approval records
    * `:metadata`             — bounded, sanitized metadata map

  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)

    now = DateTime.utc_now()
    raw_status = Map.get(normalized, :status, :draft)
    status = normalize_status(raw_status)
    version = Map.get(normalized, :version, 1)
    schema_version = normalize_schema_version(Map.get(normalized, :schema_version))
    tasks = normalize_tasks(Map.get(normalized, :tasks, []))

    %__MODULE__{
      id: Map.get(normalized, :id),
      session_id: Map.get(normalized, :session_id),
      version: version,
      schema_version: schema_version,
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
      assumptions: normalize_string_list(Map.get(normalized, :assumptions, [])),
      required_permissions: normalize_string_list(Map.get(normalized, :required_permissions, [])),
      agent_assignments: normalize_map_list(Map.get(normalized, :agent_assignments, [])),
      phases: normalize_map_list(Map.get(normalized, :phases, [])),
      steps: Map.get(normalized, :steps, []),
      inspected_files: Map.get(normalized, :inspected_files, []),
      likely_changed_files: Map.get(normalized, :likely_changed_files, []),
      files_expected: Map.get(normalized, :files_expected, []),
      commands_expected: Map.get(normalized, :commands_expected, []),
      risks: Map.get(normalized, :risks, []),
      alternatives: Map.get(normalized, :alternatives, []),
      validation: Map.get(normalized, :validation, []),
      approvals: Map.get(normalized, :approvals, []),
      metadata: normalize_metadata(Map.get(normalized, :metadata, %{}))
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
    |> Map.update!(:metadata, &normalize_metadata/1)
    |> drop_nil_values()
  end

  @doc """
  Construct a `%Muse.Plan{}` from a plain map (e.g. decoded JSON).

  This is the inverse of `to_map/1`. Tasks are converted from raw maps
  via `Muse.Task.from_map/1`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  # -- Content binding ----------------------------------------------------------

  @doc """
  Compute a deterministic SHA-256 hash over the stable content of the plan.

  Delegates to `Muse.PlanBinding.content_hash/1`. Volatile lifecycle fields,
  timestamps, approval records, and metadata are excluded from the hash.
  """
  @spec content_hash(t()) :: String.t()
  def content_hash(%__MODULE__{} = plan), do: Muse.PlanBinding.content_hash(plan)

  @doc """
  Return a binding map for plan approvals.

  Delegates to `Muse.PlanBinding.approval_binding/2`.
  """
  @spec approval_binding(t(), keyword()) :: map()
  def approval_binding(%__MODULE__{} = plan, opts \\ []),
    do: Muse.PlanBinding.approval_binding(plan, opts)

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
      render_assumptions(plan),
      render_tasks(plan),
      render_required_permissions(plan),
      render_risks(plan),
      render_footer(plan)
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

  defp render_assumptions(%__MODULE__{assumptions: []}), do: nil

  defp render_assumptions(%__MODULE__{assumptions: assumptions}) do
    assumption_lines = Enum.map(assumptions, &("- " <> &1))
    "Assumptions:\n" <> Enum.join(assumption_lines, "\n")
  end

  defp render_tasks(%__MODULE__{tasks: []}), do: nil

  defp render_tasks(%__MODULE__{tasks: tasks}) do
    task_lines =
      tasks
      |> Enum.with_index(1)
      |> Enum.map(fn {task, i} -> "#{i}. #{task.title}" end)

    "Tasks:\n" <> Enum.join(task_lines, "\n")
  end

  defp render_required_permissions(%__MODULE__{required_permissions: []}), do: nil

  defp render_required_permissions(%__MODULE__{required_permissions: permissions}) do
    permission_lines = Enum.map(permissions, &("- " <> &1))
    "Required permissions:\n" <> Enum.join(permission_lines, "\n")
  end

  defp render_risks(%__MODULE__{risks: []}), do: nil

  defp render_risks(%__MODULE__{risks: risks}) do
    risk_lines = Enum.map(risks, &("- " <> &1))
    "Risks:\n" <> Enum.join(risk_lines, "\n")
  end

  defp render_footer(%__MODULE__{status: :awaiting_approval} = plan) do
    [
      Muse.PlanApprovalRequest.render_binding(plan),
      "Approve this plan with: /approve plan\nReject this plan with: /reject plan"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp render_footer(%__MODULE__{status: :approved}) do
    "This Muse Plan has been approved. Approval records the plan decision only; implementation still requires a later explicit gate."
  end

  defp render_footer(%__MODULE__{status: :rejected}) do
    "This Muse Plan was rejected. Ask Planning Muse for a revised plan."
  end

  defp render_footer(%__MODULE__{status: :completed}) do
    "This Muse Plan has been completed."
  end

  defp render_footer(%__MODULE__{status: :cancelled}) do
    "This Muse Plan has been cancelled."
  end

  defp render_footer(%__MODULE__{status: :superseded}) do
    "This Muse Plan has been superseded."
  end

  defp render_footer(%__MODULE__{status: :in_progress}) do
    "This Muse Plan is in progress."
  end

  defp render_footer(%__MODULE__{status: :executing}) do
    "This Muse Plan is being executed."
  end

  defp render_footer(%__MODULE__{status: :draft}) do
    "This Muse Plan is a draft and is not yet ready for approval."
  end

  defp render_footer(%__MODULE__{status: :needs_revision}) do
    "This Muse Plan needs revision before it can be submitted for approval."
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
  defp normalize_status(_status), do: :draft

  defp normalize_schema_version(version) when is_binary(version) do
    case String.trim(version) do
      "" -> @default_schema_version
      value -> value
    end
  end

  defp normalize_schema_version(_version), do: @default_schema_version

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
                :schema_version,
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
                :assumptions,
                :required_permissions,
                :agent_assignments,
                :phases,
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

  defp normalize_tasks(_tasks), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) -> [value]
      value when is_atom(value) and value not in [nil, true, false] -> [Atom.to_string(value)]
      _value -> []
    end)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_map_list(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      value when is_map(value) -> [normalize_metadata(value)]
      _value -> []
    end)
  end

  defp normalize_map_list(_values), do: []

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Muse.MetadataSanitizer.sanitize(max_depth: 4, max_map_keys: 50, max_list_length: 50)
    |> normalize_metadata_map()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp normalize_metadata_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_metadata_key(key), normalize_metadata_value(value)}
    end)
  end

  defp normalize_metadata_key(key) when is_binary(key) or is_atom(key), do: key
  defp normalize_metadata_key(key), do: inspect(key, printable_limit: 100)

  defp normalize_metadata_value(value) when is_map(value), do: normalize_metadata_map(value)

  defp normalize_metadata_value(value) when is_list(value) do
    Enum.map(value, &normalize_metadata_value/1)
  end

  defp normalize_metadata_value(nil), do: nil
  defp normalize_metadata_value(value) when is_boolean(value), do: value
  defp normalize_metadata_value(value) when is_binary(value), do: value
  defp normalize_metadata_value(value) when is_number(value), do: value
  defp normalize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_metadata_value(value), do: inspect(value, printable_limit: 100)

  defp drop_nil_values(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
