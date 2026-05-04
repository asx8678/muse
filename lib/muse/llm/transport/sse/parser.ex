defmodule Muse.LLM.Transport.SSE.Parser do
  @moduledoc """
  Pure, incremental parser for HTTP Server-Sent Events (SSE).

  Implements the [SSE specification](https://html.spec.whatwg.org/multipage/server-sent-events.html)
  as a stateless, pure functional module. No network I/O, no logging, no side effects.
  The parser never logs raw chunks, avoiding credential leakage surfaces.

  ## Design

  The parser maintains explicit state (`t/0`) across chunks. Each call to
  `parse_chunk/2` returns a list of fully parsed events and the next state.
  Partial frames and partial lines are buffered until more data arrives.

  ## SSE field handling

  | Field     | Behaviour                                                          |
  |-----------|--------------------------------------------------------------------|
  | `data:`   | Appended; multiple `data:` lines join with `\n` per spec          |
  | `event:`  | Last `event:` in a frame wins; defaults to `"message"`            |
  | `id:`     | Last `id:` in a frame wins                                         |
  | `retry:`  | Last valid integer `retry:` in a frame wins; invalid values ignored |
  | `:…`      | Comment line — ignored                                             |
  | other     | Unknown field — ignored                                            |

  Frames are terminated by a blank line (`\n\n` or `\r\n\r\n`). Empty and
  comment-only frames produce no events. `data: [DONE]` emits a done marker
  (`%{done?: true, data: "[DONE]", …}`).

  ## Event shape

  All events are plain maps (no dynamic atom creation):

      %{
        event: "message",
        data:  binary(),
        id:    binary() | nil,
        retry: integer() | nil,
        done?: boolean()
      }

  ## Usage

      state = Muse.LLM.Transport.SSE.Parser.new()
      {events, state} = Muse.LLM.Transport.SSE.Parser.parse_chunk(chunk, state)
      # events => [%{event: "message", data: "hello", id: nil, retry: nil, done?: false}]
  """

  @type t :: %__MODULE__{
          buffer: binary(),
          pending_data: [binary()],
          pending_event: binary() | nil,
          pending_id: binary() | nil,
          pending_retry: integer() | nil
        }

  defstruct buffer: "",
            pending_data: [],
            pending_event: nil,
            pending_id: nil,
            pending_retry: nil

  @done_marker "[DONE]"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Create a fresh parser state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a binary chunk into the parser.

  Returns `{events, next_state}` where `events` is a (possibly empty) list of
  completed SSE event maps. Partial data is buffered in `next_state` for the
  next call.
  """
  @spec parse_chunk(binary(), t()) :: {[map()], t()}
  def parse_chunk(chunk, %__MODULE__{} = state) when is_binary(chunk) do
    state = accumulate(state, chunk)
    extract_events(state)
  end

  @doc """
  Flush any buffered partial frame as though a blank line had arrived.

  Useful at end-of-stream to emit the final event if the server omitted the
  trailing blank line. If nothing is buffered, returns `[]`.
  """
  @spec flush(t()) :: {[map()], t()}
  def flush(%__MODULE__{pending_data: []} = state), do: {[], state}

  def flush(%__MODULE__{} = state) do
    {event, state} = emit_event(state)
    {[event], state}
  end

  # ---------------------------------------------------------------------------
  # Accumulation — buffer incoming bytes and split into lines
  # ---------------------------------------------------------------------------

  defp accumulate(state, chunk) do
    %{state | buffer: state.buffer <> chunk}
  end

  # ---------------------------------------------------------------------------
  # Line extraction — handle LF and CRLF uniformly
  # ---------------------------------------------------------------------------

  defp extract_events(state) do
    case find_line(state.buffer) do
      {:ok, line, rest} ->
        {events, state} = process_line(line, %{state | buffer: rest})
        {more_events, state} = extract_events(state)
        {events ++ more_events, state}

      :partial ->
        {[], state}
    end
  end

  # A "line" ends at \n. We normalise CRLF to LF by stripping the preceding \r.
  # We also treat \r\n as a complete line ending.
  defp find_line(buffer) do
    case :binary.match(buffer, "\n") do
      :nomatch ->
        :partial

      {pos, 1} ->
        line_len = pos
        rest_start = pos + 1

        line =
          case buffer do
            <<before::binary-size(line_len), "\n", _::binary>> ->
              strip_trailing_cr(before)
          end

        rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)
        {:ok, line, rest}
    end
  end

  defp strip_trailing_cr(<<>>, _len), do: <<>>

  defp strip_trailing_cr(line, len) when byte_size(line) == len do
    case line do
      <<body::binary-size(len - 1), "\r">> -> body
      _ -> line
    end
  end

  defp strip_trailing_cr(line, _len), do: line

  defp strip_trailing_cr(line) do
    len = byte_size(line)
    strip_trailing_cr(line, len)
  end

  # ---------------------------------------------------------------------------
  # Line processing — SSE semantics
  # ---------------------------------------------------------------------------

  # Blank line => frame boundary => emit if data present
  defp process_line("", state) do
    case state.pending_data do
      [] ->
        # Empty/comment-only frame — no event
        {[], reset_pending(state)}

      _ ->
        {event, state} = emit_event(state)
        {[event], state}
    end
  end

  # Comment line (starts with ':')
  defp process_line(":" <> _, state), do: {[], state}

  # Field: value
  defp process_line(line, state) do
    case :binary.split(line, ":", []) do
      [field_name, value] ->
        # Per spec, strip a single leading space from the value if present
        value = strip_leading_space(value)
        {[], apply_field(field_name, value, state)}

      [field_name] ->
        # Field with no colon value — treat as empty value
        {[], apply_field(field_name, "", state)}
    end
  end

  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(value), do: value

  # ---------------------------------------------------------------------------
  # Field application
  # ---------------------------------------------------------------------------

  defp apply_field("data", value, state) do
    %{state | pending_data: [value | state.pending_data]}
  end

  defp apply_field("event", value, state) do
    %{state | pending_event: value}
  end

  defp apply_field("id", value, state) do
    %{state | pending_id: value}
  end

  defp apply_field("retry", value, state) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> %{state | pending_retry: int}
      _ -> state
    end
  end

  # Unknown field — ignored per spec
  defp apply_field(_field_name, _value, state), do: state

  # ---------------------------------------------------------------------------
  # Event emission
  # ---------------------------------------------------------------------------

  defp emit_event(state) do
    data =
      state.pending_data
      |> Enum.reverse()
      |> Enum.join("\n")

    done? = data == @done_marker

    event = %{
      event: state.pending_event || "message",
      data: data,
      id: state.pending_id,
      retry: state.pending_retry,
      done?: done?
    }

    {event, reset_pending(state)}
  end

  defp reset_pending(state) do
    %{state | pending_data: [], pending_event: nil, pending_id: nil, pending_retry: nil}
  end
end
