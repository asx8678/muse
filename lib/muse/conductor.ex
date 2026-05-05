defmodule Muse.Conductor do
  @moduledoc """
  Orchestrates Muse selection, prompt building, and provider interaction for a turn.

  Called by `Muse.SessionServer` during `submit/3`. Returns event specifications
  that the SessionServer folds through `emit_session_event/5` to produce
  properly-sequenced `Muse.Event` structs.

  ## Event Specification Format

  Each event spec is a tuple `{source, type, data, opts}` where:

    * `source` — atom identifying the event source (e.g. `:conductor`, `:muse`)
    * `type`   — atom event type (e.g. `:muse_selected`, `:assistant_delta`)
    * `data`   — map of event data (redacted centrally by SessionServer)
    * `opts`   — keyword list with `:visibility`, `:muse_id`, etc.

  SessionServer adds `:session_id`, `:turn_id`, and `:seq` when emitting.

  ## Telemetry

  The Conductor emits telemetry for turn and provider lifecycles:

    * `[:muse, :turn, :start]` / `[:muse, :turn, :stop]` / `[:muse, :turn, :exception]`
    * `[:muse, :provider, :start]` / `[:muse, :provider, :stop]` / `[:muse, :provider, :error]`
  """

  alias Muse.{
    MetadataSanitizer,
    MuseRegistry,
    Patch,
    Plan,
    PlanApprovalRequest,
    PlanBinding,
    PlanParser,
    Session,
    Telemetry,
    Turn
  }

  alias Muse.Conductor.ToolLoop
  alias Muse.LLM.{FakeProvider, ProviderConfig, ProviderRouter, Message}
  alias Muse.Prompt.{Assembler, ModelPreparer, Redactor}

  @type event_spec :: {atom(), atom(), map(), keyword()}

  # -- Public API ---------------------------------------------------------------

  @doc """
  Run the Conductor for a turn.

  Selects the appropriate Muse, builds the prompt bundle, calls the
  provider, and returns the result with event specifications for the
  SessionServer to emit.

  ## Options

    * `:provider_module` — explicit provider module (overrides router selection)
    * `:provider_config` — `ProviderConfig.t()` (default: `ProviderConfig.fake/0`)
    * `:prompt_opts`     — keyword opts passed to `Assembler.build/4`
    * `:request_options` — keyword opts passed to `ModelPreparer.to_request/3`

  ## Returns

    * `{:ok, result}` — map with `:assistant_text`, `:selected_muse`,
      `:prompt_bundle`, `:request`, `:response`, `:session`, `:turn`,
      and `:event_specs`
    * `{:error, %{reason: reason, event_specs: event_specs}}` — on failure,
      with any event specs collected before the error
  """
  @spec run(Session.t(), Turn.t(), keyword()) ::
          {:ok, map()} | {:error, %{reason: term(), event_specs: [event_spec()]}}
  def run(session, turn, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    session_id = session.id
    turn_id = turn.id

    :telemetry.execute(
      Telemetry.turn_start(),
      %{},
      Telemetry.turn_start_metadata(session_id: session_id, turn_id: turn_id)
    )

    try do
      execute_turn(session, turn, opts, start_time)
    rescue
      exception ->
        duration = System.monotonic_time(:millisecond) - start_time
        stacktrace = __STACKTRACE__

        # Redact the exception message before it enters telemetry metadata
        # so embedded secrets (e.g. API keys in error strings) are not leaked.
        redacted_reason = exception |> Exception.message() |> Redactor.redact_text()

        :telemetry.execute(
          Telemetry.turn_exception(),
          %{},
          Telemetry.turn_exception_metadata(
            session_id: session_id,
            turn_id: turn_id,
            kind: :error,
            reason: redacted_reason
          )
        )

        :telemetry.execute(
          Telemetry.turn_stop(),
          Telemetry.turn_stop_measurements(duration),
          Telemetry.turn_stop_metadata(session_id: session_id, turn_id: turn_id, status: :failed)
        )

        reraise exception, stacktrace
    end
  end

  @doc """
  Select the appropriate Muse profile for the given session state.

  ## Routing rules

    * **Planning Muse** is selected for sessions in `:idle`, `:running`,
      `:planning`, or `:awaiting_plan_approval` status without an approved
      plan — these are read-only planning turns.

    * **Coding Muse** is selected when the session is `:idle` with an
      approved active plan — this enables the patch-proposal path after
      plan approval.

  ## Examples

      iex> session = Muse.Session.new(workspace: "/tmp", status: :idle)
      iex> muse = Muse.Conductor.select_muse(session, [])
      iex> muse.id
      :planning

      iex> plan = Muse.Plan.new(objective: "Test", session_id: "s1")
      iex> {:ok, approved} = Muse.Plan.transition(plan, :approved)
      iex> session = %{Muse.Session.new(workspace: "/tmp", status: :idle, id: "s1") | active_plan_id: "p1", plans: %{"p1" => approved}}
      iex> muse = Muse.Conductor.select_muse(session, [])
      iex> muse.id
      :coding
  """
  @spec select_muse(Session.t(), keyword()) :: Muse.MuseProfile.t()
  def select_muse(session, _opts) do
    if coding_muse_applicable?(session) do
      MuseRegistry.get(:coding)
    else
      MuseRegistry.get(:planning)
    end
  end

  # -- Muse selection -----------------------------------------------------------

  defp coding_muse_applicable?(session) do
    session.status == :idle and session_has_approved_plan?(session)
  end

  defp session_has_approved_plan?(session) do
    session.active_plan_id != nil and
      case Map.get(session.plans || %{}, session.active_plan_id) do
        %Plan{status: :approved} -> true
        _ -> false
      end
  end

  # -- Turn execution -----------------------------------------------------------

  defp execute_turn(session, turn, opts, start_time) do
    # 1. Select Muse
    muse = select_muse(session, opts)

    # 2. Build prompt bundle
    prompt_opts = Keyword.get(opts, :prompt_opts, [])

    bundle =
      Assembler.build(
        session,
        muse,
        turn.user_text || "",
        Keyword.merge(prompt_opts, turn_id: turn.id)
      )

    # 3. Prepare provider request
    provider_config = Keyword.get(opts, :provider_config, ProviderConfig.fake())
    request_opts = Keyword.get(opts, :request_options, [])
    request = ModelPreparer.to_request(bundle, provider_config, request_opts)
    request = merge_request_options(request, request_opts)
    request = hydrate_previous_response_id(request, session, request_opts)

    # 4. Call provider
    provider_module = resolve_provider_module(opts, request)

    # Build conductor overhead event specs (always emitted)
    conductor_specs = [
      muse_selected_spec(muse),
      session_status_changed_spec(session.status, :running),
      prompt_prepared_spec(bundle),
      provider_request_started_spec(request, bundle)
    ]

    case stream_provider(provider_module, request, session, turn) do
      {:ok, response, provider_event_specs} ->
        if response_has_tool_calls?(response) do
          # Delegate to ToolLoop for iterative tool execution
          tool_loop_opts =
            [
              provider_module: provider_module,
              tool_runner: Keyword.get(opts, :tool_runner, Muse.Tool.Runner),
              limits: Keyword.get(opts, :limits, nil)
            ]
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)

          case ToolLoop.run(
                 session,
                 turn,
                 muse,
                 bundle,
                 request,
                 response,
                 provider_event_specs,
                 tool_loop_opts
               ) do
            {:ok, tool_loop_result} ->
              # NOTE: provider_event_specs are NOT prepended here because
              # ToolLoop.run/8 seeds state.event_specs with initial_event_specs
              # (== provider_event_specs) and includes them in its result.
              # Prepending them again would duplicate provider events.
              all_specs =
                conductor_specs ++
                  tool_loop_result.event_specs ++
                  [
                    {:muse, :assistant_message,
                     %{text: tool_loop_result.assistant_text, streamed?: true},
                     [visibility: :user, muse_id: muse.id]},
                    session_status_changed_spec(:running, :idle)
                  ]

              finalize_with_specs(
                session,
                turn,
                muse,
                tool_loop_result.assistant_text,
                all_specs,
                start_time,
                provider_module: provider_module,
                request: request,
                bundle: bundle,
                tool_loop_provider_state: tool_loop_result.provider_state,
                patch_proposals: tool_loop_result.patch_proposals
              )

            {:cancelled, tool_loop_result} ->
              # Same as above: provider_event_specs are already inside
              # tool_loop_result.event_specs; do not prepend them again.
              all_specs =
                conductor_specs ++
                  tool_loop_result.event_specs ++
                  [
                    {:conductor, :tool_loop_cancelled, %{iterations: tool_loop_result.iterations},
                     [visibility: :debug]},
                    {:muse, :assistant_message,
                     %{text: tool_loop_result.assistant_text, streamed?: false},
                     [visibility: :user, muse_id: muse.id]},
                    session_status_changed_spec(:running, :idle)
                  ]

              finalize_with_specs(
                session,
                turn,
                muse,
                tool_loop_result.assistant_text,
                all_specs,
                start_time,
                provider_module: provider_module,
                request: request,
                bundle: bundle,
                tool_loop_provider_state: tool_loop_result.provider_state,
                patch_proposals: tool_loop_result.patch_proposals
              )
          end
        else
          # No tool calls — original finalize path
          finalize_turn(
            session,
            turn,
            muse,
            bundle,
            request,
            response,
            provider_event_specs,
            start_time,
            provider_module: provider_module
          )
        end

      {:error, reason, provider_event_specs} ->
        all_specs =
          conductor_specs ++
            provider_event_specs ++
            [session_status_changed_spec(:running, :idle)]

        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          Telemetry.turn_stop(),
          Telemetry.turn_stop_measurements(duration),
          Telemetry.turn_stop_metadata(session_id: session.id, turn_id: turn.id, status: :failed)
        )

        {:error, %{reason: reason, event_specs: all_specs}}
    end
  end

  defp resolve_provider_module(opts, request) do
    if Keyword.has_key?(opts, :provider_module) do
      Keyword.fetch!(opts, :provider_module)
    else
      case ProviderRouter.resolve(request.provider) do
        {:ok, module} ->
          if Code.ensure_loaded?(module), do: module, else: FakeProvider

        {:error, _reason} ->
          FakeProvider
      end
    end
  end

  defp response_has_tool_calls?(%{tool_calls: calls}) when is_list(calls) and calls != [],
    do: true

  defp response_has_tool_calls?(_), do: false

  defp finalize_with_specs(session, turn, muse, assistant_text, all_event_specs, start_time, opts) do
    turn = %{turn | selected_muse: Atom.to_string(muse.id)}
    turn = Turn.mark_streamed(turn)
    {:ok, turn} = Turn.transition(turn, :completed, completed_at: DateTime.utc_now())

    # Preserve provider_state through the tool-loop path.
    # The last provider response's provider_state is carried via the
    # ToolLoop result — merge it back into the session.
    session = merge_tool_loop_provider_state(session, opts)

    {:ok, session} = Session.transition(session, :idle)
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      Telemetry.turn_stop(),
      Telemetry.turn_stop_measurements(duration),
      Telemetry.turn_stop_metadata(session_id: session.id, turn_id: turn.id, status: :completed)
    )

    result = %{
      assistant_text: assistant_text,
      selected_muse: muse,
      prompt_bundle: nil,
      request: nil,
      response: nil,
      session: session,
      turn: turn,
      event_specs: all_event_specs
    }

    # Post-process for plan creation when using Planning Muse
    result =
      case maybe_add_plan_to_result(result, session, turn, muse, start_time, opts) do
        {:ok, r} -> r
        r -> r
      end

    # Post-process for patch proposal capture when using Coding Muse
    result = maybe_capture_patch_proposal(result, muse, opts)

    {:ok, result}
  end

  # -- Provider streaming -------------------------------------------------------

  defp stream_provider(provider_module, request, session, turn) do
    provider_start_time = System.monotonic_time(:millisecond)

    :telemetry.execute(
      Telemetry.provider_start(),
      %{},
      Telemetry.provider_start_metadata(
        session_id: session.id,
        turn_id: turn.id,
        provider: request.provider,
        model: request.model
      )
    )

    # Collect LLM events during the synchronous stream call using a
    # process-dictionary key scoped by a unique ref. This is safe for
    # concurrent use because each call gets its own key.
    collector_key = {__MODULE__, :llm_events, make_ref()}
    Process.put(collector_key, [])

    emit_fn = fn llm_event ->
      Process.put(collector_key, [llm_event | Process.get(collector_key)])
      :ok
    end

    result = provider_module.stream(request, emit_fn)

    llm_events = Process.get(collector_key) |> Enum.reverse()
    Process.delete(collector_key)

    case result do
      {:ok, response} ->
        provider_duration = System.monotonic_time(:millisecond) - provider_start_time
        usage = response.usage || %{}
        token_counts = extract_token_counts(usage)

        :telemetry.execute(
          Telemetry.provider_stop(),
          Telemetry.provider_stop_measurements(provider_duration, token_counts),
          Telemetry.provider_stop_metadata(session_id: session.id, turn_id: turn.id, usage: usage)
        )

        event_specs = convert_llm_events(llm_events)
        {:ok, response, event_specs}

      {:error, reason} ->
        provider_duration = System.monotonic_time(:millisecond) - provider_start_time

        :telemetry.execute(
          Telemetry.provider_error(),
          %{duration_ms: provider_duration},
          Telemetry.provider_error_metadata(
            session_id: session.id,
            turn_id: turn.id,
            error_type: :provider_error
          )
        )

        event_specs =
          convert_llm_events(llm_events) ++
            [{:conductor, :provider_error, %{error_type: :provider_error}, [visibility: :debug]}]

        {:error, reason, event_specs}
    end
  end

  # -- LLM event conversion ----------------------------------------------------

  @spec convert_llm_events([Muse.LLM.Event.t()]) :: [event_spec()]
  defp convert_llm_events(llm_events) do
    {specs, _delta_index} =
      Enum.flat_map_reduce(llm_events, 0, fn llm_event, delta_index ->
        convert_llm_event(llm_event, delta_index)
      end)

    specs
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :response_started}, delta_index) do
    {[{:conductor, :provider_response_started, %{}, [visibility: :debug]}], delta_index}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :assistant_delta, text: text}, delta_index) do
    spec = {:muse, :assistant_delta, %{text: text, index: delta_index}, [visibility: :user]}
    {[spec], delta_index + 1}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :assistant_completed}, delta_index) do
    # Not emitted as a separate Muse event; the final assistant_message
    # event (built from the response content) covers the complete text.
    {[], delta_index}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :tool_call_started, tool_call: tc}, delta_index) do
    spec =
      {:conductor, :tool_call_requested, %{tool_name: tc.name, tool_call_id: tc.id},
       [visibility: :debug]}

    {[spec], delta_index}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :tool_call_delta}, delta_index) do
    {[], delta_index}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :tool_call_completed, tool_call: tc}, delta_index) do
    spec =
      {:conductor, :tool_call_completed, %{tool_name: tc.name, tool_call_id: tc.id},
       [visibility: :debug]}

    {[spec], delta_index}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :response_completed, usage: usage}, delta_index) do
    summary = summarize_usage(usage)
    {[{:conductor, :provider_response_completed, summary, [visibility: :debug]}], delta_index}
  end

  defp convert_llm_event(%Muse.LLM.Event{type: :provider_error}, delta_index) do
    {[{:conductor, :provider_error, %{error_type: :provider_error}, [visibility: :debug]}],
     delta_index}
  end

  # Catch-all: unexpected LLM event types or malformed terms are safely
  # ignored instead of raising. Emits a debug summary so operators can
  # spot unknown provider events in logs without crashing the pipeline.
  defp convert_llm_event(%Muse.LLM.Event{type: unknown_type}, delta_index) do
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

  # -- Turn finalization --------------------------------------------------------

  defp finalize_turn(
         session,
         turn,
         muse,
         bundle,
         request,
         response,
         provider_event_specs,
         start_time,
         extra_opts
       )
       when is_list(extra_opts) do
    assistant_text = response.content || ""

    # Build conductor overhead event specs
    conductor_specs = [
      muse_selected_spec(muse),
      session_status_changed_spec(session.status, :running),
      prompt_prepared_spec(bundle),
      provider_request_started_spec(request, bundle)
    ]

    # Build final event specs
    final_specs = [
      {:muse, :assistant_message, %{text: assistant_text, streamed?: true},
       [visibility: :user, muse_id: muse.id]},
      session_status_changed_spec(:running, :idle)
    ]

    all_event_specs = conductor_specs ++ provider_event_specs ++ final_specs

    # Update turn
    turn = %{turn | selected_muse: Atom.to_string(muse.id)}
    turn = Turn.mark_streamed(turn)
    {:ok, turn} = Turn.transition(turn, :completed, completed_at: DateTime.utc_now())

    # Merge safe provider state from response into session before transitioning
    session = merge_provider_state(session, response)

    # Transition session back to idle
    {:ok, session} = Session.transition(session, :idle)

    # Telemetry: turn stop
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      Telemetry.turn_stop(),
      Telemetry.turn_stop_measurements(duration),
      Telemetry.turn_stop_metadata(session_id: session.id, turn_id: turn.id, status: :completed)
    )

    result = %{
      assistant_text: assistant_text,
      selected_muse: muse,
      prompt_bundle: bundle,
      request: request,
      response: response,
      session: session,
      turn: turn,
      event_specs: all_event_specs
    }

    # Build opts for plan post-processing, merging extra_opts
    plan_opts =
      Keyword.merge(extra_opts,
        request: request,
        bundle: bundle
      )

    # Post-process for plan creation when using Planning Muse
    maybe_add_plan_to_result(result, session, turn, muse, start_time, plan_opts)
  end

  # -- Plan finalization --------------------------------------------------------

  @doc false
  # Post-process a turn result to handle Planning Muse plan creation.
  #
  # When the selected muse is :planning, attempts to parse the assistant
  # text as a structured plan via PlanParser. On success, replaces the
  # assistant message with Plan.render/1 output, emits :plan_created event,
  # persists the plan on the session, and transitions the session to
  # :awaiting_plan_approval. On failure, attempts one repair call to the
  # provider only when the output carries plan-specific markers; plain text
  # and generic non-plan JSON remain normal assistant responses.
  defp maybe_add_plan_to_result(result, session, turn, muse, start_time, opts) do
    if muse.id == :planning do
      assistant_text = result.assistant_text

      case parse_plan_output(assistant_text) do
        {:ok, plan} ->
          finalize_as_plan(result, session, turn, muse, plan, start_time)

        {:error, _parse_errors} ->
          if looks_like_plan_json?(assistant_text) do
            do_plan_repair(result, session, turn, muse, assistant_text, start_time, opts)
          else
            {:ok, result}
          end
      end
    else
      {:ok, result}
    end
  end

  defp parse_plan_output(text) do
    PlanParser.parse(text, extract: :auto)
  end

  # Check if text looks like it is trying to be structured plan JSON.
  # A generic JSON object (for example {"status": "ok"}) is not enough:
  # repair should only run when the output carries plan-specific markers.
  defp looks_like_plan_json?(text) when is_binary(text) do
    String.contains?(text, "\"objective\"") or
      String.contains?(text, "\"tasks\"") or
      String.contains?(text, "'objective'") or
      String.contains?(text, "'tasks'")
  end

  defp looks_like_plan_json?(_), do: false

  defp finalize_as_plan(result, _session, turn, muse, plan, _start_time) do
    plan = prepare_plan_identity(plan, result.session, turn, muse)

    {:ok, plan} = Plan.transition(plan, :awaiting_approval)
    {plan, approval_request} = PlanApprovalRequest.attach(plan)
    plan_text = Plan.render(plan)

    # Remove the old session_status_changed(:running, :idle) plus every
    # user-visible assistant delta/message that could contain raw structured
    # JSON. Keeping streamed deltas would make EventStream render raw JSON or
    # prose alongside the final rendered plan.
    clean_specs =
      result.event_specs
      |> drop_assistant_output_specs()
      |> Enum.reject(fn
        {:conductor, :session_status_changed, %{to: :idle}, _opts} -> true
        _ -> false
      end)

    plan_specs = [
      {:muse, :assistant_message, %{text: plan_text, streamed?: false},
       [visibility: :user, muse_id: result.selected_muse.id]},
      {:conductor, :plan_created,
       %{
         plan_id: plan.id,
         version: plan.version,
         status: plan.status,
         objective: safe_objective_summary(plan.objective),
         task_count: length(plan.tasks),
         approval_request: approval_request
       }, [visibility: :user]},
      approval_requested_spec(approval_request),
      session_status_changed_spec(:running, :awaiting_plan_approval)
    ]

    {:ok, plan_session} = Session.transition(result.session, :awaiting_plan_approval)
    plan_session = store_plan_in_session(plan_session, plan)

    plan_result =
      result
      |> Map.put(:assistant_text, plan_text)
      |> Map.put(:session, plan_session)
      |> Map.put(:event_specs, clean_specs ++ plan_specs)
      |> Map.put(:plan, plan)

    {:ok, plan_result}
  end

  defp prepare_plan_identity(%Plan{} = plan, %Session{} = session, %Turn{} = turn, muse) do
    plan
    |> sanitize_provider_plan_control_fields(session, muse)
    |> put_plan_version(session)
    |> put_plan_id(turn)
  end

  @provider_metadata_control_keys MapSet.new([
                                    "approval",
                                    "approval_record",
                                    "approval_audit",
                                    "approvals",
                                    "active_approval",
                                    "approval_binding",
                                    "approval_request",
                                    "rejection",
                                    "rejection_record",
                                    "rejection_audit",
                                    "rejections"
                                  ])

  defp sanitize_provider_plan_control_fields(%Plan{} = plan, %Session{id: session_id}, muse) do
    %{
      plan
      | session_id: session_id,
        version: nil,
        created_by: muse_id(muse),
        approved_at: nil,
        rejected_at: nil,
        completed_at: nil,
        approvals: [],
        metadata: sanitize_provider_plan_metadata(plan.metadata)
    }
  end

  defp sanitize_provider_plan_metadata(metadata) when is_map(metadata) do
    Map.reject(metadata, fn {key, _value} ->
      key
      |> normalize_provider_metadata_key()
      |> then(&MapSet.member?(@provider_metadata_control_keys, &1))
    end)
  end

  defp sanitize_provider_plan_metadata(_metadata), do: %{}

  defp normalize_provider_metadata_key(key) when is_atom(key),
    do: normalize_provider_metadata_key(Atom.to_string(key))

  defp normalize_provider_metadata_key(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_provider_metadata_key(key),
    do: key |> inspect() |> normalize_provider_metadata_key()

  defp muse_id(%{id: muse_id}) when is_atom(muse_id), do: Atom.to_string(muse_id)
  defp muse_id(%{id: muse_id}) when is_binary(muse_id), do: muse_id
  defp muse_id(_muse), do: nil

  defp put_plan_version(%Plan{} = plan, %Session{} = session) do
    %{plan | version: next_plan_version(session)}
  end

  defp next_plan_version(%Session{plans: plans}) when is_map(plans) and map_size(plans) > 0 do
    plans
    |> Map.values()
    |> Enum.map(&plan_version/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp next_plan_version(_session), do: 1

  defp plan_version(%Plan{version: version}) when is_integer(version), do: version
  defp plan_version(_plan), do: 0

  defp put_plan_id(%Plan{} = plan, %Turn{id: turn_id}) do
    put_plan_field_if_blank(plan, :id, generated_plan_id(turn_id))
  end

  defp put_plan_field_if_blank(plan, field, value) do
    if blank_plan_field?(Map.get(plan, field)) do
      Map.put(plan, field, value)
    else
      plan
    end
  end

  defp blank_plan_field?(nil), do: true
  defp blank_plan_field?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_plan_field?(_value), do: false

  defp generated_plan_id(turn_id) when is_binary(turn_id) do
    case sanitize_plan_id_part(turn_id) do
      "" -> random_plan_id()
      sanitized -> "plan_" <> sanitized
    end
  end

  defp generated_plan_id(_turn_id), do: random_plan_id()

  defp random_plan_id do
    suffix =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)

    "plan_#{suffix}"
  end

  defp sanitize_plan_id_part(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
  end

  defp store_plan_in_session(%Session{} = session, %Plan{} = plan) do
    plans = Map.put(session.plans || %{}, plan.id, plan)

    %{session | active_plan_id: plan.id, plans: plans}
  end

  # -- Patch proposal capture (PR17) --------------------------------------------

  # When Coding Muse completes a turn with patch_propose tool calls,
  # capture the proposals and transition the session to :awaiting_patch_approval.
  # Full `/approve patch` command lifecycle is owned by lane06.
  defp maybe_capture_patch_proposal(result, %{id: :coding} = _muse, opts) do
    proposals = Keyword.get(opts, :patch_proposals, [])

    if proposals != [] do
      latest_proposal = List.last(proposals)
      session = result.session

      case build_pending_patch(latest_proposal, session) do
        {:ok, %Patch{} = pending_patch} ->
          # Transition session to :awaiting_patch_approval instead of :idle.
          {:ok, updated_session} = Session.transition(session, :awaiting_patch_approval)
          updated_session = %{updated_session | pending_patch: pending_patch}

          guidance = patch_proposal_guidance(pending_patch)
          patch_event_data = patch_proposed_event_data(pending_patch, latest_proposal)

          %{
            result
            | session: updated_session,
              assistant_text: guidance,
              event_specs:
                result.event_specs ++
                  [
                    {:conductor, :patch_proposed, patch_event_data, [visibility: :user]},
                    {:conductor, :patch_approval_requested,
                     Map.take(patch_event_data, [:patch_id, :plan_id, :hash, :affected_files]),
                     [visibility: :user]}
                  ]
          }

        {:error, _reason} ->
          result
      end
    else
      result
    end
  end

  defp maybe_capture_patch_proposal(result, _muse, _opts), do: result

  defp build_pending_patch(proposal, %Session{} = session) when is_map(proposal) do
    with %Plan{status: :approved} = plan <- active_approved_plan(session),
         diff when is_binary(diff) and diff != "" <-
           proposal_get(proposal, :diff) || proposal_get(proposal, :patch_content) do
      metadata =
        %{
          summary: proposal_get(proposal, :summary) || proposal_get(proposal, :description),
          tool_call_id: proposal_get(proposal, :tool_call_id),
          proposed_at: DateTime.utc_now()
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      attrs = [
        session_id: session.id,
        plan_id: proposal_get(proposal, :plan_id) || plan.id || session.active_plan_id,
        plan_version: proposal_get(proposal, :plan_version) || plan.version,
        plan_hash: proposal_get(proposal, :plan_hash) || PlanBinding.content_hash(plan),
        diff: diff,
        metadata: metadata
      ]

      attrs =
        maybe_put_patch_id(
          attrs,
          proposal_get(proposal, :patch_id) || proposal_get(proposal, :id)
        )

      attrs = maybe_put_affected_files(attrs, proposal_files(proposal))

      Patch.new(attrs)
    else
      _ -> {:error, :invalid_patch_proposal}
    end
  end

  defp active_approved_plan(%Session{active_plan_id: active_plan_id, plans: plans})
       when is_binary(active_plan_id) and is_map(plans) do
    case Map.get(plans, active_plan_id) do
      %Plan{status: :approved} = plan -> plan
      _ -> nil
    end
  end

  defp active_approved_plan(_session), do: nil

  defp maybe_put_patch_id(attrs, patch_id) when is_binary(patch_id) and patch_id != "" do
    Keyword.put(attrs, :id, patch_id)
  end

  defp maybe_put_patch_id(attrs, _patch_id), do: attrs

  defp maybe_put_affected_files(attrs, files) when is_list(files) and files != [] do
    Keyword.put(attrs, :affected_files, files)
  end

  defp maybe_put_affected_files(attrs, _files), do: attrs

  defp proposal_files(proposal) do
    proposal_get(proposal, :affected_files) || proposal_get(proposal, :target_files) || []
  end

  defp patch_proposed_event_data(%Patch{} = patch, proposal) do
    %{
      patch_id: patch.id,
      plan_id: patch.plan_id,
      hash: patch.hash,
      affected_files: patch.affected_files,
      diff_ref: patch.hash
    }
    |> maybe_put_event_field(:tool_call_id, proposal_get(proposal, :tool_call_id))
  end

  defp maybe_put_event_field(data, _key, nil), do: data
  defp maybe_put_event_field(data, _key, ""), do: data
  defp maybe_put_event_field(data, key, value), do: Map.put(data, key, value)

  defp patch_proposal_guidance(%Patch{} = patch) do
    target_files = patch.affected_files || []
    description = metadata_get(patch.metadata, :summary) || ""
    content_length = byte_size(patch.diff || "")

    patch_proposal_guidance_text(target_files, description, content_length)
  end

  defp patch_proposal_guidance(proposal) do
    target_files = proposal_files(proposal)
    description = proposal_get(proposal, :description) || proposal_get(proposal, :summary) || ""

    content_length =
      proposal_get(proposal, :content_length) ||
        byte_size(proposal_get(proposal, :diff) || proposal_get(proposal, :patch_content) || "")

    patch_proposal_guidance_text(target_files, description, content_length)
  end

  defp patch_proposal_guidance_text(target_files, description, content_length) do
    file_list = if target_files != [], do: Enum.join(target_files, ", "), else: "(none specified)"

    """
    📋 Patch proposal recorded (#{content_length} chars). Awaiting approval.

    **Files:** #{file_list}
    **Description:** #{description}

    Use `/approve patch` to authorize this proposal, or `/reject patch` to discard it.
    No files have been modified.
    """
    |> String.trim()
  end

  defp proposal_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp metadata_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp metadata_get(_map, _key), do: nil

  defp drop_assistant_output_specs(event_specs) do
    Enum.reject(event_specs, fn
      {:muse, type, _data, _opts} when type in [:assistant_delta, :assistant_message] -> true
      _ -> false
    end)
  end

  defp safe_objective_summary(objective) when is_binary(objective) do
    Redactor.preview_text(objective, max_length: 200)
  end

  defp safe_objective_summary(_objective), do: nil

  defp do_plan_repair(result, session, turn, muse, assistant_text, start_time, opts) do
    provider_module = Keyword.get(opts, :provider_module)
    request = Keyword.get(opts, :request)

    if is_nil(provider_module) or is_nil(request) do
      {:ok, safe_invalid_plan_result(result, session)}
    else
      errors =
        case parse_plan_output(assistant_text) do
          {:error, errs} -> errs
          _ -> ["Invalid plan format"]
        end

      repair_prompt_text = PlanParser.repair_prompt(assistant_text, errors: errors)
      request_options = request.options || %{}

      repair_options =
        Map.put(request_options, :fake_iteration, (request_options[:fake_iteration] || 0) + 1)

      repair_message = Message.user(repair_prompt_text)

      repair_request = %{
        request
        | messages: [repair_message],
          tools: [],
          tool_choice: :none,
          options: repair_options
      }

      emit_fn = fn _llm_event -> :ok end

      case provider_module.stream(repair_request, emit_fn) do
        {:ok, repair_response} ->
          repair_text = repair_response.content || ""

          case parse_plan_output(repair_text) do
            {:ok, plan} ->
              finalize_as_plan(result, session, turn, muse, plan, start_time)

            {:error, _repair_errors} ->
              {:ok, safe_invalid_plan_result(result, session)}
          end

        {:error, _reason} ->
          {:ok, safe_invalid_plan_result(result, session)}
      end
    end
  end

  defp safe_invalid_plan_result(result, session) do
    {:ok, safe_session} = Session.transition(session, :idle)

    safe_text =
      "I was unable to generate a valid structured plan from the output. " <>
        "Please try again or rephrase your request."

    safe_specs =
      result.event_specs
      |> drop_assistant_output_specs()
      |> Kernel.++([
        {:muse, :assistant_message, %{text: safe_text, streamed?: false},
         safe_assistant_message_opts(result)}
      ])

    result
    |> Map.put(:assistant_text, safe_text)
    |> Map.put(:session, safe_session)
    |> Map.put(:event_specs, safe_specs)
  end

  defp safe_assistant_message_opts(%{selected_muse: %{id: muse_id}}) do
    [visibility: :user, muse_id: muse_id]
  end

  defp safe_assistant_message_opts(_result), do: [visibility: :user]

  # -- Event spec builders ------------------------------------------------------

  defp muse_selected_spec(muse) do
    {:conductor, :muse_selected,
     %{muse_id: muse.id, display_name: muse.display_name, role: muse.role},
     [visibility: :internal, muse_id: muse.id]}
  end

  defp session_status_changed_spec(from, to) do
    {:conductor, :session_status_changed, %{from: from, to: to}, [visibility: :internal]}
  end

  defp prompt_prepared_spec(bundle) do
    {:conductor, :prompt_prepared,
     %{
       bundle_id: bundle.id,
       muse_id: bundle.muse_id,
       layer_count: length(bundle.layers),
       message_count: length(bundle.messages),
       tool_count: length(bundle.tools),
       token_estimate: bundle.token_estimate
     }, [visibility: :debug]}
  end

  defp provider_request_started_spec(request, bundle) do
    {:conductor, :provider_request_started,
     %{
       bundle_id: bundle.id,
       provider: request.provider,
       model: request.model,
       message_count: length(request.messages),
       tool_count: length(request.tools || [])
     }, [visibility: :debug]}
  end

  defp approval_requested_spec(approval_request) do
    {:conductor, :approval_requested, approval_request, [visibility: :user]}
  end

  # -- Request option merging --------------------------------------------------

  # Merge any provider-specific options (e.g. :fake_events, :fake_error)
  # from request_options into the Request's options map. ModelPreparer
  # does not forward these, so we handle it here.
  defp merge_request_options(request, opts) do
    case Keyword.get(opts, :options) do
      nil ->
        request

      extra when is_map(extra) ->
        %{request | options: Map.merge(request.options || %{}, extra)}

      _ ->
        request
    end
  end

  # -- Previous response ID hydration -------------------------------------------

  # Hydrate `request.previous_response_id` from `session.provider_state`
  # when the caller did not explicitly provide one via request_opts.
  # This ensures conversation continuity (OpenAI Responses API) is
  # preserved across turns without requiring the caller to thread it.
  defp hydrate_previous_response_id(request, session, request_opts) do
    # If the caller explicitly set previous_response_id (via request_opts
    # or provider config), respect it — do not overwrite.
    if request.previous_response_id != nil do
      request
    else
      # Check request_opts :previous_response_id first (explicit override)
      case Keyword.get(request_opts, :previous_response_id) do
        nil ->
          # Fall back to session.provider_state[:previous_response_id]
          from_state = get_in(session.provider_state || %{}, [:previous_response_id])

          if from_state, do: %{request | previous_response_id: from_state}, else: request

        explicit ->
          %{request | previous_response_id: explicit}
      end
    end
  end

  # -- Provider state merging ---------------------------------------------------

  @doc """
  Merge safe keys from `response.provider_state` into `session.provider_state`.

  Only whitelisted safe keys are merged — raw provider payloads, secrets,
  and opaque blobs are excluded.  Existing unrelated keys in the session's
  provider_state are preserved.

  ## Safe keys

    * `:previous_response_id` — conversation continuity token

  Any key matching `Muse.MetadataSanitizer.sensitive_key?/1` is dropped
  before merge.  The `:raw` key (if present in provider_state) is also
  excluded to prevent storing full wire payloads.
  """
  @spec merge_provider_state(Session.t(), Muse.LLM.Response.t()) :: Session.t()
  def merge_provider_state(session, response) do
    incoming = response.provider_state || %{}
    safe_state = filter_safe_provider_state(incoming)

    existing = session.provider_state || %{}
    merged = Map.merge(existing, safe_state)

    %{session | provider_state: merged}
  end

  # Only allow whitelisted safe keys through.  Drops anything sensitive
  # or potentially large (e.g. :raw payloads, :access_token, etc.).
  @safe_provider_state_keys [:previous_response_id]

  defp filter_safe_provider_state(provider_state) when is_map(provider_state) do
    provider_state
    |> Map.take(@safe_provider_state_keys)
    |> reject_sensitive_values()
  end

  defp filter_safe_provider_state(_), do: %{}

  # Double-check: even whitelisted keys get their values rejected if
  # the key happens to be sensitive (defence in depth — the whitelist
  # should already exclude them, but belt-and-suspenders).
  defp reject_sensitive_values(state) when is_map(state) do
    Map.new(state, fn {k, v} ->
      if MetadataSanitizer.sensitive_key?(k) do
        {k, "**REDACTED**"}
      else
        {k, v}
      end
    end)
  end

  # In the tool-loop path, the Conductor does not have direct access to
  # the final provider response. The ToolLoop carries provider_state
  # via its result map. Extract and merge if available.
  defp merge_tool_loop_provider_state(session, opts) do
    case Keyword.get(opts, :tool_loop_provider_state) do
      nil ->
        session

      state when is_map(state) ->
        merge_provider_state(session, %Muse.LLM.Response{provider_state: state})

      _ ->
        session
    end
  end

  # -- Usage helpers ------------------------------------------------------------

  defp summarize_usage(nil), do: %{}

  defp summarize_usage(usage) when is_map(usage) do
    Map.take(usage, [:prompt_tokens, :completion_tokens, :total_tokens])
  end

  defp extract_token_counts(usage) when is_map(usage) do
    Map.take(usage, [:prompt_tokens, :completion_tokens, :total_tokens])
  end

  defp extract_token_counts(_), do: %{}
end
