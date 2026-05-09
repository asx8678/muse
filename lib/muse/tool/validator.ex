defmodule Muse.Tool.Validator do
  @moduledoc """
  Central validation of tool input arguments before execution.

  Validates tool name, argument map structure, required fields, types,
  path constraints, numeric bounds, and string length limits.

  All validation functions return `:ok` or `{:error, reason}` — never raises.
  The Runner calls `validate_args/2` before dispatching to tool handlers,
  ensuring malformed LLM tool calls never crash the runner.

  ## Validations

    1. Required fields are present and not empty strings
    2. Argument types match the spec's schema (string, integer, boolean, array)
    3. Path arguments: no traversal (`..`), not absolute, bounded length, no null bytes
    4. Numeric arguments: non-negative, bounded range
    5. String arguments: bounded length, no null bytes (path null bytes checked separately)

  ## Design

  The Validator is a first line of defense in the Runner pipeline. Tool
  handlers retain their own internal validation as defense-in-depth.
  Validator errors are structured, bounded, and safe for model consumption
  — they never leak filesystem internals or host details.
  """

  alias Muse.Tool.Spec

  # -- Bounding constants --------------------------------------------------------

  # POSIX PATH_MAX is typically 4096
  @max_path_length 4096
  # Generous string limit; tool-specific limits (e.g. diff size) are
  # enforced inside their handlers
  @max_string_length 1_000_000
  # Reasonable upper bound for count/limit integer arguments
  @max_integer_value 10_000_000

  # Keys that represent filesystem paths and need traversal/absolute/null checks
  @path_keys MapSet.new(["path", "file_path"])

  @doc """
  Validate all tool input arguments against the spec's schema.

  Returns `{:ok, normalized_args}` if all validations pass, or `{:error, reason}`
  with a clear, bounded error message suitable for model consumption.

  The returned `normalized_args` map has string keys and coerced types
  (e.g. whole-number floats like `1.0` are converted to integers `1`).

  ## Validations

    1. Required fields are present and not empty strings
    2. Argument types match the schema (string, integer, boolean, array)
    3. Path arguments: no traversal (`..`), not absolute, bounded length, no null bytes
    4. Numeric arguments: non-negative, bounded range
    5. String arguments: bounded length, no null bytes (path null bytes checked separately)

  ## Examples

      iex> spec = Muse.Tool.Registry.get("read_file")
      iex> {:ok, args} = Muse.Tool.Validator.validate_args(spec, %{"path" => "lib/muse.ex"})
      iex> args["path"]
      "lib/muse.ex"

      iex> spec = Muse.Tool.Registry.get("read_file")
      iex> Muse.Tool.Validator.validate_args(spec, %{})
      {:error, "missing required arguments: path"}

      iex> spec = Muse.Tool.Registry.get("read_file")
      iex> Muse.Tool.Validator.validate_args(spec, %{"path" => 123})
      {:error, "path: expected string, got integer"}
  """
  @spec validate_args(Spec.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def validate_args(%Spec{input_schema: schema}, args) when is_map(args) do
    properties = schema_properties(schema)
    required = schema_required(schema)

    with :ok <- validate_required(required, args),
         {:ok, normalized} <- validate_types_and_constraints(properties, args) do
      {:ok, normalized}
    end
  end

  # -- Required field validation -------------------------------------------------

  defp validate_required(required, args) do
    missing =
      Enum.filter(required, fn key ->
        key_str = to_string(key)

        case lookup_arg(args, key_str) do
          {:ok, value} when value != "" -> false
          _ -> true
        end
      end)

    if missing == [] do
      :ok
    else
      {:error, "missing required arguments: #{Enum.join(Enum.map(missing, &to_string/1), ", ")}"}
    end
  end

  # -- Type and constraint validation -------------------------------------------

  defp validate_types_and_constraints(properties, args) do
    Enum.reduce_while(args, {:ok, args}, fn {key, value}, {:ok, acc} ->
      key_str = to_string(key)
      prop_schema = Map.get(properties, key_str)

      if prop_schema do
        # Skip type validation for nil values on optional fields
        # (required fields already checked; nil on optional fields is absent)
        if value == nil do
          {:cont, {:ok, acc}}
        else
          case validate_and_coerce_single(key_str, value, prop_schema) do
            {:ok, coerced_value} ->
              # Update the normalized args with the coerced value and string key
              new_acc = Map.put(acc, key_str, coerced_value)
              {:cont, {:ok, new_acc}}

            {:error, _} = err ->
              {:halt, err}
          end
        end
      else
        # Allow extra args not in schema (forward compatibility)
        # Normalize key to string
        new_acc = Map.put(acc, key_str, value)
        {:cont, {:ok, new_acc}}
      end
    end)
  end

  defp validate_and_coerce_single(key, value, prop_schema) do
    expected_type = schema_prop_type(prop_schema)

    with {:ok, coerced} <- validate_type(key, value, expected_type),
         :ok <- validate_path_constraints(key, coerced, expected_type),
         :ok <- validate_numeric_constraints(key, coerced, expected_type),
         :ok <- validate_string_constraints(key, coerced, expected_type) do
      {:ok, coerced}
    end
  end

  # -- Type validation -----------------------------------------------------------

  # Returns {:ok, coerced_value} or {:error, msg}.
  # Coerces whole-number floats to integers for LLM provider compatibility.

  defp validate_type(_key, value, nil), do: {:ok, value}

  defp validate_type(_key, value, "string") when is_binary(value), do: {:ok, value}

  defp validate_type(key, value, "string"),
    do: {:error, "#{key}: expected string, got #{type_name(value)}"}

  defp validate_type(_key, value, "integer") when is_integer(value), do: {:ok, value}

  # LLM providers sometimes send 1.0 instead of 1 — accept and coerce
  defp validate_type(key, value, "integer") when is_float(value) do
    if value == trunc(value) do
      {:ok, trunc(value)}
    else
      {:error, "#{key}: expected integer, got float #{value}"}
    end
  end

  defp validate_type(key, value, "integer"),
    do: {:error, "#{key}: expected integer, got #{type_name(value)}"}

  defp validate_type(_key, value, "boolean") when is_boolean(value), do: {:ok, value}

  defp validate_type(key, value, "boolean"),
    do: {:error, "#{key}: expected boolean, got #{type_name(value)}"}

  defp validate_type(_key, value, "array") when is_list(value), do: {:ok, value}

  defp validate_type(key, value, "array"),
    do: {:error, "#{key}: expected array, got #{type_name(value)}"}

  defp validate_type(_key, value, "object") when is_map(value), do: {:ok, value}

  defp validate_type(key, value, "object"),
    do: {:error, "#{key}: expected object, got #{type_name(value)}"}

  # Unknown type in schema — allow through
  defp validate_type(_key, value, _unknown_type), do: {:ok, value}

  # -- Path constraints ----------------------------------------------------------

  # Only validate path constraints for string-typed arguments whose key
  # is a known path key ("path", "file_path").
  defp validate_path_constraints(key, value, "string") when is_binary(value) do
    if MapSet.member?(@path_keys, key) do
      with :ok <- check_path_not_absolute(key, value),
           :ok <- check_path_no_traversal(key, value),
           :ok <- check_path_no_null_bytes(key, value),
           :ok <- check_path_length(key, value) do
        :ok
      end
    else
      :ok
    end
  end

  defp validate_path_constraints(_key, _value, _type), do: :ok

  defp check_path_not_absolute(key, path) do
    if Path.type(path) == :absolute do
      {:error, "#{key}: absolute paths are not allowed"}
    else
      :ok
    end
  end

  defp check_path_no_traversal(key, path) do
    if path_contains_traversal?(path) do
      {:error, "#{key}: path traversal (..) is not allowed"}
    else
      :ok
    end
  end

  defp check_path_no_null_bytes(key, path) do
    if String.contains?(path, "\0") do
      {:error, "#{key}: path contains null bytes"}
    else
      :ok
    end
  end

  defp check_path_length(key, path) do
    if String.length(path) > @max_path_length do
      {:error, "#{key}: path exceeds maximum length of #{@max_path_length}"}
    else
      :ok
    end
  end

  defp path_contains_traversal?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  # -- Numeric constraints -------------------------------------------------------

  defp validate_numeric_constraints(key, value, "integer") when is_integer(value) do
    cond do
      value < 0 ->
        {:error, "#{key}: value must be non-negative (got #{value})"}

      value > @max_integer_value ->
        {:error, "#{key}: value exceeds maximum of #{@max_integer_value}"}

      true ->
        :ok
    end
  end

  # Accept whole-number floats that were promoted to integer type
  defp validate_numeric_constraints(key, value, "integer") when is_float(value) do
    validate_numeric_constraints(key, trunc(value), "integer")
  end

  defp validate_numeric_constraints(_key, _value, _type), do: :ok

  # -- String constraints --------------------------------------------------------

  # Null bytes in strings are rejected. Path strings already have their own
  # null-byte check in `validate_path_constraints`; for non-path strings we
  # check here.
  defp validate_string_constraints(key, value, "string") when is_binary(value) do
    if not MapSet.member?(@path_keys, key) and String.contains?(value, "\0") do
      {:error, "#{key}: string contains null bytes"}
    else
      if byte_size(value) > @max_string_length do
        {:error, "#{key}: string exceeds maximum length of #{@max_string_length} bytes"}
      else
        :ok
      end
    end
  end

  defp validate_string_constraints(_key, _value, _type), do: :ok

  # -- Schema helpers ------------------------------------------------------------

  defp schema_properties(schema) do
    raw = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}
    # Normalize atom keys to string keys for consistent lookup
    Map.new(raw, fn {k, v} -> {to_string(k), v} end)
  end

  defp schema_required(schema) do
    Map.get(schema, "required") || Map.get(schema, :required) || []
  end

  defp schema_prop_type(prop) do
    Map.get(prop, "type") || Map.get(prop, :type)
  end

  # -- Type naming (for error messages) -----------------------------------------

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(value) when is_nil(value), do: "null"
  defp type_name(_), do: "unknown"

  # -- Arg lookup (handles both string and atom keys) --------------------------

  defp lookup_arg(args, key_str) when is_map(args) do
    case Map.get(args, key_str) do
      nil ->
        # Try atom key as fallback (internal callers may use atom keys)
        try do
          atom_key = String.to_existing_atom(key_str)

          case Map.get(args, atom_key) do
            nil -> :error
            value -> {:ok, value}
          end
        rescue
          ArgumentError -> :error
        end

      value ->
        {:ok, value}
    end
  end
end
