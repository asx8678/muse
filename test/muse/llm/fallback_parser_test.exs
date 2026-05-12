defmodule Muse.LLM.FallbackParserTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{FallbackParser, Response, ToolCall}

  describe "parse/1 — no tool calls" do
    test "returns unchanged response when no textual tool calls are present" do
      response = Response.new(content: "Hello world", tool_calls: [])
      assert FallbackParser.parse(response) == response
    end

    test "ignores malformed lines gracefully" do
      response = Response.new(content: "<tool_call>no_args_here")
      parsed = FallbackParser.parse(response)

      assert parsed.tool_calls == []
    end
  end

  describe "parse/1 — Format 1: XML Tool Call with JSON payload" do
    test "extracts standard JSON inside <tool_call> tags" do
      content = """
      <tool_call>
      {"name": "read_file", "arguments": {"path": "lib/foo.ex"}}
      </tool_call>
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
      assert String.starts_with?(tc.id, "fallback_")
    end

    test "extracts nested JSON arguments inside <tool_call> tags" do
      content = """
      <tool_call>
      {"name": "run_test", "arguments": {"config": {"suite": "unit", "parallel": true}}}
      </tool_call>
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "run_test"
      assert tc.arguments == %{"config" => %{"suite" => "unit", "parallel" => true}}
    end
  end

  describe "parse/1 — Format 2: Pseudo-JSON" do
    test "extracts a single pseudo-JSON tool call" do
      response = Response.new(content: "<tool_call>read_file{path:lib/muse.ex}")
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse.ex"}
    end

    test "extracts multiple pseudo-JSON tool calls" do
      content = """
      I will read two files.
      <tool_call>read_file{path:lib/muse.ex}
      <tool_call>read_file{path:lib/muse_web/endpoint.ex}
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 2
      [tc1, tc2] = parsed.tool_calls
      assert tc1.name == "read_file"
      assert tc1.arguments == %{"path" => "lib/muse.ex"}
      assert tc2.name == "read_file"
      assert tc2.arguments == %{"path" => "lib/muse_web/endpoint.ex"}
    end

    test "handles nested braces in pseudo-JSON" do
      content = ~s(<tool_call>read_file{"config": {"path": "lib/muse.ex"}})

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"config" => %{"path" => "lib/muse.ex"}}
    end

    test "handles pseudo-JSON with trailing text and optional closing tag" do
      content = ~s|<tool_call>read_file{path: lib/foo.ex}(question=)|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end

    test "parses JSON-style arguments in pseudo-JSON" do
      response =
        Response.new(
          content: ~s(<tool_call>create_file{\"path\":\"test.txt\",\"content\":\"hi\"})
        )

      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "create_file"
      assert tc.arguments == %{"path" => "test.txt", "content" => "hi"}
    end

    test "handles whitespace around pseudo-JSON components" do
      response =
        Response.new(content: "<tool_call>  list_files  {  directory : . , recursive : true }")

      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "list_files"
      assert tc.arguments == %{"directory" => ".", "recursive" => "true"}
    end
  end

  describe "parse/1 — Format 3: ReAct style" do
    test "extracts ReAct format with JSON action input" do
      content = """
      Action: read_file
      Action Input: {"path": "lib/foo.ex"}
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end

    test "extracts ReAct format with loose key:value action input" do
      content = """
      Action: read_file
      Action Input: path: lib/foo.ex
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end

    test "extracts multiple ReAct actions" do
      content = """
      Action: read_file
      Action Input: {"path": "a.ex"}
      Action: list_files
      Action Input: {"directory": "."}
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 2
      [tc1, tc2] = parsed.tool_calls
      assert tc1.name == "read_file"
      assert tc2.name == "list_files"
    end
  end

  describe "parse/1 — Format 4: Markdown JSON blocks" do
    test "extracts tool call from fenced json block" do
      content = """
      ```json
      {"name": "read_file", "arguments": {"path": "lib/foo.ex"}}
      ```
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end

    test "extracts tool call from fenced block without json label" do
      content = """
      ```
      {"name": "run_test", "arguments": {"suite": "unit"}}
      ```
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "run_test"
    end

    test "ignores markdown blocks without name/arguments keys" do
      content = """
      ```json
      {"foo": "bar"}
      ```
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert parsed.tool_calls == []
    end
  end

  describe "parse/1 — Format 5: Invocations (<tool_call>name(...))" do
    test "extracts JSON object inside parens" do
      content = ~s|<tool_call>read_file({"path": "lib/muse_web/endpoint.ex"})|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse_web/endpoint.ex"}
      assert String.starts_with?(tc.id, "fallback_")
    end

    test "extracts nested JSON arguments inside parens" do
      content = ~s|<tool_call>run_test({"config": {"suite": "unit", "parallel": true}})|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "run_test"
      assert tc.arguments == %{"config" => %{"suite" => "unit", "parallel" => true}}
    end

    test "extracts double-quoted keyword args" do
      content = ~s|<tool_call>read_file(path="test.txt")|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "test.txt"}
    end

    test "extracts single-quoted keyword args" do
      content = "<tool_call>read_file(path='test.txt')"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "test.txt"}
    end

    test "extracts bare (unquoted) keyword args" do
      content = "<tool_call>read_file(path=test.txt)"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "test.txt"}
    end

    test "extracts multiple keyword args separated by commas" do
      content = ~s|<tool_call>read_file(path="test.txt", max_lines=500)|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "test.txt", "max_lines" => "500"}
    end

    test "extracts multiple invocation tool calls" do
      content =
        "I will read two files.\n" <>
          ~s|<tool_call>read_file({"path": "lib/muse.ex"})| <>
          "\n" <>
          ~s|<tool_call>read_file({"path": "lib/muse_web/endpoint.ex"})|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 2
      [tc1, tc2] = parsed.tool_calls
      assert tc1.name == "read_file"
      assert tc1.arguments == %{"path" => "lib/muse.ex"}
      assert tc2.name == "read_file"
      assert tc2.arguments == %{"path" => "lib/muse_web/endpoint.ex"}
    end

    test "handles whitespace between prefix, name, and arguments" do
      content = ~s|<tool_call>  list_files  ({"directory": ".", "recursive": true})|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "list_files"
      assert tc.arguments == %{"directory" => ".", "recursive" => true}
    end

    test "falls through to loose key:value parsing when no JSON or equals" do
      content = "<tool_call>read_file(path:lib/foo.ex)"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end

    test "ignores malformed content without parens" do
      response = Response.new(content: "<tool_call>no_parens_here")
      parsed = FallbackParser.parse(response)

      assert parsed.tool_calls == []
    end

    test "ignores invalid JSON inside parens" do
      content = "<tool_call>read_file({invalid json!!!})"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert parsed.tool_calls == []
    end
  end

  describe "parse/1 — Format 6: Space-separated arguments (<tool_call>name arg1 arg2)" do
    test "extracts single path argument" do
      content = "<tool_call>read_file /path/to/file.ex"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/path/to/file.ex"}
    end

    test "extracts number then path (e.g. line count + path)" do
      content = "<tool_call>read_file 6 /path/to/file.ex"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/path/to/file.ex", "max_lines" => "6"}
    end

    test "extracts path then number" do
      content = "<tool_call>read_file /path/to/file.ex 10"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/path/to/file.ex", "max_lines" => "10"}
    end

    test "joins multiple non-numeric parts as a single path" do
      content = "<tool_call>read_file lib/muse/llm/fallback_parser.ex"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse/llm/fallback_parser.ex"}
    end

    test "skips content that starts with parens (handled by Format 5)" do
      content = ~s|<tool_call>read_file({"path": "lib/foo.ex"})|

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      # Format 5 extracts this; Format 6 must not produce a duplicate
      read_file_calls = Enum.filter(parsed.tool_calls, &(&1.name == "read_file"))
      assert length(read_file_calls) == 1
    end

    test "skips content that starts with braces (handled by Format 2)" do
      content = "<tool_call>read_file{path:lib/foo.ex}"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      # Format 2 extracts this; Format 6 must not produce a duplicate
      read_file_calls = Enum.filter(parsed.tool_calls, &(&1.name == "read_file"))
      assert length(read_file_calls) == 1
    end

    test "handles keyword args with equals sign" do
      content = "<tool_call>read_file path=/tmp/foo.ex max_lines=50"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) >= 1

      tc =
        Enum.find(
          parsed.tool_calls,
          &(&1.name == "read_file" and Map.has_key?(&1.arguments, "path"))
        )

      assert tc.arguments == %{"path" => "/tmp/foo.ex", "max_lines" => "50"}
    end

    test "extracts multiple space-separated tool calls" do
      content = """
      I need to check two files.
      <tool_call>read_file lib/muse.ex
      <tool_call>list_files lib/muse_web
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      names = Enum.map(parsed.tool_calls, & &1.name)
      assert "read_file" in names
      assert "list_files" in names
    end

    test "ignores bare <tool_call>name with no arguments" do
      content = "<tool_call>some_tool_name"

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      # No extractor should produce a tool call from a bare name with no args
      assert Enum.all?(parsed.tool_calls, &(map_size(&1.arguments) > 0))
    end
  end

  describe "parse/1 — deduplication and existing tool calls" do
    test "appends textual tool calls to existing structured tool calls" do
      existing = ToolCall.new("existing_tool", %{"a" => "1"}, id: "call_123")
      response = Response.new(content: "<tool_call>new_tool{b:c}", tool_calls: [existing])
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 2
      [tc1, tc2] = parsed.tool_calls
      assert tc1.name == "existing_tool"
      assert tc2.name == "new_tool"
      assert tc2.arguments == %{"b" => "c"}
    end

    test "deduplicates overlapping formats" do
      content = """
      <tool_call>read_file{path: lib/foo.ex}</tool_call>
      """

      response = Response.new(content: content)
      parsed = FallbackParser.parse(response)

      # pseudo-JSON and XML JSON could both match; dedup keeps one
      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end
  end
end
