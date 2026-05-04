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
end
