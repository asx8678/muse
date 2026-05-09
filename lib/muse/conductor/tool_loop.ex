defmodule Muse.Conductor.ToolLoop do
  @moduledoc """
  Iterative tool-call loop for the Conductor.

  When the provider returns tool calls (instead of a final text response),
  the ToolLoop executes valid read-only tools via `Muse.Tool.Runner`,
  feeds tool-result messages back to the provider, and repeats until
  the provider returns a final assistant text or a safety cap is hit.

  ## Safety caps

    * `max_iterations`            — maximum provider→tool→provider loops (default: 4)
    * `max_tool_calls_per_iteration` — cap per iteration (default: 8)
    * `max_total_tool_calls`     — global cap across all iterations (default: 20)

  When a cap is hit, a `:tool_loop_limit_reached` event is emitted and
  one final provider call is attempted with tools disabled. If that
  also fails, a fallback text is returned.

  ## Cancellation

  The loop checks `TurnRunner.cancelled?/0` between iterations and
  between tool calls within an iteration. If cancelled, the loop
  returns immediately with partial results and a safe cancellation
  response.

  ## Blocked/unsafe tools

  Tools like `write_file`, `shell_command`, etc. are blocked by the
  `Muse.Tool.Runner`. The ToolLoop feeds the blocked-result back as
  a synthetic tool-result message so the model can adjust its plan.

  Malformed tool calls (missing name, non-map args, etc.) also produce
  safe error results fed back to the model — they never crash the loop.

  ## Tool-loop optimizations (T1-18)

    * **O(n) accumulators** — event specs, patch proposals, and messages use
      prepend-then-reverse instead of growing-list `++`, avoiding O(n²) cost
      across iterations.
    * **Dedup/memoization** — within a single turn, duplicate tool calls
      (same tool name + identical args) return a cached result instead of
      re-executing. Only read-only/idempotent tools are cached; write/apply/
      approval tools always execute.
    * **Bounded concurrency** — read-only tools execute in parallel (up to
      `Muse.Bounds.tool_concurrency/0`, default 4) using `Task.async_stream`.
      Write/patch/interactive/approval tools remain serial.
    * **Token reduction** — model-facing tool result content is centrally
      bounded by `Muse.Bounds.tool_result_bytes/0` (default 10KB). Truncated
      results include a `:__truncated__` flag so the model knows output was
      cut short.

  ## Event specs

  All event specs are returned for the caller (SessionServer) to emit
  via `emit_session_event/5`, ensuring proper session_id/turn_id/seq.
  The ToolLoop does NOT emit directly to State when `emit_events?: false`
  is set in the runner context.

  ## Provider state carry-over

  The ToolLoop tracks `provider_state` from the latest provider response
  and includes it in the result map. The Conductor uses this to merge
  safe keys (e.g. `:previous_response_id`) back into the session's
  `provider_state` after the tool loop completes.

  Between iterations, `response.provider_state.previous_response_id` is
  automatically hydrated into the next provider request's
  `previous_response_id` field for conversation continuity (OpenAI
  Responses API).
  """

  alias Muse.Tool
  alias Muse.LLM.{Event, Message}
  alias Muse.Conductor.StreamCollector
  alias Muse.Conductor.TurnRunner
  alias Muse.Prompt.Redactor

  @type event_spec :: {atom(), atom(), map(), keyword()}

  @default_limits %{
    max_iterations: 4,
    max_tool_calls_per_iteration: 8,
    max_total_tool_calls: 20
  }

  @doc """
  Run the tool loop for a turn.

  Takes the initial provider response (which contains tool calls) and
  iterates: execute tools → feed results → call provider again → repeat.

  ## Arguments

    * `session`  — `Muse.Session.t()`
    * `turn`     — `Muse.Turn.t()`
    * `muse`     — `Muse.MuseProfile.t()`
    * `bundle`   — `Muse.Prompt.Bundle.t()`
    * `request`  — `Muse.LLM.Request.t()`
    * `initial_response` — the first `Muse.LLM.Response.t()` (has tool calls)
    * `initial_event_specs` — event specs from the first provider call
    * `opts`     — keyword options

  ## Options

    * `:provider_module` — provider module (default `Muse.LLM.FakeProvider`)
    * `:tool_runner`     — tool runner module (default `Muse.Tool.Runner`)
    * `:limits`          — map of loop limits (see `@default_limits`)
    * `:request_options` — original safe request opts; an explicit
      `:previous_response_id` here is respected instead of provider state
    * `:tool_concurrency` — override bounded concurrency cap for read-only
      tools (default from `Muse.Bounds.tool_concurrency/0`)
    * `:tool_result_bytes` — override max bytes for model-facing tool
      results (default from `Muse.Bounds.tool_result_bytes/0`)

  ## Returns

    * `{:ok, result}` — map with `:assistant_text`, `:event_specs`, `:iterations`,
      `:total_tool_calls`, `:limit_reached?`, `:provider_state`
    * `{:cancelled, result}` — partial result with cancellation flag
  """
  @spec run(map(), map(), map(), map(), map(), map(), [event_spec()], keyword()) ::
          {:ok, map()} | {:cancelled, map()}
  def run(session, turn, muse, bundle, request, initial_response, initial_event_specs, opts \\ []) do
    provider_module = Keyword.get(opts, :provider_module, Muse.LLM.FakeProvider)
    tool_runner = Keyword.get(opts, :tool_runner, Tool.Runner)
    limits = Keyword.get(opts, :limits, @default_limits)
    emit_event_fn = Keyword.get(opts, :emit_event_fn)
    tool_concurrency = Keyword.get(opts, :tool_concurrency, Muse.Bounds.tool_concurrency())
    tool_result_bytes = Keyword.get(opts, :tool_result_bytes, Muse.Bounds.tool_result_bytes())

    state = %{
      session: session,
      turn: turn,
      muse: muse,
      bundle: bundle,
      request: request,
      provider_module: provider_module,
      tool_runner: tool_runner,
      limits: limits,
      emit_event_fn: emit_event_fn,
      tool_concurrency: tool_concurrency,
      tool_result_bytes: tool_result_bytes,
      messages: request.messages,
      # Prepend-based accumulators (reversed at result build)
      event_specs_acc: initial_event_specs,
      patch_proposals_acc: [],
      provider_state: initial_response.provider_state || %{},
      previous_response_id_override: previous_response_id_override(opts),
      # Tool dedup cache: %{cache_key => Tool.Result.t()}
      tool_cache: %{},
      total_tool_calls: 0,
      iterations: 0,
      limit_reached: false,
      cancelled: false
    }

    # Process the initial response (which has tool calls)
    process_tool_call_response(state, initial_response)
  end

  # -- Process a response with tool calls ---------------------------------------

  defp process_tool_call_response(state, response) do
    # Provider-side conversation state is advanced exactly once per provider
    # response, before the continuation request is built. If the next provider
    # call fails mid-turn, this function returns a safe error/fallback; it does
    # not re-enter this response and does not re-run already executed tools.
    state = advance_provider_state(state, response)

    # Check cancellation before tool execution
    if TurnRunner.cancelled?() do
      {:cancelled, build_result(%{state | cancelled: true}, "Turn cancelled during tool loop.")}
    else
      # Execute tool calls from this response
      {tool_results, tool_event_specs, new_total, hit_limit?, new_proposals, new_cache} =
        execute_tool_calls(state, response.tool_calls)

      state = %{
        state
        | event_specs_acc: prepend_specs(state.event_specs_acc, tool_event_specs),
          patch_proposals_acc: new_proposals ++ state.patch_proposals_acc,
          tool_cache: Map.merge(state.tool_cache, new_cache),
          total_tool_calls: new_total
      }

      state = if hit_limit?, do: mark_limit_reached(state), else: state

      # Feed results back as tool messages (prepend, reverse at build)
      tool_messages = build_tool_messages(tool_results, state.tool_result_bytes)
      assistant_msg = Message.assistant(response.content)

      # Messages use chronological order so we reverse the accumulated
      # list at the end.  Prepend new messages: tool_messages first
      # (they come after assistant_msg in chronological order, but
      # prepending means tool_messages then assistant_msg gives the
      # right order when reversed).
      new_messages_acc =
        (tool_messages ++ [assistant_msg]) ++ state.messages

      # Rebuild request with updated messages and increment fake_iteration
      # so that FakeProvider with :fake_event_batches returns the next batch.
      # Also carry response.provider_state.previous_response_id into the
      # next request for conversation continuity (OpenAI Responses API).
      new_request = %{state.request | messages: Enum.reverse(new_messages_acc)}
      new_request = put_previous_response_id(new_request, state)
      new_request = increment_fake_iteration(new_request, state.iterations + 1)

      state = %{
        state
        | messages: new_messages_acc,
          request: new_request,
          iterations: state.iterations + 1
      }

      # Check cancellation after tool execution
      if TurnRunner.cancelled?() do
        {:cancelled, build_result(%{state | cancelled: true}, "Turn cancelled during tool loop.")}
      else
        # If limit was reached, do one final provider call with tools disabled
        if state.limit_reached do
          case final_provider_call(state) do
            {:ok, text, specs, response} ->
              state =
                state
                |> advance_provider_state(response)
                |> prepend_specs_to_acc(specs)

              {:ok, build_result(state, text)}

            {:error, _reason, specs} ->
              state = prepend_specs_to_acc(state, specs)
              {:ok, build_result(state, fallback_summary(state))}
          end
        else
          loop(state)
        end
      end
    end
  end

  # -- Loop core ----------------------------------------------------------------

  defp loop(%{cancelled: true} = state) do
    {:cancelled, build_result(state, "Turn cancelled during tool loop.")}
  end

  defp loop(%{iterations: iter, limits: %{max_iterations: max}} = state)
       when iter >= max do
    state = mark_limit_reached(state)

    case final_provider_call(state) do
      {:ok, text, specs, response} ->
        state =
          state
          |> advance_provider_state(response)
          |> prepend_specs_to_acc(specs)

        {:ok, build_result(state, text)}

      {:error, _reason, specs} ->
        state = prepend_specs_to_acc(state, specs)
        {:ok, build_result(state, fallback_summary(state))}
    end
  end

  defp loop(state) do
    # Check cancellation before each iteration
    if TurnRunner.cancelled?() do
      state = %{state | cancelled: true}
      loop(state)
    else
      case run_iteration(state) do
        {:no_tool_calls, text, specs, response} ->
          state =
            state
            |> advance_provider_state(response)
            |> prepend_specs_to_acc(specs)

          {:ok, build_result(state, text)}

        {:tool_calls, _tc_specs, provider_specs, response} ->
          state = prepend_specs_to_acc(state, provider_specs)
          # Update provider_state from this iteration's response
          state = advance_provider_state(state, response)
          process_tool_call_response(state, response)

        {:error, _reason, specs} ->
          state = prepend_specs_to_acc(state, specs)
          {:ok, build_result(state, "Error during provider call in tool loop.")}
      end
    end
  end

  # -- Single iteration ---------------------------------------------------------

  defp run_iteration(state) do
    %{provider_module: provider_module, request: request, emit_event_fn: emit_event_fn} = state

    {:ok, collector} = StreamCollector.start()

    emit_fn = fn llm_event ->
      try do
        case StreamCollector.record(collector, llm_event) do
          {:delta, text, idx} when is_function(emit_event_fn, 1) ->
            spec = {:muse, :assistant_delta, %{text: text, index: idx}, [visibility: :user]}
            emit_event_fn.(spec)
            StreamCollector.mark_live_emitted(collector)

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end

    result = provider_module.stream(request, emit_fn)

    {llm_events, live_delta_count} = StreamCollector.collect(collector)

    event_specs =
      llm_events
      |> convert_llm_events_to_specs()
      |> mark_live_emitted_deltas(live_delta_count)

    case result do
      {:ok, response} ->
        if response_has_tool_calls?(response) do
          {:tool_calls, [], event_specs, response}
        else
          text = response.content || ""
          {:no_tool_calls, text, event_specs, response}
        end

      {:error, reason} ->
        {:error, reason, event_specs}
    end
  end

  # -- Tool execution -----------------------------------------------------------

  defp execute_tool_calls(state, tool_calls) do
    %{
      limits: limits,
      total_tool_calls: total,
      tool_runner: tool_runner,
      session: session,
      turn: turn,
      muse: muse,
      tool_cache: cache,
      tool_concurrency: concurrency_cap
    } = state

    max_per_iter =
      limits[:max_tool_calls_per_iteration] || @default_limits.max_tool_calls_per_iteration

    max_total = limits[:max_total_tool_calls] || @default_limits.max_total_tool_calls

    remaining_total = max_total - total

    # Cap the number of tool calls we'll actually execute
    {executable, deferred} =
      split_at_cap(tool_calls, min(max_per_iter, remaining_total))

    # Separate read-only (concurrent + cacheable) from serial tools
    {read_only_calls, serial_calls} =
      Enum.split_with(executable, fn tc ->
        read_only_tool?(tc.name)
      end)

    # Execute read-only tools with bounded concurrency + dedup
    {ro_results, ro_specs, ro_total, ro_proposals, ro_cache} =
      execute_read_only_tools(read_only_calls, tool_runner, session, turn, muse,
        total: total,
        max_total: max_total,
        cache: cache,
        concurrency: concurrency_cap
      )

    # Execute serial tools (write/apply/patch/interactive) — no caching
    {serial_results, serial_specs, serial_total, serial_proposals} =
      execute_serial_tools(serial_calls, tool_runner, session, turn, muse,
        total: ro_total,
        max_total: max_total
      )

    all_results = ro_results ++ serial_results
    all_specs = ro_specs ++ serial_specs
    final_total = serial_total
    all_proposals = ro_proposals ++ serial_proposals
    merged_cache = Map.merge(cache, ro_cache)

    # Deferred tool calls become synthetic "limit reached" results
    deferred_results =
      Enum.map(deferred, fn tc ->
        Tool.Result.error(
          tc.name || "unknown",
          "Tool call deferred: total tool call limit reached",
          %{tool_call_id: tc.id || "tc_unknown"}
        )
      end)

    deferred_specs =
      Enum.map(deferred, fn tc ->
        {:conductor, :tool_call_deferred,
         redact_event_data(%{
           tool_name: tc.name,
           tool_call_id: tc.id,
           reason: "total limit reached"
         }), [visibility: :debug]}
      end)

    final_results = all_results ++ deferred_results
    final_specs = all_specs ++ deferred_specs
    hit_limit? = length(deferred) > 0 or final_total >= max_total

    {final_results, final_specs, final_total, hit_limit?, all_proposals, merged_cache}
  end

  # -- Read-only tool execution (bounded concurrency + dedup) -------------------

  defp execute_read_only_tools(calls, tool_runner, session, turn, muse, opts) do
    total = Keyword.fetch!(opts, :total)
    max_total = Keyword.fetch!(opts, :max_total)
    cache = Keyword.fetch!(opts, :cache)
    concurrency = Keyword.fetch!(opts, :concurrency)

    if calls == [] do
      {[], [], total, [], cache}
    else
      # Three-way partition:
      #   1. Already in cache from previous iterations -> dedup result
      #   2. First occurrence in this iteration -> execute
      #   3. Duplicate within this iteration (already seen in slot 2) -> will
      #      either dedup (if first execution succeeded & cached) or execute fresh
      {cached_from_prev, remaining} =
        Enum.split_with(calls, fn tc ->
          Map.has_key?(cache, cache_key(tc))
        end)

      # Find duplicates within remaining calls (first occurrence executes, rest
      # are candidates for dedup — but they'll only get dedup results if the
      # first execution's result is in the cache after execution)
      {unique_in_iter, dup_in_iter} =
        dedup_within_iteration(remaining)

      # Return cached results for previous-cache hits
      prev_cached_results = build_dedup_results(cached_from_prev, cache)

      # Execute unique uncached read-only tools with bounded concurrency
      {fresh_results, fresh_specs, fresh_total, fresh_proposals, fresh_cache} =
        if unique_in_iter == [] do
          {[], [], total, [], %{}}
        else
          execute_concurrent_tools(unique_in_iter, tool_runner, session, turn, muse,
            total: total,
            max_total: max_total,
            concurrency: concurrency
          )
        end

      # Now build dedup results for within-iteration duplicates using
      # merged cache. Only calls whose first execution produced a
      # cacheable (successful) result will get dedup; the rest are
      # executed fresh.
      merged_with_fresh = Map.merge(cache, fresh_cache)
      iter_dup_dedup_results = build_dedup_results(dup_in_iter, merged_with_fresh)

      # Calls that didn't get dedup results (cache miss) need fresh execution
      deduped_ids = Enum.map(iter_dup_dedup_results, fn {id, _, _} -> id end)

      dup_in_iter_uncached =
        Enum.reject(dup_in_iter, fn tc ->
          (tc.id || "tc_unknown") in deduped_ids
        end)

      {dup_fresh_results, dup_fresh_specs, dup_fresh_total, dup_fresh_proposals, dup_fresh_cache} =
        if dup_in_iter_uncached == [] do
          {[], [], fresh_total, [], %{}}
        else
          execute_concurrent_tools(dup_in_iter_uncached, tool_runner, session, turn, muse,
            total: fresh_total,
            max_total: max_total,
            concurrency: concurrency
          )
        end

      # Merge all results maintaining original call order
      _all_exec_results = fresh_results ++ dup_fresh_results
      _all_exec_specs = fresh_specs ++ dup_fresh_specs

      {result_list, spec_list} =
        merge_all_results_in_order(
          calls,
          cached_from_prev,
          prev_cached_results,
          unique_in_iter,
          fresh_results,
          fresh_specs,
          dup_in_iter,
          iter_dup_dedup_results,
          dup_in_iter_uncached,
          dup_fresh_results,
          dup_fresh_specs
        )

      # Merge caches
      merged_cache = Map.merge(cache, Map.merge(fresh_cache, dup_fresh_cache))

      # Collect patch proposals from successful patch_propose calls
      proposals =
        unique_in_iter
        |> Enum.zip(fresh_results)
        |> Enum.flat_map(fn {tc, result} ->
          if tc.name == "patch_propose" and result.success do
            [extract_patch_proposal("patch_propose", normalize_tool_args(tc.arguments), result)]
          else
            []
          end
        end)
        |> Enum.reject(&is_nil/1)

      all_proposals = proposals ++ fresh_proposals ++ dup_fresh_proposals
      actual_total = dup_fresh_total

      {result_list, spec_list, actual_total, all_proposals, merged_cache}
    end
  end

  # Deduplicate within a single iteration: first occurrence is kept as unique,
  # subsequent duplicates are returned separately.
  defp dedup_within_iteration(calls) do
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

  # Build dedup results (with lifecycle events) for cached tool calls.
  # Falls back to an error result if the cache key is not found (e.g.
  # the original execution failed and the result was not cached).
  defp build_dedup_results(calls, cache) do
    Enum.flat_map(calls, fn tc ->
      key = cache_key(tc)
      tool_call_id = tc.id || "tc_unknown"

      case Map.fetch(cache, key) do
        {:ok, result} ->
          result = %{result | metadata: Map.merge(result.metadata, %{tool_call_id: tool_call_id})}

          dedup_spec =
            {:conductor, :tool_call_dedup,
             redact_event_data(%{
               tool_call_id: tool_call_id,
               tool_name: tc.name || "unknown",
               cache_key_hash: cache_key_hash(key)
             }), [visibility: :debug]}

          started_spec =
            {:conductor, :tool_call_started,
             redact_event_data(%{
               tool_call_id: tool_call_id,
               tool_name: tc.name || "unknown",
               args_summary: safe_args_summary(normalize_tool_args(tc.arguments))
             }), [visibility: :debug]}

          completed_spec =
            {:conductor, :tool_call_completed,
             redact_event_data(%{
               tool_call_id: tool_call_id,
               tool_name: tc.name || "unknown",
               success: result.success,
               output_summary: Tool.Result.safe_summary(result)
             }), [visibility: :debug]}

          [{tc.id || "tc_unknown", result, [dedup_spec, started_spec, completed_spec]}]

        :error ->
          # Cache miss — produce a fresh execution instead of dedup
          []
      end
    end)
  end

  # Merge all results (prev-cached, executed, within-iteration dups, and
  # uncached-dup-fresh) maintaining original call order.
  defp merge_all_results_in_order(
         all_calls,
         _prev_cached_calls,
         prev_cached_results,
         executed_calls,
         exec_results,
         exec_specs,
         _iter_dup_calls,
         iter_dup_results,
         dup_uncached_calls,
         dup_fresh_results,
         dup_fresh_specs
       ) do
    # Build maps from call id -> {result, specs}
    prev_map =
      prev_cached_results
      |> Enum.map(fn {id, result, specs} -> {id, {result, specs}} end)
      |> Map.new()

    iter_dup_map =
      iter_dup_results
      |> Enum.map(fn {id, result, specs} -> {id, {result, specs}} end)
      |> Map.new()

    exec_map =
      exec_results
      |> Enum.zip(executed_calls)
      |> Enum.map(fn {result, tc} -> {tc.id || "tc_unknown", {result, []}} end)
      |> Map.new()

    dup_fresh_map =
      dup_fresh_results
      |> Enum.zip(dup_uncached_calls)
      |> Enum.map(fn {result, tc} -> {tc.id || "tc_unknown", {result, []}} end)
      |> Map.new()

    # Walk original calls in order
    {result_list, spec_list} =
      Enum.reduce(all_calls, {[], []}, fn tc, {res, specs} ->
        id = tc.id || "tc_unknown"

        cond do
          Map.has_key?(prev_map, id) ->
            {result, c_specs} = Map.fetch!(prev_map, id)
            {[result | res], specs ++ c_specs}

          Map.has_key?(iter_dup_map, id) ->
            {result, c_specs} = Map.fetch!(iter_dup_map, id)
            {[result | res], specs ++ c_specs}

          Map.has_key?(exec_map, id) ->
            {result, _} = Map.fetch!(exec_map, id)
            {[result | res], specs}

          Map.has_key?(dup_fresh_map, id) ->
            {result, _} = Map.fetch!(dup_fresh_map, id)
            {[result | res], specs}

          true ->
            {res, specs}
        end
      end)

    {Enum.reverse(result_list), spec_list ++ exec_specs ++ dup_fresh_specs}
  end

  # Execute read-only tools using bounded Task.async/Task.yield_many.
  #
  # When concurrency > 1, batches calls into groups of `concurrency` size,
  # spawning tasks under Task.Supervisor, then yielding all at once.
  # When concurrency == 1, runs sequentially (simpler, avoids Task overhead).
  defp execute_concurrent_tools(calls, tool_runner, session, turn, muse, opts) do
    total = Keyword.fetch!(opts, :total)
    max_total = Keyword.fetch!(opts, :max_total)
    concurrency = Keyword.fetch!(opts, :concurrency)

    if calls == [] do
      {[], [], total, [], %{}}
    else
      num_calls = length(calls)

      if concurrency <= 1 do
        # Sequential execution — simpler and deterministic
        execute_tools_sequential(calls, tool_runner, session, turn, muse,
          total: total,
          max_total: max_total
        )
      else
        # Bounded parallel execution via Task.Supervisor
        execute_tools_parallel(calls, tool_runner, session, turn, muse,
          total: total,
          max_total: max_total,
          concurrency: concurrency,
          num_calls: num_calls
        )
      end
    end
  end

  # Sequential execution with prepend-based accumulators
  defp execute_tools_sequential(calls, tool_runner, session, turn, muse, opts) do
    total = Keyword.fetch!(opts, :total)
    max_total = Keyword.fetch!(opts, :max_total)

    {results_rev, specs_acc, cache_acc, proposals_rev} =
      Enum.reduce(calls, {[], [], %{}, []}, fn tc, {res_acc, spec_acc, cache_acc, prop_acc} ->
        if TurnRunner.cancelled?() do
          {res_acc, spec_acc, cache_acc, prop_acc}
        else
          {result, tool_specs, _new_count} =
            execute_single_tool(tc, tool_runner, session, turn, muse,
              updated_total: total,
              max_total: max_total
            )

          new_cache =
            if result.success do
              Map.put(cache_acc, cache_key(tc), result)
            else
              cache_acc
            end

          proposal =
            if tc.name == "patch_propose" and result.success do
              extract_patch_proposal("patch_propose", normalize_tool_args(tc.arguments), result)
            else
              nil
            end

          new_prop_acc = if proposal, do: [proposal | prop_acc], else: prop_acc
          {[result | res_acc], spec_acc ++ tool_specs, new_cache, new_prop_acc}
        end
      end)

    {Enum.reverse(results_rev), specs_acc, total + length(calls), Enum.reverse(proposals_rev),
     cache_acc}
  end

  # Bounded parallel execution via Task.Supervisor + yield_many
  defp execute_tools_parallel(calls, tool_runner, session, turn, muse, opts) do
    total = Keyword.fetch!(opts, :total)
    max_total = Keyword.fetch!(opts, :max_total)
    concurrency = Keyword.fetch!(opts, :concurrency)
    num_calls = Keyword.fetch!(opts, :num_calls)

    {results, specs, proposals, new_cache} =
      calls
      |> Enum.with_index()
      |> Enum.chunk_every(concurrency)
      |> Enum.reduce({[], [], [], %{}}, fn batch, {res_acc, spec_acc, prop_acc, cache_acc} ->
        if TurnRunner.cancelled?() do
          {res_acc, spec_acc, prop_acc, cache_acc}
        else
          batch_start_total = total + length(res_acc)

          tasks =
            Enum.map(batch, fn {tc, idx} ->
              Task.Supervisor.async_nolink(Muse.TaskSupervisor, fn ->
                execute_single_tool(tc, tool_runner, session, turn, muse,
                  updated_total: batch_start_total + idx,
                  max_total: max_total
                )
              end)
            end)

          batch_results =
            tasks
            |> Task.yield_many(30_000)
            |> Enum.zip(batch)
            |> Enum.map(fn
              {{_task, {:ok, {result, tool_specs, _new_count}}}, {tc, _idx}} ->
                {result, tool_specs, tc}

              {{task, nil}, {tc, _idx}} ->
                Task.shutdown(task, :brutal_kill)
                err = Tool.Result.error(tc.name || "unknown", "tool execution timed out")
                {err, [], tc}

              {{_task, {:exit, reason}}, {tc, _idx}} ->
                safe = inspect(reason, limit: 5, printable_limit: 200)
                err = Tool.Result.error(tc.name || "unknown", "tool execution error: #{safe}")
                {err, [], tc}
            end)

          batch_res = Enum.map(batch_results, fn {r, _, _} -> r end)
          batch_specs = Enum.flat_map(batch_results, fn {_, s, _} -> s end)

          batch_cache =
            batch_results
            |> Enum.flat_map(fn {result, _, tc} ->
              if result.success, do: [{cache_key(tc), result}], else: []
            end)
            |> Map.new()

          batch_proposals =
            batch_results
            |> Enum.flat_map(fn {result, _, tc} ->
              if tc.name == "patch_propose" and result.success do
                [
                  extract_patch_proposal(
                    "patch_propose",
                    normalize_tool_args(tc.arguments),
                    result
                  )
                ]
              else
                []
              end
            end)
            |> Enum.reject(&is_nil/1)

          {batch_res ++ res_acc, batch_specs ++ spec_acc, batch_proposals ++ prop_acc,
           Map.merge(cache_acc, batch_cache)}
        end
      end)

    final_total = total + num_calls
    {Enum.reverse(results), specs, final_total, Enum.reverse(proposals), new_cache}
  end

  # -- Serial tool execution (write/apply/patch/interactive) --------------------

  defp execute_serial_tools(calls, tool_runner, session, turn, muse, opts) do
    total = Keyword.fetch!(opts, :total)
    max_total = Keyword.fetch!(opts, :max_total)

    # Use prepend-based accumulators for O(n) instead of O(n²)
    {results_rev, specs_rev, final_total, proposals_rev} =
      Enum.reduce(calls, {[], [], total, []}, fn tc, {res_acc, spec_acc, t, prop_acc} ->
        if TurnRunner.cancelled?() do
          # Short-circuit on cancellation
          {res_acc, spec_acc, t, prop_acc}
        else
          {result, tool_specs, updated_total} =
            execute_single_tool(tc, tool_runner, session, turn, muse,
              updated_total: t,
              max_total: max_total
            )

          # Collect patch proposals from serial tool results too
          proposal =
            if tc.name == "patch_propose" and result.success do
              extract_patch_proposal("patch_propose", normalize_tool_args(tc.arguments), result)
            else
              nil
            end

          new_prop_acc = if proposal, do: [proposal | prop_acc], else: prop_acc
          {[result | res_acc], tool_specs ++ spec_acc, updated_total, new_prop_acc}
        end
      end)

    {Enum.reverse(results_rev), specs_rev, final_total, Enum.reverse(proposals_rev)}
  end

  defp execute_single_tool(tc, tool_runner, session, turn, muse, opts) do
    tool_name = tc.name || "unknown"
    args = normalize_tool_args(tc.arguments)
    tool_call_id = tc.id || "tc_unknown"
    current_total = Keyword.fetch!(opts, :updated_total)

    # Emit tool lifecycle event specs (session-owned, not Runner-owned)
    started_spec =
      {:conductor, :tool_call_started,
       redact_event_data(%{
         tool_call_id: tool_call_id,
         tool_name: tool_name,
         args_summary: safe_args_summary(args)
       }), [visibility: :debug]}

    # Build plan context for Coding Muse so patch_propose can verify
    # approved plan binding (PR17 hardening).
    plan_context =
      case {session.active_plan_id, Map.get(session.plans, session.active_plan_id)} do
        {plan_id, %Muse.Plan{status: :approved} = plan} when is_binary(plan_id) ->
          %{
            plan_status: :approved,
            plan_id: plan_id,
            plan_version: plan.version,
            plan_hash: Muse.PlanBinding.content_hash(plan)
          }

        _ ->
          %{}
      end

    context =
      %{
        workspace: session.workspace || "/tmp/muse_workspace",
        muse_id: muse.id,
        session_id: session.id,
        turn_id: turn.id,
        emit_events?: false
      }
      |> Map.merge(plan_context)

    result = tool_runner.run(tool_name, args, context)

    # Preserve tool_call_id in result metadata so build_tool_messages/1
    # can feed it back as Message.tool(content, tool_call_id) instead
    # of falling back to "tc_unknown".
    result = %{result | metadata: Map.merge(result.metadata, %{tool_call_id: tool_call_id})}

    completed_spec =
      {:conductor, :tool_call_completed,
       redact_event_data(%{
         tool_call_id: tool_call_id,
         tool_name: tool_name,
         success: result.success,
         output_summary: Tool.Result.safe_summary(result)
       }), [visibility: :debug]}

    # If blocked, add a blocked spec. Other failures get an explicit failed spec
    # so unknown/malformed calls are visible even when Runner-owned events are disabled.
    blocked? = blocked_result?(result)

    blocked_spec =
      if blocked? do
        [
          {:conductor, :tool_call_blocked,
           redact_event_data(%{
             tool_call_id: tool_call_id,
             tool_name: tool_name,
             reason: result.error
           }), [visibility: :debug]}
        ]
      else
        []
      end

    failed_spec =
      if not result.success and not blocked? do
        [
          {:conductor, :tool_call_failed,
           redact_event_data(%{
             tool_call_id: tool_call_id,
             tool_name: tool_name,
             error: result.error
           }), [visibility: :debug]}
        ]
      else
        []
      end

    new_total = current_total + 1
    specs = [completed_spec] ++ blocked_spec ++ failed_spec ++ [started_spec]

    {result, specs, new_total}
  end

  # -- Extract patch proposals from tool results (PR17) --------------------------

  defp extract_patch_proposal("patch_propose", args, %Tool.Result{success: true} = result) do
    from_metadata = Map.get(result.metadata, :patch_proposal)

    if from_metadata do
      Map.merge(from_metadata, %{tool_call_id: Map.get(result.metadata, :tool_call_id)})
    else
      %{
        patch_content: Map.get(args, "diff") || Map.get(args, :diff),
        target_files: Map.get(args, "affected_files") || Map.get(args, :affected_files) || [],
        description: Map.get(args, "summary") || Map.get(args, :summary) || "",
        tool_call_id: Map.get(result.metadata, :tool_call_id)
      }
    end
  end

  defp extract_patch_proposal(_tool_name, _args, _result), do: nil

  # -- Build tool messages for provider -----------------------------------------

  defp build_tool_messages(tool_results, max_bytes) do
    Enum.map(tool_results, fn result ->
      content = encode_tool_result(result, max_bytes)
      tool_call_id = get_tool_call_id(result)
      Message.tool(content, tool_call_id)
    end)
  end

  defp encode_tool_result(%Tool.Result{} = result, max_bytes) do
    safe = %{
      tool_name: result.tool_name,
      success: result.success,
      error: redact_for_model(result.error),
      output: summarize_for_model(result.output, max_bytes)
    }

    # Add truncation flag if the output was truncated
    safe =
      if result.metadata[:__truncated__] do
        Map.put(safe, :__truncated__, true)
      else
        safe
      end

    Jason.encode!(safe)
  rescue
    _ ->
      Jason.encode!(%{
        tool_name: result.tool_name,
        success: result.success,
        error: redact_for_model(result.error),
        __truncated__: true
      })
  end

  defp summarize_for_model(nil, _max_bytes), do: nil

  defp summarize_for_model(output, max_bytes) when is_binary(output) do
    if byte_size(output) > max_bytes do
      {:ok, truncated} = Muse.Tool.SafeText.safe_truncate(output, max_bytes)
      truncated
    else
      output
    end
  end

  defp summarize_for_model(output, max_bytes) when is_map(output) do
    encoded = Jason.encode!(output)

    if byte_size(encoded) > max_bytes do
      # Truncate the encoded JSON and add truncation marker
      {:ok, truncated} = Muse.Tool.SafeText.safe_truncate(encoded, max_bytes - 20)
      truncated <> "... [__truncated__]"
    else
      output
    end
  rescue
    _ -> inspect(output, limit: 10, printable_limit: min(max_bytes, 500))
  end

  defp summarize_for_model(output, max_bytes) do
    inspect(output, limit: 10, printable_limit: min(max_bytes, 500))
  end

  defp get_tool_call_id(%Tool.Result{metadata: %{tool_call_id: id}}) when is_binary(id), do: id
  defp get_tool_call_id(_), do: "tc_unknown"

  # -- Final provider call (tools disabled) -------------------------------------

  defp final_provider_call(state) do
    %{provider_module: provider_module, request: request, emit_event_fn: emit_event_fn} = state

    # Disable tools for the final call
    final_request = %{request | tools: [], tool_choice: :none}

    {:ok, collector} = StreamCollector.start()

    emit_fn = fn llm_event ->
      try do
        case StreamCollector.record(collector, llm_event) do
          {:delta, text, idx} when is_function(emit_event_fn, 1) ->
            spec = {:muse, :assistant_delta, %{text: text, index: idx}, [visibility: :user]}
            emit_event_fn.(spec)
            StreamCollector.mark_live_emitted(collector)

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end

    result = provider_module.stream(final_request, emit_fn)

    {llm_events, live_delta_count} = StreamCollector.collect(collector)

    event_specs =
      llm_events
      |> convert_llm_events_to_specs()
      |> mark_live_emitted_deltas(live_delta_count)

    case result do
      {:ok, response} ->
        {:ok, response.content || "", event_specs, response}

      {:error, reason} ->
        {:error, reason, event_specs}
    end
  end

  # -- Limit helpers ------------------------------------------------------------

  defp mark_limit_reached(state) do
    spec =
      {:conductor, :tool_loop_limit_reached,
       %{
         iterations: state.iterations,
         total_tool_calls: state.total_tool_calls,
         reason: "Tool loop safety limit reached"
       }, [visibility: :debug]}

    %{state | limit_reached: true, event_specs_acc: [spec | state.event_specs_acc]}
  end

  defp fallback_summary(state) do
    "Tool loop limit reached after #{state.iterations} iterations and #{state.total_tool_calls} tool calls. Unable to produce a complete response."
  end

  # -- Result building ----------------------------------------------------------

  defp build_result(state, assistant_text) do
    %{
      assistant_text: assistant_text,
      event_specs: Enum.reverse(state.event_specs_acc),
      tool_results: [],
      iterations: state.iterations,
      total_tool_calls: state.total_tool_calls,
      limit_reached?: state.limit_reached,
      provider_state: state.provider_state,
      patch_proposals: Enum.reverse(state.patch_proposals_acc)
    }
  end

  # -- Prepend helpers for event specs (O(1) instead of O(n) ++) ---------------

  defp prepend_specs(acc, new_specs) when is_list(new_specs) do
    # Prepend each spec in reverse order so the final Enum.reverse
    # restores chronological order.  This is O(length(new_specs))
    # instead of O(length(acc)).
    Enum.reduce(new_specs, acc, fn spec, a -> [spec | a] end)
  end

  defp prepend_specs_to_acc(state, new_specs) do
    %{state | event_specs_acc: prepend_specs(state.event_specs_acc, new_specs)}
  end

  # -- Tool dedup helpers -------------------------------------------------------

  # Cache key: {tool_name, args_fingerprint}
  # We hash the args to keep cache keys bounded and deterministic.
  @doc false
  @spec cache_key(map()) :: {String.t(), String.t()}
  def cache_key(%{name: name, arguments: args}) do
    {name || "unknown", args_fingerprint(args)}
  end

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

  defp cache_key_hash({_name, fingerprint}), do: fingerprint

  # Classify a tool as read-only (concurrent + cacheable) vs serial
  defp read_only_tool?(nil), do: true

  defp read_only_tool?(name) when is_binary(name) do
    case Muse.Tool.Registry.get(name) do
      %Muse.Tool.Spec{kind: :read} -> true
      # Unknown/blocked tools are treated as "read-only" for execution
      # purposes (they'll fail quickly with error/blocked results)
      _ -> false
    end
  end

  defp read_only_tool?(_), do: true

  # -- LLM event conversion (mirrors Conductor) --------------------------------

  defp convert_llm_events_to_specs(llm_events) do
    {specs, _delta_index} =
      Enum.flat_map_reduce(llm_events, 0, fn llm_event, delta_index ->
        convert_llm_event(llm_event, delta_index)
      end)

    specs
  end

  defp convert_llm_event(%Event{type: :response_started}, delta_index) do
    {[{:conductor, :provider_response_started, %{}, [visibility: :debug]}], delta_index}
  end

  defp convert_llm_event(%Event{type: :assistant_delta, text: text}, delta_index) do
    spec = {:muse, :assistant_delta, %{text: text, index: delta_index}, [visibility: :user]}
    {[spec], delta_index + 1}
  end

  defp convert_llm_event(%Event{type: :assistant_completed}, delta_index) do
    {[], delta_index}
  end

  defp convert_llm_event(%Event{type: :tool_call_started, tool_call: tc}, delta_index) do
    spec =
      {:conductor, :tool_call_requested, %{tool_name: tc.name, tool_call_id: tc.id},
       [visibility: :debug]}

    {[spec], delta_index}
  end

  defp convert_llm_event(%Event{type: :tool_call_delta}, delta_index) do
    {[], delta_index}
  end

  defp convert_llm_event(%Event{type: :tool_call_completed, tool_call: tc}, delta_index) do
    spec =
      {:conductor, :tool_call_completed, %{tool_name: tc.name, tool_call_id: tc.id},
       [visibility: :debug]}

    {[spec], delta_index}
  end

  defp convert_llm_event(%Event{type: :response_completed, usage: usage}, delta_index) do
    summary = summarize_usage(usage)
    {[{:conductor, :provider_response_completed, summary, [visibility: :debug]}], delta_index}
  end

  defp convert_llm_event(%Event{type: :provider_error}, delta_index) do
    {[{:conductor, :provider_error, %{error_type: :provider_error}, [visibility: :debug]}],
     delta_index}
  end

  defp convert_llm_event(%Event{type: unknown_type}, delta_index) do
    {[
       {:conductor, :provider_event_ignored, %{unhandled_type: unknown_type},
        [visibility: :debug]}
     ], delta_index}
  end

  defp convert_llm_event(other, delta_index) do
    {[
       {:conductor, :provider_event_ignored, %{unhandled_type: inspect(other)},
        [visibility: :debug]}
     ], delta_index}
  end

  # Mark the first `count` assistant_delta specs as live-emitted so
  # SessionServer can skip them during final event-spec folding.
  # Mirrors Conductor.mark_live_emitted_deltas/2.
  @doc false
  @spec mark_live_emitted_deltas([event_spec()], non_neg_integer()) :: [event_spec()]
  def mark_live_emitted_deltas(specs, 0), do: specs

  def mark_live_emitted_deltas(specs, count) when count > 0 do
    {_remaining, marked} =
      Enum.reduce(specs, {count, []}, fn spec, {n, acc} ->
        case spec do
          {:muse, :assistant_delta, data, opts} when n > 0 ->
            {n - 1, [{:muse, :assistant_delta, data, [{:live_emitted, true} | opts]} | acc]}

          other ->
            {n, [other | acc]}
        end
      end)

    Enum.reverse(marked)
  end

  # -- Helpers ------------------------------------------------------------------

  defp response_has_tool_calls?(%{tool_calls: calls}) when is_list(calls) and calls != [],
    do: true

  defp response_has_tool_calls?(_), do: false

  defp split_at_cap(items, cap) when cap >= 0 do
    {Enum.take(items, cap), Enum.drop(items, cap)}
  end

  defp split_at_cap(items, _cap), do: {[], items}

  defp normalize_tool_args(nil), do: %{}
  defp normalize_tool_args(args) when is_map(args), do: args
  defp normalize_tool_args(args), do: %{"raw_args" => inspect(args)}

  defp blocked_result?(%Tool.Result{success: false, error: error}) when is_binary(error) do
    String.starts_with?(error, "blocked:")
  end

  defp blocked_result?(_), do: false

  defp redact_event_data(data), do: Muse.Prompt.Redactor.redact_term(data)

  defp redact_for_model(nil), do: nil

  defp redact_for_model(binary) when is_binary(binary) do
    Muse.Prompt.Redactor.redact_text(binary)
  end

  defp redact_for_model(term) do
    term
    |> inspect(limit: 10, printable_limit: 500)
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp safe_args_summary(args) when is_map(args) do
    args
    |> Map.new(fn {k, v} ->
      case v do
        s when is_binary(s) and byte_size(s) > 50 ->
          {k, String.slice(s, 0, 50) <> "…"}

        _ ->
          {k, v}
      end
    end)
    |> inspect(limit: 5, printable_limit: 100)
    |> Redactor.redact_text()
  end

  defp safe_args_summary(args) do
    args
    |> inspect(limit: 5, printable_limit: 100)
    |> Redactor.redact_text()
  end

  defp summarize_usage(nil), do: %{}

  defp summarize_usage(usage) when is_map(usage) do
    Map.take(usage, [:prompt_tokens, :completion_tokens, :total_tokens])
  end

  # Increment fake_iteration in request options for FakeProvider batch support
  defp increment_fake_iteration(request, iteration) do
    options = request.options || %{}

    if Map.has_key?(options, :fake_event_batches) do
      options = Map.put(options, :fake_iteration, iteration)
      %{request | options: options}
    else
      request
    end
  end

  # -- Provider state continuation ---------------------------------------------

  @no_previous_response_id_override :__muse_no_previous_response_id_override__

  defp previous_response_id_override(opts) do
    cond do
      Keyword.has_key?(opts, :previous_response_id) ->
        {:override, Keyword.fetch!(opts, :previous_response_id)}

      match?({:override, _value}, request_options_previous_response_id(opts)) ->
        request_options_previous_response_id(opts)

      true ->
        @no_previous_response_id_override
    end
  end

  defp request_options_previous_response_id(opts) do
    opts
    |> Keyword.get(:request_options, [])
    |> explicit_previous_response_id_from_options()
  end

  defp explicit_previous_response_id_from_options(options) when is_list(options) do
    if Keyword.has_key?(options, :previous_response_id) do
      {:override, Keyword.fetch!(options, :previous_response_id)}
    else
      @no_previous_response_id_override
    end
  end

  defp explicit_previous_response_id_from_options(options) when is_map(options) do
    cond do
      Map.has_key?(options, :previous_response_id) ->
        {:override, Map.fetch!(options, :previous_response_id)}

      Map.has_key?(options, "previous_response_id") ->
        {:override, Map.fetch!(options, "previous_response_id")}

      true ->
        @no_previous_response_id_override
    end
  end

  defp explicit_previous_response_id_from_options(_options), do: @no_previous_response_id_override

  defp advance_provider_state(%{request: %{wire_api: :responses}} = state, response) do
    case response_previous_response_id(response) do
      nil ->
        state

      previous_response_id ->
        provider_state =
          Map.put(state.provider_state || %{}, :previous_response_id, previous_response_id)

        %{state | provider_state: provider_state}
    end
  end

  defp advance_provider_state(state, _response), do: state

  defp response_previous_response_id(%{provider_state: provider_state})
       when is_map(provider_state) do
    provider_state
    |> previous_response_id_from_provider_state()
    |> normalize_previous_response_id()
  end

  defp response_previous_response_id(_response), do: nil

  defp previous_response_id_from_provider_state(provider_state) do
    Map.get(provider_state, :previous_response_id) ||
      Map.get(provider_state, "previous_response_id")
  end

  defp normalize_previous_response_id(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp normalize_previous_response_id(_value), do: nil

  defp put_previous_response_id(request, %{previous_response_id_override: {:override, value}}) do
    %{request | previous_response_id: value}
  end

  defp put_previous_response_id(%{wire_api: :chat_completions} = request, _state), do: request

  defp put_previous_response_id(%{wire_api: :responses} = request, state) do
    case Map.get(state.provider_state || %{}, :previous_response_id) do
      nil -> request
      previous_response_id -> %{request | previous_response_id: previous_response_id}
    end
  end

  defp put_previous_response_id(request, _state), do: request
end
