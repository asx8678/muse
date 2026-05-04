defmodule Muse.LLM.StructTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Event, Message, Request, Response, ToolCall}

  # ---------------------------------------------------------------------------
  # Message
  # ---------------------------------------------------------------------------

  describe "Muse.LLM.Message" do
    test "system/1 builds a system message" do
      msg = Message.system("You are a helpful assistant.")
      assert msg.role == :system
      assert msg.content == "You are a helpful assistant."
      assert msg.name == nil
      assert msg.tool_call_id == nil
      assert msg.metadata == %{}
    end

    test "user/1 builds a user message" do
      msg = Message.user("add a /version command")
      assert msg.role == :user
      assert msg.content == "add a /version command"
    end

    test "assistant/1 builds an assistant message with text" do
      msg = Message.assistant("Here is my plan.")
      assert msg.role == :assistant
      assert msg.content == "Here is my plan."
    end

    test "assistant/1 allows nil content for tool-call-only turns" do
      msg = Message.assistant(nil)
      assert msg.role == :assistant
      assert msg.content == nil
    end

    test "tool/2 builds a tool-result message" do
      msg = Message.tool("File contents...", "call_abc123")
      assert msg.role == :tool
      assert msg.content == "File contents..."
      assert msg.tool_call_id == "call_abc123"
    end

    test "direct struct creation with @enforce_keys respects required role" do
      msg = %Message{role: :user, content: "hello"}
      assert msg.role == :user
      assert msg.content == "hello"
    end

    test "default metadata is an empty map" do
      msg = Message.user("test")
      assert msg.metadata == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # ToolCall
  # ---------------------------------------------------------------------------

  describe "Muse.LLM.ToolCall" do
    test "new/2 creates a tool call with name and arguments" do
      tc = ToolCall.new("read_file", %{"path" => "lib/muse.ex"})
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/muse.ex"}
      assert tc.id == nil
      assert tc.raw == nil
    end

    test "new/3 accepts optional id and raw" do
      tc = ToolCall.new("list_files", %{"path" => "."}, id: "call_1", raw: %{original: "data"})
      assert tc.id == "call_1"
      assert tc.name == "list_files"
      assert tc.raw == %{original: "data"}
    end

    test "new/2 normalizes nil arguments to empty map" do
      tc = ToolCall.new("read_file", nil)
      assert tc.arguments == %{}
    end

    test "new/3 with empty opts works" do
      tc = ToolCall.new("search", %{"q" => "test"}, [])
      assert tc.name == "search"
      assert tc.id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Request
  # ---------------------------------------------------------------------------

  describe "Muse.LLM.Request" do
    test "default stream is true" do
      req = %Request{messages: [Message.user("hi")]}
      assert req.stream == true
      assert req.options == %{}
    end

    test "latest_user_text/1 returns the last user message text" do
      req = %Request{
        messages: [
          Message.system("be helpful"),
          Message.user("first question"),
          Message.assistant("ok"),
          Message.user("second question")
        ]
      }

      assert Request.latest_user_text(req) == "second question"
    end

    test "latest_user_text/1 returns fallback when no user message" do
      req = %Request{messages: [Message.system("be helpful")]}
      assert Request.latest_user_text(req) == "(no user message)"
    end

    test "latest_user_text/1 returns fallback when user message has nil content" do
      req = %Request{messages: [%Message{role: :user, content: nil}]}
      assert Request.latest_user_text(req) == "(no user message)"
    end

    test "latest_user_text/1 returns fallback when messages is nil" do
      req = %Request{messages: nil}
      assert Request.latest_user_text(req) == "(no user message)"
    end
  end

  # ---------------------------------------------------------------------------
  # Response
  # ---------------------------------------------------------------------------

  describe "Muse.LLM.Response" do
    test "new/1 creates minimal response" do
      resp = Response.new()
      assert resp.content == nil
      assert resp.text == nil
      assert resp.tool_calls == []
      assert resp.finish_reason == nil
    end

    test "new/1 with content sets both content and text" do
      resp = Response.new(content: "Hello")
      assert resp.content == "Hello"
      assert resp.text == "Hello"
    end

    test "new/1 accepts explicit text different from content" do
      resp = Response.new(content: "Hello", text: "Hi")
      assert resp.content == "Hello"
      assert resp.text == "Hi"
    end

    test "has_tool_calls?/1 returns true when tool_calls is non-empty" do
      tc = ToolCall.new("read_file", %{})
      resp = Response.new(tool_calls: [tc])
      assert Response.has_tool_calls?(resp)
    end

    test "has_tool_calls?/1 returns false when tool_calls is empty" do
      resp = Response.new(tool_calls: [])
      refute Response.has_tool_calls?(resp)
    end

    test "has_tool_calls?/1 returns false when tool_calls is nil" do
      resp = Response.new()
      refute Response.has_tool_calls?(resp)
    end

    test "has_content?/1 returns true when content is present" do
      resp = Response.new(content: "hello")
      assert Response.has_content?(resp)
    end

    test "has_content?/1 returns false when content and text are nil" do
      resp = Response.new(content: nil, text: nil)
      refute Response.has_content?(resp)
    end

    test "has_content?/1 returns false when content and text are empty string" do
      resp = Response.new(content: "", text: "")
      refute Response.has_content?(resp)
    end
  end

  # ---------------------------------------------------------------------------
  # Event — normalized types and constructors
  # ---------------------------------------------------------------------------

  describe "Muse.LLM.Event" do
    test "event_types/0 returns all canonical types" do
      assert Event.event_types() == [
               :response_started,
               :assistant_delta,
               :assistant_completed,
               :tool_call_started,
               :tool_call_delta,
               :tool_call_completed,
               :response_completed,
               :provider_error
             ]
    end

    test "valid_event_type?/1 returns true for all canonical types" do
      for type <- Event.event_types() do
        assert Event.valid_event_type?(type), "expected #{inspect(type)} to be valid"
      end
    end

    test "valid_event_type?/1 returns false for unknown types" do
      refute Event.valid_event_type?(:unknown)
      refute Event.valid_event_type?(:foo)
      refute Event.valid_event_type?(nil)
    end

    test "response_started/0 creates the correct event" do
      event = Event.response_started()
      assert event.type == :response_started
      assert event.text == nil
      assert event.tool_call == nil
      assert event.usage == nil
      assert event.error == nil
    end

    test "assistant_delta/1 creates the correct event" do
      event = Event.assistant_delta("Hello")
      assert event.type == :assistant_delta
      assert event.text == "Hello"
    end

    test "assistant_completed/0 creates event with nil text" do
      event = Event.assistant_completed()
      assert event.type == :assistant_completed
      assert event.text == nil
    end

    test "assistant_completed/1 creates event with final text" do
      event = Event.assistant_completed("Final answer")
      assert event.type == :assistant_completed
      assert event.text == "Final answer"
    end

    test "tool_call_started/1 creates the correct event" do
      tc = ToolCall.new("read_file", %{"path" => "x"})
      event = Event.tool_call_started(tc)
      assert event.type == :tool_call_started
      assert event.tool_call == tc
    end

    test "tool_call_delta/1 creates the correct event" do
      tc = ToolCall.new("read_file", %{"path" => "x"})
      event = Event.tool_call_delta(tc)
      assert event.type == :tool_call_delta
      assert event.tool_call == tc
    end

    test "tool_call_completed/1 creates the correct event" do
      tc = ToolCall.new("read_file", %{"path" => "x"})
      event = Event.tool_call_completed(tc)
      assert event.type == :tool_call_completed
      assert event.tool_call == tc
    end

    test "response_completed/0 creates event with nil usage" do
      event = Event.response_completed()
      assert event.type == :response_completed
      assert event.usage == nil
    end

    test "response_completed/1 creates event with usage data" do
      event = Event.response_completed(%{prompt_tokens: 10, completion_tokens: 20})
      assert event.type == :response_completed
      assert event.usage == %{prompt_tokens: 10, completion_tokens: 20}
    end

    test "provider_error/1 creates the correct event" do
      event = Event.provider_error("rate limit exceeded")
      assert event.type == :provider_error
      assert event.error == "rate limit exceeded"
    end

    test "provider_error/1 works with atom errors" do
      event = Event.provider_error(:timeout)
      assert event.type == :provider_error
      assert event.error == :timeout
    end

    test "events require the :type field" do
      # The @enforce_keys [:type] means literal %Event{} syntax fails at compile
      # time if :type is omitted.  At runtime we can verify that valid Event
      # structs always have a proper type set.
      event = Event.response_started()
      assert event.type == :response_started
    end

    test "events can be pattern-matched on type" do
      event = Event.assistant_delta("chunk")
      assert %Event{type: :assistant_delta, text: "chunk"} = event
    end
  end
end
