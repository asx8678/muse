defmodule Muse.SessionStore.Jsonl do
  @moduledoc """
  JSONL encoding/decoding helpers for `Muse.SessionStore`.

  Centralizes JSON line serialization, deserialization, encoding
  for storage, and streaming read logic so that SessionStore itself
  stays focused on the persistence API.

  ## Lifecycle

  Called from `SessionStore` for every JSONL file read/write.
  All functions are pure — they accept and return data with no
  side effects beyond the `File` calls in `stream_read_jsonl/1`.
  """

  @doc """
  Parse a list of JSONL lines into a list of decoded maps.

  Invalid lines are counted and skipped. Returns `{valid_entries, skipped_count}`.
  """
  @spec parse_jsonl_lines([String.t()]) :: {[map()], non_neg_integer()}
  def parse_jsonl_lines(lines) when is_list(lines) do
    lines
    |> Enum.reduce({[], 0}, &parse_jsonl_reducer/2)
    |> then(fn {acc, skipped} -> {Enum.reverse(acc), skipped} end)
  end

  @doc """
  Encode a term as a JSONL line (with trailing newline).

  Structs are converted via `encode_for_storage/1` first.
  """
  @spec encode_jsonl_line(term()) :: {:ok, String.t()} | {:error, term()}
  def encode_jsonl_line(data) do
    encoded = encode_for_storage(data)

    case Jason.encode(encoded) do
      {:ok, json} -> {:ok, json <> "\n"}
      error -> error
    end
  end

  @doc """
  Encode a term for storage serialization.

  Structs are converted to maps, atom keys become strings,
  `%DateTime{}` values become ISO8601 strings.
  """
  @spec encode_for_storage(term()) :: term()
  def encode_for_storage(data) when is_struct(data) do
    data
    |> Map.from_struct()
    |> encode_for_storage()
  end

  def encode_for_storage(data) when is_map(data) do
    encode_map(data)
  end

  def encode_for_storage(data), do: data

  @doc """
  Stream-read a JSONL file, yielding decoded maps.

  Invalid lines are silently skipped. Returns a `Stream` that
  can be piped into `Enum.to_list/1` or `Stream.filter/2`, etc.
  """
  @spec stream_read_jsonl(String.t()) :: Enumerable.t()
  def stream_read_jsonl(path) do
    path
    |> File.stream!([], :read_ahead)
    |> Stream.flat_map(fn line ->
      line
      |> String.trim()
      |> case do
        "" ->
          []

        trimmed ->
          case Jason.decode(trimmed) do
            {:ok, decoded} -> [decoded]
            {:error, _} -> []
          end
      end
    end)
  end

  # -- Private helpers ----------------------------------------------------------

  defp parse_jsonl_reducer(line, {acc, skipped}) do
    line = String.trim(line)

    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) ->
        {[decoded | acc], skipped}

      {:ok, _decoded} ->
        {acc, skipped + 1}

      {:error, _} ->
        {acc, skipped + 1}
    end
  end

  defp encode_map(map) do
    Map.new(map, fn {key, value} ->
      {encode_key(key), encode_value(value)}
    end)
  end

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key) when is_binary(key), do: key

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value
end
