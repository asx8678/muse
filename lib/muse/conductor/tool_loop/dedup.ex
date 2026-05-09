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

  Returns `{unique_calls, cache_updates, dedup_results}` where:
  - `unique_calls` — calls to actually execute
  - `cache_updates` — `{key, result}` pairs to add to the cache
  - `dedup_results` — `Tool.Result` structs for deduplicated calls
  """
  @spec dedup_within_iteration([map()], map()) :: {[map()], [{String.t(), map()}], [map()]}
  def dedup_within_iteration(calls, cache) when is_list(calls) and is_map(cache) do
    {unique, cache_updates, dedup_results} =
      Enum.reduce(calls, {[], [], []}, fn call, {u, cu, dr} ->
        key = cache_key(call)

        case Map.get(cache, key) do
          nil ->
            {[call | u], cu, dr}

          cached_result ->
            {u, cu, [build_dedup_result(call, cached_result) | dr]}
        end
      end)

    {Enum.reverse(unique), Enum.reverse(cache_updates), Enum.reverse(dedup_results)}
  end

  @doc """
  Compute a content-addressed cache key for a tool call.

  Uses the tool name and a hash of the arguments.
  """
  @spec cache_key(map()) :: String.t()
  def cache_key(%{name: name, arguments: args}) do
    fingerprint = args_fingerprint(args)
    "#{name}:#{fingerprint}"
  end

  def cache_key(call) when is_map(call) do
    name = Map.get(call, :name) || Map.get(call, "name") || "unknown"
    args = Map.get(call, :arguments) || Map.get(call, "arguments") || %{}
    fingerprint = args_fingerprint(args)
    "#{name}:#{fingerprint}"
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

  defp build_dedup_result(_call, _cached_result) do
    # Return a summary indicating this was a deduplicated call
    %{deduplicated: true}
  end
end
