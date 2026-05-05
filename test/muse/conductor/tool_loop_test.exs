defmodule Muse.Conductor.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Muse.{Session, Turn, MuseRegistry}
  alias Muse.Conductor.ToolLoop
  alias Muse.LLM.{FakeProvider, Request, Response, ToolCall}

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

    test "approved plan in session does not unlock blocked write tools" do
      plan = %{
        id: "approved_plan_1",
        session_id: "toolloop-session",
        version: 1,
        plan_hash: "approved_hash_1"
      }

      session =
        build_session(status: :executing, active_plan_id: "approved_plan_1")
        |> Map.put(:plans, %{"approved_plan_1" => plan})
        |> Map.put(:approvals, [
          %{
            scope: :plan,
            status: :approved,
            session_id: "toolloop-session",
            plan_id: "approved_plan_1",
            plan_version: 1,
            plan_hash: "approved_hash_1"
          }
        ])

      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "write_file", %{"path" => "test.txt", "content" => "hello"},
           "call_wf_approved_plan"},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "I still cannot write files."},
          {:assistant_completed, "I still cannot write files."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("write_file", %{"path" => "test.txt", "content" => "hello"},
            id: "call_wf_approved_plan"
          )
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider
        )

      blocked_specs = filter_specs(result.event_specs, :tool_call_blocked)
      assert length(blocked_specs) >= 1

      {_source, _type, data, _opts} = hd(blocked_specs)
      assert data.tool_name == "write_file"
      assert result.assistant_text =~ "I still cannot write files"
    end

    test "blocked and failed tool event specs redact provider-supplied secrets" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()
      fake_secret = "sk-test-tool-loop-secret"

      fake_event_batches = [
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("write_file", %{"path" => "x.ex", "content" => "API_KEY=#{fake_secret}"},
            id: "call_secret_block"
          ),
          ToolCall.new("totally_unknown_tool", %{"api_key" => fake_secret},
            id: "call_secret_fail"
          )
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider
        )

      assert filter_specs(result.event_specs, :tool_call_blocked) != []
      assert filter_specs(result.event_specs, :tool_call_failed) != []

      for {_source, _type, data, _opts} <- result.event_specs do
        refute inspect(data) =~ fake_secret
      end
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
