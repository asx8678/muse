defmodule Muse.Conductor.TurnRunner do
  @moduledoc """
  Runs Conductor turns as async Tasks outside the SessionServer process.

  This allows `SessionServer.status/1` to remain responsive during long-running
  provider/tool-loop turns. The TurnRunner spawns a Task via
  `Task.Supervisor.async_nolink/2` under `Muse.TaskSupervisor`.

  ## Cancellation

  `cancel/1` sends a cancellation message to the runner task. The ToolLoop
  polls `cancelled?/0` between iterations and between tool calls to check
  for pending cancellation.

  Cancellation state is stored in the process dictionary of the runner task,
  keyed by `turn_id`. The `cancelled?/0` function also checks the process
  mailbox for pending cancellation messages.

  ## API

    * `async(session, turn, opts)` — spawn an async task running the Conductor
    * `cancel(pid, turn_id)` — send cancellation to a running task
    * `cancelled?()` — check if the current process has been cancelled (polls mailbox)
  """

  alias Muse.{Conductor, Session, Turn}

  @cancel_prefix :muse_turn_cancel

  @doc """
  Spawn an async task that runs the Conductor for the given turn.

  Returns `%Task{}`. The caller (SessionServer) receives the result as
  a message: `{ref, result}` or `{ref, :cancelled}` on cancellation.

  The task runs `Muse.Conductor.run/3` with cancellation checking enabled.
  """
  @spec async(Session.t(), Turn.t(), keyword()) :: Task.t()
  def async(session, turn, opts \\ []) do
    turn_id = turn.id

    Task.Supervisor.async_nolink(Muse.TaskSupervisor, fn ->
      # Store turn_id in process dictionary for cancellation checks
      Process.put(:muse_turn_id, turn_id)
      Process.put(:muse_cancelled, false)

      # Add cancel-check option so Conductor/ToolLoop can poll
      opts_with_cancel = Keyword.put(opts, :cancel_check_fn, &cancelled?/0)

      # The :emit_event_fn callback (if present) is a function that
      # sends live event specs to the SessionServer process for
      # immediate PubSub broadcast during provider streaming.
      # It is passed through to Conductor.run/3 unchanged.
      result = Conductor.run(session, turn, opts_with_cancel)

      # If cancelled during execution, return a cancelled result
      if cancelled?() do
        {:cancelled, result}
      else
        result
      end
    end)
  end

  @doc """
  Send a cancellation signal to a running turn task.

  Sends a message to the task process that will be picked up by
  `cancelled?/0` on its next poll.
  """
  @spec cancel(pid(), String.t()) :: :ok
  def cancel(pid, turn_id) when is_pid(pid) and is_binary(turn_id) do
    send(pid, {@cancel_prefix, turn_id})
    :ok
  end

  @doc """
  Check whether the current process (task) has received a cancellation signal.

  Polls the process mailbox for pending cancellation messages and stores
  the cancellation flag in the process dictionary. Once cancelled, always
  returns `true`.

  This function is designed to be called from within the ToolLoop and
  Conductor to check for cancellation between iterations/tool calls.
  """
  @spec cancelled?() :: boolean()
  def cancelled? do
    # Check process dictionary first (already cancelled)
    if Process.get(:muse_cancelled, false) do
      true
    else
      # Poll mailbox for cancellation messages
      check_mailbox_for_cancel()
    end
  end

  defp check_mailbox_for_cancel do
    turn_id = Process.get(:muse_turn_id)

    receive do
      {@cancel_prefix, ^turn_id} ->
        Process.put(:muse_cancelled, true)
        true

      {@cancel_prefix, other_turn_id} ->
        # Not for this turn; re-queue and continue
        send(self(), {@cancel_prefix, other_turn_id})
        false
    after
      0 -> false
    end
  end
end
