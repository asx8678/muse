defmodule MuseTest do
  use ExUnit.Case, async: false

  alias Muse.State

  # -- Helpers ------------------------------------------------------------------

  defp stop_state do
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

  defp stop_self_healing_queue do
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
  end

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp start_fresh do
    stop_state()
    {:ok, _} = State.start_link()
  end

  defp start_self_healing_queue do
    stop_self_healing_queue()
    {:ok, _} = Muse.SelfHealingQueue.start_link([])
  end

  # Number of events per normal submit after Conductor integration
  @normal_submit_events 12
  # Number of events per submit with self-healing
  @self_heal_submit_events 13

  # -- Setup --------------------------------------------------------------------

  setup do
    ensure_pubsub()
    start_fresh()
    start_self_healing_queue()

    on_exit(fn ->
      stop_self_healing_queue()
      stop_state()
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  test "Muse module compiles and is defined" do
    assert Code.ensure_loaded?(Muse)
  end

  test "Muse.Application module compiles and is defined" do
    assert Code.ensure_loaded?(Muse.Application)
  end

  describe "submit/2" do
    test "returns {:ok, assistant_text} with placeholder response" do
      assert {:ok, text} = Muse.submit(:cli, "hello")
      assert text =~ "Placeholder response"
    end

    test "appends streaming event sequence in order" do
      Muse.submit(:cli, "hello")
      events = State.events()

      # 12 events after Conductor integration
      assert length(events) == @normal_submit_events

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

      user_event = Enum.find(events, &(&1.type == :user_message))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))

      # User event
      assert user_event.source == :cli
      assert user_event.type == :user_message

      # Assistant final event
      assert assistant_event.source == :muse
      assert assistant_event.type == :assistant_message
      assert assistant_event.data.streamed? == true
    end

    test "assistant event text matches the returned text" do
      {:ok, returned_text} = Muse.submit(:cli, "test input")
      events = State.events()
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))

      assert assistant_event.data.text == returned_text
    end

    test "with queued self-healing issues, attaches them as an event" do
      diagnostic = Muse.Diagnostic.new(:error, "heal me")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      {:ok, _text} = Muse.submit(:cli, "fix it")
      events = State.events()

      # 13 events: user + queued_issues + turn_started +
      # 9 Conductor events + turn_completed
      assert length(events) == @self_heal_submit_events

      types = Enum.map(events, & &1.type)

      assert types == [
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

      healing_event = Enum.find(events, &(&1.type == :queued_issues_attached))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))

      assert healing_event.source == :self_healing
      assert healing_event.data.issues != []

      assert assistant_event.data.text =~ "Placeholder response"
    end

    test "marks queued issues as in_progress when attached to submit turn" do
      diagnostic = Muse.Diagnostic.new(:warning, "progress me")
      issue = Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      Muse.submit(:cli, "process")

      # The issue should now be in_progress
      [updated] = Muse.SelfHealingQueue.list()
      assert updated.status == :in_progress
      assert updated.id == issue.id
    end

    test "second submit does not re-attach already claimed issues" do
      diagnostic = Muse.Diagnostic.new(:error, "once only")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      {:ok, _text1} = Muse.submit(:cli, "first")

      # Second submit: no queued_issues_attached event
      {:ok, _text2} = Muse.submit(:cli, "second")

      all_events = State.events()
      healing_events = Enum.filter(all_events, &(&1.type == :queued_issues_attached))
      # Only one self-healing attachment event from first submit
      assert length(healing_events) == 1
    end

    test "without queued issues, works as before" do
      {:ok, text} = Muse.submit(:cli, "normal submit")
      events = State.events()

      assert length(events) == @normal_submit_events
      assert text =~ "Placeholder response"
    end
  end
end
