defmodule Muse.Conductor.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Muse.{Session, Turn, MuseRegistry}
  alias Muse.Conductor.ToolLoop
  alias Muse.LLM.{FakeProvider, Request, Response, ToolCall}

  defmodule ResponsesContinuationProvider do
    @moduledoc false

    import ExUnit.Assertions

    alias Muse.LLM.{Event, Response, ToolCall}

    def stream(request, emit) do
      case next_call() do
        1 ->
          tool_call = ToolCall.new("list_files", %{"path" => "."}, id: "call_resp_1")
          emit_tool_call(emit, tool_call)

          {:ok,
           Response.new(
             content: "I need to inspect files.",
             tool_calls: [tool_call],
             provider_state: %{previous_response_id: "resp_tool_1"},
             finish_reason: "tool_calls"
           )}

        2 ->
          assert request.previous_response_id == "resp_tool_1"

          assert Enum.any?(
                   request.messages,
                   &(&1.role == :tool and &1.tool_call_id == "call_resp_1")
                 )

          emit_final_text(emit, "Finished with Responses continuation.")
          {:ok, Response.new(content: "Finished with Responses continuation.")}
      end
    end

    defp next_call do
      key = {__MODULE__, :calls}
      count = Process.get(key, 0) + 1
      Process.put(key, count)
      count
    end

    defp emit_tool_call(emit, tool_call) do
      emit.(Event.tool_call_started(tool_call))
      emit.(Event.tool_call_completed(tool_call))
      emit.(Event.response_completed())
    end

    defp emit_final_text(emit, text) do
      emit.(Event.assistant_delta(text))
      emit.(Event.assistant_completed(text))
      emit.(Event.response_completed())
    end
  end

  defmodule AdvancingResponsesContinuationProvider do
    @moduledoc false

    import ExUnit.Assertions

    alias Muse.LLM.{Event, Response, ToolCall}

    def stream(request, emit) do
      case next_call() do
        1 ->
          tool_call = ToolCall.new("list_files", %{"path" => "."}, id: "call_adv_1")
          emit_tool_call(emit, tool_call)

          {:ok,
           Response.new(
             content: "First tool needed.",
             tool_calls: [tool_call],
             provider_state: %{"previous_response_id" => "resp_tool_1"},
             finish_reason: "tool_calls"
           )}

        2 ->
          assert request.previous_response_id == "resp_tool_1"

          tool_call = ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_adv_2")
          emit_tool_call(emit, tool_call)

          {:ok,
           Response.new(
             content: "Second tool needed.",
             tool_calls: [tool_call],
             provider_state: %{previous_response_id: "resp_tool_2"},
             finish_reason: "tool_calls"
           )}

        3 ->
          assert request.previous_response_id == "resp_tool_2"
          assert Enum.count(request.messages, &(&1.role == :tool)) == 2

          emit_final_text(emit, "Finished after advanced provider state.")
          {:ok, Response.new(content: "Finished after advanced provider state.")}
      end
    end

    defp next_call do
      key = {__MODULE__, :calls}
      count = Process.get(key, 0) + 1
      Process.put(key, count)
      count
    end

    defp emit_tool_call(emit, tool_call) do
      emit.(Event.tool_call_started(tool_call))
      emit.(Event.tool_call_completed(tool_call))
      emit.(Event.response_completed())
    end

    defp emit_final_text(emit, text) do
      emit.(Event.assistant_delta(text))
      emit.(Event.assistant_completed(text))
      emit.(Event.response_completed())
    end
  end

  defmodule ChatCompletionsProviderStateProvider do
    @moduledoc false

    import ExUnit.Assertions

    alias Muse.LLM.{Event, Response, ToolCall}

    def stream(request, emit) do
      case next_call() do
        1 ->
          tool_call = ToolCall.new("list_files", %{"path" => "."}, id: "call_chat_1")
          emit.(Event.tool_call_started(tool_call))
          emit.(Event.tool_call_completed(tool_call))
          emit.(Event.response_completed())

          {:ok,
           Response.new(
             content: "Tool needed.",
             tool_calls: [tool_call],
             provider_state: %{previous_response_id: "resp_chat_should_not_apply"},
             finish_reason: "tool_calls"
           )}

        2 ->
          assert request.wire_api == :chat_completions
          assert request.previous_response_id == nil

          emit.(Event.assistant_completed("Chat completions final."))
          emit.(Event.response_completed())
          {:ok, Response.new(content: "Chat completions final.")}
      end
    end

    defp next_call do
      key = {__MODULE__, :calls}
      count = Process.get(key, 0) + 1
      Process.put(key, count)
      count
    end
  end

  defmodule OverridePreviousResponseIdProvider do
    @moduledoc false

    import ExUnit.Assertions

    alias Muse.LLM.{Event, Response, ToolCall}

    def stream(request, emit) do
      case next_call() do
        1 ->
          tool_call = ToolCall.new("list_files", %{"path" => "."}, id: "call_override_1")
          emit.(Event.tool_call_started(tool_call))
          emit.(Event.tool_call_completed(tool_call))
          emit.(Event.response_completed())

          {:ok,
           Response.new(
             content: "Tool needed.",
             tool_calls: [tool_call],
             provider_state: %{previous_response_id: "resp_tool_1"},
             finish_reason: "tool_calls"
           )}

        2 ->
          assert request.previous_response_id == "resp_safe_override"

          emit.(Event.assistant_completed("Override respected."))
          emit.(Event.response_completed())
          {:ok, Response.new(content: "Override respected.")}
      end
    end

    defp next_call do
      key = {__MODULE__, :calls}
      count = Process.get(key, 0) + 1
      Process.put(key, count)
      count
    end
  end

  defmodule FailingAfterToolProvider do
    @moduledoc false

    import ExUnit.Assertions

    alias Muse.LLM.Event

    def stream(request, emit) do
      assert Enum.any?(
               request.messages,
               &(&1.role == :tool and &1.tool_call_id == "call_write_1")
             )

      emit.(Event.provider_error(:websocket_closed_mid_turn))
      {:error, :websocket_closed_mid_turn}
    end
  end

  defmodule CountingWriteToolRunner do
    @moduledoc false

    alias Muse.Tool.Result

    def run(tool_name, args, _context) do
      send(self(), {:counting_write_tool_runner, tool_name, args})
      Result.ok(tool_name, %{side_effect_recorded?: true})
    end
  end

  # -- Helpers ------------------------------------------------------------------

  defp build_session(opts \\ []) do
    defaults = [id: "toolloop-session", workspace: "/tmp/test_workspace", status: :idle]
    Session.new(Keyword.merge(defaults, opts))
  end

  defp build_turn(opts \\ []) do
    defaults = [
      session_id: "toolloop-session",
      id: "turn_toolloop1",
      source: :cli,
      user_text: "check the files"
    ]

    Turn.new(Keyword.merge(defaults, opts))
  end

  defp build_muse do
    MuseRegistry.get(:planning)
  end

  defp build_request(fake_event_batches, iteration) do
    options = %{fake_event_batches: fake_event_batches, fake_iteration: iteration}

    %Request{
      provider: :fake,
      model: "fake-planning-model",
      messages: [Muse.LLM.Message.user("check the files")],
      tools: [],
      options: options
    }
  end

  defp build_responses_request(opts \\ []) do
    %Request{
      provider: :fake,
      wire_api: Keyword.get(opts, :wire_api, :responses),
      model: "fake-planning-model",
      messages: [Muse.LLM.Message.user("check the files")],
      tools: [],
      previous_response_id: Keyword.get(opts, :previous_response_id),
      options: %{}
    }
  end

  defp first_provider_response(provider_module, request) do
    assert {:ok, response} = provider_module.stream(request, fn _event -> :ok end)
    response
  end

  defp build_bundle do
    %{id: "bundle-1", muse_id: :planning, session_id: "toolloop-session"}
  end

  defp filter_specs(specs, type) do
    Enum.filter(specs, fn {_source, t, _data, _opts} -> t == type end)
  end

  # -- Basic tool loop ----------------------------------------------------------

  describe "run/8 — basic tool loop" do
    test "executes a single tool call and finalizes with assistant text" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # First iteration returns a tool call, second iteration returns text
      fake_event_batches = [
        [
          {:assistant_delta, "Let me check the files."},
          {:tool_call, "list_files", %{"path" => "."}, "call_1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Found 5 files."},
          {:assistant_completed, "Found 5 files."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      # Simulate the initial response from the first provider call
      initial_response = %Response{
        content: "Let me check the files.",
        tool_calls: [ToolCall.new("list_files", %{"path" => "."}, id: "call_1")],
        finish_reason: "tool_calls"
      }

      initial_specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]},
        {:conductor, :tool_call_requested, %{tool_name: "list_files", tool_call_id: "call_1"},
         [visibility: :debug]},
        {:conductor, :tool_call_completed, %{tool_name: "list_files", tool_call_id: "call_1"},
         [visibility: :debug]},
        {:conductor, :provider_response_completed, %{}, [visibility: :debug]}
      ]

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      assert result.assistant_text =~ "Found 5 files"
      assert result.iterations == 1
      assert result.total_tool_calls == 1
      assert result.limit_reached? == false

      # Should have tool lifecycle events
      started = filter_specs(result.event_specs, :tool_call_started)
      completed = filter_specs(result.event_specs, :tool_call_completed)
      assert length(started) >= 1
      assert length(completed) >= 1
    end

    test "executes read_file tool call" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_rf1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "The mix.exs shows..."},
          {:assistant_completed, "The mix.exs shows..."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_rf1")],
        finish_reason: "tool_calls"
      }

      initial_specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]},
        {:conductor, :provider_response_completed, %{}, [visibility: :debug]}
      ]

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      assert result.total_tool_calls == 1
      assert result.assistant_text =~ "mix.exs"
    end

    test "executes repo_search tool call" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "repo_search", %{"pattern" => "defmodule"}, "call_rs1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Found many modules."},
          {:assistant_completed, "Found many modules."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [ToolCall.new("repo_search", %{"pattern" => "defmodule"}, id: "call_rs1")],
        finish_reason: "tool_calls"
      }

      initial_specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]},
        {:conductor, :provider_response_completed, %{}, [visibility: :debug]}
      ]

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      assert result.total_tool_calls == 1
    end
  end

  # -- Responses API continuation ---------------------------------------------

  describe "run/8 — Responses API previous_response_id continuation" do
    test "sets previous_response_id from provider_state on the next tool-loop request" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()
      request = build_responses_request()

      initial_response = first_provider_response(ResponsesContinuationProvider, request)

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: ResponsesContinuationProvider
        )

      assert result.assistant_text == "Finished with Responses continuation."
      assert result.iterations == 1
      assert result.total_tool_calls == 1
      assert result.provider_state == %{previous_response_id: "resp_tool_1"}

      event_spec_text = inspect(result.event_specs)
      refute event_spec_text =~ "provider_state"
      refute event_spec_text =~ "previous_response_id"
      refute event_spec_text =~ "resp_tool_1"
    end

    test "advances provider_state when a later tool-call response returns a new previous_response_id" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()
      request = build_responses_request()

      initial_response = first_provider_response(AdvancingResponsesContinuationProvider, request)

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: AdvancingResponsesContinuationProvider
        )

      assert result.assistant_text == "Finished after advanced provider state."
      assert result.iterations == 2
      assert result.total_tool_calls == 2
      assert result.provider_state == %{previous_response_id: "resp_tool_2"}

      event_spec_text = inspect(result.event_specs)
      refute event_spec_text =~ "provider_state"
      refute event_spec_text =~ "previous_response_id"
      refute event_spec_text =~ "resp_tool_1"
      refute event_spec_text =~ "resp_tool_2"
    end

    test "does not hydrate Chat Completions requests from Responses provider_state" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()
      request = build_responses_request(wire_api: :chat_completions)

      initial_response = first_provider_response(ChatCompletionsProviderStateProvider, request)

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: ChatCompletionsProviderStateProvider
        )

      assert result.assistant_text == "Chat completions final."
      assert result.iterations == 1
    end

    test "respects explicit safe request_options previous_response_id override" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()
      request = build_responses_request()

      initial_response = first_provider_response(OverridePreviousResponseIdProvider, request)

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: OverridePreviousResponseIdProvider,
          request_options: [previous_response_id: "resp_safe_override"]
        )

      assert result.assistant_text == "Override respected."
      assert result.iterations == 1
      assert result.provider_state == %{previous_response_id: "resp_tool_1"}
    end

    test "provider failure after a write-like tool side effect returns a safe error without rerunning the tool" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()
      request = build_responses_request()

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("write_file", %{"path" => "side-effect.txt", "content" => "hello"},
            id: "call_write_1"
          )
        ],
        provider_state: %{previous_response_id: "resp_write_1"},
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FailingAfterToolProvider,
          tool_runner: CountingWriteToolRunner
        )

      assert result.assistant_text == "Error during provider call in tool loop."
      assert result.total_tool_calls == 1
      assert result.provider_state == %{previous_response_id: "resp_write_1"}

      assert_received {:counting_write_tool_runner, "write_file",
                       %{"path" => "side-effect.txt", "content" => "hello"}}

      refute_received {:counting_write_tool_runner, "write_file", _args}
    end
  end

  # -- Blocked tools ------------------------------------------------------------

  describe "run/8 — blocked/unsafe tools" do
    test "blocked tool produces error result fed back to model" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "write_file", %{"path" => "test.txt", "content" => "hello"}, "call_wf1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "I cannot write files."},
          {:assistant_completed, "I cannot write files."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("write_file", %{"path" => "test.txt", "content" => "hello"},
            id: "call_wf1"
          )
        ],
        finish_reason: "tool_calls"
      }

      initial_specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]},
        {:conductor, :provider_response_completed, %{}, [visibility: :debug]}
      ]

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      # The blocked tool should produce a tool_call_blocked event spec
      blocked_specs = filter_specs(result.event_specs, :tool_call_blocked)
      assert length(blocked_specs) >= 1

      {_s, _t, data, _opts} = hd(blocked_specs)
      assert data.tool_name == "write_file"

      # And the loop should continue to the next iteration
      assert result.assistant_text =~ "I cannot write files"
    end
  end

  # -- Malformed tool calls -----------------------------------------------------

  describe "run/8 — malformed tool calls" do
    test "tool call with nil name produces safe error result" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          # Tool call with nil name — malformed
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Moving on."},
          {:assistant_completed, "Moving on."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      # Create a tool call with nil name
      initial_response = %Response{
        content: nil,
        tool_calls: [%ToolCall{name: nil, id: "call_mal1", arguments: %{}, raw: nil}],
        finish_reason: "tool_calls"
      }

      initial_specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]},
        {:conductor, :provider_response_completed, %{}, [visibility: :debug]}
      ]

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      # Should not crash and should produce tool lifecycle events
      assert is_binary(result.assistant_text)
      # The tool name "unknown" should be used
      completed = filter_specs(result.event_specs, :tool_call_completed)
      assert length(completed) >= 1
    end
  end

  # -- Max caps -----------------------------------------------------------------

  describe "run/8 — safety caps" do
    test "max_iterations cap triggers limit event and final fallback" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Script that always returns tool calls — will hit iteration cap
      always_tool_call = [
        {:tool_call, "list_files", %{"path" => "."},
         "call_loop_#{:erlang.unique_integer([:positive])}"},
        {:response_completed, nil}
      ]

      fake_event_batches = [
        always_tool_call,
        always_tool_call,
        always_tool_call,
        always_tool_call,
        always_tool_call
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: "checking...",
        tool_calls: [ToolCall.new("list_files", %{"path" => "."}, id: "call_cap_1")],
        finish_reason: "tool_calls"
      }

      initial_specs = []

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider,
          limits: %{max_iterations: 2, max_tool_calls_per_iteration: 8, max_total_tool_calls: 20}
        )

      # Should have hit the limit
      limit_specs = filter_specs(result.event_specs, :tool_loop_limit_reached)
      assert length(limit_specs) >= 1

      assert result.limit_reached? == true
      assert result.iterations >= 2
    end

    test "max_total_tool_calls cap triggers limit event" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Script that returns 3 tool calls per iteration
      multi_tool = [
        {:tool_call, "list_files", %{"path" => "."}, "call_a"},
        {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_b"},
        {:tool_call, "repo_search", %{"pattern" => "def"}, "call_c"},
        {:response_completed, nil}
      ]

      fake_event_batches = [multi_tool, multi_tool, multi_tool, multi_tool, multi_tool]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: "checking...",
        tool_calls: [
          ToolCall.new("list_files", %{"path" => "."}, id: "call_a0"),
          ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_b0"),
          ToolCall.new("repo_search", %{"pattern" => "def"}, id: "call_c0")
        ],
        finish_reason: "tool_calls"
      }

      initial_specs = []

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider,
          limits: %{max_iterations: 10, max_tool_calls_per_iteration: 8, max_total_tool_calls: 4}
        )

      assert result.limit_reached? == true
      assert result.total_tool_calls >= 4

      # Should have deferred tool calls
      deferred = filter_specs(result.event_specs, :tool_call_deferred)
      assert length(deferred) >= 1
    end
  end

  # -- Event spec correctness ---------------------------------------------------

  describe "run/8 — event spec correctness" do
    test "tool lifecycle events use :conductor source and :debug visibility" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_ev1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Done."},
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: "",
        tool_calls: [ToolCall.new("list_files", %{"path" => "."}, id: "call_ev1")],
        finish_reason: "tool_calls"
      }

      initial_specs = []

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      for {source, _type, _data, opts} <- filter_specs(result.event_specs, :tool_call_started) do
        assert source == :conductor
        assert Keyword.get(opts, :visibility) == :debug
      end

      for {source, _type, _data, opts} <- filter_specs(result.event_specs, :tool_call_completed) do
        assert source == :conductor
        assert Keyword.get(opts, :visibility) == :debug
      end
    end

    test "tool_call_completed event contains safe_summary, not raw output" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_safe1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: "",
        tool_calls: [ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_safe1")],
        finish_reason: "tool_calls"
      }

      initial_specs = []

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      completed = filter_specs(result.event_specs, :tool_call_completed)
      assert length(completed) >= 1

      {_source, _type, data, _opts} = hd(completed)
      # Should have output_summary, not raw output
      assert Map.has_key?(data, :output_summary)
      refute Map.has_key?(data, :output)
    end
  end
end
