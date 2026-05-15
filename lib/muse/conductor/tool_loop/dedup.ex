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

  # -- Planning for cross-iteration + within-iteration dedup --------------------

  @typedoc """
  Disposition of a single tool call during read-only dedup planning.

  - `:prev_cache` — key was in the cache from a previous tool-loop iteration.
  - `:execute` — first time we have seen this key in the current provider response;
    this call will be executed (it becomes the canonical for the key).
  - `{:dup, canonical_id}` — later occurrence of a key whose canonical is being
    executed in this iteration. After the canonical finishes we will decide
    whether this can be served from the fresh result or must also be executed.
  """
  @type disposition :: :prev_cache | :execute | {:dup, String.t()}

  @typedoc "A planned item for one original tool call."
  @type planned :: %{
          call: map(),
          key: {String.t(), String.t()},
          id: String.t(),
          disposition: disposition()
        }

  @doc """
  Produce a plan for executing (or deduplicating) a list of tool calls given an
  incoming cache from previous iterations.

  This is a pure function that makes the complex dedup decisions in
  `execute_read_only_tools` explicit and testable.

  Returns a list of `planned` items in the same order as the input `calls`.
  For every key that is not in `incoming_cache`, the *first* call with that key
  in the input list receives `disposition: :execute`; subsequent ones receive
  `{:dup, canonical_id}` where `canonical_id` is the tool_call_id of the first.
  """
  @spec plan_read_only_execution([map()], map()) :: [planned()]
  def plan_read_only_execution(calls, incoming_cache)
      when is_list(calls) and is_map(incoming_cache) do
    {planned_rev, _seen} =
      Enum.reduce(calls, {[], %{}}, fn tc, {acc, seen} ->
        key = cache_key(tc)
        id = tc.id || "tc_unknown"

        disposition =
          cond do
            Map.has_key?(incoming_cache, key) ->
              :prev_cache

            Map.has_key?(seen, key) ->
              {:dup, Map.fetch!(seen, key)}

            true ->
              :execute
          end

        new_seen =
          case disposition do
            :execute -> Map.put(seen, key, id)
            _ -> seen
          end

        item = %{call: tc, key: key, id: id, disposition: disposition}
        {[item | acc], new_seen}
      end)

    Enum.reverse(planned_rev)
  end
end
