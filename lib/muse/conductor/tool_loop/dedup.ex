defmodule Muse.Conductor.ToolLoop.Dedup do
  @moduledoc """
  Tool call deduplication and caching for `Muse.Conductor.ToolLoop`.

  When a single provider response contains duplicate tool calls
  (same name + same arguments), executing them twice is wasteful.
  This module deduplicates within a single iteration using a
  turn-scoped content-addressed cache.

  ## Lifecycle

  Called from `ToolLoop.execute_tool_calls/4` before dispatching
  tool calls to the runner. All functions are pure.
  """

  @doc """
  Deduplicate tool calls within a single iteration.

  Returns `{unique_calls, duplicate_calls}` where:
  - `unique_calls` — first occurrence of each distinct call (to execute)
  - `duplicate_calls` — subsequent duplicates (to serve from cache)
  """
  @spec dedup_within_iteration([map()]) :: {[map()], [map()]}
  def dedup_within_iteration(calls) do
    {unique, dups, _seen} =
      Enum.reduce(calls, {[], [], MapSet.new()}, fn tc, {uniq, dups, seen} ->
        key = cache_key(tc)

        if MapSet.member?(seen, key) do
          {uniq, [tc | dups], seen}
        else
          {[tc | uniq], dups, MapSet.put(seen, key)}
        end
      end)

    {Enum.reverse(unique), Enum.reverse(dups)}
  end

  @doc """
  Compute a content-addressed cache key for a tool call.

  Returns a `{tool_name, args_fingerprint}` tuple.
  """
  @spec cache_key(map()) :: {String.t(), String.t()}
  def cache_key(%{name: name, arguments: args}) do
    {name || "unknown", args_fingerprint(args)}
  end

  @doc "Extract the hash portion from a cache key tuple."
  @spec cache_key_hash({String.t(), String.t()}) :: String.t()
  def cache_key_hash({_name, fingerprint}), do: fingerprint

  # -- Private helpers ----------------------------------------------------------

  defp args_fingerprint(nil), do: ""

  defp args_fingerprint(args) when is_map(args) do
    args
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp args_fingerprint(args), do: args_fingerprint(%{"raw" => inspect(args)})
end
