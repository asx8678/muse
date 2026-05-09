defmodule Muse.BoundsTest do
  use ExUnit.Case, async: false

  alias Muse.Bounds

  describe "default values" do
    test "session_events returns positive integer" do
      assert is_integer(Bounds.session_events())
      assert Bounds.session_events() > 0
    end

    test "command_history returns positive integer" do
      assert is_integer(Bounds.command_history())
      assert Bounds.command_history() > 0
    end

    test "toasts returns positive integer" do
      assert is_integer(Bounds.toasts())
      assert Bounds.toasts() > 0
    end

    test "streaming_buffer_bytes returns positive integer" do
      assert is_integer(Bounds.streaming_buffer_bytes())
      assert Bounds.streaming_buffer_bytes() > 0
    end

    test "diagnostics returns positive integer" do
      assert is_integer(Bounds.diagnostics())
      assert Bounds.diagnostics() > 0
    end
  end

  describe "app-env overrides" do
    setup do
      original = Application.get_env(:muse, :bounds)
      on_exit(fn -> Application.put_env(:muse, :bounds, original) end)
      :ok
    end

    test "individual cap can be overridden via app env" do
      Application.put_env(:muse, :bounds, %{toasts: 5})
      assert Bounds.toasts() == 5
      # Others still fall back to defaults
      assert Bounds.command_history() > 0
    end

    test "all/0 returns merged map" do
      Application.put_env(:muse, :bounds, %{toasts: 7})
      result = Bounds.all()
      assert result.toasts == 7
      assert Map.has_key?(result, :session_events)
      assert Map.has_key?(result, :command_history)
      assert Map.has_key?(result, :streaming_buffer_bytes)
      assert Map.has_key?(result, :diagnostics)
    end

    test "non-map env value is ignored safely" do
      Application.put_env(:muse, :bounds, toasts: 99)
      # Keyword list is not a map, so overrides should be empty
      assert is_integer(Bounds.toasts())
    end

    test "invalid cap values are ignored safely" do
      Application.put_env(:muse, :bounds, %{
        toasts: 0,
        command_history: "many",
        session_events: -1,
        unknown: 123
      })

      assert is_integer(Bounds.toasts())
      assert Bounds.toasts() > 0
      assert is_integer(Bounds.command_history())
      assert Bounds.command_history() > 0
      all = Bounds.all()
      assert all.session_events > 0
      refute Map.has_key?(all, :unknown)
    end

    test "nil env value is ignored safely" do
      Application.put_env(:muse, :bounds, nil)
      assert is_integer(Bounds.toasts())
    end
  end

  describe "trim_newest_first/2" do
    test "returns list unchanged when within cap" do
      assert Bounds.trim_newest_first([1, 2, 3], 5) == [1, 2, 3]
    end

    test "returns list unchanged when exactly at cap" do
      assert Bounds.trim_newest_first([1, 2, 3], 3) == [1, 2, 3]
    end

    test "drops oldest elements when over cap" do
      assert Bounds.trim_newest_first([1, 2, 3, 4, 5], 3) == [3, 4, 5]
    end

    test "empty list returns empty" do
      assert Bounds.trim_newest_first([], 3) == []
    end

    test "single element list" do
      assert Bounds.trim_newest_first([42], 3) == [42]
    end
  end

  describe "trim_streaming_buffer/2" do
    test "returns buffer unchanged when within byte cap" do
      assert Bounds.trim_streaming_buffer("hello", 100) == "hello"
    end

    test "truncates oldest content when over byte cap" do
      buffer = String.duplicate("a", 100)
      result = Bounds.trim_streaming_buffer(buffer, 50)
      assert byte_size(result) <= 50
      # Should contain the tail (most recent)
      assert result =~ String.duplicate("a", 50)
    end

    test "empty string returns empty" do
      assert Bounds.trim_streaming_buffer("", 100) == ""
    end

    test "preserves valid UTF-8 after truncation" do
      # Multi-byte emoji characters
      buffer = String.duplicate("🌟", 100)
      result = Bounds.trim_streaming_buffer(buffer, 50)
      assert String.valid?(result)
    end

    test "result never exceeds max_bytes" do
      buffer = String.duplicate("x", 1000)
      result = Bounds.trim_streaming_buffer(buffer, 100)
      assert byte_size(result) <= 100
    end
  end
end
