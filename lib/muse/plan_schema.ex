defmodule Muse.PlanSchema do
  @moduledoc """
  Structured plan JSON schema definition and validation.

  This module defines the expected shape of a decoded plan JSON object
  and provides `validate/1` to check that a plain map conforms to the
  schema before it is promoted to a `%Muse.Plan{}` struct.

  ## Required fields

    * `objective` — must be a non-empty string
    * `tasks`     — must be a non-empty list of task maps
    * Each task must have `title` (string) and `description` (string)

  ## Boolean fields

    * `requires_write` and `requires_shell` must be booleans when present;
      they default to `false` when absent.

  ## List fields

    * `risks` must be a list when present.

  ## Schema

      iex> Muse.PlanSchema.schema() |> Map.get(:type)
      "object"

  """

  @default_schema_version "planning.v1"

  @doc """
  Return the suggested structured plan JSON schema as a map.

  This is a descriptive schema suitable for documentation, LLM tool
  definitions, or future JSON Schema validation.
  """
  @spec schema() :: map()
  def schema do
    %{
      type: "object",
      required: ["objective", "tasks"],
      properties: %{
        schema_version: %{
          type: "string",
          default: @default_schema_version,
          description: "Structured plan schema version. Defaults to planning.v1 when omitted."
        },
        objective: %{
          type: "string",
          description: "One-sentence goal of the plan."
        },
        summary: %{
          type: "string",
          description: "Longer summary of the plan."
        },
        tasks: %{
          type: "array",
          minItems: 1,
          items: %{
            type: "object",
            required: ["title", "description"],
            properties: %{
              title: %{type: "string"},
              description: %{type: "string"},
              target_files: %{type: "array", items: %{type: "string"}},
              phase: %{type: "string"},
              required_permissions: %{type: "array", items: %{type: "string"}},
              requires_write: %{type: "boolean", default: false},
              requires_shell: %{type: "boolean", default: false},
              verification: %{type: "string"},
              recommended_muse: %{type: "string"}
            }
          }
        },
        assumptions: %{
          type: "array",
          items: %{type: "string"}
        },
        required_permissions: %{
          type: "array",
          items: %{type: "string"}
        },
        agent_assignments: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              agent: %{type: "string"},
              task_ids: %{type: "array", items: %{type: "string"}},
              notes: %{type: "string"}
            }
          }
        },
        phases: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              id: %{type: "string"},
              title: %{type: "string"},
              description: %{type: "string"},
              task_ids: %{type: "array", items: %{type: "string"}}
            }
          }
        },
        metadata: %{
          type: "object",
          additionalProperties: true
        },
        risks: %{
          type: "array",
          items: %{type: "string"}
        },
        alternatives: %{
          type: "array",
          items: %{type: "object"}
        },
        validation: %{
          type: "array",
          items: %{type: "string"}
        },
        inspected_files: %{
          type: "array",
          items: %{type: "string"}
        },
        likely_changed_files: %{
          type: "array",
          items: %{type: "string"}
        }
      }
    }
  end

  @doc """
  Validate a decoded plan map against the structured plan schema.

  Returns `{:ok, normalized_map}` with defaults applied when valid, or
  `{:error, errors}` with a list of error strings when invalid.

  Normalization includes:
    - Defaulting `schema_version` to `"planning.v1"`
    - Defaulting `requires_write` and `requires_shell` to `false` on each task
    - Defaulting `risks`, `assumptions`, `required_permissions`,
      `agent_assignments`, `phases`, and other optional list fields to `[]`
    - Sanitizing `metadata` to a bounded JSON-compatible map

  ## Examples

      iex> {:ok, plan} = Muse.PlanSchema.validate(%{"objective" => "Fix bug", "tasks" => [%{"title" => "T1", "description" => "D1"}]})
      iex> plan["tasks"] |> hd() |> Map.get("requires_write")
      false

      iex> Muse.PlanSchema.validate(%{"tasks" => []})
      {:error, ["objective is required", "tasks must be non-empty"]}

  """
  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(data) when is_map(data) do
    errors = []

    errors = validate_schema_version(data, errors)
    errors = validate_objective(data, errors)
    errors = validate_tasks(data, errors)
    errors = validate_risks(data, errors)
    errors = validate_string_list_field(data, "assumptions", errors)
    errors = validate_string_list_field(data, "required_permissions", errors)
    errors = validate_map_list_field(data, "agent_assignments", errors)
    errors = validate_map_list_field(data, "phases", errors)
    errors = validate_metadata(data, errors)

    if errors == [] do
      {:ok, normalize(data)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(_data) do
    {:error, ["plan must be a map"]}
  end

  # -- Field validators ---------------------------------------------------------

  # Fetch a value by checking both string and atom key forms.
  # Uses Map.fetch for the primary key to preserve false/nil distinction.
  defp fetch_any_key(data, key) when is_binary(key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(key)
        Map.get(data, atom_key)
    end
  rescue
    ArgumentError -> nil
  end

  defp validate_schema_version(data, errors) do
    case fetch_any_key(data, "schema_version") do
      nil ->
        errors

      version when is_binary(version) ->
        validate_non_empty_string(version, "schema_version", errors)

      _version ->
        [~s(schema_version must be a string) | errors]
    end
  end

  defp validate_non_empty_string(value, field, errors) do
    if String.trim(value) == "" do
      [~s(#{field} must be non-empty) | errors]
    else
      errors
    end
  end

  defp validate_objective(data, errors) do
    case fetch_any_key(data, "objective") do
      nil -> [~s(objective is required) | errors]
      obj when not is_binary(obj) -> [~s(objective must be a string) | errors]
      "" -> [~s(objective must be non-empty) | errors]
      _ -> errors
    end
  end

  defp validate_tasks(data, errors) do
    tasks = fetch_any_key(data, "tasks")

    cond do
      is_nil(tasks) ->
        [~s(tasks is required) | errors]

      not is_list(tasks) ->
        [~s(tasks must be a list) | errors]

      tasks == [] ->
        [~s(tasks must be non-empty) | errors]

      true ->
        task_errors = validate_each_task(tasks, 0, [])

        if task_errors == [] do
          errors
        else
          [Enum.join(task_errors, "; ") | errors]
        end
    end
  end

  defp validate_each_task([], _idx, errors), do: Enum.reverse(errors)

  defp validate_each_task([task | rest], idx, errors) when is_map(task) do
    task_errors = validate_task(task, idx)
    validate_each_task(rest, idx + 1, task_errors ++ errors)
  end

  defp validate_each_task([_task | rest], idx, errors) do
    validate_each_task(rest, idx + 1, ["task[#{idx}] must be a map" | errors])
  end

  defp validate_task(task, idx) do
    errors = []

    # title — use fetch_any_key to handle string/atom keys
    errors =
      case fetch_any_key(task, "title") do
        nil -> ["task[#{idx}]: title is required" | errors]
        t when not is_binary(t) -> ["task[#{idx}]: title must be a string" | errors]
        "" -> ["task[#{idx}]: title must be non-empty" | errors]
        _ -> errors
      end

    # description
    errors =
      case fetch_any_key(task, "description") do
        nil -> ["task[#{idx}]: description is required" | errors]
        d when not is_binary(d) -> ["task[#{idx}]: description must be a string" | errors]
        "" -> ["task[#{idx}]: description must be non-empty" | errors]
        _ -> errors
      end

    # requires_write — use fetch_bool that preserves false
    errors =
      case fetch_any_key(task, "requires_write") do
        nil -> errors
        rw when not is_boolean(rw) -> ["task[#{idx}]: requires_write must be a boolean" | errors]
        _ -> errors
      end

    # requires_shell
    errors =
      case fetch_any_key(task, "requires_shell") do
        nil -> errors
        rs when not is_boolean(rs) -> ["task[#{idx}]: requires_shell must be a boolean" | errors]
        _ -> errors
      end

    errors = validate_task_string_field(task, idx, "phase", errors)
    errors = validate_task_string_list_field(task, idx, "required_permissions", errors)

    Enum.reverse(errors)
  end

  defp validate_risks(data, errors) do
    case fetch_any_key(data, "risks") do
      nil ->
        errors

      risks when not is_list(risks) ->
        [~s(risks must be a list) | errors]

      risks ->
        risk_errors =
          risks
          |> Enum.with_index()
          |> Enum.flat_map(fn
            {risk, _idx} when is_binary(risk) -> []
            {_risk, idx} -> ["risk[#{idx}] must be a string"]
          end)

        if risk_errors == [] do
          errors
        else
          [Enum.join(risk_errors, "; ") | errors]
        end
    end
  end

  defp validate_string_list_field(data, field, errors) do
    case fetch_any_key(data, field) do
      nil ->
        errors

      values when is_list(values) ->
        validate_string_list_items(values, field, errors)

      _values ->
        [~s(#{field} must be a list) | errors]
    end
  end

  defp validate_string_list_items(values, field, errors) do
    item_errors =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {value, _idx} when is_binary(value) -> []
        {_value, idx} -> [~s(#{field}[#{idx}] must be a string)]
      end)

    case item_errors do
      [] -> errors
      _ -> [Enum.join(item_errors, "; ") | errors]
    end
  end

  defp validate_map_list_field(data, field, errors) do
    case fetch_any_key(data, field) do
      nil ->
        errors

      values when is_list(values) ->
        validate_map_list_items(values, field, errors)

      _values ->
        [~s(#{field} must be a list) | errors]
    end
  end

  defp validate_map_list_items(values, field, errors) do
    item_errors =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {value, _idx} when is_map(value) -> []
        {_value, idx} -> [~s(#{field}[#{idx}] must be a map)]
      end)

    case item_errors do
      [] -> errors
      _ -> [Enum.join(item_errors, "; ") | errors]
    end
  end

  defp validate_metadata(data, errors) do
    case fetch_any_key(data, "metadata") do
      nil -> errors
      metadata when is_map(metadata) -> errors
      _metadata -> [~s(metadata must be a map) | errors]
    end
  end

  defp validate_task_string_field(task, idx, field, errors) do
    case fetch_any_key(task, field) do
      nil -> errors
      value when is_binary(value) -> errors
      _value -> [~s(task[#{idx}]: #{field} must be a string) | errors]
    end
  end

  defp validate_task_string_list_field(task, idx, field, errors) do
    case fetch_any_key(task, field) do
      nil ->
        errors

      values when is_list(values) ->
        item_errors =
          values
          |> Enum.with_index()
          |> Enum.flat_map(fn
            {value, _item_idx} when is_binary(value) -> []
            {_value, item_idx} -> [~s(task[#{idx}]: #{field}[#{item_idx}] must be a string)]
          end)

        case item_errors do
          [] -> errors
          _ -> [Enum.join(item_errors, "; ") | errors]
        end

      _values ->
        [~s(task[#{idx}]: #{field} must be a list) | errors]
    end
  end

  # -- Normalization ------------------------------------------------------------

  @doc """
  Normalize a decoded plan map by applying defaults and safe metadata filtering.

  This function does not validate the input shape; callers that need validation
  should use `validate/1`, which calls `normalize/1` only after all validation
  checks pass.
  """
  @spec normalize(map()) :: map()
  def normalize(data) when is_map(data) do
    data
    |> put_default_any_key("schema_version", @default_schema_version)
    |> normalize_tasks()
    |> normalize_risks()
    |> normalize_optional_lists()
    |> normalize_metadata_field()
  end

  defp normalize_tasks(data) do
    # Handle both string-key "tasks" and atom-key :tasks input.
    # After normalization, tasks are always stored under "tasks" (string key)
    # so downstream consumers (Plan.from_map/1) consistently find them.
    tasks = fetch_any_key(data, "tasks") || []

    normalized_tasks =
      Enum.map(tasks, fn task ->
        task
        |> put_default_any_key("requires_write", false)
        |> put_default_any_key("requires_shell", false)
        |> put_default_any_key("required_permissions", [])
      end)

    data
    |> delete_atom_key("tasks")
    |> Map.put("tasks", normalized_tasks)
  end

  defp normalize_risks(data) do
    put_default_any_key(data, "risks", [])
  end

  @optional_list_fields [
    "alternatives",
    "validation",
    "inspected_files",
    "likely_changed_files",
    "files_expected",
    "commands_expected",
    "assumptions",
    "required_permissions",
    "agent_assignments",
    "phases"
  ]

  defp normalize_optional_lists(data) do
    Enum.reduce(@optional_list_fields, data, fn field, acc ->
      put_default_any_key(acc, field, [])
    end)
  end

  defp normalize_metadata_field(data) do
    metadata = fetch_any_key(data, "metadata") || %{}

    data
    |> delete_atom_key("metadata")
    |> Map.put("metadata", normalize_metadata(metadata))
  end

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

  defp put_default_any_key(data, field, default) do
    value = fetch_any_key(data, field)

    data
    |> delete_atom_key(field)
    |> Map.put(field, if(is_nil(value), do: default, else: value))
  end

  defp delete_atom_key(data, field) do
    atom_key =
      try do
        String.to_existing_atom(field)
      rescue
        ArgumentError -> nil
      end

    if atom_key, do: Map.delete(data, atom_key), else: data
  end
end
