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
end
