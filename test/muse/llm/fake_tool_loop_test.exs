defmodule Muse.LLM.FakeToolLoopTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{FakeProvider, Request, Message}

  # -- Helpers ------------------------------------------------------------------

  defp build_request(opts \\ []) do
    options = Keyword.get(opts, :options, %{})
    messages = Keyword.get(opts, :messages, [Message.user("test")])

    %Request{
      provider: :fake,
      model: "fake-planning-model",
      messages: messages,
      tools: [],
      options: options
    }
  end

  defp collect_events(request) do
    emit = fn event ->
      send(self(), {:fake_event, event})
      :ok
    end

    result = FakeProvider.stream(request, emit)

    received =
      receive_all_events()

    {result, received}
  end

  defp receive_all_events(acc \\ []) do
    receive do
      {:fake_event, event} -> receive_all_events([event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  # -- fake_event_batches -------------------------------------------------------

  describe "fake_event_batches" do
    test "uses iteration 0 batch on first call" do
      batches = [
        [
          {:assistant_delta, "First response."},
          {:assistant_completed, "First response."},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Second response."},
          {:assistant_completed, "Second response."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(options: %{fake_event_batches: batches, fake_iteration: 0})

      {{:ok, response}, events} = collect_events(request)

      assert response.content == "First response."

      delta_events = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(delta_events) == 1
      assert hd(delta_events).text == "First response."
    end

    test "uses iteration 1 batch on second call" do
      batches = [
        [
          {:assistant_delta, "First."},
          {:assistant_completed, "First."},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Second."},
          {:assistant_completed, "Second."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(options: %{fake_event_batches: batches, fake_iteration: 1})

      {{:ok, response}, events} = collect_events(request)

      assert response.content == "Second."

      delta_events = Enum.filter(events, &(&1.type == :assistant_delta))
      assert hd(delta_events).text == "Second."
    end

    test "falls back to default when iteration exceeds batch count" do
      batches = [
        [
          {:assistant_delta, "Only one."},
          {:assistant_completed, "Only one."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(options: %{fake_event_batches: batches, fake_iteration: 5})

      {{:ok, response}, _events} = collect_events(request)

      # Should produce default text since iteration 5 is out of range
      assert response.content =~ "Placeholder response"
    end
  end

  # -- Default text with tool messages ------------------------------------------

  describe "default text for requests with tool messages" do
    test "produces tool-inspection summary when tool-role messages are present" do
      messages = [
        Message.user("check files"),
        Message.assistant("Let me check."),
        Message.tool(Jason.encode!(%{result: "5 files"}), "call_1")
      ]

      request = build_request(messages: messages)

      {{:ok, response}, _events} = collect_events(request)

      assert response.content =~ "Placeholder response after tool inspection"
      assert response.content =~ "1 tool result"
    end

    test "produces standard default when no tool messages" do
      request = build_request()

      {{:ok, response}, _events} = collect_events(request)

      assert response.content =~ "Placeholder response: received"
      refute response.content =~ "tool inspection"
    end

    test "counts multiple tool result messages" do
      messages = [
        Message.user("check files"),
        Message.assistant("Checking..."),
        Message.tool("result1", "call_1"),
        Message.tool("result2", "call_2"),
        Message.tool("result3", "call_3")
      ]

      request = build_request(messages: messages)

      {{:ok, response}, _events} = collect_events(request)

      assert response.content =~ "3 tool result"
    end
  end

  # -- fake_event_batches with tool calls ---------------------------------------

  describe "fake_event_batches with tool calls" do
    test "iteration 0 can return tool calls, iteration 1 returns text" do
      batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_batch_1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Based on listing..."},
          {:assistant_completed, "Based on listing..."},
          {:response_completed, nil}
        ]
      ]

      # First call (iteration 0) — should return tool calls
      request0 = build_request(options: %{fake_event_batches: batches, fake_iteration: 0})

      {{:ok, response0}, _events0} = collect_events(request0)
      assert response0.tool_calls != []
      assert hd(response0.tool_calls).name == "list_files"

      # Second call (iteration 1) — should return text
      request1 = build_request(options: %{fake_event_batches: batches, fake_iteration: 1})

      {{:ok, response1}, _events1} = collect_events(request1)
      assert response1.content == "Based on listing..."
      assert response1.tool_calls == []
    end
  end
end
