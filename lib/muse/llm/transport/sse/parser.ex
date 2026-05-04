defmodule Muse.LLM.Transport.SSE.Parser do
  @moduledoc """
  Pure SSE (Server-Sent Events) text parser.

  Parses a binary or string of SSE-formatted text into a list of structured
  SSE event maps. Follows the [W3C SSE specification](https://html.spec.whatwg.org/multipage/server-sent-events.html):

    * `data:` lines accumulate into a single `:data` field (newline-joined).
    * `event:`, `id:`, and `retry:` set their respective fields.
    * Lines starting with `:` are comments and ignored.
    * Blank lines dispatch the current event and start a new one.
    * `data: [DONE]` is preserved as a normal event with `data: "[DONE]"` —
      interpretation is left to the downstream decoder.

  This module performs no HTTP, no JSON decoding, and no secret redaction.
  It is a pure text→struct transformation.
  """

  @type sse_event :: %{
          event: String.t() | nil,
          data: String.t() | nil,
          id: String.t() | nil,
          retry: non_neg_integer() | nil
        }

  @doc """
  Parse a complete SSE text into a list of SSE event maps.

  Returns events in document order. Trailing buffered events (without a
  terminating blank line) are dispatched as well.
  """
  @spec parse(binary() | String.t()) :: [sse_event()]
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], empty_buffer()}, &process_line/2)
    |> flush_buffer()
  end

  # ---------------------------------------------------------------------------
  # Line processing
  # ---------------------------------------------------------------------------

  defp process_line(line, {events, buffer}) do
    cond do
      # Comment line — ignore
      String.starts_with?(line, ":") ->
        {events, buffer}

      # Blank line — dispatch current event
      String.trim(line) == "" ->
        {dispatch_event(events, buffer), empty_buffer()}

      # Field line
      true ->
        {events, process_field(line, buffer)}
    end
  end

  defp process_field(line, buffer) do
    case split_field(line) do
      {"data", value} ->
        data = if buffer.data, do: buffer.data <> "\n" <> value, else: value
        %{buffer | data: data}

      {"event", value} ->
        %{buffer | event: value}

      {"id", value} ->
        %{buffer | id: value}

      {"retry", value} ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> %{buffer | retry: n}
          _ -> buffer
        end

      # Unknown field — ignore per SSE spec
      _unknown ->
        buffer
    end
  end

  defp split_field(line) do
    case String.split(line, ":", parts: 2) do
      [field, "" <> rest] ->
        # Per spec, strip one leading space from value after colon
        value = if String.starts_with?(rest, " "), do: String.slice(rest, 1..-1//1), else: rest
        {field, value}

      [field] ->
        {field, ""}

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Buffer management
  # ---------------------------------------------------------------------------

  defp empty_buffer, do: %{event: nil, data: nil, id: nil, retry: nil}

  defp dispatch_event(events, %{data: nil} = _buffer), do: events

  defp dispatch_event(events, buffer) do
    event = Map.take(buffer, [:event, :data, :id, :retry])
    events ++ [event]
  end

  defp flush_buffer({events, buffer}) do
    # Any remaining buffered event (no trailing blank line) gets dispatched
    dispatch_event(events, buffer)
  end
end
