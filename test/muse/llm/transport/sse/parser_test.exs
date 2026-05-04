defmodule Muse.LLM.Transport.SSE.ParserTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.Transport.SSE.Parser

  describe "new/0" do
    test "returns a fresh parser state" do
      state = Parser.new()
      assert state.buffer == ""
      assert state.pending_data == []
      assert state.pending_event == nil
      assert state.pending_id == nil
      assert state.pending_retry == nil
    end
  end

  describe "parse_chunk/2 — basic single event" do
    test "parses a simple data event" do
      chunk = "data: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{event: "message", data: "hello", id: nil, retry: nil, done?: false}] = events
    end

    test "parses event with explicit event type" do
      chunk = "event: add\ndata: payload\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{event: "add", data: "payload"}] = events
    end

    test "parses id field" do
      chunk = "id: 42\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{id: "42", data: "hello"}] = events
    end

    test "parses retry field as integer" do
      chunk = "retry: 5000\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{retry: 5000, data: "hello"}] = events
    end

    test "ignores invalid retry value" do
      chunk = "retry: abc\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{retry: nil, data: "hello"}] = events
    end

    test "ignores negative retry value — still integer, but we only accept >= 0" do
      chunk = "retry: -100\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      # Negative is not accepted per our guard, so retry stays nil
      assert [%{retry: nil, data: "hello"}] = events
    end

    test "ignores retry with trailing text" do
      chunk = "retry: 100ms\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{retry: nil, data: "hello"}] = events
    end

    test "accepts zero retry" do
      chunk = "retry: 0\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{retry: 0, data: "hello"}] = events
    end
  end

  describe "parse_chunk/2 — multiline data" do
    test "joins multiple data lines with newline per SSE spec" do
      chunk = "data: line1\ndata: line2\ndata: line3\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "line1\nline2\nline3"}] = events
    end

    test "single data line has no extra newline" do
      chunk = "data: only\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "only"}] = events
    end

    test "empty data field is preserved" do
      chunk = "data:\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: ""}] = events
    end

    test "data field with only a space after colon" do
      chunk = "data: \n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: ""}] = events
    end
  end

  describe "parse_chunk/2 — multiple events in one chunk" do
    test "parses two consecutive events" do
      chunk = "data: first\n\ndata: second\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "first"}, %{data: "second"}] = events
    end

    test "parses three consecutive events with mixed fields" do
      chunk =
        "event: msg\ndata: hello\n\n" <>
          "id: 1\ndata: world\n\n" <>
          "retry: 1000\ndata: again\n\n"

      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [
               %{event: "msg", data: "hello", id: nil, retry: nil},
               %{event: "message", data: "world", id: "1", retry: nil},
               %{event: "message", data: "again", id: nil, retry: 1000}
             ] = events
    end
  end

  describe "parse_chunk/2 — CRLF support" do
    test "parses event with CRLF line endings" do
      chunk = "data: hello\r\n\r\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "hello"}] = events
    end

    test "parses multiline data with CRLF" do
      chunk = "data: line1\r\ndata: line2\r\n\r\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "line1\nline2"}] = events
    end

    test "handles mixed LF and CRLF in the same stream" do
      chunk = "data: lf\n\ndata: crlf\r\n\r\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "lf"}, %{data: "crlf"}] = events
    end
  end

  describe "parse_chunk/2 — comments" do
    test "ignores comment lines starting with colon" do
      chunk = ": this is a comment\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "hello"}] = events
    end

    test "comment-only frame does not emit event" do
      chunk = ": comment1\n: comment2\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert events == []
    end

    test "empty frame (double blank line) does not emit event" do
      chunk = "\n\ndata: actual\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "actual"}] = events
    end

    test "comment between data fields is ignored" do
      chunk = "data: first\n: a comment\ndata: second\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "first\nsecond"}] = events
    end
  end

  describe "parse_chunk/2 — unknown fields" do
    test "unknown field is silently ignored" do
      chunk = "foo: bar\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "hello"}] = events
    end

    test "field with no colon is treated as field name with empty value" do
      chunk = "somedata\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      # "somedata" has no colon, so it's an unknown field with empty value — ignored
      assert events == []
    end
  end

  describe "parse_chunk/2 — [DONE] marker" do
    test "data: [DONE] emits done marker" do
      chunk = "data: [DONE]\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{done?: true, data: "[DONE]", event: "message"}] = events
    end

    test "[DONE] as part of multiline data is NOT a done marker" do
      chunk = "data: prefix\ndata: [DONE]\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{done?: false, data: "prefix\n[DONE]"}] = events
    end

    test "[DONE] with event type still marks done" do
      chunk = "event: stop\ndata: [DONE]\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{done?: true, data: "[DONE]", event: "stop"}] = events
    end
  end

  describe "parse_chunk/2 — incremental/chunked parsing" do
    test "partial line is buffered across chunks" do
      state = Parser.new()

      {events1, state} = Parser.parse_chunk("data: hel", state)
      assert events1 == []

      {events2, _state} = Parser.parse_chunk("lo\n\n", state)
      assert [%{data: "hello"}] = events2
    end

    test "partial frame split at blank line boundary" do
      state = Parser.new()

      {events1, state} = Parser.parse_chunk("data: hello\n", state)
      assert events1 == []

      {events2, _state} = Parser.parse_chunk("\n", state)
      assert [%{data: "hello"}] = events2
    end

    test "multiple chunks reassemble a single event" do
      state = Parser.new()

      # "ev" + "ent: custom\n" => buffer contains "event: custom\n" when the \n arrives
      {[], state} = Parser.parse_chunk("ev", state)
      {[], state} = Parser.parse_chunk("ent: custom\n", state)
      {[], state} = Parser.parse_chunk("da", state)
      {events, _state} = Parser.parse_chunk("ta: payload\n\n", state)

      assert [%{event: "custom", data: "payload"}] = events
    end

    test "incremental parsing — byte by byte" do
      source = "data: hello\n\n"

      {events, _state} =
        source
        |> String.graphemes()
        |> Enum.reduce({[], Parser.new()}, fn char, {acc_events, state} ->
          {new_events, state} = Parser.parse_chunk(char, state)
          {acc_events ++ new_events, state}
        end)

      assert [%{data: "hello", done?: false}] = events
    end

    test "incremental parsing — two events byte by byte" do
      source = "data: first\n\ndata: second\n\n"

      {events, _state} =
        source
        |> String.graphemes()
        |> Enum.reduce({[], Parser.new()}, fn char, {acc_events, state} ->
          {new_events, state} = Parser.parse_chunk(char, state)
          {acc_events ++ new_events, state}
        end)

      assert [%{data: "first"}, %{data: "second"}] = events
    end
  end

  describe "parse_chunk/2 — last field wins" do
    test "last event field in a frame wins" do
      chunk = "event: first\nevent: second\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{event: "second", data: "hello"}] = events
    end

    test "last id field in a frame wins" do
      chunk = "id: 1\nid: 2\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{id: "2", data: "hello"}] = events
    end

    test "last retry field in a frame wins" do
      chunk = "retry: 1000\nretry: 2000\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{retry: 2000, data: "hello"}] = events
    end
  end

  describe "parse_chunk/2 — incomplete final frame buffering" do
    test "partial data without trailing blank line stays buffered" do
      state = Parser.new()

      {events, state} = Parser.parse_chunk("data: partial\n", state)
      assert events == []

      {events, state} = Parser.parse_chunk("data: more\n", state)
      assert events == []

      # Still buffered — no blank line yet (internal order is prepend-based)
      assert length(state.pending_data) == 2

      # Now close the frame
      {events, _state} = Parser.parse_chunk("\n", state)
      assert [%{data: "partial\nmore"}] = events
    end

    test "entire stream with no final blank line — flush recovers it" do
      state = Parser.new()

      {[], state} = Parser.parse_chunk("data: hello\n", state)

      # No blank line — flush to get the event
      {events, _state} = Parser.flush(state)
      assert [%{data: "hello"}] = events
    end

    test "flush on empty state returns no events" do
      {events, state} = Parser.flush(Parser.new())
      assert events == []
      assert state.buffer == ""
    end

    test "flush after complete event returns empty" do
      {_events, state} = Parser.parse_chunk("data: done\n\n", Parser.new())
      {events, _state} = Parser.flush(state)
      assert events == []
    end
  end

  describe "parse_chunk/2 — SSE spec edge cases" do
    test "field value with no space after colon" do
      chunk = "data:no-space\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      # Per spec, only a single leading space is stripped; "no-space" is the value
      assert [%{data: "no-space"}] = events
    end

    test "field value with multiple spaces after colon — only first stripped" do
      chunk = "data:  two spaces\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      # Only one leading space is stripped; remaining spaces stay
      assert [%{data: " two spaces"}] = events
    end

    test "field with empty value (colon only)" do
      chunk = "data:\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: ""}] = events
    end

    test "BOM in data is preserved" do
      chunk = "data: \uFEFFhello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: "\uFEFFhello"}] = events
    end

    test "NULL character in id is preserved (spec technically forbids, but we don't crash)" do
      chunk = "id: \0\ndata: hello\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      # We just verify no crash; the NULL stays in id
      assert length(events) == 1
      assert Enum.at(events, 0).id =~ "\0"
    end
  end

  describe "parse_chunk/2 — credential safety" do
    test "parser state does not include raw buffer after events are emitted" do
      chunk = "data: sensitive-api-key-here\n\n"
      {_events, state} = Parser.parse_chunk(chunk, Parser.new())

      # After emitting, the buffer should be empty
      assert state.buffer == ""
      # Pending data should be reset
      assert state.pending_data == []
    end

    test "parser never logs — it is a pure function" do
      # This is a design assertion: the parser module has no Logger calls.
      # We verify by checking the source at compile time (the module is pure by design).
      # The real test is code review; this test documents the intent.
      source =
        File.read!(
          Path.join([
            __DIR__ | ~w(.. .. .. .. .. lib muse llm transport sse parser.ex)
          ])
        )

      refute source =~ "Logger"
      refute source =~ "require_logger"
    end
  end

  describe "parse_chunk/2 — realistic OpenAI-style stream" do
    test "parses OpenAI chat completion SSE chunks" do
      chunks =
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" <>
          "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" <>
          "data: [DONE]\n\n"

      {events, _state} = Parser.parse_chunk(chunks, Parser.new())

      assert length(events) == 3
      assert Enum.at(events, 0).done? == false
      assert Enum.at(events, 1).done? == false
      assert Enum.at(events, 2).done? == true
      assert Enum.at(events, 2).data == "[DONE]"
    end

    test "parses OpenAI stream delivered in small chunks" do
      stream =
        "data: {\"id\":\"1\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n" <>
          "data: [DONE]\n\n"

      # Split at arbitrary boundaries
      {events, _state} =
        stream
        |> String.graphemes()
        |> Enum.reduce({[], Parser.new()}, fn char, {acc, state} ->
          {new_events, state} = Parser.parse_chunk(char, state)
          {acc ++ new_events, state}
        end)

      assert length(events) == 2
      assert Enum.at(events, 0).data =~ "Hi"
      assert Enum.at(events, 1).done? == true
    end
  end

  describe "parse_chunk/2 — stress / boundary" do
    test "empty chunk produces no events" do
      {events, state} = Parser.parse_chunk("", Parser.new())
      assert events == []
      assert state.buffer == ""
    end

    test "chunk containing only newlines" do
      {events, _state} = Parser.parse_chunk("\n\n\n\n", Parser.new())
      assert events == []
    end

    test "very long data line" do
      long_data = String.duplicate("x", 10_000)
      chunk = "data: #{long_data}\n\n"
      {events, _state} = Parser.parse_chunk(chunk, Parser.new())

      assert [%{data: ^long_data}] = events
    end

    test "many events in one chunk" do
      count = 100

      chunk =
        Enum.map_join(1..count, fn i ->
          "data: event-#{i}\n\n"
        end)

      {events, _state} = Parser.parse_chunk(chunk, Parser.new())
      assert length(events) == count
      assert Enum.at(events, 0).data == "event-1"
      assert Enum.at(events, 99).data == "event-100"
    end
  end
end
