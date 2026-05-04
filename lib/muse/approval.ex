defmodule Muse.Approval do
  @moduledoc """
  Security helpers for approval records and approval event payloads.

  This module intentionally does **not** grant runtime authority. Approval
  checks remain owned by the runtime/session/tool gate that is about to perform
  an action. The helpers here only make approval audit data safe to persist or
  emit:

    * reasons and metadata are recursively redacted with `Muse.EventPayloadRedactor`
    * raw plan JSON, raw file contents, patches, and diffs are replaced by
      content references
    * content references include a SHA-256 hash and byte size without storing
      the raw content in events

  Future approval gates can use these helpers to bind an approval to reviewed
  content while keeping event logs and persisted approval maps free of raw
  payloads and secret-like values.
  """

  @raw_content_keys ~w(
    content
    diff
    file_content
    file_contents
    patch
    plan
    plan_json
    raw_content
    raw_file
    raw_file_content
    raw_file_contents
    raw_json
    raw_plan
    raw_plan_json
  )

  @type content_ref :: %{
          label: String.t(),
          algorithm: String.t(),
          hash: String.t(),
          bytes: non_neg_integer()
        }

  @doc """
  Build a redacted, event-safe approval payload.

  Any raw-content keys are removed and summarized under `:content_refs`.
  Non-raw fields such as `:reason` and `:metadata` are recursively redacted.
  """
  @spec event_payload(map() | keyword()) :: map()
  def event_payload(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> event_payload()
  end

  def event_payload(attrs) when is_map(attrs) do
    {payload, content_refs} = strip_raw_content(attrs)

    payload
    |> Muse.EventPayloadRedactor.redact()
    |> put_content_refs(content_refs)
  end

  @doc """
  Return a redacted approval record suitable for persistence.

  This is currently equivalent to `event_payload/1`; it is named separately so
  future persistence rules can evolve without changing callers.
  """
  @spec safe_record(map() | keyword()) :: map()
  def safe_record(attrs), do: event_payload(attrs)

  @doc """
  Compute a stable SHA-256 content hash for approval binding.

  The returned value is only the lowercase hex digest. Callers should store this
  hash (or `content_ref/2`), not the raw plan JSON/file contents, in approval
  events.
  """
  @spec content_hash(term()) :: String.t()
  def content_hash(content) do
    content
    |> canonical_binary()
    |> sha256()
  end

  @doc """
  Build a content reference containing hash metadata but no raw content.
  """
  @spec content_ref(atom() | String.t(), term()) :: content_ref()
  def content_ref(label, content) do
    canonical = canonical_binary(content)

    %{
      label: to_string(label),
      algorithm: "sha256",
      hash: sha256(canonical),
      bytes: byte_size(canonical)
    }
  end

  defp strip_raw_content(map) when is_map(map) do
    map
    |> Enum.reduce({%{}, []}, fn {key, value}, {acc, refs} ->
      if raw_content_key?(key) do
        {acc, refs ++ [content_ref(key, value)]}
      else
        {safe_value, nested_refs} = strip_raw_value(value)
        {Map.put(acc, key, safe_value), refs ++ nested_refs}
      end
    end)
  end

  defp strip_raw_value(value) when is_map(value) and not is_struct(value) do
    strip_raw_content(value)
  end

  defp strip_raw_value(value) when is_list(value) do
    {values, refs} =
      Enum.reduce(value, {[], []}, fn item, {items, refs} ->
        {safe_item, nested_refs} = strip_raw_value(item)
        {[safe_item | items], refs ++ nested_refs}
      end)

    {Enum.reverse(values), refs}
  end

  defp strip_raw_value(value) when is_tuple(value) do
    {values, refs} =
      value
      |> Tuple.to_list()
      |> Enum.reduce({[], []}, fn item, {items, refs} ->
        {safe_item, nested_refs} = strip_raw_value(item)
        {[safe_item | items], refs ++ nested_refs}
      end)

    {values |> Enum.reverse() |> List.to_tuple(), refs}
  end

  defp strip_raw_value(value), do: {value, []}

  defp raw_content_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace("-", "_")
    |> then(&(&1 in @raw_content_keys))
  end

  defp put_content_refs(payload, []), do: payload
  defp put_content_refs(payload, refs), do: Map.put(payload, :content_refs, refs)

  defp sha256(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp canonical_binary(content) do
    content
    |> normalize_for_hash()
    |> Jason.encode!()
  rescue
    _ -> inspect(content, limit: :infinity, printable_limit: :infinity)
  end

  defp normalize_for_hash(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_for_hash(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_for_hash(%Time{} = time), do: Time.to_iso8601(time)
  defp normalize_for_hash(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp normalize_for_hash(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, inspect(struct.__struct__))
    |> normalize_for_hash()
  end

  defp normalize_for_hash(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      [normalize_hash_key(key), normalize_for_hash(value)]
    end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp normalize_for_hash(list) when is_list(list) do
    Enum.map(list, &normalize_for_hash/1)
  end

  defp normalize_for_hash(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_for_hash/1)
  end

  defp normalize_for_hash(nil), do: nil
  defp normalize_for_hash(bool) when is_boolean(bool), do: bool
  defp normalize_for_hash(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_for_hash(binary) when is_binary(binary), do: binary
  defp normalize_for_hash(number) when is_number(number), do: number
  defp normalize_for_hash(pid) when is_pid(pid), do: inspect(pid)
  defp normalize_for_hash(ref) when is_reference(ref), do: inspect(ref)
  defp normalize_for_hash(fun) when is_function(fun), do: inspect(fun)
  defp normalize_for_hash(other), do: inspect(other, limit: :infinity, printable_limit: :infinity)

  defp normalize_hash_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_hash_key(key) when is_binary(key), do: key
  defp normalize_hash_key(key), do: inspect(key, printable_limit: 100)
end
