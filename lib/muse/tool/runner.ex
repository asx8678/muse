defmodule Muse.Tool.Runner do
  @moduledoc """
  Executes tool calls with safety validation, approval gating, and event emission.

  The runner is the single entry point for all tool invocations. It:

    1. Validates the tool exists in the registry (or is a known blocked tool)
    2. Checks the active Muse is allowed to use the tool
    3. Checks approval/permission categories are satisfied
    4. Validates required input keys
    5. Enforces workspace safety (via `Muse.Workspace.safe_resolve!/2`)
    6. Executes the handler
    7. Caps and redacts output
    8. Emits lifecycle events via `Muse.State`

  ## API

    `run(tool_name, args, context)` → `%Muse.Tool.Result{}`

  The runner **always** returns a `%Result{}` — either success or error.
  It **never** raises; all safety violations and errors are captured as
  error results.

  ## Event emission

  The runner emits `:tool_call_started`, `:tool_call_completed`,
  `:tool_call_failed`, and `:tool_call_blocked` events via `Muse.State`
  if it is running. It never crashes if State/PubSub are absent.

  Events include safe summaries only: tool_call_id, tool_name, muse_id,
  permission, args summary, output summary, elapsed_ms, session/turn
  metadata. No raw file contents or secrets in events.
  """

  alias Muse.ApprovalGate
  alias Muse.Telemetry, as: MuseTelemetry
  alias Muse.Tool.{Registry, Result, Spec, Validator}

  # @default_output_limit available if needed later
  # @default_output_limit 50_000

  @doc """
  Run a tool call with full safety validation.

  ## Arguments

    * `tool_name` — the tool name string (e.g. `"read_file"`)
    * `args` — map of tool arguments
    * `context` — map with `:workspace`, `:muse_id`, `:session_id`, `:turn_id`

  ## Returns

  Always returns `%Result{}`:

      - `%Result{success: true, output: ..., ...}` on success
      - `%Result{success: false, error: "blocked: ...", ...}` on permission denial
      - `%Result{success: false, error: "...", ...}` on other failures

  ## Context keys

    * `:workspace` (required) — workspace root path
    * `:muse_id` — requesting Muse profile id atom
    * `:session_id` — session identifier
    * `:turn_id` — turn identifier
  """
  @spec run(String.t(), map(), map()) :: Result.t()
  def run(tool_name, args, context)
      when is_binary(tool_name) and is_map(args) and is_map(context) do
    call_id = generate_call_id()
    start_time = System.monotonic_time(:millisecond)
    muse_id = context[:muse_id]

    # Emit telemetry: tool start
    emit_telemetry_tool_start(tool_name, context)

    # Emit start event
    emit_event(
      :tool_call_started,
      %{
        tool_call_id: call_id,
        tool_name: tool_name,
        muse_id: muse_id,
        args_summary: safe_args_summary(args)
      },
      context
    )

    {result, _exception?} =
      try do
        result = execute_tool_pipeline(tool_name, args, context, call_id, muse_id)
        {result, false}
      rescue
        exception ->
          # Unexpected exception in Runner validation code (not handler code).
          # Handler exceptions are caught inside execute_handler/4 with their
          # own tool_exception telemetry. This clause is a safety net for bugs
          # in check_* functions.
          emit_telemetry_tool_exception(tool_name, exception, context)

          r = Result.error(tool_name, "tool execution error: #{Exception.message(exception)}")
          {r, true}
      catch
        kind, reason ->
          # Safety net for throws/exits from Runner code (not handler code).
          safe_reason = safe_catch_reason(kind, reason)
          emit_telemetry_tool_exception_raw(tool_name, safe_reason, context)
          r = Result.error(tool_name, "tool execution error: #{safe_reason}")
          {r, true}
      end

    elapsed = System.monotonic_time(:millisecond) - start_time

    # Emit telemetry: tool stop
    emit_telemetry_tool_stop(tool_name, elapsed, result.success, context)

    emit_event(
      :tool_call_completed,
      %{
        tool_call_id: call_id,
        tool_name: tool_name,
        muse_id: muse_id,
        success: result.success,
        output_summary: Result.safe_summary(result),
        elapsed_ms: elapsed
      },
      context
    )

    result
  end

  def run(tool_name, args, _context) do
    reason =
      cond do
        not is_binary(tool_name) -> "invalid tool call: tool_name must be a string"
        not is_map(args) -> "invalid tool call: arguments must be a map"
        true -> "invalid tool call"
      end

    Result.error(tool_name, reason)
  end

  # -- Tool pipeline (extracted for rescue boundary) ----------------------------

  defp execute_tool_pipeline(tool_name, args, context, call_id, muse_id) do
    with :ok <- check_blocked(tool_name),
         {:ok, spec} <- check_registered(tool_name),
         :ok <- check_muse_allowed(spec, muse_id),
         :ok <- check_approval(spec, context),
         {:ok, normalized_args} <- validate_args(spec, args),
         {:ok, context_with_workspace} <- ensure_workspace(context),
         {:ok, final_result} <-
           execute_handler(spec, normalized_args, context_with_workspace, call_id) do
      cap_and_redact_result(final_result, spec)
    else
      {:blocked, reason} ->
        r = Result.blocked(tool_name, reason)

        emit_event(
          :tool_call_blocked,
          %{
            tool_call_id: call_id,
            tool_name: tool_name,
            muse_id: muse_id,
            reason: reason
          },
          context
        )

        r

      {:error, reason} ->
        r = Result.error(tool_name, reason)

        emit_event(
          :tool_call_failed,
          %{
            tool_call_id: call_id,
            tool_name: tool_name,
            muse_id: muse_id,
            error: reason
          },
          context
        )

        r
    end
  end

  # -- Validation steps ---------------------------------------------------------

  defp check_blocked(tool_name) do
    if Registry.blocked_tool?(tool_name) do
      {:blocked, "#{tool_name} is a blocked tool (write/shell/network/delete/remote)"}
    else
      :ok
    end
  end

  defp check_registered(tool_name) do
    case Registry.fetch(tool_name) do
      {:ok, spec} -> {:ok, spec}
      {:error, :not_found} -> {:error, "unknown tool: #{tool_name}"}
    end
  end

  defp check_muse_allowed(%Spec{allowed_muses: allowed}, muse_id) do
    cond do
      is_nil(muse_id) ->
        :ok

      muse_id in allowed ->
        :ok

      true ->
        {:blocked, "#{muse_id} is not allowed to use this tool"}
    end
  end

  defp check_approval(%Spec{} = spec, context) do
    case ApprovalGate.authorize_tool(spec, context) do
      :ok -> :ok
      {:blocked, reason} -> {:blocked, reason}
    end
  end

  defp validate_args(%Spec{} = spec, args) do
    case Validator.validate_args(spec, args) do
      {:ok, normalized_args} -> {:ok, normalized_args}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_workspace(context) do
    case Map.fetch(context, :workspace) do
      {:ok, workspace} when is_binary(workspace) and workspace != "" ->
        {:ok, Map.put(context, :workspace, workspace)}

      _ ->
        {:error, "workspace is required in context"}
    end
  end

  # -- Execution ----------------------------------------------------------------

  defp execute_handler(%Spec{handler: handler, name: name}, args, context, _call_id) do
    try do
      result = handler.execute(args, context)

      # Handlers may return %Result{} or {:ok, output} / {:error, reason}
      case result do
        %Result{tool_name: ^name} = r -> {:ok, r}
        %Result{} = r -> {:ok, %{r | tool_name: name}}
        {:ok, output} -> {:ok, Result.ok(name, output)}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        # Emit telemetry for the handler exception BEFORE converting to
        # the safe {:error, _} tuple that the pipeline swallows.
        emit_telemetry_tool_exception(name, e, context)
        {:error, "tool execution error: #{Exception.message(e)}"}
    catch
      kind, reason ->
        # Catch throws and exits from handler code. Emit telemetry with
        # a safe reason string, then return the normal error tuple so the
        # Runner's contract (never raises, returns %Result{}) is preserved.
        safe_reason = safe_catch_reason(kind, reason)
        emit_telemetry_tool_exception_raw(name, safe_reason, context)
        {:error, "tool execution error: #{safe_reason}"}
    end
  end

  # -- Output safety ------------------------------------------------------------

  defp cap_and_redact_result(%Result{success: true, output: output} = result, %Spec{
         output_limit: limit
       }) do
    capped = cap_output(output, limit)
    redacted = redact_output(capped)
    %{result | output: redacted}
  end

  defp cap_and_redact_result(%Result{success: false} = result, _spec) do
    %{
      result
      | tool_name: redact_scalar(result.tool_name),
        error: redact_scalar(result.error),
        output: redact_output(result.output)
    }
  end

  defp cap_and_redact_result(%Result{} = result, _spec), do: result

  defp cap_output(output, limit) when is_binary(output) and byte_size(output) > limit do
    String.slice(output, 0, limit)
  end

  defp cap_output(output, limit) when is_map(output) do
    if term_size(output) > limit do
      # For structs, convert to plain map first.
      base = if is_struct(output), do: Map.from_struct(output), else: output

      # Deeply truncate large values so the returned output
      # never retains huge raw content beyond the spec limit.
      # Preserve useful structural fields (path, truncated, metadata)
      # while capping large string/binary values.
      capped = deep_cap_map(base, limit)
      final = Map.put(capped, :__truncated__, true)

      # Verify the final map actually fits; aggressive fallback if not
      if term_size(final) <= limit + 100 do
        final
      else
        compact_fallback_map(capped, limit)
      end
    else
      output
    end
  end

  defp cap_output(output, limit) when is_list(output) do
    if term_size(output) > limit do
      # Deeply truncate large values in the list too
      deep_cap_list(output, limit)
    else
      output
    end
  end

  defp cap_output(output, _limit), do: output

  # Recursively cap large binaries in a map, preserving structural keys.
  # We give ~60% of the limit to content-like fields and keep small
  # fields (path, metadata, etc.) intact.
  defp deep_cap_map(map, limit) when is_map(map) and not is_struct(map) do
    # First pass: estimate which values are "large" binaries
    per_value_limit = div(limit, max(map_size(map), 1))

    Map.new(map, fn {k, v} ->
      {k, deep_cap_value(v, per_value_limit)}
    end)
  end

  defp deep_cap_map(map, limit) do
    if is_struct(map) do
      map
      |> Map.from_struct()
      |> deep_cap_map(limit)
    else
      map
    end
  end

  defp deep_cap_value(v, per_value_limit) when is_binary(v) do
    if byte_size(v) > per_value_limit do
      binary_part(v, 0, per_value_limit)
    else
      v
    end
  end

  defp deep_cap_value(v, per_value_limit) when is_map(v) do
    deep_cap_map(v, per_value_limit)
  end

  defp deep_cap_value(v, per_value_limit) when is_list(v) do
    deep_cap_list(v, per_value_limit)
  end

  defp deep_cap_value(v, _limit), do: v

  defp deep_cap_list(items, limit) when is_list(items) do
    # For lists, cap each element proportionally then truncate the list
    # if it's still too large.
    per_item = max(div(limit, max(length(items), 1)), 100)
    capped = Enum.map(items, &deep_cap_value(&1, per_item))

    if term_size(capped) <= limit do
      capped
    else
      shrink_list(capped, limit)
    end
  end

  defp shrink_list(items, limit) do
    len = length(items)

    if len <= 1 do
      [:__truncated__]
    else
      half_len = div(len, 2)
      half = Enum.take(items, half_len)
      candidate = half ++ [:__truncated__]

      if term_size(candidate) <= limit do
        candidate
      else
        shrink_list(half, limit)
      end
    end
  end

  defp redact_output(output) when is_binary(output) do
    Muse.Prompt.Redactor.redact_text(output)
  end

  defp redact_output(output) when is_map(output) do
    # Recursively redact strings in the output map
    redact_map(output)
  end

  defp redact_output(output), do: output

  defp redact_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, redact_value(v)} end)
  end

  defp redact_map(%{__struct__: struct_name} = struct) do
    map =
      struct
      |> Map.from_struct()
      |> Map.new(fn {k, v} -> {k, redact_value(v)} end)

    try do
      struct(struct_name, map)
    rescue
      _ -> map
    end
  end

  defp redact_map(other), do: other

  defp redact_value(v) when is_binary(v), do: Muse.Prompt.Redactor.redact_text(v)
  defp redact_value(v) when is_map(v), do: redact_map(v)
  defp redact_value(v) when is_list(v), do: Enum.map(v, &redact_value/1)
  defp redact_value(v), do: v

  defp redact_scalar(nil), do: nil
  defp redact_scalar(v) when is_binary(v), do: Muse.Prompt.Redactor.redact_text(v)

  defp redact_scalar(v) do
    v
    |> inspect(limit: 10, printable_limit: 500)
    |> Muse.Prompt.Redactor.redact_text()
  end

  # -- Event emission ------------------------------------------------------------

  defp emit_event(type, data, context) do
    # When ToolLoop manages events centrally via SessionServer,
    # skip direct State emission to avoid duplicate unsequenced events.
    if context[:emit_events?] == false do
      :ok
    else
      do_emit_event(type, data, context)
    end
  end

  defp do_emit_event(type, data, context) do
    # Redact at event boundary — no secrets leak into stored events
    redacted_data = Muse.Prompt.Redactor.redact_term(data)

    event =
      Muse.Event.new(
        :tool_runner,
        type,
        redacted_data,
        session_id: context[:session_id],
        turn_id: context[:turn_id],
        muse_id: context[:muse_id] && to_string(context[:muse_id]),
        visibility: :debug
      )

    try do
      Muse.State.append(event)
    catch
      # Never crash if State/PubSub is absent
      :exit, _ -> :ok
    end
  end

  # -- Accurate size estimation ------------------------------------------------

  # Use limit: :infinity, printable_limit: :infinity so ALL list items and ALL
  # string characters are counted — no hidden oversize from defaults.
  defp term_size(term) do
    term
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> byte_size()
  end

  # Aggressive fallback when deep_cap_map + __truncated__ still exceeds budget.
  # Truncate every value to a small preview; if even that overflows, emit
  # a minimal %{__truncated__: true, _preview: ...} map.
  defp compact_fallback_map(capped, limit) do
    preview =
      capped
      |> Map.drop([:__truncated__, :_preview])
      |> Map.new(fn {k, v} -> {k, truncate_value(v, 200)} end)
      |> Map.put(:__truncated__, true)

    if term_size(preview) <= limit do
      preview
    else
      %{__truncated__: true, _preview: inspect(capped, limit: 3, printable_limit: 100)}
    end
  end

  defp truncate_value(v, max) when is_binary(v) do
    if byte_size(v) > max do
      String.slice(v, 0, max) <> "..."
    else
      v
    end
  end

  defp truncate_value(v, max) when is_list(v) do
    case v do
      [] -> []
      [h | _] -> [truncate_value(h, max), :__truncated__]
    end
  end

  defp truncate_value(v, max) when is_map(v) and not is_struct(v) do
    v
    |> Map.to_list()
    |> Enum.take(3)
    |> Map.new(fn {k, val} -> {k, truncate_value(val, div(max, 4))} end)
    |> Map.put(:__truncated__, true)
  end

  defp truncate_value(v, _max), do: v

  # -- Telemetry emission ------------------------------------------------------

  defp emit_telemetry_tool_start(tool_name, context) do
    try do
      :telemetry.execute(
        MuseTelemetry.tool_start(),
        %{},
        MuseTelemetry.tool_metadata(
          session_id: context[:session_id],
          turn_id: context[:turn_id],
          tool_name: tool_name
        )
      )
    catch
      # Never let telemetry crash tool execution (any failure class)
      _kind, _reason -> :ok
    end
  end

  defp emit_telemetry_tool_stop(tool_name, duration_ms, _success?, context) do
    try do
      :telemetry.execute(
        MuseTelemetry.tool_stop(),
        MuseTelemetry.tool_stop_measurements(duration_ms),
        MuseTelemetry.tool_metadata(
          session_id: context[:session_id],
          turn_id: context[:turn_id],
          tool_name: tool_name
        )
      )
    catch
      _kind, _reason -> :ok
    end
  end

  defp emit_telemetry_tool_exception(tool_name, exception, context) do
    try do
      :telemetry.execute(
        MuseTelemetry.tool_exception(),
        %{},
        MuseTelemetry.tool_exception_metadata(
          session_id: context[:session_id],
          turn_id: context[:turn_id],
          tool_name: tool_name,
          reason: Exception.message(exception)
        )
      )
    catch
      _kind, _reason -> :ok
    end
  end

  # Variant for catch-clause reasons where we don't have an Exception struct.
  defp emit_telemetry_tool_exception_raw(tool_name, reason_string, context) do
    try do
      :telemetry.execute(
        MuseTelemetry.tool_exception(),
        %{},
        MuseTelemetry.tool_exception_metadata(
          session_id: context[:session_id],
          turn_id: context[:turn_id],
          tool_name: tool_name,
          reason: reason_string
        )
      )
    catch
      _kind, _reason -> :ok
    end
  end

  # Convert a catch-clause kind/reason into a safe, redacted string.
  # The inspected text may contain secrets from handler arguments or state;
  # pass it through Redactor.redact_text/1 before returning.
  defp safe_catch_reason(:throw, value) do
    "throw: #{inspect(value, limit: 10, printable_limit: 200)}"
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp safe_catch_reason(:exit, reason) do
    "exit: #{inspect(reason, limit: 10, printable_limit: 200)}"
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp safe_catch_reason(kind, reason) do
    "#{kind}: #{inspect(reason, limit: 10, printable_limit: 200)}"
    |> Muse.Prompt.Redactor.redact_text()
  end

  # -- Helpers ------------------------------------------------------------------

  defp generate_call_id do
    "tc_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
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
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp safe_args_summary(args),
    do: Muse.Prompt.Redactor.redact_text(inspect(args, limit: 5, printable_limit: 100))
end
