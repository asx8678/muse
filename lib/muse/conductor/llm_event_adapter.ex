defmodule Muse.Conductor.LLMEventAdapter do
  @moduledoc """
  Converts `Muse.LLM.Event` structs from provider streaming into
  Conductor event specification tuples.

  Both `Muse.Conductor` and `Muse.Conductor.ToolLoop` perform the same
  conversion during provider streaming and tool-loop finalization. This
  module centralizes that logic to eliminate duplication.

  ## Lifecycle

  Called during provider streaming (via `stream_provider/6` in Conductor)
  and during tool-loop iterations (in ToolLoop). The resulting event
  specs are folded into the session event stream by SessionServer.

  All functions are pure — they accept and return data structures.
  """

  alias Muse.LLM.Event

  @type event_spec :: {atom(), atom(), map(), keyword()}

  @doc """
  Convert a list of `Muse.LLM.Event` structs into event specification tuples.

  Uses `Enum.flat_map_reduce` to track a delta index across all events,
  incrementing it for each `:assistant_delta` so that downstream consumers
  can correlate delta indices with the original stream order.
  """
  @spec convert_llm_events([Event.t()]) :: [event_spec()]
  def convert_llm_events(llm_events) do
    {specs, _delta_index} =
      Enum.flat_map_reduce(llm_events, 0, fn llm_event, delta_index ->
        convert_llm_event(llm_event, delta_index)
      end)

    specs
  end

  @doc """
  Convert a single `Muse.LLM.Event` into event specification tuples.

  Returns `{spec_list, new_delta_index}` where `spec_list` is a list of
  event spec tuples (may be empty for skipped events) and `new_delta_index`
  is the updated delta counter.
  """
  @spec convert_llm_event(Event.t(), non_neg_integer()) ::
          {[event_spec()], non_neg_integer()}
  def convert_llm_event(%Event{type: :response_started}, delta_index) do
    {[{:conductor, :provider_response_started, %{}, [visibility: :debug]}], delta_index}
  end

  def convert_llm_event(%Event{type: :assistant_delta, text: text}, delta_index) do
    spec = {:muse, :assistant_delta, %{text: text, index: delta_index}, [visibility: :user]}
    {[spec], delta_index + 1}
  end

  def convert_llm_event(%Event{type: :assistant_completed}, delta_index) do
    # Not emitted as a separate Muse event; the final assistant_message
    # event (built from the response content) covers the complete text.
    {[], delta_index}
  end

  def convert_llm_event(%Event{type: :tool_call_started, tool_call: tc}, delta_index) do
    spec =
      {:conductor, :tool_call_requested, %{tool_name: tc.name, tool_call_id: tc.id},
       [visibility: :debug]}

    {[spec], delta_index}
  end

  def convert_llm_event(%Event{type: :tool_call_delta}, delta_index) do
    {[], delta_index}
  end

  def convert_llm_event(%Event{type: :tool_call_completed, tool_call: tc}, delta_index) do
    spec =
      {:conductor, :tool_call_completed, %{tool_name: tc.name, tool_call_id: tc.id},
       [visibility: :debug]}

    {[spec], delta_index}
  end

  def convert_llm_event(%Event{type: :response_completed, usage: usage}, delta_index) do
    summary = summarize_usage(usage)
    {[{:conductor, :provider_response_completed, summary, [visibility: :debug]}], delta_index}
  end

  def convert_llm_event(%Event{type: :provider_error}, delta_index) do
    {[{:conductor, :provider_error, %{error_type: :provider_error}, [visibility: :debug]}],
     delta_index}
  end

  # Catch-all: unexpected LLM event types or malformed terms are safely
  # ignored instead of raising. Emits a debug summary so operators can
  # spot unknown provider events in logs without crashing the pipeline.
  def convert_llm_event(%Event{type: unknown_type}, delta_index) do
    {[
       {:conductor, :provider_event_ignored, %{unhandled_type: unknown_type},
        [visibility: :debug]}
     ], delta_index}
  end

  def convert_llm_event(other, delta_index) do
    {[
       {:conductor, :provider_event_ignored, %{unhandled_type: inspect(other)},
        [visibility: :debug]}
     ], delta_index}
  end

  @doc """
  Mark the first `count` assistant_delta event specs as live-emitted.

  Live-emitted specs are skipped during final event-spec folding in
  SessionServer because they were already broadcast during provider
  streaming. This prevents duplicate PubSub broadcasts.
  """
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

  # -- Private helpers ----------------------------------------------------------

  defp summarize_usage(nil), do: %{}

  defp summarize_usage(usage) when is_map(usage) do
    Map.take(usage, [:prompt_tokens, :completion_tokens, :total_tokens])
  end
end
