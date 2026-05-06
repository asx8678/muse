defmodule Muse.ConductorTest do
  use ExUnit.Case, async: true

  alias Muse.{Conductor, Session, Turn}
  alias Muse.LLM.{ProviderConfig, FakeProvider}

  # -- Helpers ------------------------------------------------------------------

  defp build_session(opts \\ []) do
    defaults = [id: "test-session", workspace: "/tmp/test_workspace", status: :idle]
    Session.new(Keyword.merge(defaults, opts))
  end

  defp build_turn(opts \\ []) do
    defaults = [
      session_id: "test-session",
      id: "turn_test1",
      source: :cli,
      user_text: "add a /version command"
    ]

    Turn.new(Keyword.merge(defaults, opts))
  end

  defp find_event_spec(specs, type) do
    Enum.find(specs, fn {_source, t, _data, _opts} -> t == type end)
  end

  defp filter_event_specs(specs, type) do
    Enum.filter(specs, fn {_source, t, _data, _opts} -> t == type end)
  end

  defp build_sse_chunks_for_conductor(text, id, model) do
    role_body = %{
      "id" => id,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant"}}]
    }

    role_chunk = "data: #{Jason.encode!(role_body)}\n\n"

    content_body = %{
      "id" => id,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => %{"content" => text}}]
    }

    content_chunk = "data: #{Jason.encode!(content_body)}\n\n"

    finish_body = %{
      "id" => id,
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 5, "total_tokens" => 8}
    }

    finish_chunk = "data: #{Jason.encode!(finish_body)}\n\n"

    done_chunk = "data: [DONE]\n\n"

    [role_chunk, content_chunk, finish_chunk, done_chunk]
  end

  defp with_telemetry_handler(event_name, handler_id, test_pid, tag) do
    :telemetry.attach(
      handler_id,
      event_name,
      fn _name, measures, metadata, config ->
        send(config[:test_pid], {:telemetry, config[:tag], measures, metadata})
      end,
      %{test_pid: test_pid, tag: tag}
    )
  end

  # -- select_muse/2 ------------------------------------------------------------

  describe "select_muse/2" do
    test "selects Planning Muse for idle session" do
      muse = Conductor.select_muse(build_session(status: :idle), [])
      assert muse.id == :planning
    end

    test "selects Planning Muse for running session" do
      muse = Conductor.select_muse(build_session(status: :running), [])
      assert muse.id == :planning
    end

    test "selects Planning Muse for planning session" do
      muse = Conductor.select_muse(build_session(status: :planning), [])
      assert muse.id == :planning
    end

    test "selects Planning Muse for awaiting_plan_approval session" do
      muse = Conductor.select_muse(build_session(status: :awaiting_plan_approval), [])
      assert muse.id == :planning
    end

    test "does not select Coding Muse before plan approval" do
      muse = Conductor.select_muse(build_session(status: :idle), [])
      assert muse.id != :coding
    end
  end

  # -- run/3 basic --------------------------------------------------------------

  describe "run/3 — basic flow" do
    test "selects Planning Muse for code-change request" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert result.selected_muse.id == :planning
    end

    test "builds prompt bundle with muse_id :planning" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      bundle = result.prompt_bundle
      assert bundle.muse_id == :planning
      assert bundle.session_id == "test-session"
      assert bundle.turn_id == "turn_test1"
    end

    test "prompt bundle includes provider-ready read-only tools" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      tool_names = Enum.map(result.prompt_bundle.tools, & &1["function"]["name"])

      assert "list_files" in tool_names
      assert "read_file" in tool_names
      assert "repo_search" in tool_names
    end

    test "LLM request uses fake provider and model" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert result.request.provider == :fake
      assert result.request.model == "fake-planning-model"
    end

    test "fake provider response is returned" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert %Muse.LLM.Response{} = result.response
      assert result.response.content =~ "Placeholder response"
    end

    test "returns assistant text from provider response" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert result.assistant_text =~ "Placeholder response"
    end

    test "turn is marked as completed and streamed" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert result.turn.status == :completed
      assert result.turn.streamed? == true
      assert result.turn.selected_muse == "planning"
    end

    test "session is transitioned back to idle" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert result.session.status == :idle
    end
  end

  # -- run/3 event specs --------------------------------------------------------

  describe "run/3 — event specs" do
    test "returns event specs for the full turn lifecycle" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert is_list(result.event_specs)
      assert length(result.event_specs) > 0

      types = Enum.map(result.event_specs, fn {_source, type, _data, _opts} -> type end)

      # Conductor overhead events
      assert :muse_selected in types
      assert :session_status_changed in types
      assert :prompt_prepared in types
      assert :provider_request_started in types

      # Provider response events
      assert :provider_response_started in types
      assert :provider_response_completed in types

      # User-visible assistant events
      assert :assistant_delta in types
      assert :assistant_message in types

      # turn_completed is emitted by SessionServer, not Conductor
      refute :turn_completed in types
    end

    test "event specs have correct visibility levels" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      # muse_selected is internal
      {_s, _t, _d, opts} = find_event_spec(result.event_specs, :muse_selected)
      assert Keyword.get(opts, :visibility) == :internal

      # prompt_prepared is debug
      {_s, _t, _d, opts} = find_event_spec(result.event_specs, :prompt_prepared)
      assert Keyword.get(opts, :visibility) == :debug

      # provider_request_started is debug
      {_s, _t, _d, opts} = find_event_spec(result.event_specs, :provider_request_started)
      assert Keyword.get(opts, :visibility) == :debug

      # assistant_delta is user
      {_s, _t, _d, opts} = find_event_spec(result.event_specs, :assistant_delta)
      assert Keyword.get(opts, :visibility) == :user

      # assistant_message is user
      {_s, _t, _d, opts} = find_event_spec(result.event_specs, :assistant_message)
      assert Keyword.get(opts, :visibility) == :user
    end

    test "muse_selected event spec includes muse id and display name" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      {_source, :muse_selected, data, opts} = find_event_spec(result.event_specs, :muse_selected)
      assert data.muse_id == :planning
      assert data.display_name == "Planning Muse"
      assert Keyword.get(opts, :muse_id) == :planning
    end

    test "prompt_prepared event spec contains summary not full content" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      {_source, :prompt_prepared, data, _opts} =
        find_event_spec(result.event_specs, :prompt_prepared)

      # Summary fields present
      assert Map.has_key?(data, :bundle_id)
      assert Map.has_key?(data, :muse_id)
      assert Map.has_key?(data, :layer_count)
      assert Map.has_key?(data, :message_count)
      assert Map.has_key?(data, :tool_count)
      assert Map.has_key?(data, :token_estimate)

      # Full prompt content NOT present
      refute Map.has_key?(data, :messages)
      refute Map.has_key?(data, :layers)
      refute Map.has_key?(data, :content)
    end

    test "provider_request_started event spec contains request summary" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      {_source, :provider_request_started, data, _opts} =
        find_event_spec(result.event_specs, :provider_request_started)

      assert Map.has_key?(data, :bundle_id)
      assert data.provider == :fake
      assert is_binary(data.model)
      assert is_integer(data.message_count)
      assert is_integer(data.tool_count)
    end

    test "session_status_changed events describe idle→running→idle" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      status_specs = filter_event_specs(result.event_specs, :session_status_changed)
      assert length(status_specs) == 2

      {_s, _t, data1, _o} = Enum.at(status_specs, 0)
      assert data1.from == :idle
      assert data1.to == :running

      {_s, _t, data2, _o} = Enum.at(status_specs, 1)
      assert data2.from == :running
      assert data2.to == :idle
    end

    test "assistant_message event spec includes muse_id" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      {_source, :assistant_message, data, opts} =
        find_event_spec(result.event_specs, :assistant_message)

      assert data.text =~ "Placeholder response"
      assert data.streamed? == true
      assert Keyword.get(opts, :muse_id) == :planning
    end
  end

  # -- run/3 with scripted provider events --------------------------------------

  describe "run/3 — scripted provider events" do
    test "scripted fake deltas produce assistant_delta event specs with indices" do
      session = build_session(id: "script-session")

      turn =
        build_turn(
          session_id: "script-session",
          id: "turn_script1",
          user_text: "plan the feature"
        )

      fake_events = [
        {:assistant_delta, "I'll analyze the codebase first."},
        {:assistant_delta, "Here is my plan:"},
        {:assistant_delta, "1. Step one"},
        {:assistant_completed, "Here is my plan:\n1. Step one"},
        {:response_completed, %{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      # Should have 3 assistant_delta specs
      delta_specs = filter_event_specs(result.event_specs, :assistant_delta)
      assert length(delta_specs) == 3

      # Verify delta indices
      {_, _, data0, _} = Enum.at(delta_specs, 0)
      assert data0.index == 0
      assert data0.text == "I'll analyze the codebase first."

      {_, _, data1, _} = Enum.at(delta_specs, 1)
      assert data1.index == 1

      {_, _, data2, _} = Enum.at(delta_specs, 2)
      assert data2.index == 2
    end

    test "provider_response_completed contains usage summary" do
      session = build_session(id: "usage-session")
      turn = build_turn(session_id: "usage-session", id: "turn_usage1", user_text: "test")

      fake_events = [
        {:assistant_delta, "Hello"},
        {:assistant_completed, "Hello"},
        {:response_completed, %{prompt_tokens: 200, completion_tokens: 75, total_tokens: 275}}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      {_source, :provider_response_completed, data, _opts} =
        find_event_spec(result.event_specs, :provider_response_completed)

      assert data.prompt_tokens == 200
      assert data.completion_tokens == 75
      assert data.total_tokens == 275
    end

    test "tool_call events trigger ToolLoop execution and produce debug event specs" do
      session = build_session(id: "tc-session")
      turn = build_turn(session_id: "tc-session", id: "turn_tc1", user_text: "check files")

      # Use fake_event_batches so the ToolLoop gets different scripts per iteration:
      # Iteration 0 (initial Conductor call): tool call for list_files
      # Iteration 1 (ToolLoop after tool result): final text
      fake_event_batches = [
        [
          {:assistant_delta, "Let me check the files."},
          {:tool_call, "list_files", %{"path" => "."}, "call_fixture_1"},
          {:assistant_completed, nil},
          {:response_completed, nil}
        ],
        [
          {:assistant_delta, "Based on the listing..."},
          {:assistant_completed, "Based on the listing..."},
          {:response_completed, nil}
        ]
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_event_batches: fake_event_batches}]
        )

      # Should have tool_call_requested debug events from the first provider call
      requested_specs = filter_event_specs(result.event_specs, :tool_call_requested)
      assert length(requested_specs) >= 1

      {_s, _t, tc_data, tc_opts} = hd(requested_specs)
      assert tc_data.tool_name == "list_files"
      assert Keyword.get(tc_opts, :visibility) == :debug

      # ToolLoop should have executed the tool call and produced lifecycle events
      started_specs = filter_event_specs(result.event_specs, :tool_call_started)
      completed_specs = filter_event_specs(result.event_specs, :tool_call_completed)
      assert length(started_specs) >= 1
      assert length(completed_specs) >= 1

      # Final assistant text should come from the second iteration
      assert result.assistant_text =~ "Based on the listing"
    end

    test "no full prompt or message content leaks through event specs" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      for {_source, _type, data, _opts} <- result.event_specs do
        # Check no data value is a large string that could be prompt content
        for {_key, value} <- data, is_binary(value) do
          refute String.length(value) > 500,
                 "Event data contains suspiciously long string value — possible prompt leak"
        end
      end
    end
  end

  # -- run/3 error path ---------------------------------------------------------

  describe "run/3 — error path" do
    test "returns error when provider fails" do
      session = build_session(id: "err-session")
      turn = build_turn(session_id: "err-session", id: "turn_err1", user_text: "test")

      result =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_error: :simulated_error}]
        )

      assert {:error, %{reason: _reason, event_specs: event_specs}} = result

      types = Enum.map(event_specs, fn {_source, type, _data, _opts} -> type end)
      assert :muse_selected in types
      assert :provider_error in types
      # Session should transition back to idle even on error
      assert :session_status_changed in types
    end
  end

  # -- LLM event catch-all ------------------------------------------------------

  describe "convert_llm_event/2 — catch-all" do
    test "unknown LLM event type produces :provider_event_ignored debug spec" do
      session = build_session(id: "catchall-session")
      turn = build_turn(session_id: "catchall-session", id: "turn_catch1", user_text: "test")

      # Inject a raw %Muse.LLM.Event{} with an unknown type directly into
      # fake_events — FakeProvider emits %Event{} structs as-is.
      unknown_event = %Muse.LLM.Event{type: :some_new_feature}

      fake_events = [
        {:assistant_delta, "Hello"},
        unknown_event,
        {:assistant_completed, "Hello"},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      ignored_specs = filter_event_specs(result.event_specs, :provider_event_ignored)
      assert length(ignored_specs) == 1

      {_source, _type, data, opts} = hd(ignored_specs)
      assert data.unhandled_type == :some_new_feature
      assert Keyword.get(opts, :visibility) == :debug
    end

    test "unknown LLM event type from raw Event struct produces :provider_event_ignored debug spec" do
      session = build_session(id: "catchall2-session")
      turn = build_turn(session_id: "catchall2-session", id: "turn_catch2", user_text: "test")

      # Use a valid %Muse.LLM.Event{} with an unexpected type.
      # FakeProvider emits Event structs directly when given as fake_events entries.
      unknown_event = %Muse.LLM.Event{type: :rate_limited}

      fake_events = [
        {:assistant_delta, "Hello"},
        unknown_event,
        {:assistant_completed, "Hello"},
        {:response_completed, nil}
      ]

      {:ok, result} =
        Conductor.run(session, turn,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{fake_events: fake_events}]
        )

      ignored_specs = filter_event_specs(result.event_specs, :provider_event_ignored)
      assert length(ignored_specs) == 1

      {_source, _type, data, opts} = hd(ignored_specs)
      assert data.unhandled_type == :rate_limited
      assert Keyword.get(opts, :visibility) == :debug
    end
  end

  # -- run/3 opts passthrough ---------------------------------------------------

  describe "run/3 — opts passthrough" do
    test "accepts custom provider_module and provider_config" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          provider_module: FakeProvider,
          provider_config: ProviderConfig.fake(),
          prompt_opts: [project_rules?: false]
        )

      assert result.selected_muse.id == :planning
      assert result.assistant_text =~ "Placeholder response"
    end

    test "provider_module option takes precedence over router-selected provider config" do
      provider_config = %ProviderConfig{
        id: "openai_compatible",
        name: "OpenAI Compatible",
        base_url: "https://llm.example.test/v1",
        wire_api: :chat_completions,
        transport: :none,
        model: "offline-test-model"
      }

      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          provider_module: FakeProvider,
          provider_config: provider_config,
          prompt_opts: [project_rules?: false]
        )

      assert result.request.provider == :openai_compatible
      assert result.assistant_text =~ "Placeholder response"
    end

    test "router-selected OpenAI-compatible provider keeps :sse transport and calls stream path" do
      parent = self()
      assistant_text = "hello over the OpenAI-compatible stream route"

      provider_config = %ProviderConfig{
        id: "openai_compatible",
        name: "OpenAI Compatible",
        base_url: "https://api.example.test/v1",
        wire_api: :chat_completions,
        transport: :sse,
        model: "gpt-4.1-mini",
        auth: :none,
        supports_streaming: true,
        supports_websockets: false,
        supports_tools: true,
        timeout_ms: 12_000,
        max_retries: 0
      }

      sse_post_fn = fn url, req_options, on_chunk ->
        send(parent, {:openai_compatible_sse_post, url, req_options})

        # Build SSE chunks from the response data
        chunks =
          build_sse_chunks_for_conductor(assistant_text, "chatcmpl_sse_route", "gpt-4.1-mini")

        Enum.each(chunks, &on_chunk.(&1))

        {:ok, %{status: 200}}
      end

      {:ok, result} =
        Conductor.run(
          build_session(id: "openai-sse-session"),
          build_turn(
            session_id: "openai-sse-session",
            id: "turn_openai_sse",
            user_text: "say hello"
          ),
          provider_config: provider_config,
          prompt_opts: [project_rules?: false],
          request_options: [options: %{sse_post_fn: sse_post_fn}]
        )

      assert result.request.provider == :openai_compatible
      assert result.request.transport == :sse
      assert result.response.id == "chatcmpl_sse_route"
      assert result.assistant_text == assistant_text

      assert_receive {:openai_compatible_sse_post, url, req_options}
      assert url == "https://api.example.test/v1/chat/completions"
      assert req_options[:json]["model"] == "gpt-4.1-mini"
      assert req_options[:json]["stream"] == true
      assert [%{"role" => "user"} | _] = Enum.reverse(req_options[:json]["messages"])

      {_source, :assistant_delta, data, _opts} =
        find_event_spec(result.event_specs, :assistant_delta)

      assert data.text == assistant_text
    end

    test "accepts prompt_opts for assembler customization" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          prompt_opts: [project_rules?: false, model: "custom-model"]
        )

      assert result.prompt_bundle.model == "custom-model"
    end
  end

  # -- Telemetry ----------------------------------------------------------------

  describe "run/3 — telemetry" do
    test "emits turn start/stop and provider start/stop telemetry" do
      session = build_session(id: "telem-session")
      turn = build_turn(session_id: "telem-session", id: "turn_telem1", user_text: "test")

      with_telemetry_handler(
        Muse.Telemetry.turn_start(),
        "cond-test-turn-start",
        self(),
        :turn_start
      )

      with_telemetry_handler(
        Muse.Telemetry.turn_stop(),
        "cond-test-turn-stop",
        self(),
        :turn_stop
      )

      with_telemetry_handler(
        Muse.Telemetry.provider_start(),
        "cond-test-prov-start",
        self(),
        :provider_start
      )

      with_telemetry_handler(
        Muse.Telemetry.provider_stop(),
        "cond-test-prov-stop",
        self(),
        :provider_stop
      )

      Conductor.run(session, turn, prompt_opts: [project_rules?: false])

      assert_received {:telemetry, :turn_start, _measures, metadata}
      assert metadata.session_id == "telem-session"
      assert metadata.turn_id == "turn_telem1"

      assert_received {:telemetry, :provider_start, _measures, metadata}
      assert metadata.provider == "fake"

      assert_received {:telemetry, :provider_stop, measures, metadata}
      assert is_integer(measures.duration_ms)
      assert metadata.session_id == "telem-session"

      assert_received {:telemetry, :turn_stop, measures, metadata}
      assert is_integer(measures.duration_ms)
      assert metadata.status == "completed"

      :telemetry.detach("cond-test-turn-start")
      :telemetry.detach("cond-test-turn-stop")
      :telemetry.detach("cond-test-prov-start")
      :telemetry.detach("cond-test-prov-stop")
    end

    test "emits provider error telemetry on failure" do
      session = build_session(id: "telem-err-session")
      turn = build_turn(session_id: "telem-err-session", id: "turn_telem_err", user_text: "test")

      with_telemetry_handler(
        Muse.Telemetry.provider_error(),
        "cond-test-prov-error",
        self(),
        :provider_error
      )

      Conductor.run(session, turn,
        prompt_opts: [project_rules?: false],
        request_options: [options: %{fake_error: :simulated_error}]
      )

      assert_received {:telemetry, :provider_error, measures, metadata}
      assert is_integer(measures.duration_ms)
      assert metadata.error_type == "provider_error"

      :telemetry.detach("cond-test-prov-error")
    end
  end

  # -- run/3 model routing -----------------------------------------------------

  describe "run/3 — model routing" do
    test "model_router_opts with model_pins overrides model for Planning Muse" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          prompt_opts: [project_rules?: false],
          model_router_opts: [model_pins: %{planning: "pinned-planning-model"}]
        )

      assert result.selected_muse.id == :planning
      assert result.request.model == "pinned-planning-model"
    end

    test "model_router_opts with model_pins for non-selected Muse leaves model unchanged" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          prompt_opts: [project_rules?: false],
          model_router_opts: [model_pins: %{coding: "pinned-coder-model"}]
        )

      # Planning Muse is selected, coding pin doesn't match
      assert result.request.model == "fake-planning-model"
    end

    test "without model_router_opts, model remains default" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(), prompt_opts: [project_rules?: false])

      assert result.request.model == "fake-planning-model"
    end

    test "empty model_router_opts does not change model" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          prompt_opts: [project_rules?: false],
          model_router_opts: []
        )

      assert result.request.model == "fake-planning-model"
    end

    test "model_router_opts with env map model pin works" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          prompt_opts: [project_rules?: false],
          model_router_opts: [env: %{"MUSE_PLANNING_MODEL" => "env-planner"}]
        )

      assert result.request.model == "env-planner"
    end

    test "explicit request_options model takes precedence over model_router pin" do
      {:ok, result} =
        Conductor.run(build_session(), build_turn(),
          prompt_opts: [project_rules?: false, model: "explicit-bundle-model"],
          model_router_opts: [model_pins: %{planning: "router-pinned-model"}]
        )

      # bundle.model from prompt_opts takes precedence over provider config model
      # (ModelPreparer uses opts[:model] || bundle.model || provider_config.model)
      assert result.request.model == "explicit-bundle-model"
    end
  end
end
