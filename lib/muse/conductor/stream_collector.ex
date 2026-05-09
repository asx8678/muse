defmodule Muse.Conductor.StreamCollector do
  @moduledoc """
  Thread-safe collector for LLM streaming events.

  Replaces process-dictionary accumulation (`Process.put/get/delete`) so that
  provider callbacks which execute from another process (e.g. async SSE or
  WebSocket providers) can safely emit deltas without losing events or
  corrupting the delta index.

  ## Why not the process dictionary?

  The previous implementation stored the event accumulator and live-delta
  index in the process dictionary of the caller (Conductor/ToolLoop).  The
  `emit_fn` closure captured the dictionary key and called
  `Process.put/get` — which silently writes to **the caller's own**
  dictionary.  When a provider invokes `emit_fn` from a spawned process,
  those writes land in the spawned process's dictionary, invisible to the
  original caller.  Events are lost and the delta index diverges.

  An `Agent` owns a single mutable state cell accessible from any process
  that holds its pid, making it safe for cross-process callbacks.

  ## Lifecycle

  1. `start/0` — spawn the collector Agent
  2. `record/2` — append an LLM event (called inside `emit_fn`)
  3. `mark_live_emitted/1` — record that one delta was emitted live
  4. `collect/1` — retrieve all events + live-emitted count, then stop

  The Agent is short-lived (spanning a single `provider_module.stream/2`
  call) and is always stopped via `collect/1`, so there is no resource leak.
  """

  alias Muse.LLM.Event

  @type t :: pid()

  @doc """
  Start a new collector Agent.

  Returns `{:ok, pid}` on success.  The pid is passed to `record/2`,
  `mark_live_emitted/1`, and `collect/1`.
  """
  @spec start() :: Agent.on_start()
  def start do
    Agent.start_link(fn -> %{events: [], delta_index: 0, live_emitted_count: 0} end)
  end

  @doc """
  Record a single LLM event into the collector.

  Thread-safe: may be called from any process that holds the collector pid.

  Returns `{:delta, text, index}` when the event is an `assistant_delta`
  (useful for live emission), or `:ok` for all other event types.

  The `index` in the return value is the delta's zero-based position among
  all assistant_deltas recorded so far, suitable for the `:index` field in
  the `assistant_delta` event spec.  It always increments for each delta
  regardless of whether `emit_event_fn` is present.
  """
  @spec record(pid(), Event.t()) :: {:delta, String.t(), non_neg_integer()} | :ok
  def record(pid, %Event{type: :assistant_delta, text: text} = event) do
    Agent.get_and_update(pid, fn state ->
      idx = state.delta_index
      new_state = %{state | events: [event | state.events], delta_index: idx + 1}
      {{:delta, text, idx}, new_state}
    end)
  catch
    :exit, _reason -> :ok
  end

  def record(pid, %Event{} = event) do
    Agent.update(pid, fn state ->
      %{state | events: [event | state.events]}
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Record that one assistant_delta was emitted live via `emit_event_fn`.

  Call this after `emit_event_fn.(spec)` succeeds.  The resulting
  `live_emitted_count` from `collect/1` is passed to
  `mark_live_emitted_deltas/2` so that SessionServer can skip
  already-broadcast deltas during final event folding.

  Thread-safe: may be called from any process.
  """
  @spec mark_live_emitted(pid()) :: :ok
  def mark_live_emitted(pid) do
    Agent.update(pid, fn state ->
      %{state | live_emitted_count: state.live_emitted_count + 1}
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Retrieve all recorded events (in emission order) and the
  live-emitted delta count, then stop the Agent.

  The `live_emitted_count` reflects how many times `mark_live_emitted/1`
  was called — i.e., how many assistant_deltas were actually forwarded
  to SessionServer via `emit_event_fn` during streaming.  When
  `emit_event_fn` is nil, this count is 0 and `mark_live_emitted_deltas/2`
  leaves specs unchanged.
  """
  @spec collect(pid()) :: {[Event.t()], non_neg_integer()}
  def collect(pid) do
    %{events: events, live_emitted_count: live_emitted_count} = Agent.get(pid, & &1)
    Agent.stop(pid)
    {Enum.reverse(events), live_emitted_count}
  end
end
