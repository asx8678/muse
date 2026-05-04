defmodule Muse.Task do
  @moduledoc """
  Struct representing a single task within a Muse Plan.

  A task captures one discrete unit of work — inspection, implementation,
  verification, etc. — along with metadata about which Muse should perform
  it, what files are involved, and what capabilities (write/shell) it
  requires.

  ## Construction

      iex> task = Muse.Task.new(title: "Add command definition", description: "Update commands.ex")
      iex> task.status
      :pending
      iex> task.requires_write?
      false
      iex> task.requires_shell?
      false

  For deterministic tests, pass `id:` to pin the identifier:

      iex> task = Muse.Task.new(id: "task_1", title: "Read files", description: "Inspect modules")
      iex> task.id
      "task_1"

  ## Status

  Tasks default to `:pending`. Other valid task statuses: `:draft`, `:in_progress`,
  `:completed`, `:blocked`, `:skipped`.
  """

  @enforce_keys [:id, :title, :status]

  defstruct [
    :id,
    :title,
    :description,
    :status,
    :recommended_muse,
    :files,
    :target_files,
    :tools,
    :dependencies,
    :validation,
    :verification,
    :risk_level,
    :approval_required,
    :requires_write?,
    :requires_shell?
  ]

  @type status ::
          :draft
          | :pending
          | :in_progress
          | :completed
          | :blocked
          | :skipped

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          status: status(),
          recommended_muse: String.t() | atom() | nil,
          files: [String.t()],
          target_files: [String.t()],
          tools: [String.t()],
          dependencies: [String.t()],
          validation: [String.t()],
          verification: String.t() | nil,
          risk_level: String.t() | atom() | nil,
          approval_required: boolean() | nil,
          requires_write?: boolean(),
          requires_shell?: boolean()
        }

  # -- Valid statuses -----------------------------------------------------------

  @statuses [:draft, :pending, :in_progress, :completed, :blocked, :skipped]

  @doc """
  Return the canonical list of task statuses.

      iex> Muse.Task.statuses()
      [:draft, :pending, :in_progress, :completed, :blocked, :skipped]
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
  Create a new `%Muse.Task{}` from a keyword list or map.

  Accepts both atom and string keys. When `:id` is absent, a stable-ish
  identifier is generated from a monotonic counter.

  Defaults:
    - `:status`          → `:pending`
    - `:requires_write?` → `false`
    - `:requires_shell?` → `false`
    - `:files`           → `[]`
    - `:target_files`    → `[]`
    - `:tools`           → `[]`
    - `:dependencies`    → `[]`
    - `:validation`      → `[]`

  ## Options

    * `:id`                — task identifier (auto-generated when absent)
    * `:title`            — **required** short task title
    * `:description`      — longer description (required by schema, may be nil in struct)
    * `:status`           — `:pending` by default
    * `:recommended_muse` — which Muse should execute this task
    * `:files`            — files to inspect
    * `:target_files`     — files this task intends to change
    * `:tools`            — tools this task needs
    * `:dependencies`     — IDs of tasks this depends on
    * `:validation`       — validation steps
    * `:verification`     — verification description
    * `:risk_level`       — risk level (e.g. `:low`, `:medium`, `:high`)
    * `:approval_required` — whether explicit approval is needed
    * `:requires_write` / `:requires_write?` — needs file-write access
    * `:requires_shell` / `:requires_shell?`  — needs shell-command access

  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)

    id = Map.get(normalized, :id) || generate_id()
    title = Map.fetch!(normalized, :title)
    status = Map.get(normalized, :status, :pending)

    # Accept both `:requires_write` and `:requires_write?` key forms.
    # The JSON key is `requires_write` (no trailing `?`), but the struct
    # field is `requires_write?` — we bridge both forms here.
    requires_write =
      Map.get(normalized, :requires_write?) ||
        Map.get(normalized, :requires_write) ||
        false

    requires_shell =
      Map.get(normalized, :requires_shell?) ||
        Map.get(normalized, :requires_shell) ||
        false

    %__MODULE__{
      id: id,
      title: title,
      description: Map.get(normalized, :description),
      status: if(valid_status?(status), do: status, else: :pending),
      recommended_muse: Map.get(normalized, :recommended_muse),
      files: Map.get(normalized, :files, []),
      target_files: Map.get(normalized, :target_files, []),
      tools: Map.get(normalized, :tools, []),
      dependencies: Map.get(normalized, :dependencies, []),
      validation: Map.get(normalized, :validation, []),
      verification: Map.get(normalized, :verification),
      risk_level: Map.get(normalized, :risk_level),
      approval_required: Map.get(normalized, :approval_required),
      requires_write?: requires_write,
      requires_shell?: requires_shell
    }
  end

  # -- Conversion helpers -------------------------------------------------------

  @doc """
  Convert a `%Muse.Task{}` to a plain map suitable for JSON serialization.

  The `requires_write?` and `requires_shell?` struct fields are exported
  as `requires_write` and `requires_shell` (without the trailing `?`)
  to match the JSON schema convention.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = task) do
    task
    |> Map.from_struct()
    |> Map.put(:requires_write, task.requires_write?)
    |> Map.put(:requires_shell, task.requires_shell?)
    |> Map.drop([:requires_write?, :requires_shell?])
    |> drop_nil_values()
  end

  @doc """
  Construct a `%Muse.Task{}` from a plain map (e.g. decoded JSON).

  This is the inverse of `to_map/1` — it handles the `requires_write` /
  `requires_shell` → `requires_write?` / `requires_shell?` key mapping
  and normalizes atom/string keys.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  # -- Private ------------------------------------------------------------------

  @known_keys MapSet.new([
    :id, :title, :description, :status, :recommended_muse,
    :files, :target_files, :tools, :dependencies, :validation,
    :verification, :risk_level, :approval_required,
    :requires_write, :requires_write?, :requires_shell, :requires_shell?
  ])

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  # Only convert known string keys to atoms — prevents atom table exhaustion
  # from arbitrary user/LLM JSON. Unknown string keys are kept as-is (and
  # will be ignored by struct construction).
  defp safe_atom(key) when is_binary(key) do
    if MapSet.member?(@known_keys, String.to_existing_atom(key)) do
      String.to_existing_atom(key)
    else
      # Not a known field — return binary so it won't match any struct field
      key
    end
  rescue
    ArgumentError -> key
  end

  # We intentionally only use String.to_atom on keys we control —
  # the task-specific field names are all known compile-time atoms.
  # Status atoms from user input must go through `valid_status?/1`.

  defp generate_id do
    n = System.unique_integer([:positive, :monotonic])
    "task_#{n}"
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
