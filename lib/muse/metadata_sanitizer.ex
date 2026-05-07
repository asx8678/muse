defmodule Muse.MetadataSanitizer do
  @moduledoc """
  Shared sanitizer for metadata maps across the Muse system.

  Converts arbitrary terms to safe, bounded, JSON-compatible values:

    * **Depth limiting** — prevents runaway nesting from OOM or stack overflow.
    * **Size bounding** — caps map keys, list length, and string size.
    * **Key redaction** — sensitive keys (tokens, passwords, etc.) are replaced
      with a redacted placeholder, case-insensitive for both atom and string keys.
    * **Term normalization** — atoms, pids, refs, and functions are converted to
      safe strings; tuples become lists; unknown terms are inspect-stringed.

  ## Usage

      iex> Muse.MetadataSanitizer.sanitize(%{api_key: "shhh", count: 3})
      %{api_key: "**REDACTED**", count: 3}

      iex> Muse.MetadataSanitizer.sanitize(%{"Password" => "hunter2"})
      %{"Password" => "**REDACTED**"}

  Options (all have sensible defaults):

    * `:max_depth`        — nesting limit (default 3)
    * `:max_map_keys`    — max keys per map (default 20)
    * `:max_list_length` — max items per list (default 10)
    * `:max_string_len`  — max chars per string (default 500)
  """

  @redacted "**REDACTED**"

  # Case-insensitive patterns for sensitive key names.
  @sensitive_patterns ~w(
    token secret password authorization cookie api_key csrf_token
    access_key private_key auth_key session_key refresh_token id_token
    access_token bearer credential credential_ref
  )

  @default_max_depth 3
  @default_max_map_keys 20
  @default_max_list_length 10
  @default_max_string_len 500

  @doc """
  Sanitizes an arbitrary term into a safe, bounded, JSON-compatible value.

  Maps are walked recursively with depth tracking; sensitive keys have their
  values replaced with `"**REDACTED**"`.  Atoms, pids, refs, and functions are
  converted to strings.  Tuples become lists.  When depth exceeds the limit the
  remainder is converted to a truncated inspect string.
  """
  @spec sanitize(term(), keyword()) :: term()
  def sanitize(term, opts \\ []) do
    walk(term, 0, opts)
  end

  # -- Dispatch by depth then type ----------------------------------------------

  defp walk(term, depth, opts) do
    if depth > max_depth(opts) do
      trunc_inspect(term, max_string_len(opts))
    else
      walk_by_type(term, depth, opts)
    end
  end

  # -- Maps ---------------------------------------------------------------------

  # Keys are preserved as-is (atom stays atom, string stays string) so that
  # downstream code can still access by the original key type.  We only *check*
  # keys for sensitivity — we never transform them.

  defp walk_by_type(map, depth, opts) when is_map(map) and not is_struct(map) do
    max_keys = max_map_keys(opts)
    next = depth + 1

    map
    |> Enum.take(max_keys)
    |> Enum.into(%{}, fn {k, v} ->
      {k, map_value(k, v, next, opts)}
    end)
  end

  defp walk_by_type(%_{} = struct, depth, opts) do
    next = depth + 1

    struct
    |> Map.from_struct()
    |> Enum.take(max_map_keys(opts))
    |> Enum.into(%{}, fn {k, v} ->
      {k, map_value(k, v, next, opts)}
    end)
    |> Map.put("__struct__", struct.__struct__)
  end

  # -- Lists --------------------------------------------------------------------

  defp walk_by_type(list, depth, opts) when is_list(list) do
    list
    |> Enum.take(max_list_length(opts))
    |> Enum.map(&walk(&1, depth + 1, opts))
  end

  # -- Tuples -------------------------------------------------------------------

  defp walk_by_type(tuple, depth, opts) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.take(max_list_length(opts))
    |> Enum.map(&walk(&1, depth + 1, opts))
  end

  # -- Primitives ---------------------------------------------------------------

  defp walk_by_type(binary, _depth, opts) when is_binary(binary) do
    trunc_string(binary, max_string_len(opts))
  end

  defp walk_by_type(atom, _depth, _opts) when is_atom(atom) do
    # nil, true, false are valid JSON — keep them.
    if atom in [nil, true, false], do: atom, else: Atom.to_string(atom)
  end

  defp walk_by_type(number, _depth, _opts) when is_number(number), do: number
  defp walk_by_type(bool, _depth, _opts) when is_boolean(bool), do: bool

  # -- Special terms -------------------------------------------------------------

  defp walk_by_type(pid, _depth, _opts) when is_pid(pid), do: inspect(pid)
  defp walk_by_type(ref, _depth, _opts) when is_reference(ref), do: inspect(ref)
  defp walk_by_type(fun, _depth, _opts) when is_function(fun), do: inspect(fun)

  # -- Fallback ------------------------------------------------------------------

  defp walk_by_type(term, _depth, opts) do
    trunc_inspect(term, max_string_len(opts))
  end

  # -- Map value redaction -------------------------------------------------------

  defp map_value(key, value, depth, opts) do
    if sensitive_key?(key) do
      @redacted
    else
      walk(value, depth, opts)
    end
  end

  # -- Redaction -----------------------------------------------------------------

  @doc """
  Returns `true` if the key (atom or string) matches a sensitive pattern,
  case-insensitive.
  """
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  def sensitive_key?(key) when is_binary(key) do
    # Normalize hyphens to underscores so "x-api-key" matches "api_key".
    normalized = key |> String.downcase() |> String.replace("-", "_")
    Enum.any?(@sensitive_patterns, &String.contains?(normalized, &1))
  end

  def sensitive_key?(_key), do: false

  # -- Truncation helpers --------------------------------------------------------

  defp trunc_string(str, max) do
    if byte_size(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end

  defp trunc_inspect(term, max) do
    term
    |> inspect(limit: 10, printable_limit: max)
    |> trunc_string(max)
  end

  # -- Option readers -------------------------------------------------------------

  defp max_depth(opts), do: Keyword.get(opts, :max_depth, @default_max_depth)
  defp max_map_keys(opts), do: Keyword.get(opts, :max_map_keys, @default_max_map_keys)
  defp max_list_length(opts), do: Keyword.get(opts, :max_list_length, @default_max_list_length)
  defp max_string_len(opts), do: Keyword.get(opts, :max_string_len, @default_max_string_len)
end
