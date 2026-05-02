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
  end
end
