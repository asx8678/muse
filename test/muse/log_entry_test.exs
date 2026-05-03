defmodule Muse.LogEntryTest do
  use ExUnit.Case, async: true

  alias Muse.LogEntry

  describe "new/4" do
    test "creates entry with defaults" do
      entry = LogEntry.new(:info, "hello")
      assert %LogEntry{} = entry
      assert entry.id > 0
      assert entry.timestamp != nil
      assert entry.level == :info
      assert entry.source == :app
      assert entry.message == "hello"
      assert entry.metadata == %{}
    end

    test "creates entry with custom source and metadata" do
      entry = LogEntry.new(:error, "fail", %{code: 500}, :runtime)
      assert entry.level == :error
      assert entry.source == :runtime
      # Sanitizer preserves integer values
      assert entry.metadata[:code] == 500
    end

    test "normalizes :warn to :warning" do
      entry = LogEntry.new(:warn, "be careful")
      assert entry.level == :warning
    end

    test "normalizes unknown level to :info" do
      entry = LogEntry.new(:trace, "something")
      assert entry.level == :info
    end

    test "converts non-string message to string" do
      entry = LogEntry.new(:info, 42)
      assert entry.message == "42"
    end

    test "generates unique IDs" do
      e1 = LogEntry.new(:info, "a")
      e2 = LogEntry.new(:info, "b")
      assert e1.id != e2.id
    end
  end
end
