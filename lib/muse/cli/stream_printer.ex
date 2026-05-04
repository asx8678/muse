defmodule Muse.CLI.StreamPrinter do
  @moduledoc """
  Streams assistant delta events to the CLI and suppresses duplicate
  final-message output when the turn was streamed.

  ## Behaviour

  1. Subscribes to `Muse.State` PubSub for real-time events.
  2. Calls `Muse.SessionServer.submit/3` asynchronously.
  3. Collects `:assistant_delta` events for the current turn, printing
     each chunk as it arrives.
  4. When a `:turn_completed` event arrives, stops collecting and
     returns the full assistant text.
  5. If no deltas were received (e.g. State/PubSub unavailable),
     falls back to printing `assistant> <final text>`.

  ## Usage

      {:ok, text} = Muse.CLI.StreamPrinter.stream_submit(:cli, "hello", session_id: "default")

  For deterministic tests, pass `deltas:` and `final_text:` to bypass
  PubSub and test the rendering logic directly.
  """

  @doc """
  Determine whether a result was streamed (deltas were printed).

  Returns `{:ok, assistant_text}` when complete.

  ## Options

    * `:session_id` — session ID for the submit (default: `"default"`)
    * `:timeout` — max ms to wait for turn completion (default: 5_000)
  """
  @spec stream_submit(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def stream_submit(source, text, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "default")
    timeout = Keyword.get(opts, :timeout, 5_000)

    # Subscribe before submit so we don't miss events
    subscribe_safely()

    # Submit synchronously (placeholder is instant; future conductor will be async)
    result = Muse.submit(source, text)

    # Now collect streaming events for this turn
    collect_stream(result, session_id, timeout)
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
    Map.get(data, :streamed?) == true
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

  defp collect_stream({:ok, _text}, _session_id, _timeout) do
    # With the current synchronous placeholder, all events are already
    # in State. Check for delta events and print them.
    events = Muse.State.events()

    case find_current_turn_events(events) do
      %{deltas: [], final: final_event} ->
        # No deltas — fallback to traditional print
        text = Map.get(final_event.data, :text, "")
        print_final(text)
        {:ok, text}

      %{deltas: deltas, final: nil} ->
        # Deltas but no final — still streaming (shouldn't happen with
        # synchronous placeholder but handle gracefully)
        text = Enum.map_join(deltas, "", &Map.get(&1.data, :text, ""))
        Enum.each(deltas, &print_delta(Map.get(&1.data, :text, "")))
        IO.write("\n")
        {:ok, text}

      %{deltas: deltas, final: final_event} ->
        # Deltas were streamed — print each delta, skip final reprint
        Enum.each(deltas, &print_delta(Map.get(&1.data, :text, "")))
        IO.write("\n")
        text = Map.get(final_event.data, :text, "")
        {:ok, text}
    end
  end

  defp collect_stream({:error, reason}, _session_id, _timeout) do
    IO.puts("[error] #{inspect(reason)}")
    {:error, reason}
  end

  defp collect_stream(other, _session_id, _timeout) do
    IO.puts("[error] #{inspect(other)}")
    {:error, other}
  end

  # Find the most recent turn's events from the event stream.
  # Returns %{deltas: [...], final: event | nil}
  defp find_current_turn_events(events) do
    # Find the most recent turn_id from an assistant event
    assistant_events =
      events
      |> Enum.filter(&(&1.type in [:assistant_delta, :assistant_message]))

    case Enum.reverse(assistant_events) do
      [] ->
        %{deltas: [], final: nil}

      [latest | _] ->
        turn_id = latest.turn_id

        turn_events =
          events
          |> Enum.filter(
            &(&1.turn_id == turn_id and &1.type in [:assistant_delta, :assistant_message])
          )

        deltas = Enum.filter(turn_events, &(&1.type == :assistant_delta))
        finals = Enum.filter(turn_events, &(&1.type == :assistant_message))

        %{deltas: deltas, final: List.first(finals)}
    end
  end
end
