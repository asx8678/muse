defmodule Muse.PlanBinding do
  @moduledoc """
  Deterministic content-binding helpers for plan approvals.

  Provides a canonical hash over stable plan content and a binding map
  that captures the essential identity of a plan at approval time.

  ## Design principles

    * **Stable content only** — volatile timestamps, prior approval records,
      and runtime status are excluded from the hash so it reflects *what*
      the plan says, not *when* it was approved or *who* approved it.

    * **Deterministic ordering** — all keys are normalized to strings and
      sorted alphabetically at every nesting level before hashing, ensuring
      identical content always produces the same hash.

    * **No dynamic atoms** — unknown string keys from JSON or LLM output
      never create atoms; all canonicalization uses string keys exclusively.

    * **Secret-safe** — metadata (which may contain redacted secrets) and
      approval records are excluded from the hash and debug output.

  ## Hash algorithm

  SHA-256 over the Erlang deterministic binary encoding of the canonical
  term (`:erlang.term_to_binary/2` with `[:deterministic]`), which sorts
  map keys by Erlang term order. All keys are strings to ensure a
  consistent, well-defined sort.

  ## Usage

      iex> plan = Muse.Plan.new(id: "p1", session_id: "s1", objective: "Add feature")
      iex> hash = Muse.PlanBinding.content_hash(plan)
      iex> is_binary(hash) and byte_size(hash) == 64
      true

      iex> binding = Muse.PlanBinding.approval_binding(plan, workspace: "/tmp/project")
      iex> binding.kind
      "plan_approval"

      iex> binding.plan_hash == hash
      true
  """

  alias Muse.Plan
  alias Muse.Task

  @binding_kind "plan_approval"

  # -- Stable fields included in the content hash --------------------------------
  # Ordered alphabetically; this list is the canonical source of truth.
  @stable_fields [
    :alternatives,
    :assumptions,
    :commands_expected,
    :files_expected,
    :id,
    :inspected_files,
    :likely_changed_files,
    :objective,
    :phases,
    :required_permissions,
    :risks,
    :schema_version,
    :session_id,
    :steps,
    :tasks,
    :title,
    :validation,
    :version
  ]

  # -- Volatile fields explicitly EXCLUDED from the hash -------------------------
  #
  # Timestamps (change on every transition):
  #   :created_at, :updated_at, :approved_at, :rejected_at, :completed_at
  #
  # Runtime state (changes during lifecycle):
  #   :status
  #
  # Prior approval records (accumulate over time):
  #   :approvals
  #
  # Identity/metadata (volatile or secret-bearing):
  #   :created_by — creator identity, not content
  #   :summary — descriptive, may be edited without changing content identity
  #   :metadata — may contain redacted secrets, volatile
  #   :agent_assignments — operational routing, not plan content

  @doc """
  Return the list of stable field names included in the content hash.

  Useful for debugging and documentation.
  """
  @spec stable_fields() :: [atom()]
  def stable_fields, do: @stable_fields

  @doc """
  Compute a deterministic SHA-256 hash over the stable content of a plan.

  The hash covers the plan's identity fields (id, session_id, version,
  schema_version), its objective, tasks, and all declared assumptions,
  risks, permissions, expected files/commands, and validation steps.

  Volatile timestamps, prior approval records, status, metadata,
  created_by, summary, and agent_assignments are excluded.

  Returns a lowercase hex string (64 characters).

  ## Examples

      iex> plan = Muse.Plan.new(id: "p1", session_id: "s1", objective: "Add feature")
      iex> hash = Muse.PlanBinding.content_hash(plan)
      iex> is_binary(hash) and byte_size(hash) == 64
      true

      iex> same_plan = Muse.Plan.new(id: "p1", session_id: "s1", objective: "Add feature")
      iex> Muse.PlanBinding.content_hash(same_plan) == Muse.PlanBinding.content_hash(plan)
      true
  """
  @spec content_hash(Plan.t()) :: String.t()
  def content_hash(%Plan{} = plan) do
    plan
    |> canonical_term()
    |> then(&:erlang.term_to_binary(&1, [:deterministic]))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Return a binding map for plan approvals.

  The binding captures the essential identity of a plan at approval time:
  the kind of approval, session, plan id, version, content hash, and
  workspace (when available).

  ## Options

    * `:workspace` — the workspace path (defaults to `nil`)

  ## Examples

      iex> plan = Muse.Plan.new(id: "p1", session_id: "s1", objective: "Test")
      iex> binding = Muse.PlanBinding.approval_binding(plan, workspace: "/tmp/project")
      iex> binding.kind
      "plan_approval"
      iex> binding.workspace
      "/tmp/project"
      iex> binding.plan_hash == Muse.PlanBinding.content_hash(plan)
      true
  """
  @spec approval_binding(Plan.t(), keyword()) :: map()
  def approval_binding(%Plan{} = plan, opts \\ []) do
    %{
      kind: @binding_kind,
      session_id: plan.session_id,
      plan_id: plan.id,
      plan_version: plan.version,
      plan_hash: content_hash(plan),
      workspace: Keyword.get(opts, :workspace)
    }
  end

  @doc """
  Return the canonical binding kind string.
  """
  @spec binding_kind() :: String.t()
  def binding_kind, do: @binding_kind

  # -- Canonical term construction -----------------------------------------------

  # Build a deterministic term from the plan's stable fields.
  # All keys are strings; nil values are dropped; maps are sorted by key
  # (handled by :erlang.term_to_binary/2 with [:deterministic]).
  # Lists preserve their order (tasks are ordered by position).
  @spec canonical_term(Plan.t()) :: map()
  defp canonical_term(%Plan{} = plan) do
    for field <- @stable_fields,
        value = Map.fetch!(plan, field),
        not is_nil(value),
        into: %{} do
      {Atom.to_string(field), canonicalize_value(field, value)}
    end
  end

  # Tasks need special handling: convert each Task struct to a canonical
  # string-keyed map with nil values dropped.
  defp canonicalize_value(:tasks, tasks) when is_list(tasks) do
    Enum.map(tasks, &canonicalize_task/1)
  end

  # Alternatives, phases, steps are list-of-maps:
  # normalize each map to have string keys with nil values dropped.
  defp canonicalize_value(:alternatives, items) when is_list(items) do
    Enum.map(items, &canonicalize_map/1)
  end

  defp canonicalize_value(:phases, items) when is_list(items) do
    Enum.map(items, &canonicalize_map/1)
  end

  defp canonicalize_value(:steps, items) when is_list(items) do
    Enum.map(items, &canonicalize_map/1)
  end

  # All other stable fields: pass through as-is (strings, integers, lists of strings).
  # These are already in a normalized form from Plan.new/1.
  defp canonicalize_value(_field, value), do: value

  # Convert a Task struct to a canonical string-keyed map.
  # Only include fields with non-nil values to keep the canonical form stable.
  # All atom keys become string keys. The requires_write? / requires_shell?
  # fields are exported as "requires_write" / "requires_shell" (no trailing ?).
  @spec canonicalize_task(Task.t()) :: map()
  defp canonicalize_task(%Task{} = task) do
    task
    |> Task.to_map()
    # to_map already uses atom keys and drops nils; convert to string keys.
    |> stringify_keys()
  end

  # Convert a plain map (from alternatives, phases, etc.) to a canonical
  # string-keyed form with nil values dropped.
  @spec canonicalize_map(map()) :: map()
  defp canonicalize_map(map) when is_map(map) do
    map
    |> stringify_keys()
    |> drop_nil_values()
  end

  # Recursively convert all atom keys to string keys.
  # Does NOT create atoms from string keys — only converts atoms to strings.
  @spec stringify_keys(term()) :: term()
  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    map
    |> Map.new(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
      {k, v} -> {inspect(k), stringify_keys(v)}
    end)
    |> drop_nil_values()
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value

  @spec drop_nil_values(map()) :: map()
  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
