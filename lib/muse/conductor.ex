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

  alias Muse.{MuseRegistry, Session, Telemetry, Turn}
  alias Muse.Conductor.ToolLoop
  alias Muse.LLM.{FakeProvider, ProviderConfig}
  alias Muse.Prompt.{Assembler, ModelPreparer, Redactor}

  @type event_spec :: {atom(), atom(), map(), keyword()}

  # -- Public API ---------------------------------------------------------------

  @doc """
  Run the Conductor for a turn.

  Selects the appropriate Muse, builds the prompt bundle, calls the
  provider, and returns the result with event specifications for the
  SessionServer to emit.

  ## Options

    * `:provider_module` — provider module (default: `Muse.LLM.FakeProvider`)
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

  For PR07a, the Planning Muse is selected for all sessions that are in
  idle, running, planning, or awaiting_plan_approval status. The Coding Muse
  is never selected before plan approval.

  ## Examples

      iex> session = Muse.Session.new(workspace: "/tmp", status: :idle)
      iex> muse = Muse.Conductor.select_muse(session, [])
      iex> muse.id
      :planning
  """
  @spec select_muse(Session.t(), keyword()) :: Muse.MuseProfile.t()
  def select_muse(session, _opts) do
    if planning_muse_applicable?(session) do
      MuseRegistry.get(:planning)
    else
      # Default to Planning Muse until plan-approval flow is implemented
      MuseRegistry.get(:planning)
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

    # 4. Call provider
    provider_module = Keyword.get(opts, :provider_module, FakeProvider)

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
                start_time
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
                start_time
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
            start_time
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

  defp response_has_tool_calls?(%{tool_calls: calls}) when is_list(calls) and calls != [],
    do: true

  defp response_has_tool_calls?(_), do: false

  defp finalize_with_specs(session, turn, muse, assistant_text, all_event_specs, start_time) do
    turn = %{turn | selected_muse: Atom.to_string(muse.id)}
    turn = Turn.mark_streamed(turn)
    {:ok, turn} = Turn.transition(turn, :completed, completed_at: DateTime.utc_now())
    {:ok, session} = Session.transition(session, :idle)

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      Telemetry.turn_stop(),
      Telemetry.turn_stop_measurements(duration),
      Telemetry.turn_stop_metadata(session_id: session.id, turn_id: turn.id, status: :completed)
    )

    {:ok,
     %{
       assistant_text: assistant_text,
       selected_muse: muse,
       prompt_bundle: nil,
       request: nil,
       response: nil,
       session: session,
       turn: turn,
       event_specs: all_event_specs
     }}
  end

  # -- Muse selection -----------------------------------------------------------

  defp planning_muse_applicable?(session) do
    session.status in [:idle, :running, :planning, :awaiting_plan_approval]
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
         start_time
       ) do
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

    # Transition session back to idle
    {:ok, session} = Session.transition(session, :idle)

    # Telemetry: turn stop
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      Telemetry.turn_stop(),
      Telemetry.turn_stop_measurements(duration),
      Telemetry.turn_stop_metadata(session_id: session.id, turn_id: turn.id, status: :completed)
    )

    {:ok,
     %{
       assistant_text: assistant_text,
       selected_muse: muse,
       prompt_bundle: bundle,
       request: request,
       response: response,
       session: session,
       turn: turn,
       event_specs: all_event_specs
     }}
  end

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
