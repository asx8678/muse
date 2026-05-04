defmodule Muse.LLM.Transport.SSE.ParserTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.Transport.SSE.Parser

  describe "parse/2 complete events" do
    test "parses a single SSE event" do
      {events, buf} = Parser.parse("data: hello\n\n", "")

      assert [%{event: "message", data: "hello", id: nil}] = events
      assert buf == ""
    end

    test "parses multiple SSE events in one chunk" do
      {events, buf} = Parser.parse("data: first\n\ndata: second\n\n", "")

      assert length(events) == 2
      assert Enum.at(events, 0).data == "first"
      assert Enum.at(events, 1).data == "second"
      assert buf == ""
    end

    test "parses SSE event with custom event type" do
      {events, _buf} = Parser.parse("event: ping\ndata: {}\n\n", "")

      assert [%{event: "ping", data: "{}"}] = events
    end

    test "parses SSE event with id" do
      {events, _buf} = Parser.parse("id: 42\ndata: hello\n\n", "")

      assert [%{data: "hello", id: "42"}] = events
    end

    test "joins multi-line data fields" do
      {events, _buf} = Parser.parse("data: line1\ndata: line2\n\n", "")

      assert [%{data: "line1\nline2"}] = events
    end
  end

  describe "parse/2 incremental buffering" do
    test "buffers incomplete events" do
      {events, buf} = Parser.parse("data: hel", "")

      assert events == []
      assert buf == "data: hel"
    end

    test "completes buffered events with next chunk" do
      {events1, buf1} = Parser.parse("data: hel", "")
      assert events1 == []

      {events2, buf2} = Parser.parse("lo\n\n", buf1)

      assert [%{data: "hello"}] = events2
      assert buf2 == ""
    end

    test "handles partial boundary split across chunks" do
      # Chunk ending mid-JSON, followed by rest + boundary
      {events1, buf1} = Parser.parse("data: {\"x\":1", "")
      assert events1 == []

      {events2, buf2} = Parser.parse("}\n\ndata: next\n\n", buf1)

      assert length(events2) == 2
      assert Enum.at(events2, 0).data == "{\"x\":1}"
      assert Enum.at(events2, 1).data == "next"
      assert buf2 == ""
    end
  end

  describe "parse/1 convenience" do
    test "parses complete SSE text" do
      events = Parser.parse("data: a\n\ndata: b\n\n")

      assert length(events) == 2
    end
  end

  describe "done_sentinel?/1" do
    test "detects [DONE] sentinel" do
      assert Parser.done_sentinel?("[DONE]") == true
      assert Parser.done_sentinel?("not done") == false
      assert Parser.done_sentinel?("") == false
    end
  end

  describe "Chat Completions [DONE] handling" do
    test "filters out [DONE] sentinel from events" do
      text =
        "data: {\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n"

      {events, _buf} = Parser.parse(text, "")

      # Only one event — [DONE] is filtered
      assert [%{data: "{\"id\":\"t\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}"}] = events
    end
  end

  describe "edge cases" do
    test "ignores comment lines" do
      {events, _buf} = Parser.parse(": this is a comment\ndata: real\n\n", "")

      assert [%{data: "real"}] = events
    end

    test "ignores retry lines" do
      {events, _buf} = Parser.parse("retry: 5000\ndata: ok\n\n", "")

      assert [%{data: "ok"}] = events
    end

    test "skips events with empty data" do
      {events, _buf} = Parser.parse("event: ping\n\n", "")

      assert events == []
    end

    test "normalizes \\r\\n to \\n" do
      {events, buf} = Parser.parse("data: hello\r\n\r\n", "")

      assert [%{data: "hello"}] = events
      assert buf == ""
    end

    test "handles empty input" do
      {events, buf} = Parser.parse("", "")

      assert events == []
      assert buf == ""
    end
  end
end
