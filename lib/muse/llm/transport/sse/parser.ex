defmodule Muse.LLM.Transport.SSE.Parser do
  @moduledoc """
  Incremental Server-Sent Events (SSE) parser.

  Parses raw SSE text into a stream of `%{event: type, data: data, id: id}` maps.
  Handles partial chunks, multi-line `data:` fields, and the Chat Completions
  `data: [DONE]` termination sentinel.

  ## SSE wire format

  Each SSE event is separated by a blank line (`\\n\\n`). Within an event:

    * `event:` — optional event type (defaults to `"message"`)
    * `data:`  — data line(s); multiple `data:` lines are joined with `\\n`
    * `id:`    — optional last event ID
    * `retry:` — optional reconnection interval (ignored by this parser)

  The parser is pure and stateless across calls: `parse/2` returns
  `{events, remaining_buffer}` so callers can feed incremental chunks.

  ## Usage

      {events, buf} = SSE.Parser.parse("data: hello\\n\\ndata: ", "")
      # events => [%{event: "message", data: "hello", id: nil}]
      # buf    => "data: "

      {events, buf} = SSE.Parser.parse("world\\n\\n", buf)
      # events => [%{event: "message", data: "world", id: nil}]
      # buf    => ""
  """

  @done_sentinel "[DONE]"

  @type sse_event :: %{event: String.t(), data: String.t(), id: String.t() | nil}
  @type buffer :: String.t()

  @doc """
  Parse raw SSE text, returning parsed events and any remaining buffer.

  Handles partial lines that span chunk boundaries by buffering incomplete
  text. Callers should pass the returned buffer into the next `parse/2` call.

  Returns `{events, remaining_buffer}` where `events` is a list of parsed
  SSE event maps (may be empty if no complete events are available).
  """
  @spec parse(String.t(), buffer()) :: {[sse_event()], buffer()}
  def parse(chunk, buffer) when is_binary(chunk) and is_binary(buffer) do
    text = buffer <> chunk

    # Normalize \r\n → \n for robustness
    text = String.replace(text, "\r\n", "\n")

    extract_complete_events(text, [])
  end

  @doc """
  Convenience: parse a complete SSE text with no buffering.

  Useful for tests and when the full response body is available at once.
  """
  @spec parse(String.t()) :: [sse_event()]
  def parse(text) when is_binary(text) do
    {events, ""} = parse(text, "")
    events
  end

  @doc """
  Check whether an SSE data value is the stream-termination sentinel.

  Chat Completions streams end with `data: [DONE]`.
  """
  @spec done_sentinel?(String.t()) :: boolean()
  def done_sentinel?(@done_sentinel), do: true
  def done_sentinel?(_data), do: false

  # ---------------------------------------------------------------------------
  # Event extraction — split on \n\n boundaries
  # ---------------------------------------------------------------------------

  defp extract_complete_events(text, acc) do
    case String.split(text, "\n\n", parts: 2) do
      [event_text, rest] ->
        event = parse_single_event(event_text)

        acc =
          if event != nil do
            [event | acc]
          else
            acc
          end

        extract_complete_events(rest, acc)

      [_incomplete] ->
        # No complete event boundary found — buffer the rest
        {Enum.reverse(acc), text}
    end
  end

  # ---------------------------------------------------------------------------
  # Parse a single SSE event text into a structured map
  # ---------------------------------------------------------------------------

  defp parse_single_event(""), do: nil

  defp parse_single_event(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)

    result =
      lines
      |> Enum.reduce(%{event: "message", data_lines: [], id: nil}, &parse_line/2)

    data = Enum.join(result.data_lines, "\n")

    # Skip events with empty data or the [DONE] sentinel
    if data == "" or data == @done_sentinel do
      nil
    else
      %{event: result.event, data: data, id: result.id}
    end
  end

  defp parse_line(line, acc) do
    cond do
      String.starts_with?(line, "event:") ->
        value = line |> String.slice(6..-1//1) |> String.trim()
        %{acc | event: value}

      String.starts_with?(line, "data:") ->
        value = line |> String.slice(5..-1//1) |> String.trim_leading()
        %{acc | data_lines: acc.data_lines ++ [value]}

      String.starts_with?(line, "id:") ->
        value = line |> String.slice(3..-1//1) |> String.trim()
        %{acc | id: value}

      String.starts_with?(line, "retry:") ->
        # Ignored per SSE spec
        acc

      String.starts_with?(line, ":") ->
        # Comment line — ignored per SSE spec
        acc

      line == "" ->
        acc

      true ->
        # Unknown field — skip gracefully
        acc
    end
  end
end
