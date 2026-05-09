defmodule Muse.ConductorStreamingTest do
  @moduledoc """
  T0-05: True live event emission during provider streaming.

  Acceptance criteria tested here:

    1. First assistant delta reaches PubSub before provider completion.
    2. LiveView can render streaming text while provider call is still active.
    3. Provider completion does not duplicate already-emitted deltas.
    4. Stale deltas from old turn ids are ignored.
    5. Tool-loop provider calls use the same streaming approach.
  """

  use ExUnit.Case, async: false

  alias Muse.{Conductor, Session, Turn, State}
  alias Muse.LLM.FakeProvider

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_session(opts \\ []) do
    defaults = [id: "streaming-test-session", workspace: "/tmp/test_workspace", status: :idle]
    Session.new(Keyword.merge(defaults, opts))
  end

  defp build_turn(opts \\ []) do
    defaults = [
      session_id: "streaming-test-session",
      id: "turn_stream1",
      source: :cli,
      user_text: "stream this"
    ]

    Turn.new(Keyword.merge(defaults, opts))
  end

  defp ensure_infrastructure do
    if Process.whereis(Muse.ActiveWorkspace) do
      Muse.ActiveWorkspace.reset()
    end

    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _pid -> :ok
    end

    :ok
  end

  defp cleanup do
    case Process.whereis(Muse.State) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  setup do
    cleanup()
    ensure_infrastructure()

    on_exit(fn ->
      cleanup()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. First assistant delta reaches PubSub before provider completion
  # ---------------------------------------------------------------------------

  describe "live emission: deltas before completion" do
    test "emit_event_fn receives assistant_delta specs during streaming" do
      session = build_session()
      turn = build_turn()

      # Track what specs the emit_event_fn receives and when
      test_pid = self()
      _live_specs = []

      emit_event_fn = fn spec ->
        send(test_pid, {:live_spec, spec})
      end

      # Provider with multiple deltas
      opts = [
        provider_module: FakeProvider,
        provider_config: Muse.LLM.ProviderConfig.fake(),
        request_options: [
          options: %{
            fake_events: [
              {:assistant_delta, "First chunk"},
              {:assistant_delta, " second chunk"},
              {:assistant_completed, "First chunk second chunk"},
              {:response_completed, nil}
            ]
          }
        ],
        emit_event_fn: emit_event_fn
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      # Verify that the Conductor result still contains all event specs
      delta_specs =
        Enum.filter(result.event_specs, fn
          {:muse, :assistant_delta, _, _} -> true
          _ -> false
        end)

      assert length(delta_specs) == 2

      # Verify that live specs were received during streaming
      assert_received {:live_spec, {:muse, :assistant_delta, %{text: "First chunk", index: 0}, _}}

      assert_received {:live_spec,
                       {:muse, :assistant_delta, %{text: " second chunk", index: 1}, _}}
    end

    test "emit_event_fn is not called when not provided (backward compat)" do
      session = build_session()
      turn = build_turn()

      # No emit_event_fn — should work as before
      opts = [
        provider_module: FakeProvider,
        provider_config: Muse.LLM.ProviderConfig.fake(),
        request_options: [
          options: %{
            fake_events: [
              {:assistant_delta, "Hello"},
              {:assistant_completed, "Hello"},
              {:response_completed, nil}
            ]
          }
        ]
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      delta_specs =
        Enum.filter(result.event_specs, fn
          {:muse, :assistant_delta, _, _} -> true
          _ -> false
        end)

      assert length(delta_specs) == 1
      # No live_emitted flag since emit_event_fn was not provided
      {_s, _t, _d, opts} = hd(delta_specs)
      refute Keyword.get(opts, :live_emitted, false)
    end

    test "live-emitted delta specs are marked with live_emitted flag" do
      session = build_session()
      turn = build_turn()

      test_pid = self()

      emit_event_fn = fn spec ->
        send(test_pid, {:live_spec, spec})
      end

      opts = [
        provider_module: FakeProvider,
        provider_config: Muse.LLM.ProviderConfig.fake(),
        request_options: [
          options: %{
            fake_events: [
              {:assistant_delta, "Chunk"},
              {:assistant_completed, "Chunk"},
              {:response_completed, nil}
            ]
          }
        ],
        emit_event_fn: emit_event_fn
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      delta_specs =
        Enum.filter(result.event_specs, fn
          {:muse, :assistant_delta, _, _} -> true
          _ -> false
        end)

      assert length(delta_specs) == 1
      {_s, _t, _d, opts} = hd(delta_specs)
      assert Keyword.get(opts, :live_emitted) == true
    end

    test "non-delta events are NOT emitted live (only assistant_delta)" do
      session = build_session()
      turn = build_turn()

      test_pid = self()

      emit_event_fn = fn spec ->
        send(test_pid, {:live_spec, spec})
      end

      opts = [
        provider_module: FakeProvider,
        provider_config: Muse.LLM.ProviderConfig.fake(),
        request_options: [
          options: %{
            fake_events: [
              {:assistant_delta, "Hello"},
              {:assistant_completed, "Hello"},
              {:response_completed, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}
            ]
          }
        ],
        emit_event_fn: emit_event_fn
      ]

      {:ok, _result} = Conductor.run(session, turn, opts)

      # Only assistant_delta should be emitted live
      received = receive_all_specs()
      types = Enum.map(received, fn {_s, t, _d, _o} -> t end)
      assert Enum.all?(types, &(&1 == :assistant_delta))
    end
  end

  # ---------------------------------------------------------------------------
  # 2 & 3. SessionServer live emission & deduplication
  # ---------------------------------------------------------------------------

  describe "SessionServer: live streaming and dedup" do
    setup do
      # Ensure clean session infrastructure
      clean_sessions()

      case Process.whereis(Muse.SessionSupervisor) do
        nil -> :ok
        _ -> :ok
      end

      on_exit(fn ->
        clean_sessions()
      end)

      :ok
    end

    defp clean_sessions do
      case Process.whereis(Muse.SessionSupervisor) do
        nil ->
          :ok

        pid ->
          pid
          |> DynamicSupervisor.which_children()
          |> Enum.each(fn
            {_, child_pid, _, _} when is_pid(child_pid) ->
              try do
                DynamicSupervisor.terminate_child(Muse.SessionSupervisor, child_pid)
              catch
                :exit, _ -> :ok
              end

            _ ->
              :ok
          end)
      end
    end

    defp start_server(session_id) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {Muse.SessionServer, session_id: session_id}
        )

      pid
    end

    test "assistant_delta reaches PubSub before turn completion" do
      pid = start_server("live-delta-pubsub")

      # Subscribe to PubSub before submit
      :ok = Muse.State.subscribe()

      {:ok, _turn_id} = Muse.SessionServer.submit_async(pid, :web, "hello live")

      # We should receive the assistant_delta event via PubSub
      # before the turn_completed event
      delta_received = receive_do(:assistant_delta, 5000)
      assert delta_received != nil, "Expected to receive assistant_delta via PubSub"

      # Also receive turn_completed eventually
      turn_completed = receive_do(:turn_completed, 5000)
      assert turn_completed != nil, "Expected to receive turn_completed via PubSub"
    end

    test "no duplicate assistant_delta events in final events list" do
      pid = start_server("live-delta-dedup")

      Muse.SessionServer.submit(pid, :cli, "dedup test")

      events = State.events()

      # Count assistant_delta events — should be exactly 1
      deltas = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(deltas) == 1, "Expected exactly 1 assistant_delta, got #{length(deltas)}"

      # Total events should still be the expected count
      assert length(events) == 12
    end

    test "live-emitted deltas are in correct order in events list" do
      pid = start_server("live-delta-order")

      Muse.SessionServer.submit(pid, :cli, "order test")

      events = State.events()
      types = Enum.map(events, & &1.type)

      # assistant_delta should appear after turn_started and before
      # muse_selected (the first conductor overhead event)
      turn_started_idx = Enum.find_index(types, &(&1 == :turn_started))
      delta_idx = Enum.find_index(types, &(&1 == :assistant_delta))
      muse_selected_idx = Enum.find_index(types, &(&1 == :muse_selected))

      assert turn_started_idx != nil
      assert delta_idx != nil
      assert muse_selected_idx != nil

      # Delta comes after turn_started
      assert delta_idx > turn_started_idx
      # Delta comes before muse_selected (live emission)
      assert delta_idx < muse_selected_idx
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Stale deltas from old turn ids are ignored
  # ---------------------------------------------------------------------------

  describe "stale turn event rejection" do
    test "SessionServer ignores turn_event_spec with wrong turn_id" do
      # This test verifies the handler logic directly
      # by simulating a stale message
      pid = start_stale_server("stale-turn-test")

      # The server has no active turn, so any turn_event_spec should be ignored
      spec = {:muse, :assistant_delta, %{text: "stale", index: 0}, [visibility: :user]}

      # Send a stale turn_event_spec
      send(pid, {:turn_event_spec, "turn_old123", spec})

      # Give the server time to process
      Process.sleep(50)

      # The stale event should NOT be in the events list
      status = Muse.SessionServer.status(pid)
      # No events should have been added from the stale spec
      assert status.event_count == 0
    end

    test "SessionServer ignores turn_event_spec when no turn is active" do
      pid = start_stale_server("no-turn-active")

      spec = {:muse, :assistant_delta, %{text: "orphan", index: 0}, [visibility: :user]}
      send(pid, {:turn_event_spec, "turn_orphan", spec})

      Process.sleep(50)

      status = Muse.SessionServer.status(pid)
      assert status.event_count == 0
    end

    test "SessionServer ignores malformed live event specs without crashing" do
      pid = start_stale_server("malformed-live-spec")

      send(pid, {:turn_event_spec, "turn_bad", :not_an_event_spec})

      Process.sleep(50)

      status = Muse.SessionServer.status(pid)
      assert status.event_count == 0
      assert Process.alive?(pid)
    end

    test "SessionServer suppresses live deltas after cancellation is requested" do
      pid = start_stale_server("cancel-live-deltas")
      :ok = Muse.State.subscribe()

      {:ok, _turn_id} =
        Muse.SessionServer.submit_async(pid, :web, "cancel streaming",
          provider_module: FakeProvider,
          provider_config: Muse.LLM.ProviderConfig.fake(),
          request_options: [
            options: %{
              fake_events: [
                {:assistant_delta, "before cancel"},
                {:delay, 150},
                {:assistant_delta, " after cancel"},
                {:assistant_completed, "before cancel after cancel"},
                {:response_completed, nil}
              ]
            }
          ]
        )

      assert_receive {:muse_event, %{type: :assistant_delta, data: %{text: "before cancel"}}},
                     1_000

      assert :ok = Muse.SessionServer.cancel(pid)

      refute_receive {:muse_event, %{type: :assistant_delta, data: %{text: " after cancel"}}},
                     300

      assert_receive {:muse_event, %{type: :turn_completed, data: %{cancelled: true}}},
                     2_000

      refute Enum.any?(State.events(), fn event ->
               event.type == :assistant_delta and event.data.text == " after cancel"
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Tool-loop provider calls use the same streaming approach
  # ---------------------------------------------------------------------------

  describe "tool-loop live streaming" do
    test "tool-loop provider calls emit assistant_delta live via emit_event_fn" do
      session = build_session()
      turn = build_turn()

      test_pid = self()

      _all_live_specs = []

      emit_event_fn = fn spec ->
        send(test_pid, {:live_spec, spec})
      end

      # Two-iteration tool loop: first iteration returns tool calls,
      # second returns text. Both should emit deltas live.
      batches = [
        # Iteration 0: assistant_delta + tool call
        [
          {:assistant_delta, "Let me check."},
          {:tool_call, "list_files", %{"path" => "."}, "tc_1"},
          {:assistant_completed, nil}
        ],
        # Iteration 1: assistant_delta + final text
        [
          {:assistant_delta, "Done checking."},
          {:assistant_completed, "Done checking."},
          {:response_completed, nil}
        ]
      ]

      opts = [
        provider_module: FakeProvider,
        provider_config: Muse.LLM.ProviderConfig.fake(),
        request_options: [
          options: %{
            fake_event_batches: batches
          }
        ],
        emit_event_fn: emit_event_fn
      ]

      {:ok, result} = Conductor.run(session, turn, opts)

      # Live specs should include deltas from BOTH iterations
      # (first from stream_provider, then from ToolLoop)
      live_specs = receive_all_specs()

      delta_texts =
        live_specs
        |> Enum.filter(fn {s, t, _, _} -> s == :muse and t == :assistant_delta end)
        |> Enum.map(fn {_, _, %{text: text}, _} -> text end)

      assert "Let me check." in delta_texts, "Expected 'Let me check.' in #{inspect(delta_texts)}"

      assert "Done checking." in delta_texts,
             "Expected 'Done checking.' in #{inspect(delta_texts)}"

      # Final result should have all delta specs marked as live_emitted
      all_delta_specs =
        Enum.filter(result.event_specs, fn
          {:muse, :assistant_delta, _, _} -> true
          _ -> false
        end)

      assert length(all_delta_specs) >= 2

      for {_s, _t, _d, opts} <- all_delta_specs do
        assert Keyword.get(opts, :live_emitted) == true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Conductor.mark_live_emitted_deltas/2 unit tests
  # ---------------------------------------------------------------------------

  describe "Conductor.mark_live_emitted_deltas/2" do
    test "marks first N assistant_delta specs with live_emitted flag" do
      specs = [
        {:conductor, :provider_response_started, %{}, [visibility: :debug]},
        {:muse, :assistant_delta, %{text: "A", index: 0}, [visibility: :user]},
        {:muse, :assistant_delta, %{text: "B", index: 1}, [visibility: :user]},
        {:conductor, :provider_response_completed, %{}, [visibility: :debug]}
      ]

      marked = Conductor.mark_live_emitted_deltas(specs, 2)

      # First two deltas should be marked
      {_, _, _, opts1} = Enum.at(marked, 1)
      assert Keyword.get(opts1, :live_emitted) == true

      {_, _, _, opts2} = Enum.at(marked, 2)
      assert Keyword.get(opts2, :live_emitted) == true

      # Non-delta specs should be unchanged
      {_, _, _, opts0} = Enum.at(marked, 0)
      refute Keyword.has_key?(opts0, :live_emitted)

      {_, _, _, opts3} = Enum.at(marked, 3)
      refute Keyword.has_key?(opts3, :live_emitted)
    end

    test "returns specs unchanged when count is 0" do
      specs = [
        {:muse, :assistant_delta, %{text: "A", index: 0}, [visibility: :user]}
      ]

      assert Conductor.mark_live_emitted_deltas(specs, 0) == specs
    end

    test "only marks up to count deltas even if more exist" do
      specs = [
        {:muse, :assistant_delta, %{text: "A", index: 0}, [visibility: :user]},
        {:muse, :assistant_delta, %{text: "B", index: 1}, [visibility: :user]},
        {:muse, :assistant_delta, %{text: "C", index: 2}, [visibility: :user]}
      ]

      marked = Conductor.mark_live_emitted_deltas(specs, 1)

      {_, _, _, opts1} = Enum.at(marked, 0)
      assert Keyword.get(opts1, :live_emitted) == true

      {_, _, _, opts2} = Enum.at(marked, 1)
      refute Keyword.has_key?(opts2, :live_emitted)
    end
  end

  # ---------------------------------------------------------------------------
  # SessionServer emit_event_specs dedup
  # ---------------------------------------------------------------------------

  describe "SessionServer emit_event_specs skips live_emitted" do
    test "final event list has no duplicate assistant_delta from live+final" do
      # This is already covered by the dedup test above,
      # but let's also verify the count explicitly.
      # The emit_event_specs/3 function is private, so we test
      # the end-to-end behavior through the SessionServer.
      pid = start_stale_server("live-emitted-dedup")

      Muse.SessionServer.submit(pid, :cli, "dedup verify")

      events = State.events()

      deltas = Enum.filter(events, &(&1.type == :assistant_delta))
      assert length(deltas) == 1, "Expected exactly 1 assistant_delta, got #{length(deltas)}"

      # Non-live events should all be present
      types = Enum.map(events, & &1.type)
      assert :muse_selected in types
      assert :assistant_message in types
      assert :turn_completed in types
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp receive_all_specs, do: receive_all_specs(:live_spec)
  defp receive_all_specs(tag), do: receive_all_specs(tag, [])

  defp receive_all_specs(tag, acc) do
    receive do
      {^tag, spec} -> receive_all_specs(tag, [spec | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp receive_do(type, timeout) do
    receive do
      {:muse_event, %{type: ^type} = event} -> event
    after
      timeout -> nil
    end
  end

  defp start_stale_server(session_id) do
    case Process.whereis(Muse.ActiveWorkspace) do
      nil -> :ok
      _ -> Muse.ActiveWorkspace.reset()
    end

    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _ -> :ok
    end

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {Muse.SessionServer, session_id: session_id}
      )

    pid
  end
end
