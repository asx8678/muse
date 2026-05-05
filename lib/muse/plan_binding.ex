defmodule Muse.PlanBinding do
  @moduledoc """
  Deterministic content-binding helpers for plan approvals.

  Provides a canonical hash over stable plan content and a binding map that
  captures the essential identity of a plan at approval time.

  ## Design principles

    * **Stable content only** — volatile timestamps, lifecycle status, prior
      approval records, and secret-bearing metadata are excluded from the hash
      so it reflects *what* the plan says, not *when* it was approved or *who*
      approved it.

    * **Deterministic ordering** — all keys are normalized to strings and sorted
      alphabetically at every nesting level before hashing, ensuring identical
      content always produces the same hash.

    * **No dynamic atoms** — unknown string keys from JSON or LLM output never
      create atoms; all canonicalization uses string keys exclusively.
  """

  alias Muse.{Plan, Task}

  @binding_kind "plan_approval"

  # Stable fields included in the content hash. Keep ordered alphabetically.
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

  @doc "Return the stable field names included in the content hash."
  @spec stable_fields() :: [atom()]
  def stable_fields, do: @stable_fields

  @doc """
  Compute a deterministic SHA-256 hash over the stable content of a plan.

  Volatile timestamps, lifecycle status, approval records, `metadata`,
  `created_by`, `summary`, and operational `agent_assignments` are excluded.
  Content-bearing fields such as id, session id, version, objective, tasks,
  risks, expected files/commands, and validation steps are included.
  """
  @spec content_hash(Plan.t()) :: String.t()
  def content_hash(%Plan{} = plan) do
    plan
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Return a binding map for plan approvals.

  The binding captures plan/session identity, version, stable content hash, and
  workspace (when available). It is safe to include in status output and session
  snapshots; it contains no raw plan JSON.
  """
  @spec approval_binding(Plan.t(), keyword()) :: map()
  def approval_binding(%Plan{} = plan, opts \\ []) do
    %{
      kind: @binding_kind,
      session_id: plan.session_id,
      plan_id: plan.id,
      plan_version: plan.version,
      plan_hash: content_hash(plan),
      content_hash: content_hash(plan),
      workspace: Keyword.get(opts, :workspace)
    }
  end

  @doc "Return the canonical binding kind string."
  @spec binding_kind() :: String.t()
  def binding_kind, do: @binding_kind

  @spec canonical_term(Plan.t()) :: map()
  defp canonical_term(%Plan{} = plan) do
    for field <- @stable_fields,
        value = Map.fetch!(plan, field),
        not is_nil(value),
        into: %{} do
      {Atom.to_string(field), canonicalize_value(field, value)}
    end
  end

  defp canonicalize_value(:tasks, tasks) when is_list(tasks) do
    Enum.map(tasks, &canonicalize_task/1)
  end

  defp canonicalize_value(field, items)
       when field in [:alternatives, :phases, :steps] and is_list(items) do
    Enum.map(items, &canonicalize_map/1)
  end

  defp canonicalize_value(_field, value), do: stringify_keys(value)

  @spec canonicalize_task(Task.t() | map()) :: map()
  defp canonicalize_task(%Task{} = task) do
    task
    |> Task.to_map()
    |> stringify_keys()
  end

  defp canonicalize_task(task) when is_map(task), do: stringify_keys(task)
  defp canonicalize_task(other), do: stringify_keys(other)

  @spec canonicalize_map(map()) :: map()
  defp canonicalize_map(map) when is_map(map) do
    map
    |> stringify_keys()
    |> drop_nil_values()
  end

  defp canonicalize_map(other), do: stringify_keys(other)

  @spec stringify_keys(term()) :: term()
  defp stringify_keys(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp stringify_keys(%Date{} = date), do: Date.to_iso8601(date)
  defp stringify_keys(%Time{} = time), do: Time.to_iso8601(time)
  defp stringify_keys(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp stringify_keys(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Map.new(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
      {k, v} -> {inspect(k), stringify_keys(v)}
    end)
    |> drop_nil_values()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> stringify_keys()

  defp stringify_keys(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify_keys(value), do: value

  @spec drop_nil_values(map()) :: map()
  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
