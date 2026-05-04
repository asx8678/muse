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
              requires_write: %{type: "boolean", default: false},
              requires_shell: %{type: "boolean", default: false},
              verification: %{type: "string"},
              recommended_muse: %{type: "string"}
            }
          }
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
    - Defaulting `requires_write` and `requires_shell` to `false` on each task
    - Defaulting `risks` to `[]`
    - Defaulting empty optional list fields to `[]`

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

    errors = validate_objective(data, errors)
    errors = validate_tasks(data, errors)
    errors = validate_risks(data, errors)

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

  # -- Normalization ------------------------------------------------------------

  defp normalize(data) do
    data
    |> normalize_tasks()
    |> normalize_risks()
    |> normalize_optional_lists()
  end

  defp normalize_tasks(data) do
    # Handle both string-key "tasks" and atom-key :tasks input.
    # After normalization, tasks are always stored under "tasks" (string key)
    # so downstream consumers (Plan.from_map/1) consistently find them.
    tasks =
      case Map.fetch(data, "tasks") do
        {:ok, tasks} -> tasks
        :error -> Map.get(data, :tasks, [])
      end

    normalized_tasks =
      Enum.map(tasks || [], fn task ->
        task
        |> Map.put_new("requires_write", false)
        |> Map.put_new("requires_shell", false)
      end)

    Map.put(data, "tasks", normalized_tasks)
  end

  defp normalize_risks(data) do
    Map.put_new(data, "risks", [])
  end

  @optional_list_fields [
    "alternatives",
    "validation",
    "inspected_files",
    "likely_changed_files",
    "files_expected",
    "commands_expected"
  ]

  defp normalize_optional_lists(data) do
    Enum.reduce(@optional_list_fields, data, fn field, acc ->
      Map.put_new(acc, field, [])
    end)
  end
end
