defmodule Muse.StateTest do
  use ExUnit.Case, async: false

  alias Muse.{Event, State}

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

  defp start_fresh do
    stop_state()
    {:ok, _} = State.start_link()
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    start_fresh()
    on_exit(fn -> stop_state() end)
    :ok
  end

  # -- Tests --------------------------------------------------------------------

  describe "initial state" do
    test "events are empty" do
      assert State.events() == []
    end

    test "get returns full state with empty events" do
      assert State.get() == %{events: []}
    end

    test "max_events returns configured event cap" do
      assert State.max_events() == 1_000
    end
  end

  describe "append/1" do
    test "stores an event" do
      event = Event.new(:test, :stored, %{ok: true})
      assert :ok = State.append(event)

      [stored] = State.events()
      assert stored.id == event.id
      assert stored.source == :test
      assert stored.type == :stored
    end

    test "preserves append order (oldest first)" do
      e1 = Event.new(:a, :first, nil)
      e2 = Event.new(:b, :second, nil)
      e3 = Event.new(:c, :third, nil)

      State.append(e1)
      State.append(e2)
      State.append(e3)

      events = State.events()
      assert length(events) == 3
      assert Enum.map(events, & &1.type) == [:first, :second, :third]
    end

    test "get returns full state with events" do
      event = Event.new(:state, :check, nil)
      State.append(event)

      state = State.get()
      assert length(state.events) == 1
      assert hd(state.events).type == :check
    end
  end

  describe "clear/0" do
    test "removes all events" do
      Event.new(:a, :first, nil) |> State.append()
      Event.new(:b, :second, nil) |> State.append()
      assert length(State.events()) == 2

      assert :ok = State.clear()
      assert State.events() == []
    end

    test "get returns empty state after clear" do
      Event.new(:a, :first, nil) |> State.append()
      assert :ok = State.clear()
      assert State.get() == %{events: []}
    end

    test "subscriber receives {:muse_events_cleared} on clear" do
      :ok = State.subscribe()
      Event.new(:a, :first, nil) |> State.append()
      # Flush the append broadcast
      assert_received {:muse_event, _}

      assert :ok = State.clear()
      assert_received {:muse_events_cleared}
    end
  end

  describe "subscribe/0 + broadcast" do
    test "subscriber receives {:muse_event, event} on append" do
      :ok = State.subscribe()
      event = Event.new(:pub, :broadcast, %{payload: 42})
      :ok = State.append(event)

      assert_received {:muse_event, ^event}
    end

    test "non-subscriber does NOT receive broadcast" do
      # Deliberately not calling subscribe/0
      event = Event.new(:pub, :silent, nil)
      :ok = State.append(event)

      refute_received {:muse_event, _}
    end
  end

  describe "session-scoped subscribe/1 + append/2" do
    test "subscribe/0 subscribes to the default session topic" do
      :ok = State.subscribe()
      event = Event.new(:test, :default_topic, nil)
      :ok = State.append(event)

      assert_received {:muse_event, ^event}
    end

    test "subscribe/1 subscribes to a session-scoped topic" do
      :ok = State.subscribe("diag-42")
      event = Event.new(:test, :scoped, nil)
      :ok = State.append(event, "diag-42")

      assert_received {:muse_event, ^event}
    end

    test "session-scoped subscriber does NOT receive default session events" do
      :ok = State.subscribe("diag-99")
      event = Event.new(:test, :default_only, nil)
      :ok = State.append(event)

      refute_received {:muse_event, _}
    end

    test "append/2 broadcasts on session-scoped topic" do
      :ok = State.subscribe("diag-7")
      event = Event.new(:test, :session_broadcast, nil)
      :ok = State.append(event, "diag-7")

      # Receive the event from the session-scoped topic
      assert_received {:muse_event, ^event}
    end

    test "append/2 broadcasts on global topic for backward compat" do
      # Subscribe directly to the global topic
      Phoenix.PubSub.subscribe(Muse.PubSub, "muse:events")
      event = Event.new(:test, :global_broadcast, nil)
      :ok = State.append(event, "diag-7")

      # Global topic subscribers still receive events regardless of session_id
      assert_received {:muse_event, ^event}
    end

    test "append/1 with default session_id broadcasts on default topic" do
      :ok = State.subscribe()
      event = Event.new(:test, :default_append, nil)
      :ok = State.append(event)

      assert_received {:muse_event, ^event}
    end

    test "unsubscribe/1 removes session-scoped subscription" do
      :ok = State.subscribe("diag-55")
      :ok = State.unsubscribe("diag-55")
      event = Event.new(:test, :after_unsub, nil)
      :ok = State.append(event, "diag-55")

      refute_received {:muse_event, _}
    end
  end
end
