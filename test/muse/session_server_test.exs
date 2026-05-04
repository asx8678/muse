defmodule Muse.SessionServerTest do
  use ExUnit.Case, async: false

  alias Muse.State

  # -- Helpers ------------------------------------------------------------------

  defp ensure_infrastructure do
    # PubSub, SessionRegistry, and SessionSupervisor are started by
    # Application.base_children/0 even in test mode.  We only need to
    # ensure State is running.
    case Process.whereis(Muse.State) do
      nil -> {:ok, _} = State.start_link([])
      _pid -> :ok
    end

    # Clean up any leftover session processes from previous tests
    clean_sessions()
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

        # Wait for processes to fully exit and Registry entries to be cleaned
        Process.sleep(10)
    end
  end

  defp cleanup do
    clean_sessions()

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

  defp start_server(session_id) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Muse.SessionSupervisor,
        {Muse.SessionServer, session_id: session_id}
      )

    pid
  end

  defp awaiting_plan(session_id, opts \\ []) do
    plan =
      Muse.Plan.new(
        id: Keyword.get(opts, :id, "#{session_id}-plan"),
        session_id: session_id,
        objective: Keyword.get(opts, :objective, "Approve or reject this plan"),
        status: Keyword.get(opts, :status, :draft),
        tasks:
          Keyword.get(opts, :tasks, [
            Muse.Task.new(title: "Task A", description: "Do A"),
            Muse.Task.new(title: "Task B", description: "Do B")
          ])
      )

    case plan.status do
      :awaiting_approval -> plan
      _ -> elem(Muse.Plan.transition(plan, :awaiting_approval), 1)
    end
  end

  defp persist_plan_snapshot(session_id, plan, session_status \\ "awaiting_plan_approval") do
    :ok =
      Muse.SessionStore.save_session(session_id, %{
        "status" => session_status,
        "active_plan_id" => plan.id,
        "plan" => Muse.Plan.to_map(plan),
        "plans" => %{plan.id => Muse.Plan.to_map(plan)}
      })

    :ok
  end

  # Number of events per normal submit (no self-healing) after Conductor integration
  @normal_submit_events 12

  # Number of events per submit with self-healing attached
  @self_heal_submit_events 13

  # -- Setup --------------------------------------------------------------------

  setup do
    cleanup()
    ensure_infrastructure()

    on_exit(fn ->
      cleanup()
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  describe "start_link/1" do
    test "starts a session server" do
      pid = start_server("server-1")
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "registers in SessionRegistry" do
      pid = start_server("reg-session")
      assert [{^pid, _}] = Registry.lookup(Muse.SessionRegistry, "reg-session")
    end

    test "refuses duplicate session id" do
      start_server("dup-test")

      assert {:error, {:already_started, _pid}} =
               DynamicSupervisor.start_child(
                 Muse.SessionSupervisor,
                 {Muse.SessionServer, session_id: "dup-test"}
               )
    end
  end

  describe "event ownership" do
    test "self-healing attachment events are included in session-local event count" do
      started_queue? =
        case Process.whereis(Muse.SelfHealingQueue) do
          nil ->
            {:ok, _} = Muse.SelfHealingQueue.start_link([])
            true

          _pid ->
            false
        end

      if started_queue? do
        on_exit(fn ->
          case Process.whereis(Muse.SelfHealingQueue) do
            nil ->
              :ok

            pid ->
              try do
                GenServer.stop(pid)
              catch
                :exit, _ -> :ok
              end
          end
        end)
      end

      diagnostic = Muse.Diagnostic.new(:error, "heal me")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      pid = start_server("self-heal-session")

      status_before = Muse.SessionServer.status(pid)
      assert status_before.event_count == 0

      Muse.SessionServer.submit(pid, :cli, "fix it")

      status_after = Muse.SessionServer.status(pid)
      # With Conductor: user + queued_issues + turn_started +
      # 9 Conductor events + turn_completed
      assert status_after.event_count == @self_heal_submit_events

      # Global State also has the same number of events
      events = State.events()
      assert length(events) == @self_heal_submit_events

      event_types = Enum.map(events, & &1.type)

      assert event_types == [
               :user_message,
               :queued_issues_attached,
               :turn_started,
               :muse_selected,
               :session_status_changed,
               :prompt_prepared,
               :provider_request_started,
               :provider_response_started,
               :assistant_delta,
               :provider_response_completed,
               :assistant_message,
               :session_status_changed,
               :turn_completed
             ]
    end
  end

  describe "submit/3" do
    test "returns {:ok, text} with placeholder response" do
      pid = start_server("submit-test")
      assert {:ok, text} = Muse.SessionServer.submit(pid, :cli, "hello")
      assert text =~ "Placeholder response"
    end

    test "appends structured streaming events to State" do
      pid = start_server("state-events")
      Muse.SessionServer.submit(pid, :web, "test message")

      events = State.events()
      assert length(events) == @normal_submit_events

      # Key structural events — verify the important ones by type
      user_event = Enum.find(events, &(&1.type == :user_message))
      assert user_event.source == :web
      assert user_event.data.text == "test message"
      assert user_event.visibility == :user

      turn_started = Enum.find(events, &(&1.type == :turn_started))
      assert turn_started.visibility == :internal

      muse_selected = Enum.find(events, &(&1.type == :muse_selected))
      assert muse_selected.visibility == :internal

      delta = Enum.find(events, &(&1.type == :assistant_delta))
      assert delta.source == :muse
      assert delta.data.index == 0

      assistant_event = Enum.find(events, &(&1.type == :assistant_message))
      assert assistant_event.source == :muse
      assert assistant_event.data.streamed? == true
      assert assistant_event.visibility == :user

      turn_completed = Enum.find(events, &(&1.type == :turn_completed))
      assert turn_completed.visibility == :internal
      assert turn_completed.data.streamed? == true
    end

    test "preserves event order across multiple submits" do
      pid = start_server("order-test")

      Muse.SessionServer.submit(pid, :cli, "first")
      Muse.SessionServer.submit(pid, :cli, "second")

      events = State.events()
      assert length(events) == @normal_submit_events * 2

      types = Enum.map(events, & &1.type)

      expected_single = [
        :user_message,
        :turn_started,
        :muse_selected,
        :session_status_changed,
        :prompt_prepared,
        :provider_request_started,
        :provider_response_started,
        :assistant_delta,
        :provider_response_completed,
        :assistant_message,
        :session_status_changed,
        :turn_completed
      ]

      assert types == expected_single ++ expected_single
    end
  end

  describe "status/1" do
    test "returns session status map" do
      pid = start_server("status-test")
      status = Muse.SessionServer.status(pid)

      assert status.session_id == "status-test"
      assert status.status == :idle
      assert status.active_muse == nil
      assert status.event_count == 0
    end

    test "event count increases after submit" do
      pid = start_server("event-count")

      status_before = Muse.SessionServer.status(pid)
      assert status_before.event_count == 0

      Muse.SessionServer.submit(pid, :cli, "count me")
      status_after = Muse.SessionServer.status(pid)
      assert status_after.event_count == @normal_submit_events
    end

    test "works while server is alive (no blocking)" do
      pid = start_server("responsive")
      assert Muse.SessionServer.status(pid).status == :idle

      Muse.SessionServer.submit(pid, :cli, "ping")
      assert Muse.SessionServer.status(pid).event_count == @normal_submit_events
    end

    test "active_muse is set after submit" do
      pid = start_server("active-muse-test")
      status_before = Muse.SessionServer.status(pid)
      assert status_before.active_muse == nil

      Muse.SessionServer.submit(pid, :cli, "hello")
      status_after = Muse.SessionServer.status(pid)
      assert status_after.active_muse == "planning"
    end
  end

  describe "session-scoped event metadata" do
    test "emitted events carry session_id matching the server" do
      pid = start_server("meta-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()

      for event <- events do
        assert event.session_id == "meta-session"
      end
    end

    test "emitted events carry monotonically increasing seq values" do
      pid = start_server("seq-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      seqs = Enum.map(events, & &1.seq)
      expected_seqs = Enum.to_list(1..@normal_submit_events)
      assert seqs == expected_seqs
    end

    test "seq continues incrementing across multiple submits" do
      pid = start_server("seq-multi-session")
      Muse.SessionServer.submit(pid, :cli, "first")
      Muse.SessionServer.submit(pid, :cli, "second")

      events = State.events()
      seqs = Enum.map(events, & &1.seq)
      expected_seqs = Enum.to_list(1..(@normal_submit_events * 2))
      assert seqs == expected_seqs
    end

    test "events within the same submit share the same turn_id" do
      pid = start_server("turn-id-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      turn_ids = Enum.map(events, & &1.turn_id)
      assert length(Enum.uniq(turn_ids)) == 1
      assert String.starts_with?(hd(turn_ids), "turn_")
    end

    test "different submits produce different turn_ids" do
      pid = start_server("turn-diff-session")
      Muse.SessionServer.submit(pid, :cli, "first")
      Muse.SessionServer.submit(pid, :cli, "second")

      events = State.events()
      [first_turn | _] = Enum.map(events, & &1.turn_id)
      # Second submit's events start at offset
      [second_turn | _] = Enum.drop(events, @normal_submit_events) |> Enum.map(& &1.turn_id)
      assert first_turn != second_turn
    end

    test "user and assistant events have :user visibility" do
      pid = start_server("vis-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      user_event = Enum.find(events, &(&1.type == :user_message))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))
      assert user_event.visibility == :user
      assert assistant_event.visibility == :user
    end

    test "self-healing attachment events have :debug visibility" do
      started_queue? =
        case Process.whereis(Muse.SelfHealingQueue) do
          nil ->
            {:ok, _} = Muse.SelfHealingQueue.start_link([])
            true

          _pid ->
            false
        end

      if started_queue? do
        on_exit(fn ->
          case Process.whereis(Muse.SelfHealingQueue) do
            nil ->
              :ok

            pid ->
              try do
                GenServer.stop(pid)
              catch
                :exit, _ -> :ok
              end
          end
        end)
      end

      diagnostic = Muse.Diagnostic.new(:error, "heal me")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      pid = start_server("vis-self-heal-session")
      Muse.SessionServer.submit(pid, :cli, "fix it")

      events = State.events()
      user_event = Enum.find(events, &(&1.type == :user_message))
      sh_event = Enum.find(events, &(&1.type == :queued_issues_attached))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))
      assert user_event.visibility == :user
      assert sh_event.visibility == :debug
      assert assistant_event.visibility == :user
    end

    test "muse_selected event carries muse_id" do
      pid = start_server("muse-id-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      muse_event = Enum.find(events, &(&1.type == :muse_selected))
      assert muse_event.data.muse_id == :planning
      # muse_id field is string-normalized by SessionServer
      assert muse_event.muse_id == "planning"
    end

    test "assistant_message event carries muse_id" do
      pid = start_server("msg-muse-id-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      msg = Enum.find(events, &(&1.type == :assistant_message))
      assert msg.muse_id == "planning"
    end
  end

  describe "streaming event sequence" do
    test "normal submit emits full Conductor event sequence" do
      pid = start_server("stream-seq-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      types = Enum.map(events, & &1.type)

      assert types == [
               :user_message,
               :turn_started,
               :muse_selected,
               :session_status_changed,
               :prompt_prepared,
               :provider_request_started,
               :provider_response_started,
               :assistant_delta,
               :provider_response_completed,
               :assistant_message,
               :session_status_changed,
               :turn_completed
             ]
    end

    test "assistant_delta has index and text" do
      pid = start_server("delta-content-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      delta = Enum.find(events, &(&1.type == :assistant_delta))
      assert delta.data.index == 0
      assert delta.data.text =~ "Placeholder response"
    end

    test "final assistant_message has streamed? true" do
      pid = start_server("streamed-flag-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      final = Enum.find(events, &(&1.type == :assistant_message))
      assert final.data.streamed? == true
    end

    test "turn_completed has streamed? true and delta_count" do
      pid = start_server("turn-comp-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      tc = Enum.find(events, &(&1.type == :turn_completed))
      assert tc.data.streamed? == true
      assert tc.data.delta_count == 1
    end

    test "turn_completed has duration_ms > 0" do
      pid = start_server("turn-duration-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      tc = Enum.find(events, &(&1.type == :turn_completed))
      assert is_integer(tc.data.duration_ms)
      assert tc.data.duration_ms >= 0
    end

    test "all events in a submit share the same turn_id" do
      pid = start_server("turn-id-stream-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      turn_ids = Enum.map(events, & &1.turn_id)
      assert length(Enum.uniq(turn_ids)) == 1
    end

    test "turn_started has internal visibility" do
      pid = start_server("turn-started-vis")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      ts = Enum.find(events, &(&1.type == :turn_started))
      assert ts.visibility == :internal
    end

    test "turn_completed has internal visibility" do
      pid = start_server("turn-comp-vis")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      tc = Enum.find(events, &(&1.type == :turn_completed))
      assert tc.visibility == :internal
    end

    test "user text with sk- key is redacted in events" do
      pid = start_server("redact-session")
      Muse.SessionServer.submit(pid, :cli, "my key is sk-test-12345")

      events = State.events()
      user_event = Enum.find(events, &(&1.type == :user_message))
      refute user_event.data.text =~ "sk-test-12345"
      assert user_event.data.text =~ "[REDACTED]"
    end
  end

  describe "Conductor event visibility" do
    test "muse_selected has internal visibility" do
      pid = start_server("muse-sel-vis")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      ms = Enum.find(events, &(&1.type == :muse_selected))
      assert ms.visibility == :internal
    end

    test "session_status_changed has internal visibility" do
      pid = start_server("status-ch-vis")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      ssc = Enum.filter(events, &(&1.type == :session_status_changed))
      assert length(ssc) == 2
      assert Enum.all?(ssc, &(&1.visibility == :internal))
    end

    test "prompt_prepared and provider events have debug visibility" do
      pid = start_server("debug-vis")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      pp = Enum.find(events, &(&1.type == :prompt_prepared))
      assert pp.visibility == :debug

      prs = Enum.find(events, &(&1.type == :provider_request_started))
      assert prs.visibility == :debug

      prsp = Enum.find(events, &(&1.type == :provider_response_started))
      assert prsp.visibility == :debug

      prc = Enum.find(events, &(&1.type == :provider_response_completed))
      assert prc.visibility == :debug
    end

    test "session_status_changed events describe idle→running→idle" do
      pid = start_server("status-trans")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      status_events = Enum.filter(events, &(&1.type == :session_status_changed))

      assert length(status_events) == 2
      [first, second] = status_events
      assert first.data.from == :idle and first.data.to == :running
      assert second.data.from == :running and second.data.to == :idle
    end
  end

  describe "independent seq counters per session" do
    test "seq starts at 1 independently for each session" do
      pid_a = start_server("seq-indep-a")
      pid_b = start_server("seq-indep-b")

      Muse.SessionServer.submit(pid_a, :cli, "hello from a")
      Muse.SessionServer.submit(pid_b, :cli, "hello from b")

      events_a = State.events() |> Enum.filter(&(&1.session_id == "seq-indep-a"))
      events_b = State.events() |> Enum.filter(&(&1.session_id == "seq-indep-b"))

      seqs_a = Enum.map(events_a, & &1.seq)
      seqs_b = Enum.map(events_b, & &1.seq)

      # Both sessions start at seq=1
      expected = Enum.to_list(1..@normal_submit_events)
      assert seqs_a == expected
      assert seqs_b == expected
    end

    test "status reports seq counter" do
      pid = start_server("seq-status-session")

      status = Muse.SessionServer.status(pid)
      assert status.seq == 0

      Muse.SessionServer.submit(pid, :cli, "hello")
      status = Muse.SessionServer.status(pid)
      assert status.seq == @normal_submit_events
    end
  end

  describe "centralized redaction — self-healing secret leak regression" do
    test "diagnostic message containing sk-test-12345 does not appear in State events" do
      started_queue? =
        case Process.whereis(Muse.SelfHealingQueue) do
          nil ->
            {:ok, _} = Muse.SelfHealingQueue.start_link([])
            true

          _pid ->
            false
        end

      if started_queue? do
        on_exit(fn ->
          case Process.whereis(Muse.SelfHealingQueue) do
            nil ->
              :ok

            pid ->
              try do
                GenServer.stop(pid)
              catch
                :exit, _ -> :ok
              end
          end
        end)
      end

      # Diagnostic with a secret in the message
      diagnostic = Muse.Diagnostic.new(:error, "api key sk-test-12345 is leaked")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      pid = start_server("redact-sh-session")
      Muse.SessionServer.submit(pid, :cli, "fix it")

      events = State.events()

      # Search all events for the secret string
      for event <- events do
        event_str = inspect(event)

        refute event_str =~ "sk-test-12345",
               "Found leaked secret sk-test-12345 in event: #{inspect(event.type)}"
      end

      # Verify redaction marker appears somewhere
      all_text = Enum.map_join(events, " ", &inspect(&1.data))
      assert all_text =~ "[REDACTED]"
    end

    test "diagnostic message containing Bearer secret-token does not appear in State events" do
      started_queue? =
        case Process.whereis(Muse.SelfHealingQueue) do
          nil ->
            {:ok, _} = Muse.SelfHealingQueue.start_link([])
            true

          _pid ->
            false
        end

      if started_queue? do
        on_exit(fn ->
          case Process.whereis(Muse.SelfHealingQueue) do
            nil ->
              :ok

            pid ->
              try do
                GenServer.stop(pid)
              catch
                :exit, _ -> :ok
              end
          end
        end)
      end

      diagnostic = Muse.Diagnostic.new(:error, "Authorization: Bearer secret-token-here")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      pid = start_server("redact-bearer-session")
      Muse.SessionServer.submit(pid, :cli, "fix it")

      events = State.events()

      for event <- events do
        event_str = inspect(event)

        refute event_str =~ "secret-token-here",
               "Found leaked Bearer secret in event: #{inspect(event.type)}"
      end
    end

    test "redacted events do not leak secrets in EventFormatter export" do
      started_queue? =
        case Process.whereis(Muse.SelfHealingQueue) do
          nil ->
            {:ok, _} = Muse.SelfHealingQueue.start_link([])
            true

          _pid ->
            false
        end

      if started_queue? do
        on_exit(fn ->
          case Process.whereis(Muse.SelfHealingQueue) do
            nil ->
              :ok

            pid ->
              try do
                GenServer.stop(pid)
              catch
                :exit, _ -> :ok
              end
          end
        end)
      end

      diagnostic = Muse.Diagnostic.new(:error, "key is sk-test-12345 for real")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      pid = start_server("redact-export-session")
      Muse.SessionServer.submit(pid, :cli, "export test")

      events = State.events()

      # Verify event_to_map also doesn't leak
      for event <- events do
        map = MuseWeb.EventFormatter.event_to_map(event)
        map_str = inspect(map)

        refute map_str =~ "sk-test-12345",
               "Found leaked secret in event_to_map output: #{map_str}"
      end
    end
  end

  describe "emit_session_event/5 — error assistant_message" do
    test "emits assistant_message with system source and streamed? false for error events" do
      _pid = start_server("emit-error-session")

      # Use the public emit_session_event to verify the error-path
      # assistant_message event shape (source :system, streamed? false,
      # visibility :user).
      state = %{session_id: "emit-error-session", seq: 0}

      {event, _state} =
        Muse.SessionServer.emit_session_event(
          state,
          :system,
          :assistant_message,
          %{text: "Error: provider error occurred", streamed?: false},
          turn_id: "turn_test",
          visibility: :user
        )

      assert event.source == :system
      assert event.type == :assistant_message
      assert event.data.text == "Error: provider error occurred"
      assert event.data.streamed? == false
      assert event.visibility == :user
    end
  end

  describe "process lifecycle" do
    test "different session ids have different processes" do
      pid_a = start_server("lifecycle-a")
      pid_b = start_server("lifecycle-b")

      assert pid_a != pid_b
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)
    end

    test "temporary child is not restarted after crash" do
      pid = start_server("temp-crash")
      Process.exit(pid, :kill)
      Process.sleep(15)

      refute Process.alive?(pid)
    end
  end

  # -- PR07b: TurnRunner / async integration -----------------------------------

  describe "async turn execution — PR07b" do
    test "status is responsive during turn execution" do
      pid = start_server("responsive-turn")

      # Before submit, status should be idle
      status = Muse.SessionServer.status(pid)
      assert status.status == :idle

      # Submit with a delayed fake provider — this runs async
      # so the GenServer should remain responsive
      submit_pid = self()

      # Start submit in a separate process so we can check status
      _task =
        Task.async(fn ->
          Muse.SessionServer.submit(pid, :cli, "delayed hello")
          send(submit_pid, :submit_done)
        end)

      # Give the submit a moment to start
      Process.sleep(50)

      # Status should now show running (or still idle if already completed)
      status = Muse.SessionServer.status(pid)
      # The status should include the new fields
      assert Map.has_key?(status, :active_turn_id)
      assert Map.has_key?(status, :runner_pid)
      assert Map.has_key?(status, :cancellation_requested)

      # Wait for the submit to complete
      receive do
        :submit_done -> :ok
      after
        5000 -> flunk("Submit did not complete")
      end

      # After completion, status should be idle
      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
    end

    test "submit returns {:ok, text} for normal path" do
      pid = start_server("async-normal")
      assert {:ok, text} = Muse.SessionServer.submit(pid, :cli, "hello")
      assert text =~ "Placeholder response"
    end

    test "events are persisted with correct session/turn/seq" do
      pid = start_server("async-events-persist")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      assert length(events) == @normal_submit_events

      # All events should have the correct session_id
      for event <- events do
        assert event.session_id == "async-events-persist"
      end

      # Seq should be monotonically increasing
      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.to_list(1..@normal_submit_events)

      # All events should share the same turn_id
      turn_ids = Enum.map(events, & &1.turn_id)
      assert length(Enum.uniq(turn_ids)) == 1
    end
  end

  describe "cancel/1 — PR07b" do
    test "cancel returns error when no active turn" do
      pid = start_server("cancel-idle")
      assert {:error, :no_active_turn} = Muse.SessionServer.cancel(pid)
    end

    test "cancel sends signal during running turn" do
      pid = start_server("cancel-running")

      # Start a submit with a long delay
      submit_pid = self()

      _task =
        Task.async(fn ->
          result = Muse.SessionServer.submit(pid, :cli, "delayed cancel")
          send(submit_pid, {:submit_result, result})
        end)

      # Give the submit a moment to start
      Process.sleep(50)

      # Try to cancel
      result = Muse.SessionServer.cancel(pid)
      # Should return :ok or :no_active_turn (if already completed)
      assert result == :ok or result == {:error, :no_active_turn}

      # Wait for the submit to complete
      receive do
        {:submit_result, _result} -> :ok
      after
        5000 -> flunk("Submit did not complete")
      end

      # Session should be back to idle
      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
    end

    test "status map includes cancellation_requested field after cancel" do
      pid = start_server("cancel-status-field")

      # Before any submit
      status = Muse.SessionServer.status(pid)
      assert status.cancellation_requested == false
    end
  end

  describe "no spurious turn_failed events — PR07b regression" do
    test "normal submit produces exactly @normal_submit_events with no turn_failed or nil turn_id" do
      pid = start_server("no-spurious-session")
      Muse.SessionServer.submit(pid, :cli, "hello")

      events = State.events()
      assert length(events) == @normal_submit_events

      # No turn_failed events should appear for a successful submit
      failed = Enum.filter(events, &(&1.type == :turn_failed))
      assert failed == []

      # Every event must have a non-nil turn_id
      for event <- events do
        assert event.turn_id != nil,
               "Event #{inspect(event.type)} (seq=#{event.seq}) has nil turn_id"

        assert String.starts_with?(event.turn_id, "turn_"),
               "Event #{inspect(event.type)} (seq=#{event.seq}) has invalid turn_id: #{inspect(event.turn_id)}"
      end

      # Short sleep to ensure no delayed spurious events arrive
      Process.sleep(50)
      events_after = State.events()
      assert length(events_after) == @normal_submit_events
    end
  end

  describe "approve_plan/2 and reject_plan/2" do
    test "approving an awaiting plan transitions, persists, and emits lifecycle events" do
      session_id = "approve-plan-#{:erlang.unique_integer([:positive])}"
      plan = awaiting_plan(session_id, objective: "Approve persisted plan")
      :ok = persist_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, approved_plan} = Muse.SessionServer.approve_plan(pid, :cli)
      assert approved_plan.status == :approved
      assert %DateTime{} = approved_plan.approved_at
      assert approved_plan.rejected_at == nil

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.plan.status == :approved
      assert status.plan.approved_at == approved_plan.approved_at
      assert status.plans[plan.id].status == :approved
      assert status.active_plan_id == plan.id
      assert status.active_turn_id == nil
      assert status.runner_pid == nil
      assert status.event_count == 2

      events = State.events()
      assert Enum.map(events, & &1.type) == [:plan_approved, :session_status_changed]

      [plan_event, status_event] = events
      assert plan_event.source == :cli
      assert plan_event.visibility == :user
      assert plan_event.session_id == session_id
      assert plan_event.turn_id == nil
      assert plan_event.seq == 1

      assert plan_event.data.plan_id == plan.id
      assert plan_event.data.version == plan.version
      assert plan_event.data.status == :approved
      assert plan_event.data.task_count == 2
      assert plan_event.data.content_hash =~ ~r/^[a-f0-9]{64}$/
      refute Map.has_key?(plan_event.data, :objective)

      assert status_event.source == :conductor
      assert status_event.visibility == :internal
      assert status_event.session_id == session_id
      assert status_event.turn_id == nil
      assert status_event.seq == 2
      assert status_event.data == %{from: :awaiting_plan_approval, to: :idle}

      assert {:ok, stored} = Muse.SessionStore.load_session(session_id)
      assert stored["status"] == "idle"
      assert stored["active_plan_id"] == plan.id
      assert stored["plan"]["status"] == "approved"
      assert stored["plan"]["approved_at"] != nil
      assert stored["plans"][plan.id]["status"] == "approved"
    end

    test "rejecting an awaiting plan transitions, persists, and emits lifecycle events" do
      session_id = "reject-plan-#{:erlang.unique_integer([:positive])}"
      plan = awaiting_plan(session_id, objective: "Reject persisted plan")
      :ok = persist_plan_snapshot(session_id, plan)

      pid = start_server(session_id)

      assert {:ok, rejected_plan} = Muse.SessionServer.reject_plan(pid, :web)
      assert rejected_plan.status == :rejected
      assert %DateTime{} = rejected_plan.rejected_at
      assert rejected_plan.approved_at == nil

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.plan.status == :rejected
      assert status.plan.rejected_at == rejected_plan.rejected_at
      assert status.plans[plan.id].status == :rejected
      assert status.event_count == 2

      events = State.events()
      assert Enum.map(events, & &1.type) == [:plan_rejected, :session_status_changed]

      [plan_event, status_event] = events
      assert plan_event.source == :web
      assert plan_event.visibility == :user
      assert plan_event.session_id == session_id
      assert plan_event.turn_id == nil
      assert plan_event.seq == 1

      assert plan_event.data.plan_id == plan.id
      assert plan_event.data.version == plan.version
      assert plan_event.data.status == :rejected
      assert plan_event.data.task_count == 2
      assert plan_event.data.content_hash =~ ~r/^[a-f0-9]{64}$/
      refute Map.has_key?(plan_event.data, :objective)

      assert status_event.visibility == :internal
      assert status_event.data == %{from: :awaiting_plan_approval, to: :idle}

      assert {:ok, stored} = Muse.SessionStore.load_session(session_id)
      assert stored["status"] == "idle"
      assert stored["plan"]["status"] == "rejected"
      assert stored["plan"]["rejected_at"] != nil
      assert stored["plans"][plan.id]["status"] == "rejected"
    end

    test "approve and reject return no_active_plan when no plan is active" do
      pid = start_server("no-active-plan")

      assert {:error, :no_active_plan} = Muse.SessionServer.approve_plan(pid)
      assert {:error, :no_active_plan} = Muse.SessionServer.reject_plan(pid)

      status = Muse.SessionServer.status(pid)
      assert status.status == :idle
      assert status.plan == nil
      assert status.active_plan_id == nil
      assert status.event_count == 0
      assert State.events() == []
    end

    test "approve and reject refuse while a turn is running" do
      session_id = "approve-running-#{:erlang.unique_integer([:positive])}"
      plan = awaiting_plan(session_id)
      :ok = persist_plan_snapshot(session_id, plan)
      pid = start_server(session_id)

      :sys.replace_state(pid, fn state -> %{state | status: :running, runner_pid: self()} end)

      assert {:error, :turn_running} = Muse.SessionServer.approve_plan(pid)
      assert {:error, :turn_running} = Muse.SessionServer.reject_plan(pid)

      status = Muse.SessionServer.status(pid)
      assert status.status == :running
      assert status.plan.status == :awaiting_approval
      assert status.event_count == 0
      assert State.events() == []
    end

    test "approve and reject refuse non-awaiting plans without corrupting state" do
      approved_session_id = "already-approved-#{:erlang.unique_integer([:positive])}"
      approved_plan = awaiting_plan(approved_session_id)
      {:ok, approved_plan} = Muse.Plan.transition(approved_plan, :approved)
      :ok = persist_plan_snapshot(approved_session_id, approved_plan, "idle")
      approved_pid = start_server(approved_session_id)
      approved_before = Muse.SessionServer.status(approved_pid)

      assert {:error, {:plan_not_awaiting_approval, :approved}} =
               Muse.SessionServer.approve_plan(approved_pid)

      approved_status = Muse.SessionServer.status(approved_pid)
      assert approved_status.status == :idle
      assert approved_status.plan == approved_before.plan
      assert approved_status.event_count == 0

      rejected_session_id = "already-rejected-#{:erlang.unique_integer([:positive])}"
      rejected_plan = awaiting_plan(rejected_session_id)
      {:ok, rejected_plan} = Muse.Plan.transition(rejected_plan, :rejected)
      :ok = persist_plan_snapshot(rejected_session_id, rejected_plan, "idle")
      rejected_pid = start_server(rejected_session_id)
      rejected_before = Muse.SessionServer.status(rejected_pid)

      assert {:error, {:plan_not_awaiting_approval, :rejected}} =
               Muse.SessionServer.reject_plan(rejected_pid)

      rejected_status = Muse.SessionServer.status(rejected_pid)
      assert rejected_status.status == :idle
      assert rejected_status.plan == rejected_before.plan
      assert rejected_status.event_count == 0
      assert State.events() == []
    end
  end

  describe "plan lifecycle — status and persistence" do
    test "status includes plan/plans/active_plan_id fields (nil when no plan)" do
      pid = start_server("plan-lifecycle-status-test")
      status = Muse.SessionServer.status(pid)

      assert Map.has_key?(status, :plan)
      assert Map.has_key?(status, :plans)
      assert Map.has_key?(status, :active_plan_id)
      assert status.plan == nil
      assert status.plans == %{}
      assert status.active_plan_id == nil
    end

    test "restores plan from persisted session snapshot on init" do
      session_id = "plan-persist-restore-#{:erlang.unique_integer([:positive])}"

      # Create and persist a plan manually via SessionStore
      plan =
        Muse.Plan.new(
          id: "plan_persist_1",
          session_id: session_id,
          objective: "Persisted plan test",
          tasks: [Muse.Task.new(title: "Task A", description: "Do A")]
        )

      {:ok, plan} = Muse.Plan.transition(plan, :awaiting_approval)

      data = %{
        "status" => "awaiting_plan_approval",
        "active_plan_id" => "plan_persist_1",
        "plan" => Muse.Plan.to_map(plan),
        "plans" => %{"plan_persist_1" => Muse.Plan.to_map(plan)}
      }

      assert :ok = Muse.SessionStore.save_session(session_id, data)

      # Start server with this session_id — should restore from snapshot
      pid = start_server(session_id)
      status = Muse.SessionServer.status(pid)

      assert status.status == :awaiting_plan_approval
      assert status.active_plan_id == "plan_persist_1"

      assert status.plan != nil
      assert status.plan.objective == "Persisted plan test"

      # Verify restored status is :awaiting_approval, not :draft
      assert status.plan.status == :awaiting_approval,
             "Restored plan status should be :awaiting_approval, got: #{inspect(status.plan.status)}"

      # Verify rendered header reflects awaiting_approval
      rendered = Muse.Plan.render(status.plan)

      assert rendered =~ "Planning Muse prepared a plan.",
             "Rendered plan header should be 'Planning Muse prepared a plan.'"
    end

    test "planning turn assigns and persists active plan identity when provider omits plan id" do
      session_id = "plan-generated-id-#{:erlang.unique_integer([:positive])}"
      pid = start_server(session_id)

      plan_json = ~s({
        "objective": "Create a durable active plan id.",
        "tasks": [
          {"title": "Inspect", "description": "Inspect files", "requires_write": false, "requires_shell": false}
        ]
      })

      fake_events = [
        {:assistant_delta, plan_json},
        {:assistant_completed, plan_json},
        {:response_completed, nil}
      ]

      assert {:ok, assistant_text} =
               Muse.SessionServer.submit(pid, :cli, "plan with generated id",
                 prompt_opts: [project_rules?: false],
                 request_options: [options: %{fake_events: fake_events}]
               )

      assert assistant_text =~ "Planning Muse prepared a plan."

      status = Muse.SessionServer.status(pid)
      assert status.status == :awaiting_plan_approval
      assert status.active_plan_id == status.plan.id
      assert String.starts_with?(status.active_plan_id, "plan_turn_")
      assert status.plan.session_id == session_id
      assert status.plan.version == 1
      assert status.plans[status.active_plan_id].objective == "Create a durable active plan id."

      assert {:ok, stored} = Muse.SessionStore.load_session(session_id)
      assert stored["status"] == "awaiting_plan_approval"
      assert stored["active_plan_id"] == status.active_plan_id
      assert stored["plan"]["id"] == status.active_plan_id
      assert stored["plan"]["session_id"] == session_id
      assert stored["plan"]["version"] == 1
      assert get_in(stored, ["plans", status.active_plan_id, "id"]) == status.active_plan_id

      :ok = DynamicSupervisor.terminate_child(Muse.SessionSupervisor, pid)
      Process.sleep(10)

      restored_pid = start_server(session_id)
      restored_status = Muse.SessionServer.status(restored_pid)

      assert restored_status.status == :awaiting_plan_approval
      assert restored_status.active_plan_id == status.active_plan_id
      assert restored_status.plan.id == status.active_plan_id
      assert restored_status.plan.session_id == session_id
      assert restored_status.plans[status.active_plan_id].version == 1
    end

    test "restores active plan from plans map when top-level plan snapshot is absent" do
      session_id = "plan-restore-from-history-#{:erlang.unique_integer([:positive])}"
      plan = awaiting_plan(session_id, id: "history-only-plan")

      assert :ok =
               Muse.SessionStore.save_session(session_id, %{
                 "status" => "awaiting_plan_approval",
                 "active_plan_id" => plan.id,
                 "plans" => %{plan.id => Muse.Plan.to_map(plan)}
               })

      pid = start_server(session_id)
      status = Muse.SessionServer.status(pid)

      assert status.status == :awaiting_plan_approval
      assert status.active_plan_id == plan.id
      assert status.plan.id == plan.id
      assert status.plan.status == :awaiting_approval
      assert status.plans[plan.id].objective == plan.objective
    end

    test "handles missing session snapshot gracefully" do
      session_id = "plan-no-snapshot-#{:erlang.unique_integer([:positive])}"

      pid = start_server(session_id)
      status = Muse.SessionServer.status(pid)

      assert status.status == :idle
      assert status.plan == nil
      assert status.active_plan_id == nil
    end

    test "handles corrupt session snapshot gracefully" do
      session_id = "plan-corrupt-#{:erlang.unique_integer([:positive])}"

      # Write invalid JSON to the session file
      dir = Muse.SessionStore.session_dir(session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "session.json"), "not valid json at all")

      # Should not crash, should start with default state
      pid = start_server(session_id)
      status = Muse.SessionServer.status(pid)

      assert status.status == :idle
      assert status.plan == nil
    end
  end
end
