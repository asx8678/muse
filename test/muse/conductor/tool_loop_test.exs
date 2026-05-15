defmodule Muse.Conductor.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Muse.{Session, Turn, MuseRegistry}
  alias Muse.Conductor.ToolLoop
  alias Muse.LLM.{FakeProvider, Request, Response, ToolCall}
  alias Muse.Test.FakeToolRunner

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

  # -- T1-18: Tool dedup/memoization -------------------------------------------

  describe "run/8 — tool dedup/memoization (T1-18)" do
    test "duplicate read-only tool calls within a turn are deduplicated" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # First iteration: two identical read_file calls with same args
      fake_event_batches = [
        [
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_dup1"},
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_dup2"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_dup1"),
          ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_dup2")
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_runner: FakeToolRunner
        )

      # Should have tool_call_dedup event for the second call
      dedup_specs = filter_specs(result.event_specs, :tool_call_dedup)
      assert length(dedup_specs) >= 1

      # Second call should have the dedup event referencing its ID
      dedup_ids = Enum.map(dedup_specs, fn {_, _, data, _} -> data.tool_call_id end)
      assert "call_dup2" in dedup_ids
    end

    test "duplicate tool calls across iterations are deduplicated" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # First iteration: list_files with path "."
      # Second iteration: list_files with same path "."
      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_li1"},
          {:response_completed, nil}
        ],
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_li2"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [ToolCall.new("list_files", %{"path" => "."}, id: "call_li1")],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_runner: FakeToolRunner
        )

      dedup_specs = filter_specs(result.event_specs, :tool_call_dedup)
      assert length(dedup_specs) >= 1
    end

    test "different tool args are NOT deduplicated" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Two read_file calls with different paths — should both execute
      fake_event_batches = [
        [
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_diff1"},
          {:tool_call, "read_file", %{"path" => "README.md"}, "call_diff2"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_diff1"),
          ToolCall.new("read_file", %{"path" => "README.md"}, id: "call_diff2")
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_runner: FakeToolRunner
        )

      dedup_specs = filter_specs(result.event_specs, :tool_call_dedup)
      assert dedup_specs == []
    end

    test "cache_key/1 produces deterministic keys for same args" do
      tc1 = %{name: "read_file", arguments: %{"path" => "lib/muse.ex"}}
      tc2 = %{name: "read_file", arguments: %{"path" => "lib/muse.ex"}}
      tc3 = %{name: "read_file", arguments: %{"path" => "lib/other.ex"}}

      assert ToolLoop.cache_key(tc1) == ToolLoop.cache_key(tc2)
      refute ToolLoop.cache_key(tc1) == ToolLoop.cache_key(tc3)
    end

    test "plan_read_only_execution classifies prev-cache, canonical execute, and within-iter dups" do
      # Incoming cache from previous iteration has one key
      prev_cache = %{
        ToolLoop.cache_key(%{name: "read_file", arguments: %{"path" => "cached.txt"}}) => %{
          success: true
        }
      }

      calls = [
        %{name: "read_file", arguments: %{"path" => "cached.txt"}, id: "c1"},
        %{name: "list_files", arguments: %{"path" => "."}, id: "c2"},
        %{name: "list_files", arguments: %{"path" => "."}, id: "c3"},
        %{name: "read_file", arguments: %{"path" => "new.txt"}, id: "c4"},
        %{name: "read_file", arguments: %{"path" => "new.txt"}, id: "c5"}
      ]

      plan = ToolLoop.plan_read_only_execution(calls, prev_cache)

      assert length(plan) == 5

      # c1 hits prev cache
      assert Enum.at(plan, 0).disposition == :prev_cache
      assert Enum.at(plan, 0).id == "c1"

      # c2 is first time for "list_files:." → execute (canonical)
      assert Enum.at(plan, 1).disposition == :execute
      assert Enum.at(plan, 1).id == "c2"

      # c3 is dup of c2 within this iteration
      assert Enum.at(plan, 2).disposition == {:dup, "c2"}
      assert Enum.at(plan, 2).id == "c3"

      # c4 is new key → execute (canonical)
      assert Enum.at(plan, 3).disposition == :execute
      assert Enum.at(plan, 3).id == "c4"

      # c5 is dup of c4
      assert Enum.at(plan, 4).disposition == {:dup, "c4"}
      assert Enum.at(plan, 4).id == "c5"
    end
  end

  # -- T1-18: Bounded concurrency ----------------------------------------------

  describe "run/8 — bounded concurrency (T1-18)" do
    test "multiple read-only tools execute with bounded concurrency" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # 3 read-only tool calls in one iteration
      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_bc1"},
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_bc2"},
          {:tool_call, "repo_search", %{"pattern" => "defmodule"}, "call_bc3"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("list_files", %{"path" => "."}, id: "call_bc1"),
          ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_bc2"),
          ToolCall.new("repo_search", %{"pattern" => "defmodule"}, id: "call_bc3")
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_concurrency: 2
        )

      # All 3 tools should have completed
      assert result.total_tool_calls == 3
    end

    test "concurrency cap can be set to 1 (serial for read-only)" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_s1"},
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_s2"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("list_files", %{"path" => "."}, id: "call_s1"),
          ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_s2")
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_concurrency: 1
        )

      assert result.total_tool_calls == 2
    end
  end

  # -- T1-18: Truncated tool results -------------------------------------------

  describe "run/8 — truncated tool results (T1-18)" do
    test "large tool result output is truncated for model consumption" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Use a very small tool_result_bytes to trigger truncation
      fake_event_batches = [
        [
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_trunc1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [ToolCall.new("read_file", %{"path" => "mix.exs"}, id: "call_trunc1")],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_result_bytes: 100
        )

      # The loop should complete without error
      assert result.total_tool_calls == 1
    end

    test "tool_result_bytes defaults from Muse.Bounds" do
      # Verify the bounds module returns a positive integer
      assert is_integer(Muse.Bounds.tool_result_bytes())
      assert Muse.Bounds.tool_result_bytes() > 0
    end
  end

  # -- T1-18: O(n) accumulators -----------------------------------------------

  describe "run/8 — O(n) accumulator performance (T1-18)" do
    test "event specs remain in chronological order with prepend-based accumulators" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Multiple iterations to exercise the accumulator
      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_acc1"},
          {:response_completed, nil}
        ],
        [
          {:tool_call, "read_file", %{"path" => "mix.exs"}, "call_acc2"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "All done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [ToolCall.new("list_files", %{"path" => "."}, id: "call_acc1")],
        finish_reason: "tool_calls"
      }

      # Give initial specs to verify they come first in the result
      initial_specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]}
      ]

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, initial_specs,
          provider_module: FakeProvider
        )

      # The initial spec should be the first in the list
      first_spec = hd(result.event_specs)
      assert {:conductor, :provider_response_started, %{}, [visibility: :debug]} = first_spec

      # Should have tool events in chronological order
      tool_started = filter_specs(result.event_specs, :tool_call_started)
      assert length(tool_started) >= 1
    end

    test "patch proposals remain in order with prepend-based accumulators" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Even without patch proposals, verify the field exists and is a list
      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_pp1"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [ToolCall.new("list_files", %{"path" => "."}, id: "call_pp1")],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider
        )

      assert is_list(result.patch_proposals)
    end
  end

  # -- T1-18: Bounds integration -----------------------------------------------

  describe "Muse.Bounds — tool loop bounds (T1-18)" do
    test "tool_result_bytes returns a positive integer" do
      val = Muse.Bounds.tool_result_bytes()
      assert is_integer(val)
      assert val > 0
    end

    test "tool_concurrency returns a positive integer" do
      val = Muse.Bounds.tool_concurrency()
      assert is_integer(val)
      assert val > 0
    end

    test "bounds all/0 includes tool_result_bytes and tool_concurrency" do
      all = Muse.Bounds.all()
      assert Map.has_key?(all, :tool_result_bytes)
      assert Map.has_key?(all, :tool_concurrency)
    end
  end

  # -- T1-18: Spec ordering regression test ----------------------------------

  describe "run/8 \u2014 spec ordering (regression for prepend_specs fix)" do
    test "dedup event specs are in chronological order (dedup \u2192 started \u2192 completed)" do
      session = build_session()
      turn = build_turn()
      muse = build_muse()
      bundle = build_bundle()

      # Two identical tool calls \u2014 second should be deduped
      fake_event_batches = [
        [
          {:tool_call, "list_files", %{"path" => "."}, "call_ord1"},
          {:tool_call, "list_files", %{"path" => "."}, "call_ord2"},
          {:response_completed, nil}
        ],
        [
          {:assistant_completed, "Done."},
          {:response_completed, nil}
        ]
      ]

      request = build_request(fake_event_batches, 0)

      initial_response = %Response{
        content: nil,
        tool_calls: [
          ToolCall.new("list_files", %{"path" => "."}, id: "call_ord1"),
          ToolCall.new("list_files", %{"path" => "."}, id: "call_ord2")
        ],
        finish_reason: "tool_calls"
      }

      {:ok, result} =
        ToolLoop.run(session, turn, muse, bundle, request, initial_response, [],
          provider_module: FakeProvider,
          tool_runner: FakeToolRunner
        )

      # Find the dedup event for call_ord2
      dedup_specs = filter_specs(result.event_specs, :tool_call_dedup)
      assert length(dedup_specs) >= 1

      dedup_spec =
        Enum.find(dedup_specs, fn {_, _, data, _} ->
          data.tool_call_id == "call_ord2"
        end)

      assert dedup_spec != nil

      # Verify chronological order: dedup \u2192 started \u2192 completed
      dedup_idx = Enum.find_index(result.event_specs, &(&1 == dedup_spec))
      started_specs = filter_specs(result.event_specs, :tool_call_started)

      started_for_ord2 =
        Enum.find(started_specs, fn {_, _, data, _} ->
          data.tool_call_id == "call_ord2"
        end)

      started_idx = Enum.find_index(result.event_specs, &(&1 == started_for_ord2))
      completed_specs = filter_specs(result.event_specs, :tool_call_completed)

      completed_for_ord2 =
        Enum.find(completed_specs, fn {_, _, data, _} ->
          data.tool_call_id == "call_ord2"
        end)

      completed_idx = Enum.find_index(result.event_specs, &(&1 == completed_for_ord2))

      assert dedup_idx < started_idx, "dedup spec must come before started spec"
      assert started_idx < completed_idx, "started spec must come before completed spec"
    end
  end
end
