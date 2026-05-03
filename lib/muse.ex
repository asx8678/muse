defmodule Muse do
  @moduledoc """
  Muse — Minimal coding-runtime foundation.

  The primary public API for submitting user input and receiving assistant
  responses. Every submission is routed through `Muse.SessionRouter` to a
  per-session `Muse.SessionServer` that appends events to the global
  `Muse.State` log and returns a placeholder assistant response.

  When queued self-healing issues exist, they are atomically claimed
  and attached as an event before the assistant response.
  """

  alias Muse.SessionRouter

  @doc """
  Submits a user message and returns a placeholder assistant response.

  Delegates to `Muse.SessionRouter.submit/3` with the `"default"` session
  id, which routes to a scoped `Muse.SessionServer`.

  The server creates a `:user_message` event from `source`, then appends a
  `:assistant_message` event with a placeholder reply. Both events are
  recorded in `Muse.State` in order.

  If there are queued self-healing issues, `Muse.SelfHealingQueue.claim_queued/0`
  atomically transitions them to `:in_progress` and a `:queued_issues_attached`
  event is inserted between the user and assistant events.

  ## Examples

      iex> {:ok, text} = Muse.submit(:cli, "hello")
      iex> text
      "Placeholder response: received \\\"hello\\\""

  """
  @spec submit(atom(), String.t()) :: {:ok, String.t()}
  def submit(source, text) do
    SessionRouter.submit(source, text)
  end
end
