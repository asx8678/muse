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

  ## Event specs

  All event specs are returned for the caller (SessionServer) to emit
  via `emit_session_event/5`, ensuring proper session_id/turn_id/seq.
  The ToolLoop does NOT emit directly to State when `emit_events?: false`
  is set in the runner context.
  """

  alias Muse.Tool
  alias Muse.LLM.{Event, Message}
  alias Muse.Conductor.TurnRunner

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

  ## Returns

    * `{:ok, result}` — map with `:assistant_text`, `:event_specs`, `:iterations`,
      `:total_tool_calls`, `:limit_reached?`
    * `{:cancelled, result}` — partial result with cancellation flag
  """
  @spec run(map(), map(), map(), map(), map(), map(), [event_spec()], keyword()) ::
          {:ok, map()} | {:cancelled, map()}
  def run(session, turn, muse, bundle, request, initial_response, initial_event_specs, opts \\ []) do
    provider_module = Keyword.get(opts, :provider_module, Muse.LLM.FakeProvider)
    tool_runner = Keyword.get(opts, :tool_runner, Tool.Runner)
    limits = Keyword.get(opts, :limits, @default_limits)

    state = %{
      session: session,
      turn: turn,
      muse: muse,
      bundle: bundle,
      request: request,
      provider_module: provider_module,
      tool_runner: tool_runner,
      limits: limits,
      messages: request.messages,
      event_specs: initial_event_specs,
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
    # Check cancellation before tool execution
    if TurnRunner.cancelled?() do
      {:cancelled, build_result(%{state | cancelled: true}, "Turn cancelled during tool loop.")}
    else
      # Execute tool calls from this response
      {tool_results, tool_event_specs, new_total, hit_limit?} =
        execute_tool_calls(state, response.tool_calls)

      state = %{
        state
        | event_specs: state.event_specs ++ tool_event_specs,
          total_tool_calls: new_total
      }

      state = if hit_limit?, do: mark_limit_reached(state), else: state

      # Feed results back as tool messages
      tool_messages = build_tool_messages(tool_results)
      assistant_msg = Message.assistant(response.content)

      new_messages = state.messages ++ [assistant_msg] ++ tool_messages

      # Rebuild request with updated messages and increment fake_iteration
      # so that FakeProvider with :fake_event_batches returns the next batch
      new_request = %{state.request | messages: new_messages}
      new_request = increment_fake_iteration(new_request, state.iterations + 1)

      state = %{
        state
        | messages: new_messages,
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
            {:ok, text, specs} ->
              state = %{state | event_specs: state.event_specs ++ specs}
              {:ok, build_result(state, text)}

            {:error, _reason, specs} ->
              state = %{state | event_specs: state.event_specs ++ specs}
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
      {:ok, text, specs} ->
        state = %{state | event_specs: state.event_specs ++ specs}
        {:ok, build_result(state, text)}

      {:error, _reason, specs} ->
        state = %{state | event_specs: state.event_specs ++ specs}
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
        {:no_tool_calls, text, specs} ->
          state = %{state | event_specs: state.event_specs ++ specs}
          {:ok, build_result(state, text)}

        {:tool_calls, _tc_specs, provider_specs, response} ->
          state = %{state | event_specs: state.event_specs ++ provider_specs}
          process_tool_call_response(state, response)

        {:error, _reason, specs} ->
          state = %{state | event_specs: state.event_specs ++ specs}
          {:ok, build_result(state, "Error during provider call in tool loop.")}
      end
    end
  end

  # -- Single iteration ---------------------------------------------------------

  defp run_iteration(state) do
    %{provider_module: provider_module, request: request} = state

    collector_key = {__MODULE__, :llm_events, make_ref()}
    Process.put(collector_key, [])

    emit_fn = fn llm_event ->
      Process.put(collector_key, [llm_event | Process.get(collector_key)])
      :ok
    end

    result = provider_module.stream(request, emit_fn)

    llm_events = Process.get(collector_key) |> Enum.reverse()
    Process.delete(collector_key)

    event_specs = convert_llm_events_to_specs(llm_events)

    case result do
      {:ok, response} ->
        if response_has_tool_calls?(response) do
          {:tool_calls, [], event_specs, response}
        else
          text = response.content || ""
          {:no_tool_calls, text, event_specs}
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
      muse: muse
    } = state

    max_per_iter =
      limits[:max_tool_calls_per_iteration] || @default_limits.max_tool_calls_per_iteration

    max_total = limits[:max_total_tool_calls] || @default_limits.max_total_tool_calls

    remaining_per_iter = max_per_iter
    remaining_total = max_total - total

    # Cap the number of tool calls we'll actually execute
    {executable, deferred} =
      split_at_cap(tool_calls, min(remaining_per_iter, remaining_total))

    {results, specs, final_total} =
      Enum.reduce(executable, {[], [], total}, fn tc, {res_acc, spec_acc, t} ->
        if TurnRunner.cancelled?() do
          # Short-circuit on cancellation
          {res_acc, spec_acc, t}
        else
          {result, tool_specs, updated_total} =
            execute_single_tool(tc, tool_runner, session, turn, muse,
              updated_total: t,
              max_total: max_total
            )

          {res_acc ++ [result], spec_acc ++ tool_specs, updated_total}
        end
      end)

    # Deferred tool calls become synthetic "limit reached" results
    deferred_results =
      Enum.map(deferred, fn tc ->
        %Tool.Result{
          success: false,
          error: "Tool call deferred: total tool call limit reached",
          tool_name: tc.name || "unknown",
          metadata: %{tool_call_id: tc.id || "tc_unknown"}
        }
      end)

    deferred_specs =
      Enum.map(deferred, fn tc ->
        {:conductor, :tool_call_deferred,
         %{tool_name: tc.name, tool_call_id: tc.id, reason: "total limit reached"},
         [visibility: :debug]}
      end)

    all_results = results ++ deferred_results
    all_specs = specs ++ deferred_specs
    hit_limit? = length(deferred) > 0 or final_total >= max_total

    {all_results, all_specs, final_total, hit_limit?}
  end

  defp execute_single_tool(tc, tool_runner, session, turn, muse, opts) do
    tool_name = tc.name || "unknown"
    args = normalize_tool_args(tc.arguments)
    tool_call_id = tc.id || "tc_unknown"
    current_total = Keyword.fetch!(opts, :updated_total)

    # Emit tool lifecycle event specs (session-owned, not Runner-owned)
    started_spec =
      {:conductor, :tool_call_started,
       %{tool_call_id: tool_call_id, tool_name: tool_name, args_summary: safe_args_summary(args)},
       [visibility: :debug]}

    context = %{
      workspace: session.workspace || "/tmp/muse_workspace",
      muse_id: muse.id,
      session_id: session.id,
      turn_id: turn.id,
      emit_events?: false
    }

    result = tool_runner.run(tool_name, args, context)

    # Preserve tool_call_id in result metadata so build_tool_messages/1
    # can feed it back as Message.tool(content, tool_call_id) instead
    # of falling back to "tc_unknown".
    result = %{result | metadata: Map.merge(result.metadata, %{tool_call_id: tool_call_id})}

    completed_spec =
      {:conductor, :tool_call_completed,
       %{
         tool_call_id: tool_call_id,
         tool_name: tool_name,
         success: result.success,
         output_summary: Tool.Result.safe_summary(result)
       }, [visibility: :debug]}

    # If blocked, add a blocked spec
    blocked_spec =
      if not result.success and result.error != nil and
           String.starts_with?(result.error, "blocked:") do
        [
          {:conductor, :tool_call_blocked,
           %{tool_call_id: tool_call_id, tool_name: tool_name, reason: result.error},
           [visibility: :debug]}
        ]
      else
        []
      end

    new_total = current_total + 1
    specs = [started_spec] ++ blocked_spec ++ [completed_spec]

    {result, specs, new_total}
  end

  # -- Build tool messages for provider -----------------------------------------

  defp build_tool_messages(tool_results) do
    Enum.map(tool_results, fn result ->
      content = encode_tool_result(result)
      tool_call_id = get_tool_call_id(result)
      Message.tool(content, tool_call_id)
    end)
  end

  defp encode_tool_result(%Tool.Result{} = result) do
    safe = %{
      tool_name: result.tool_name,
      success: result.success,
      error: result.error,
      output: summarize_for_model(result.output)
    }

    Jason.encode!(safe)
  rescue
    _ ->
      Jason.encode!(%{tool_name: result.tool_name, success: result.success, error: result.error})
  end

  defp summarize_for_model(nil), do: nil
  defp summarize_for_model(output) when is_binary(output), do: output
  defp summarize_for_model(output) when is_map(output), do: output

  defp summarize_for_model(output), do: inspect(output, limit: 10, printable_limit: 500)

  defp get_tool_call_id(%Tool.Result{metadata: %{tool_call_id: id}}) when is_binary(id), do: id
  defp get_tool_call_id(_), do: "tc_unknown"

  # -- Final provider call (tools disabled) -------------------------------------

  defp final_provider_call(state) do
    %{provider_module: provider_module, request: request} = state

    # Disable tools for the final call
    final_request = %{request | tools: [], tool_choice: :none}

    collector_key = {__MODULE__, :final_events, make_ref()}
    Process.put(collector_key, [])

    emit_fn = fn llm_event ->
      Process.put(collector_key, [llm_event | Process.get(collector_key)])
      :ok
    end

    result = provider_module.stream(final_request, emit_fn)

    llm_events = Process.get(collector_key) |> Enum.reverse()
    Process.delete(collector_key)

    event_specs = convert_llm_events_to_specs(llm_events)

    case result do
      {:ok, response} ->
        {:ok, response.content || "", event_specs}

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

    %{state | limit_reached: true, event_specs: state.event_specs ++ [spec]}
  end

  defp fallback_summary(state) do
    "Tool loop limit reached after #{state.iterations} iterations and #{state.total_tool_calls} tool calls. Unable to produce a complete response."
  end

  # -- Result building ----------------------------------------------------------

  defp build_result(state, assistant_text) do
    %{
      assistant_text: assistant_text,
      event_specs: state.event_specs,
      tool_results: [],
      iterations: state.iterations,
      total_tool_calls: state.total_tool_calls,
      limit_reached?: state.limit_reached
    }
  end

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
  end

  defp safe_args_summary(args),
    do: inspect(args, limit: 5, printable_limit: 100)

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
end
