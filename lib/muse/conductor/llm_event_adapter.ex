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

  Each event is converted via `convert_llm_event/2` and non-nil results
  are collected in order.
  """
  @spec convert_llm_events([Event.t()]) :: [event_spec()]
  def convert_llm_events(llm_events) do
    llm_events
    |> Enum.with_index()
    |> Enum.map(&convert_llm_event/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Convert a single `Muse.LLM.Event` into an event specification tuple.

  Returns `nil` for events that don't map to session-visible specs
  (e.g. `:response_started`, `:response_completed`).
  """
  @spec convert_llm_event({Event.t(), non_neg_integer()}) :: event_spec() | nil
  def convert_llm_event({%Event{type: :response_started}, _delta_index}), do: nil

  def convert_llm_event({%Event{type: :assistant_delta, text: text}, delta_index}) do
    {{:muse, :assistant_delta, %{text: text, chunk: delta_index},
      [visibility: :user, live_emitted: true]}, delta_index + 1}
    |> then(fn {spec, _} -> spec end)
  end

  def convert_llm_event({%Event{type: :assistant_completed}, _delta_index}), do: nil

  def convert_llm_event({%Event{type: :tool_call_started, tool_call: tc}, _delta_index}) do
    {:muse, :tool_call_started,
     %{
       tool_call_id: tc.id,
       name: tc.name,
       arguments: tc.arguments
     }, [visibility: :internal]}
  end

  def convert_llm_event({%Event{type: :tool_call_delta}, _delta_index}), do: nil

  def convert_llm_event({%Event{type: :tool_call_completed, tool_call: tc}, _delta_index}) do
    {:muse, :tool_call_completed,
     %{
       tool_call_id: tc.id,
       name: tc.name,
       arguments: tc.arguments
     }, [visibility: :internal]}
  end

  def convert_llm_event({%Event{type: :response_completed, usage: usage}, _delta_index}) do
    {:conductor, :response_completed, %{usage: usage}, [visibility: :internal]}
  end

  def convert_llm_event({%Event{type: :provider_error}, _delta_index}) do
    {:conductor, :provider_error, %{}, [visibility: :internal]}
  end

  def convert_llm_event({%Event{type: unknown_type}, _delta_index}) do
    require Logger

    Logger.debug("Conductor: skipping unknown LLM event type: #{inspect(unknown_type)}")
    nil
  end

  def convert_llm_event({other, _delta_index}) do
    require Logger

    Logger.debug("Conductor: skipping unrecognized event: #{inspect(other)}")
    nil
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
    {to_mark, rest} = split_at_deltas(specs, count, [])
    marked = Enum.map(to_mark, &mark_one_live_emitted/1)
    marked ++ rest
  end

  # -- Private helpers ----------------------------------------------------------

  defp split_at_deltas(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp split_at_deltas([], _n, acc), do: {Enum.reverse(acc), []}

  defp split_at_deltas([{_source, :assistant_delta, _data, opts} = spec | rest], n, acc) do
    if Keyword.get(opts, :live_emitted, false) do
      split_at_deltas(rest, n, [spec | acc])
    else
      split_at_deltas(rest, n - 1, [spec | acc])
    end
  end

  defp split_at_deltas([spec | rest], n, acc) do
    split_at_deltas(rest, n, [spec | acc])
  end

  defp mark_one_live_emitted({source, :assistant_delta, data, opts}) do
    {source, :assistant_delta, data, Keyword.put(opts, :live_emitted, true)}
  end

  defp mark_one_live_emitted(spec), do: spec
end
