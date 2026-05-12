defmodule Muse.LLM.FallbackParserTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{FallbackParser, Response, ToolCall}

  describe "parse/1" do
    test "returns unchanged response when no textual tool calls are present" do
      response = Response.new(content: "Hello world", tool_calls: [])
      assert FallbackParser.parse(response) == response
    end

    test "extracts a single textual tool call" do
      response = Response.new(content: "<tool_call>read_file{path:lib/muse.ex}")
      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse.ex"}
      assert String.starts_with?(tc.id, "fallback_")
    end

    test "extracts multiple textual tool calls" do
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

    test "parses JSON-style arguments when present" do
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

    test "ignores malformed lines gracefully" do
      response = Response.new(content: "<tool_call>no_args_here")
      parsed = FallbackParser.parse(response)

      assert parsed.tool_calls == []
    end

    test "handles whitespace around tool call components" do
      response =
        Response.new(content: "<tool_call>  list_files  {  directory : . , recursive : true }")

      parsed = FallbackParser.parse(response)

      assert length(parsed.tool_calls) == 1
      [tc] = parsed.tool_calls
      assert tc.name == "list_files"
      assert tc.arguments == %{"directory" => ".", "recursive" => "true"}
    end
  end
end
