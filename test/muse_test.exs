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

    test "appends exactly a user event and assistant event, in order" do
      Muse.submit(:cli, "hello")
      events = State.events()

      assert length(events) == 2

      [user_event, assistant_event] = events

      # User event
      assert user_event.source == :cli
      assert user_event.type == :user_message
      assert user_event.data == %{text: "hello"}

      # Assistant event
      assert assistant_event.source == :muse
      assert assistant_event.type == :assistant_message
      assert assistant_event.data == %{text: "Placeholder response: received \"hello\""}
    end

    test "assistant event text matches the returned text" do
      {:ok, returned_text} = Muse.submit(:cli, "test input")
      [_user, assistant] = State.events()

      assert assistant.data.text == returned_text
    end

    test "with queued self-healing issues, attaches them as an event" do
      diagnostic = Muse.Diagnostic.new(:error, "heal me")
      Muse.SelfHealingQueue.add_diagnostic(diagnostic)

      {:ok, text} = Muse.submit(:cli, "fix it")
      events = State.events()

      # user, self_healing, assistant — 3 events
      assert length(events) == 3

      [user_event, healing_event, assistant_event] = events

      assert user_event.source == :cli
      assert user_event.type == :user_message

      assert healing_event.source == :self_healing
      assert healing_event.type == :queued_issues_attached
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

      assert length(events) == 2
      assert text == "Placeholder response: received \"normal submit\""
    end
  end
end
