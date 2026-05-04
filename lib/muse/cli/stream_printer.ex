defmodule Muse.CLI.StreamPrinter do
  @moduledoc """
  Streams assistant delta events to the CLI via PubSub and suppresses
  duplicate final-message output when the turn was streamed.

  ## Behaviour

  1. Subscribes to `Muse.State` PubSub for real-time events.
  2. Runs `Muse.SessionRouter.submit/3` asynchronously (in a Task) so
     the caller process can receive `{:muse_event, event}` messages while
     the submit runs.
  3. Collects `:assistant_delta` events for the current turn (filtered by
     `session_id` and `turn_id`), printing each chunk as it arrives.
  4. When a `:turn_completed` event arrives, stops collecting, drains
     stale messages, and returns the full assistant text.
  5. If no deltas were received (e.g. State/PubSub unavailable), falls
     back to printing `assistant> <final text>`.

  ## Usage

      {:ok, text} = Muse.CLI.StreamPrinter.stream_submit(:cli, "hello", session_id: "default")

  ## Options

    * `:session_id` — session ID for routing the submit (default: `"default"`)
    * `:timeout` — max ms to wait for turn completion (default: 5_000)
  """

  @default_session_id "default"
  @default_timeout 5_000

  @doc """
  Submit a message and stream assistant deltas to stdout in real-time.

  Subscribes to PubSub before starting the submit, runs the submit in a
  Task so `{:muse_event, _}` messages arrive while the caller waits, and
  consumes delta events for the matching `session_id` / `turn_id`.

  Returns `{:ok, assistant_text}` when complete.
  """
  @spec stream_submit(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def stream_submit(source, text, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, @default_session_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Subscribe before submit so we don't miss events
    subscribe_safely()

    # Start submit in a Task so PubSub messages arrive in this process
    # Trap exits so a crashing SessionServer/State doesn't kill the caller
    task =
      Task.async(fn ->
        try do
          Muse.SessionRouter.submit(session_id, source, text)
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    # Collect streaming events from PubSub while the task runs
    collect_from_pubsub(task, session_id, timeout)
  end

  @doc """
  Print a single assistant delta chunk to stdout.

  Uses `IO.write/2` (no newline) so deltas appear as a continuous stream.
  """
  @spec print_delta(String.t()) :: :ok
  def print_delta(chunk) when is_binary(chunk) do
    IO.write(chunk)
  end

  @doc """
  Print a finalized assistant message with the `assistant>` prefix.

  Used as fallback when no streaming deltas were received.
  """
  @spec print_final(String.t()) :: :ok
  def print_final(text) when is_binary(text) do
    IO.puts("assistant> #{text}")
  end

  @doc """
  Determine whether a result was streamed (deltas were printed).

  Returns `true` if the data map has `streamed?: true`, false otherwise.
  """
  @spec streamed?(map()) :: boolean()
  def streamed?(%{data: data}) when is_map(data) do
    Map.get(data, :streamed?) == true or Map.get(data, "streamed?") == true
  end

  def streamed?(_), do: false

  # -- Private helpers ----------------------------------------------------------

  defp subscribe_safely do
    try do
      Muse.State.subscribe()
    catch
      :exit, _ -> {:error, :no_state}
    end
  end

  # Collect PubSub messages while the async task runs. We need to handle:
  # - delta events → print them
  # - turn_completed → stop collecting, return text
  # - task result → if no PubSub events arrived, fall back to snapshot
  # - timeout → graceful fallback
  defp collect_from_pubsub(task, session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_loop(task, session_id, deadline, nil, [], "")
  end

  defp collect_loop(task, session_id, deadline, turn_id, deltas, acc_text) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:muse_event, %{type: :assistant_delta, session_id: ^session_id} = event} ->
        event_turn_id = event.turn_id
        # Only process deltas for our turn (once we know it)
        if turn_id == nil or event_turn_id == turn_id do
          chunk = extract_text(event.data)
          print_delta(chunk)
          new_turn_id = turn_id || event_turn_id

          collect_loop(
            task,
            session_id,
            deadline,
            new_turn_id,
            deltas ++ [event],
            acc_text <> chunk
          )
        else
          collect_loop(task, session_id, deadline, turn_id, deltas, acc_text)
        end

      {:muse_event, %{type: :assistant_message, session_id: ^session_id} = event} ->
        event_turn_id = event.turn_id
        final_text = extract_text(event.data)

        if turn_id == nil or event_turn_id == turn_id do
          if deltas != [] and streamed?(event) do
            # Deltas were already printed; suppress duplicate final
            IO.write("\n")
            drain_task(task, deadline)
            {:ok, final_text}
          else
            # No deltas or not streamed — print with prefix
            print_final(final_text)
            drain_task(task, deadline)
            {:ok, final_text}
          end
        else
          collect_loop(task, session_id, deadline, turn_id, deltas, acc_text)
        end

      {:muse_event, %{type: :turn_completed, session_id: ^session_id} = event} ->
        event_turn_id = event.turn_id

        if turn_id == nil or event_turn_id == turn_id do
          # Turn is done — use accumulated text or fall back
          final_text =
            if acc_text != "" do
              acc_text
            else
              # No deltas received; try to get text from assistant_message in State
              find_assistant_text(session_id, event_turn_id)
            end

          if acc_text == "" and final_text != "" do
            print_final(final_text)
          end

          drain_task(task, deadline)

          if final_text != "" do
            {:ok, final_text}
          else
            {:ok, ""}
          end
        else
          collect_loop(task, session_id, deadline, turn_id, deltas, acc_text)
        end

      # Ignore events from other sessions
      {:muse_event, _event} ->
        collect_loop(task, session_id, deadline, turn_id, deltas, acc_text)

      # Task completed — if we already have text, return it; otherwise
      # fall back to snapshot
      {ref, {:ok, _result}}
      when is_reference(ref) and ref == task.ref ->
        if acc_text != "" do
          # Already streamed deltas; finish
          IO.write("\n")
          drain_mailbox(session_id)
          {:ok, acc_text}
        else
          # No deltas received via PubSub — fall back to State snapshot
          fallback_from_state(session_id, nil)
        end

      {ref, result}
      when is_reference(ref) and ref == task.ref ->
        case result do
          {:ok, {:ok, text}} ->
            if acc_text != "" do
              IO.write("\n")
              drain_mailbox(session_id)
              {:ok, acc_text}
            else
              fallback_text(session_id, text)
            end

          {:ok, {:error, reason}} ->
            IO.puts("[error] #{inspect(reason)}")
            drain_mailbox(session_id)
            {:error, reason}

          {:exit, reason} ->
            IO.puts("[error] #{inspect(reason)}")
            drain_mailbox(session_id)
            {:error, reason}
        end
    after
      remaining ->
        # Timeout — drain task and fall back
        Task.shutdown(task, :brutal_kill)

        if acc_text != "" do
          IO.write("\n")
          drain_mailbox(session_id)
          {:ok, acc_text}
        else
          fallback_from_state(session_id, turn_id)
        end
    end
  end

  # Drain the async task result and any remaining PubSub messages
  defp drain_task(task, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, _result} when is_reference(ref) and ref == task.ref ->
        :ok
    after
      remaining ->
        Task.shutdown(task, :brutal_kill)
        :ok
    end

    drain_mailbox(nil)
  end

  # Drain remaining {:muse_event, _} messages from the mailbox to prevent
  # buildup. If session_id is given, only drain events for that session;
  # otherwise drain all muse_events.
  defp drain_mailbox(session_id) do
    receive do
      {:muse_event, %{session_id: sid} = _event}
      when session_id != nil and sid == session_id ->
        drain_mailbox(session_id)

      {:muse_event, _event} ->
        if session_id == nil do
          drain_mailbox(nil)
        else
          drain_mailbox(session_id)
        end
    after
      0 -> :ok
    end
  end

  # Fallback: no PubSub messages received. Read from State directly.
  defp fallback_from_state(session_id, turn_id) do
    events = safe_state_events()

    assistant_events =
      events
      |> Enum.filter(&(&1.type in [:assistant_delta, :assistant_message]))
      |> Enum.filter(&(&1.session_id == session_id))

    final_event =
      if turn_id do
        Enum.find(assistant_events, &(&1.turn_id == turn_id and &1.type == :assistant_message))
      else
        Enum.find(Enum.reverse(assistant_events), &(&1.type == :assistant_message))
      end

    case final_event do
      nil ->
        # No events at all — try last resort
        drain_mailbox(session_id)
        {:ok, ""}

      event ->
        text = extract_text(event.data)

        if streamed?(event) do
          # Re-print delta chunks from State
          deltas =
            assistant_events
            |> Enum.filter(&(&1.type == :assistant_delta and &1.turn_id == event.turn_id))
            |> Enum.sort_by(& &1.seq)

          if deltas != [] do
            Enum.each(deltas, fn d ->
              print_delta(extract_text(d.data))
            end)

            IO.write("\n")
          else
            print_final(text)
          end
        else
          print_final(text)
        end

        drain_mailbox(session_id)
        {:ok, text}
    end
  end

  # Fallback when task completed with text but no PubSub messages
  defp fallback_text(session_id, text) do
    # Try to get full event info from State
    case fallback_from_state(session_id, nil) do
      {:ok, ""} ->
        # State fallback found nothing — just print the task result
        print_final(text)
        drain_mailbox(session_id)
        {:ok, text}

      {:ok, state_text} ->
        {:ok, state_text}
    end
  end

  defp find_assistant_text(session_id, turn_id) do
    events = safe_state_events()

    events
    |> Enum.filter(
      &(&1.type == :assistant_message and &1.session_id == session_id and &1.turn_id == turn_id)
    )
    |> List.first()
    |> case do
      nil -> ""
      event -> extract_text(event.data)
    end
  end

  defp safe_state_events do
    try do
      Muse.State.events()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  # Extract text from event data, handling both atom and string keys
  defp extract_text(data) when is_map(data) do
    Map.get(data, :text) || Map.get(data, "text") || ""
  end

  defp extract_text(data) when is_binary(data), do: data
  defp extract_text(_), do: ""
end
