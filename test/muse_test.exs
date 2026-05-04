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
      assert text == "Placeholder response: received \"hello\""
    end

    test "appends streaming event sequence in order" do
      Muse.submit(:cli, "hello")
      events = State.events()

      # 5 events: user_message, turn_started, assistant_delta, assistant_message, turn_completed
      assert length(events) == 5

      types = Enum.map(events, & &1.type)

      assert types == [
               :user_message,
               :turn_started,
               :assistant_delta,
               :assistant_message,
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

      {:ok, text} = Muse.submit(:cli, "fix it")
      events = State.events()

      # user, self_healing, turn_started, delta, assistant, turn_completed — 6 events
      assert length(events) == 6

      types = Enum.map(events, & &1.type)

      assert types == [
               :user_message,
               :queued_issues_attached,
               :turn_started,
               :assistant_delta,
               :assistant_message,
               :turn_completed
             ]

      healing_event = Enum.find(events, &(&1.type == :queued_issues_attached))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))

      assert healing_event.source == :self_healing
      assert healing_event.data.issues != []

      assert text =~ "self-healing issue"
      assert assistant_event.data.text =~ "self-healing issue"
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

      {:ok, text1} = Muse.submit(:cli, "first")
      assert text1 =~ "self-healing issue"

      {:ok, text2} = Muse.submit(:cli, "second")
      refute text2 =~ "self-healing issue"
    end

    test "without queued issues, works as before" do
      {:ok, text} = Muse.submit(:cli, "normal submit")
      events = State.events()

      # 5 events per submit now
      assert length(events) == 5
      assert text == "Placeholder response: received \"normal submit\""
    end
  end
end
