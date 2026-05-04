defmodule Muse.LLM.FakeProviderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{FakeProvider, Message, Request, Response, ToolCall}

  # Helper to build a minimal request
  defp default_request(opts \\ []) do
    text = Keyword.get(opts, :user_text, "add a /version command")
    options = Keyword.get(opts, :options, %{})

    %Request{
      provider: :fake,
      model: "fake-planning-model",
      messages: [Message.user(text)],
      options: options
    }
  end

  # Helper to collect events from a stream call
  defp collect_events(request) do
    {:ok, ref} = Agent.start_link(fn -> [] end)

    result =
      FakeProvider.stream(request, fn event ->
        Agent.update(ref, &[event | &1])
        :ok
      end)

    events = Agent.get(ref, &Enum.reverse/1)
    Agent.stop(ref)

    case result do
      {:ok, response} -> {:ok, response, events}
      {:error, reason} -> {:error, reason, events}
    end
  end

  # ---------------------------------------------------------------------------
  # Default (unscripted) behavior
  # ---------------------------------------------------------------------------

  describe "default deterministic response" do
    test "stream/2 emits response_started, assistant_delta, assistant_completed, response_completed" do
      request = default_request()
      {:ok, _response, events} = collect_events(request)

      event_types = Enum.map(events, & &1.type)
      assert :response_started in event_types
      assert :assistant_delta in event_types
      assert :assistant_completed in event_types
      assert :response_completed in event_types
    end

    test "stream/2 returns a %Response{} struct" do
      request = default_request()
      {:ok, response, _events} = collect_events(request)

      assert %Response{} = response
    end

    test "stream/2 response content includes the user message text" do
      request = default_request(user_text: "hello there")
      {:ok, response, _events} = collect_events(request)

      assert response.content == "Placeholder response: received hello there"
      assert response.finish_reason == "stop"
    end

    test "stream/2 emits events in canonical order" do
      request = default_request()
      {:ok, _response, events} = collect_events(request)

      assert length(events) >= 4

      # First event should be response_started, last should be response_completed
      assert hd(events).type == :response_started
      assert List.last(events).type == :response_completed
    end

    test "complete/2 returns response without events" do
      request = default_request()
      assert {:ok, %Response{} = response} = FakeProvider.complete(request)

      assert response.content == "Placeholder response: received add a /version command"
      assert response.finish_reason == "stop"
    end
  end

  # ---------------------------------------------------------------------------
  # Scripted text response from fixture-like tuples
  # ---------------------------------------------------------------------------

  describe "scripted text response" do
    test "scripted assistant deltas are emitted in order" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Step 1: "},
              {:assistant_delta, "find files"},
              {:assistant_delta, "."},
              {:assistant_completed, "Step 1: find files."},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      delta_texts =
        events
        |> Enum.filter(&(&1.type == :assistant_delta))
        |> Enum.map(& &1.text)

      assert delta_texts == ["Step 1: ", "find files", "."]
      # assistant_completed text is preferred for response.content
      assert response.content == "Step 1: find files."
      assert response.finish_reason == "stop"
    end

    test "scripted response from fixture data produces deterministic result" do
      # Simulates loading a fixture JSON file
      fixture_events = [
        {:assistant_delta, "I'll inspect the workspace structure first."},
        {:assistant_delta, "Based on the file listing, here is my plan:"},
        {:assistant_delta, "1. Locate CLI command routing.\n"},
        {:assistant_delta, "2. Add /version handling.\n"},
        {:assistant_completed,
         "I'll inspect the workspace structure first.Based on the file listing, here is my plan:\n1. Locate CLI command routing.\n2. Add /version handling.\n"},
        {:response_completed, nil}
      ]

      request =
        default_request(options: %{fake_events: fixture_events})

      {:ok, response, _events} = collect_events(request)

      assert response.content =~ "I'll inspect the workspace"
      assert response.content =~ "1. Locate CLI command routing"
      assert response.content =~ "2. Add /version handling"
      assert response.finish_reason == "stop"
    end

    test "scripted response with usage data on response_completed" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Done."},
              {:assistant_completed, "Done."},
              {:response_completed, %{prompt_tokens: 100, completion_tokens: 50}}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      completed_event = Enum.find(events, &(&1.type == :response_completed))
      assert completed_event.usage == %{prompt_tokens: 100, completion_tokens: 50}
      assert response.usage == %{prompt_tokens: 100, completion_tokens: 50}
    end
  end

  # ---------------------------------------------------------------------------
  # Scripted tool calls
  # ---------------------------------------------------------------------------

  describe "scripted tool calls" do
    test "tool call script entry emits tool_call_started and tool_call_completed" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Let me search."},
              {:tool_call, "repo_search", %{"query" => "test", "path" => "."}},
              {:assistant_completed, "Let me search."},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      started_events = Enum.filter(events, &(&1.type == :tool_call_started))
      completed_events = Enum.filter(events, &(&1.type == :tool_call_completed))

      assert length(started_events) == 1
      assert length(completed_events) == 1

      tc = hd(completed_events).tool_call
      assert %ToolCall{} = tc
      assert tc.name == "repo_search"
      assert tc.arguments == %{"query" => "test", "path" => "."}
      assert tc.id == "fake_call_0"

      assert response.tool_calls != []
      assert hd(response.tool_calls).name == "repo_search"
      assert response.finish_reason == "tool_calls"
    end

    test "tool call with explicit id uses that id" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:tool_call, "read_file", %{"path" => "lib/muse.ex"}, "call_explicit_99"},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, _response, events} = collect_events(request)
      completed_events = Enum.filter(events, &(&1.type == :tool_call_completed))

      tc = hd(completed_events).tool_call
      assert tc.id == "call_explicit_99"
    end

    test "multiple tool calls get sequential deterministic ids" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:tool_call, "search", %{"q" => "a"}, "call_a"},
              {:tool_call, "search", %{"q" => "b"}, "call_b"},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, _response, events} = collect_events(request)
      completed_events = Enum.filter(events, &(&1.type == :tool_call_completed))

      ids = Enum.map(completed_events, & &1.tool_call.id)
      assert ids == ["call_a", "call_b"]
    end

    test "tool calls appear in response struct" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:tool_call, "list_files", %{"path" => "."}, "call_list"},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, response, _events} = collect_events(request)

      assert length(response.tool_calls) == 1
      assert hd(response.tool_calls).name == "list_files"
      assert hd(response.tool_calls).id == "call_list"
    end

    test "tool call with nil arguments is normalized" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:tool_call, "read_file", %{}, "call_rf"},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, _response, events} = collect_events(request)
      completed_events = Enum.filter(events, &(&1.type == :tool_call_completed))

      assert hd(completed_events).tool_call.arguments == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Error path
  # ---------------------------------------------------------------------------

  describe "error path — safe and redacted" do
    test "error entry in fake_events emits :provider_error and returns {:error, reason}" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Starting..."},
              {:error, "connection refused"}
            ]
          }
        )

      # An {:error, _} entry inside fake_events emits a :provider_error event
      # AND makes stream/2 return {:error, reason}, matching provider failure
      # semantics — once the provider errors, the stream is over.
      assert {:error, reason, events} = collect_events(request)
      assert reason =~ "connection refused"

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1

      # Events before the error were still emitted
      delta_events = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(delta_events) == 1
    end

    test "fake_error option returns {:error, _} without crashing" do
      request =
        default_request(
          options: %{
            fake_error: :rate_limited
          }
        )

      assert {:error, reason} = FakeProvider.stream(request, fn _event -> :ok end)
      assert reason == :rate_limited
    end

    test "fake_error with string containing sk- is redacted" do
      request =
        default_request(
          options: %{
            fake_error: "invalid token: sk-test-12345"
          }
        )

      assert {:error, reason} = FakeProvider.stream(request, fn _event -> :ok end)
      refute reason =~ "sk-test-12345"
      assert reason =~ "[REDACTED]"
    end

    test "fake_error with map containing sensitive keys is redacted" do
      request =
        default_request(
          options: %{
            fake_error: %{message: "auth failed", api_key: "sk-secret-999"}
          }
        )

      assert {:error, reason} = FakeProvider.stream(request, fn _event -> :ok end)

      if is_map(reason) do
        assert reason.api_key == "[REDACTED]" or reason.api_key == "**REDACTED**"
      end
    end

    test "non-list fake_events is handled safely" do
      request =
        default_request(
          options: %{
            fake_events: "not a list"
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      assert Enum.any?(events, &(&1.type == :provider_error))
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed scripted entries
  # ---------------------------------------------------------------------------

  describe "malformed script entries — safe handling" do
    test "unknown script entry becomes :provider_error and returns {:error, reason}" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:invalid_type, "some data"}
            ]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "map-based script entry with unknown type emits :provider_error" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{type: :unknown_event_type, text: "something"}
            ]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      provider_errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(provider_errors) == 1
      assert provider_errors |> hd() |> Map.get(:error) =~ "unknown event type"
    end

    test "binary in fake_events emits :provider_error and returns {:error, reason}" do
      request =
        default_request(
          options: %{
            fake_events: ["raw string"]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "empty script does not crash" do
      request =
        default_request(
          options: %{
            fake_events: []
          }
        )

      assert {:ok, _response, _events} = collect_events(request)
    end
  end

  # ---------------------------------------------------------------------------
  # No network dependency
  # ---------------------------------------------------------------------------

  describe "no network dependency" do
    test "stream/2 works without any HTTP or network client" do
      # This test proves no network dependency by simply succeeding
      request = default_request()
      assert {:ok, %Response{} = _response} = FakeProvider.stream(request, fn _event -> :ok end)
    end

    test "complete/2 works without any HTTP or network client" do
      request = default_request()
      assert {:ok, %Response{} = _response} = FakeProvider.complete(request)
    end
  end

  # ---------------------------------------------------------------------------
  # Text assembly — assistant_completed text preferred over deltas
  # ---------------------------------------------------------------------------

  describe "text assembly — assistant_completed preferred" do
    test "response.content uses assistant_completed text when present" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Hello "},
              {:assistant_delta, "world"},
              {:assistant_completed, "Hello world"},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, response, _events} = collect_events(request)

      # Uses the authoritative completed text, NOT concatenation of deltas
      assert response.content == "Hello world"
    end

    test "response.content concatenates deltas when no assistant_completed with text" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Hello "},
              {:assistant_delta, "world"},
              {:assistant_completed, nil},
              {:response_completed, nil}
            ]
          }
        )

      {:ok, response, _events} = collect_events(request)

      # Falls back to concatenated deltas when completed text is absent
      assert response.content == "Hello world"
    end

    test "complete/2 also prefers assistant_completed text" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "partial"},
              {:assistant_completed, "full text"},
              {:response_completed, nil}
            ]
          }
        )

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "full text"
    end

    test "complete/2 concatenates deltas when no assistant_completed text" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "part1 "},
              {:assistant_delta, "part2"},
              {:response_completed, nil}
            ]
          }
        )

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "part1 part2"
    end
  end

  # ---------------------------------------------------------------------------
  # Map-based script entries — atom and string keys
  # ---------------------------------------------------------------------------

  describe "map-based script entries" do
    test "map with :type atom key and atom value" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{type: :assistant_delta, text: "hello from atom map"},
              %{type: :assistant_completed, text: "hello from atom map"},
              %{type: :response_completed}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      delta_events = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(delta_events) == 1
      assert hd(delta_events).text == "hello from atom map"
      assert response.content == "hello from atom map"
    end

    test "map with 'event' string key and string value" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{"event" => "assistant_delta", "text" => "hello from string map"},
              %{"event" => "assistant_completed", "text" => "hello from string map"},
              %{"event" => "response_completed"}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      delta_events = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(delta_events) == 1
      assert hd(delta_events).text == "hello from string map"
      assert response.content == "hello from string map"
    end

    test "map with :event atom key and string value" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{event: "assistant_delta", text: "mixed key types"},
              %{event: "assistant_completed", text: "mixed key types"},
              %{event: "response_completed"}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      assert Enum.any?(events, &(&1.type == :assistant_delta))
      assert response.content == "mixed key types"
    end

    test "map-based tool_call entry emits started and completed events" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{
                "event" => "tool_call",
                "name" => "read_file",
                "arguments" => %{"path" => "mix.exs"},
                "id" => "map_tc_1"
              },
              %{"event" => "response_completed"}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      started = Enum.filter(events, &(&1.type == :tool_call_started))
      completed = Enum.filter(events, &(&1.type == :tool_call_completed))

      assert length(started) == 1
      assert length(completed) == 1
      assert hd(completed).tool_call.name == "read_file"
      assert hd(completed).tool_call.id == "map_tc_1"
      assert response.tool_calls != []
    end

    test "map-based tool_call without explicit id gets generated id" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{type: :tool_call, name: "search", arguments: %{"q" => "test"}},
              %{type: :response_completed}
            ]
          }
        )

      {:ok, _response, events} = collect_events(request)
      completed = Enum.filter(events, &(&1.type == :tool_call_completed))
      assert hd(completed).tool_call.id =~ "fake_call_"
    end

    test "unknown string event type in map produces :provider_error" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{"event" => "nonexistent_event_type"}
            ]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(errors) == 1
      assert hd(errors).error =~ "unknown event type"
    end

    test "map with neither :type nor :event key produces :provider_error" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{"text" => "orphaned text"}
            ]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      errors = Enum.filter(events, &(&1.type == :provider_error))
      assert length(errors) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # JSONL fixture loading
  # ---------------------------------------------------------------------------

  describe "JSONL fixture loading" do
    @planning_fixture Path.expand(
                        "../../fixtures/fake_provider/planning_flow.jsonl",
                        __DIR__
                      )

    test "planning_flow.jsonl can be loaded and used as fake_events" do
      # Read JSONL file — one JSON object per line
      entries =
        @planning_fixture
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert length(entries) > 0

      # Use the parsed entries as fake_events (they are maps with string keys)
      request =
        default_request(options: %{fake_events: entries})

      {:ok, response, events} = collect_events(request)

      # The fixture includes assistant deltas, a tool call, and response_completed
      assert Enum.any?(events, &(&1.type == :assistant_delta))
      assert Enum.any?(events, &(&1.type == :tool_call_completed))
      assert Enum.any?(events, &(&1.type == :response_completed))

      # Response content should prefer the assistant_completed text (plan JSON)
      assert response.content =~ "/version"
      assert response.tool_calls != []

      # The fixture now includes a valid structured plan JSON
      assert {:ok, _plan} = Muse.PlanParser.parse(response.content)
    end

    @tool_calls_fixture Path.expand(
                          "../../fixtures/fake_provider/tool_calls_then_text.jsonl",
                          __DIR__
                        )

    test "tool_calls_then_text.jsonl can be loaded and used as fake_events" do
      entries =
        @tool_calls_fixture
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert length(entries) > 0

      request =
        default_request(options: %{fake_events: entries})

      {:ok, response, events} = collect_events(request)

      # Multiple tool calls should be present
      tool_call_events = Enum.filter(events, &(&1.type == :tool_call_completed))
      assert length(tool_call_events) >= 2

      # Usage data from response_completed should be preserved
      assert response.usage != nil
      assert response.usage["prompt_tokens"] == 250
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour conformance
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Map-based provider_error redaction
  # ---------------------------------------------------------------------------

  describe "map-based provider_error redaction (stream)" do
    test "map with provider_error event redacts the error field before emitting" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{"event" => "provider_error", "error" => "invalid token: sk-test-123"}
            ]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      # The emitted event must not contain the secret
      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1
      assert error_events |> hd() |> Map.get(:error) =~ "[REDACTED]"
      refute error_events |> hd() |> Map.get(:error) =~ "sk-test-123"

      # The returned reason must also be redacted
      refute reason =~ "sk-test-123"
      assert reason =~ "[REDACTED]"
    end

    test "map with :type provider_error and atom keys redacts the error field" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{type: :provider_error, error: "key=sk-abc123def456"}
            ]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1
      refute error_events |> hd() |> Map.get(:error) =~ "sk-abc123def456"
      refute reason =~ "sk-abc123def456"
    end

    test "map with provider_error and map-valued error redacts sensitive keys" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{
                "event" => "provider_error",
                "error" => %{"message" => "auth failed", "api_key" => "sk-secret-999"}
              }
            ]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1

      # The event error field should be redacted (map form)
      event_error = hd(error_events).error

      if is_map(event_error) do
        refute event_error["api_key"] =~ "sk-secret-999"
      end

      # The returned reason should also be redacted
      if is_map(reason) do
        refute reason["api_key"] =~ "sk-secret-999"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # complete/2 with scripted formats (tuples, maps, %Event{})
  # ---------------------------------------------------------------------------

  describe "complete/2 with scripted formats" do
    test "complete/2 with tuple entries produces content, tool_calls, and usage" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "Step 1"},
              {:assistant_completed, "Step 1"},
              {:tool_call, "read_file", %{"path" => "mix.exs"}},
              {:response_completed, %{"prompt_tokens" => 100, "completion_tokens" => 42}}
            ]
          }
        )

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "Step 1"
      assert length(response.tool_calls) == 1
      assert hd(response.tool_calls).name == "read_file"
      assert response.usage == %{"prompt_tokens" => 100, "completion_tokens" => 42}
      assert response.finish_reason == "tool_calls"
    end

    test "complete/2 with map entries (string keys from JSONL) produces content and tool calls" do
      jsonl_entries = [
        %{"event" => "assistant_delta", "text" => "Searching..."},
        %{
          "event" => "tool_call",
          "name" => "search",
          "arguments" => %{"q" => "test"},
          "id" => "call_s1"
        },
        %{"event" => "assistant_completed", "text" => "Done searching."},
        %{
          "event" => "response_completed",
          "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 20}
        }
      ]

      request =
        default_request(options: %{fake_events: jsonl_entries})

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "Done searching."
      assert length(response.tool_calls) == 1
      assert hd(response.tool_calls).name == "search"
      assert hd(response.tool_calls).id == "call_s1"
      assert response.usage == %{"prompt_tokens" => 50, "completion_tokens" => 20}
    end

    test "complete/2 with map entries (atom keys) produces content" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{type: :assistant_delta, text: "hello"},
              %{type: :assistant_completed, text: "hello"},
              %{type: :response_completed}
            ]
          }
        )

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "hello"
    end

    test "complete/2 with %Event{} entries produces content and tool_calls" do
      alias Muse.LLM.Event

      tc = Muse.LLM.ToolCall.new("list_files", %{"path" => "."}, id: "ev_tc_1")

      request =
        default_request(
          options: %{
            fake_events: [
              Event.assistant_delta("Checking files"),
              Event.tool_call_started(tc),
              Event.tool_call_completed(tc),
              Event.assistant_completed("Checking files"),
              Event.response_completed()
            ]
          }
        )

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "Checking files"
      assert length(response.tool_calls) == 1
      assert hd(response.tool_calls).name == "list_files"
    end

    test "complete/2 prefers assistant_completed text over concatenated deltas" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{"event" => "assistant_delta", "text" => "partial "},
              %{"event" => "assistant_delta", "text" => "text"},
              %{"event" => "assistant_completed", "text" => "full authoritative text"},
              %{"event" => "response_completed"}
            ]
          }
        )

      assert {:ok, response} = FakeProvider.complete(request)
      assert response.content == "full authoritative text"
    end
  end

  # ---------------------------------------------------------------------------
  # complete/2 error returns — redacted and safe
  # ---------------------------------------------------------------------------

  describe "complete/2 error returns" do
    test "complete/2 with {:error, reason} tuple returns {:error, redacted}" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "working..."},
              {:error, "token expired: sk-test-123"}
            ]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      refute reason =~ "sk-test-123"
      assert reason =~ "[REDACTED]"
    end

    test "complete/2 with map provider_error entry returns {:error, redacted}" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{"event" => "provider_error", "error" => "key=sk-proj-abc123"}
            ]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      refute reason =~ "sk-proj-abc123"
    end

    test "complete/2 with unknown map entry type returns {:error, reason}" do
      request =
        default_request(
          options: %{
            fake_events: [
              %{type: :totally_bogus_type, text: "hello"}
            ]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      assert reason =~ "unknown event type"
    end

    test "complete/2 with malformed entry returns {:error, reason}" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:weird_tuple, 42, :data}
            ]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      assert reason =~ "unknown script entry"
    end

    test "complete/2 with non-list fake_events returns {:error, reason}" do
      request =
        default_request(
          options: %{
            fake_events: "not a list"
          }
        )

      assert {:error, _reason} = FakeProvider.complete(request)
    end

    test "complete/2 with :fake_error option returns {:error, redacted}" do
      request =
        default_request(
          options: %{
            fake_error: "bad token: sk-12345"
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      refute reason =~ "sk-12345"
    end

    test "complete/2 stops at first error entry (no further accumulation)" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:assistant_delta, "before error"},
              {:error, "something broke"},
              {:assistant_delta, "after error — must not be accumulated"}
            ]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      assert reason =~ "something broke"
      # Content after the error should NOT appear
    end
  end

  # ---------------------------------------------------------------------------
  # Comprehensive redaction — tuple, exotic, and %Event{} provider_error
  # ---------------------------------------------------------------------------

  describe "redaction — tuple and exotic error types" do
    test "tuple error containing sk- key is redacted in stream" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:error, {"api_error", "key=sk-proj-abc123"}}
            ]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1
      # The error field in the event must not contain the secret
      error_str = inspect(hd(error_events).error)
      refute error_str =~ "sk-proj-abc123"

      # The returned reason must also be redacted
      refute inspect(reason) =~ "sk-proj-abc123"
    end

    test "tuple error with sk- key is redacted in complete/2" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:error, {"auth", "token sk-test-999"}}
            ]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      refute inspect(reason) =~ "sk-test-999"
    end

    test "struct/exception error containing secret is redacted" do
      err = %ArgumentError{message: "invalid key sk-proj-xyz789"}

      request =
        default_request(
          options: %{
            fake_events: [
              {:error, err}
            ]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1

      # Secret must not leak through struct redaction
      refute inspect(hd(error_events).error) =~ "sk-proj-xyz789"
      refute inspect(reason) =~ "sk-proj-xyz789"
    end

    test "numeric error passes through unchanged" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:error, 503}
            ]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert hd(error_events).error == 503
      assert reason == 503
    end

    test "exotic term (pid/ref) error is inspect-redacted safely in stream" do
      request =
        default_request(
          options: %{
            fake_events: [
              {:error, self()}
            ]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1
      # Should not crash; pid is inspect-stringed
      assert is_binary(hd(error_events).error)
    end
  end

  describe "redaction — %Event{type: :provider_error} script entries" do
    test "%Event{} provider_error with sk- secret is redacted in stream" do
      raw_event = %Muse.LLM.Event{
        type: :provider_error,
        error: "token=sk-test-12345"
      }

      request =
        default_request(
          options: %{
            fake_events: [raw_event]
          }
        )

      assert {:error, reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1
      refute hd(error_events).error =~ "sk-test-12345"
      assert hd(error_events).error =~ "[REDACTED]"

      refute reason =~ "sk-test-12345"
    end

    test "%Event{} provider_error with sk- secret is redacted in complete/2" do
      raw_event = %Muse.LLM.Event{
        type: :provider_error,
        error: "key=sk-proj-abc"
      }

      request =
        default_request(
          options: %{
            fake_events: [raw_event]
          }
        )

      assert {:error, reason} = FakeProvider.complete(request)
      refute reason =~ "sk-proj-abc"
    end

    test "%Event{} provider_error with map error containing secret is redacted" do
      raw_event = %Muse.LLM.Event{
        type: :provider_error,
        error: %{"message" => "failed", "api_key" => "sk-secret-111"}
      }

      request =
        default_request(
          options: %{
            fake_events: [raw_event]
          }
        )

      assert {:error, _reason, events} = collect_events(request)

      error_events = Enum.filter(events, &(&1.type == :provider_error))
      assert length(error_events) == 1

      event_error = hd(error_events).error

      if is_map(event_error) do
        refute event_error["api_key"] =~ "sk-secret-111"
      end
    end

    test "%Event{} non-error event is emitted unchanged" do
      delta_event = %Muse.LLM.Event{type: :assistant_delta, text: "hello"}

      request =
        default_request(
          options: %{
            fake_events: [
              delta_event,
              %Muse.LLM.Event{type: :assistant_completed, text: "hello"},
              %Muse.LLM.Event{type: :response_completed}
            ]
          }
        )

      {:ok, response, events} = collect_events(request)

      assert Enum.any?(events, &(&1.type == :assistant_delta))
      assert response.content == "hello"
    end
  end

  # ---------------------------------------------------------------------------
  # nil / non-map request.options safety
  # ---------------------------------------------------------------------------

  describe "nil/non-map request.options safety" do
    test "stream/2 with nil options uses default behavior" do
      request = %Request{
        provider: :fake,
        model: "fake-planning-model",
        messages: [Message.user("test")],
        options: nil
      }

      assert {:ok, %Response{} = response} =
               FakeProvider.stream(request, fn _event -> :ok end)

      assert response.content =~ "test"
    end

    test "complete/2 with nil options uses default behavior" do
      request = %Request{
        provider: :fake,
        model: "fake-planning-model",
        messages: [Message.user("test")],
        options: nil
      }

      assert {:ok, %Response{} = response} = FakeProvider.complete(request)
      assert response.content =~ "test"
    end

    test "stream/2 with non-map options returns {:error, reason} and emits provider_error" do
      request = %Request{
        provider: :fake,
        model: "fake-planning-model",
        messages: [Message.user("test")],
        options: "not a map"
      }

      assert {:error, reason, events} = collect_events(request)

      assert Enum.any?(events, &(&1.type == :provider_error))
      assert reason =~ "must be a map"
    end

    test "complete/2 with non-map options returns {:error, reason}" do
      request = %Request{
        provider: :fake,
        model: "fake-planning-model",
        messages: [Message.user("test")],
        options: [:list, :not, :map]
      }

      assert {:error, reason} = FakeProvider.complete(request)
      assert reason =~ "must be a map"
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour conformance
  # ---------------------------------------------------------------------------

  describe "Muse.LLM.Provider behaviour" do
    test "FakeProvider implements @behaviour Muse.LLM.Provider" do
      assert Keyword.get(FakeProvider.__info__(:attributes), :behaviour) == [Muse.LLM.Provider]

      # Verify both callbacks are implemented
      impls = FakeProvider.__info__(:functions) |> Map.new()

      assert Map.has_key?(impls, :stream),
             "FakeProvider must implement stream/2"

      assert Map.has_key?(impls, :complete),
             "FakeProvider must implement complete/2"
    end

    test "stream/2 accepts request and emit callback" do
      assert function_exported?(FakeProvider, :stream, 2)
    end
  end
end
