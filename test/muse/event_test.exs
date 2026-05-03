defmodule Muse.EventTest do
  use ExUnit.Case, async: true

  alias Muse.Event

  describe "new/3" do
    test "returns a %Muse.Event{} struct" do
      event = Event.new(:workspace, :created, %{path: "/tmp"})
      assert %Event{} = event
    end

    test "populates all fields" do
      event = Event.new(:cli, :started, %{repl: true})

      assert is_integer(event.id)
      assert event.id > 0
      assert %DateTime{} = event.timestamp
      assert event.source == :cli
      assert event.type == :started
      assert event.data == %{repl: true}
    end

    test "timestamp is a DateTime" do
      event = Event.new(:test, :unit, nil)
      assert event.timestamp.__struct__ == DateTime
    end

    test "IDs are unique across multiple events" do
      ids =
        for _ <- 1..100 do
          event = Event.new(:test, :unique, nil)
          event.id
        end

      assert length(Enum.uniq(ids)) == 100
    end

    test "metadata fields default to nil" do
      event = Event.new(:cli, :started, %{})

      assert event.session_id == nil
      assert event.turn_id == nil
      assert event.seq == nil
      assert event.parent_id == nil
      assert event.visibility == nil
      assert event.muse_id == nil
    end
  end

  describe "new/4" do
    test "accepts keyword metadata" do
      event =
        Event.new(:planning_muse, :assistant_delta, %{text: "..."},
          session_id: "sess_1",
          turn_id: "turn_1",
          seq: 12,
          visibility: :user
        )

      assert event.source == :planning_muse
      assert event.type == :assistant_delta
      assert event.data == %{text: "..."}
      assert event.session_id == "sess_1"
      assert event.turn_id == "turn_1"
      assert event.seq == 12
      assert event.visibility == :user
    end

    test "empty keyword list behaves like new/3" do
      event = Event.new(:cli, :started, %{repl: true}, [])

      assert is_integer(event.id)
      assert event.id > 0
      assert %DateTime{} = event.timestamp
      assert event.source == :cli
      assert event.type == :started
      assert event.data == %{repl: true}
      assert event.session_id == nil
    end

    test "allows deterministic id for testing" do
      event = Event.new(:test, :unit, nil, id: 42)
      assert event.id == 42
    end

    test "allows deterministic timestamp for testing" do
      ts = ~U[2025-01-01 00:00:00Z]
      event = Event.new(:test, :unit, nil, id: 1, timestamp: ts)
      assert event.timestamp == ts
    end

    test "sets parent_id" do
      parent = Event.new(:cli, :started, nil, id: 1)
      child = Event.new(:cli, :continued, nil, id: 2, parent_id: parent.id)
      assert child.parent_id == 1
    end

    test "sets muse_id" do
      event = Event.new(:planning_muse, :assistant_delta, %{}, muse_id: "planning_muse")
      assert event.muse_id == "planning_muse"
    end

    test "sets visibility to all valid values" do
      for vis <- Event.visibilities() do
        event = Event.new(:test, :unit, nil, visibility: vis)
        assert event.visibility == vis
      end
    end

    test "accepts arbitrary visibility value without validation" do
      # Event.new does not validate visibility — that's the caller's responsibility.
      # This mirrors how the existing Event.new/3 never validates source/type.
      event = Event.new(:test, :unit, nil, visibility: :unknown)
      assert event.visibility == :unknown
    end
  end

  describe "visibilities/0" do
    test "returns the four canonical visibility values" do
      assert Event.visibilities() == [:user, :debug, :internal, :sensitive]
    end
  end

  describe "valid_visibility?/1" do
    test "returns true for canonical values" do
      for vis <- Event.visibilities() do
        assert Event.valid_visibility?(vis)
      end
    end

    test "returns false for non-canonical values" do
      refute Event.valid_visibility?(:public)
      refute Event.valid_visibility?(nil)
      refute Event.valid_visibility?("user")
    end
  end

  describe "backward compatibility" do
    test "struct pattern matching still works with only core fields" do
      event = Event.new(:workspace, :created, %{path: "/tmp"}, id: 1)

      assert %Event{id: 1, source: :workspace, type: :created, data: %{path: "/tmp"}} = event
    end

    test "existing code using %Muse.Event{} literals still compiles" do
      # This mirrors how command_dispatcher_test and tui_test construct events
      event = %Event{
        id: 1,
        timestamp: DateTime.utc_now(),
        source: :cli,
        type: :user_message,
        data: %{text: "hi"}
      }

      assert event.source == :cli
      assert event.session_id == nil
    end
  end
end
