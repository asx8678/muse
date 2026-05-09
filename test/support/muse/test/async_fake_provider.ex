defmodule Muse.Test.AsyncFakeProvider do
  @moduledoc """
  A test provider that delegates to `Muse.LLM.FakeProvider` but runs the
  entire `stream/2` call in a spawned process, so all `emit_fn` invocations
  execute from a process other than the caller.

  This simulates async SSE/WebSocket providers where streaming callbacks
  execute on a different process than the one that called `stream/2`.

  ## Purpose

  The original process-dictionary collector in Conductor/ToolLoop silently
  dropped events when `emit_fn` was called from another process.  This
  provider proves that the Agent-based `StreamCollector` correctly handles
  cross-process callbacks (muse-0va).

  ## Usage

  Pass `provider_module: Muse.Test.AsyncFakeProvider` in Conductor opts
  instead of `Muse.LLM.FakeProvider`.  All `fake_events` / `fake_event_batches`
  scripts work exactly as with `FakeProvider`.
  """

  alias Muse.LLM.{FakeProvider, Request}

  @behaviour Muse.LLM.Provider

  @impl true
  def stream(%Request{} = request, emit) when is_function(emit, 1) do
    caller = self()

    # Run FakeProvider.stream in a separate linked process so that ALL
    # emit_fn calls execute from that process, not the caller's.
    # This is the exact scenario that breaks process-dictionary collectors.
    pid =
      spawn_link(fn ->
        result = FakeProvider.stream(request, emit)
        send(caller, {__MODULE__, :result, result})
      end)

    receive do
      {__MODULE__, :result, result} ->
        result
    after
      5_000 ->
        # If the spawned process doesn't complete in time, kill it and
        # return an error rather than hanging forever.
        Process.exit(pid, :kill)
        {:error, :async_provider_timeout}
    end
  end

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    FakeProvider.complete(request, opts)
  end
end
