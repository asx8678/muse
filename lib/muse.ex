defmodule Muse do
  @moduledoc """
  Muse — Minimal coding-agent foundation.

  The primary public API for submitting user input and receiving assistant
  responses. Every submission appends a pair of events (user + assistant)
  to the global `Muse.State` log.

  When queued self-healing issues exist, they are atomically claimed
  and attached as an event before the assistant response.
  """

  alias Muse.{Event, State}

  @doc """
  Submits a user message and returns a placeholder assistant response.

  Creates a `:user_message` event from `source`, then appends a
  `:assistant_message` event with a placeholder reply. Both events are
  recorded in `Muse.State` in order.

  If there are queued self-healing issues, `Muse.SelfHealingQueue.claim_queued/0`
  atomically transitions them to `:in_progress` and a `:queued_issues_attached`
  event is inserted between the user and assistant events.

  ## Examples

      iex> {:ok, text} = Muse.submit(:cli, "hello")
      iex> text
      "Placeholder response: received \\"hello\\""

  """
  @spec submit(atom(), String.t()) :: {:ok, String.t()}
  def submit(source, text) do
    user_event = Event.new(source, :user_message, %{text: text})
    :ok = State.append(user_event)

    # Atomically claim queued self-healing issues
    claimed_issues = safe_claim_queued()

    if claimed_issues != [] do
      attach_self_healing_issues(claimed_issues)
    end

    assistant_text =
      if claimed_issues != [] do
        count = length(claimed_issues)

        "Placeholder response: received #{inspect(text)} " <>
          "(#{count} self-healing issue#{if count != 1, do: "s", else: ""} attached)"
      else
        "Placeholder response: received #{inspect(text)}"
      end

    assistant_event = Event.new(:muse, :assistant_message, %{text: assistant_text})
    :ok = State.append(assistant_event)

    {:ok, assistant_text}
  end

  # -- Private helpers ----------------------------------------------------------

  defp safe_claim_queued do
    case Process.whereis(Muse.SelfHealingQueue) do
      nil -> []
      pid -> if Process.alive?(pid), do: Muse.SelfHealingQueue.claim_queued(), else: []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp attach_self_healing_issues(issues) do
    sanitized =
      Enum.map(issues, fn issue ->
        %{
          id: issue.id,
          diagnostic_id: issue.diagnostic_id,
          level: issue.level,
          message: issue.message,
          source: issue.source
        }
      end)

    event = Event.new(:self_healing, :queued_issues_attached, %{issues: sanitized})
    :ok = State.append(event)

    :ok
  end
end
