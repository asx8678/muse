defmodule Muse.LogBuffer.LoggerHandlerTest do
  use ExUnit.Case, async: false

  alias Muse.LogBuffer.LoggerHandler

  describe "install/1" do
    test "installs the handler idempotently" do
      # Clean up first
      LoggerHandler.remove()

      assert :ok = LoggerHandler.install()
      # Idempotent
      assert :ok = LoggerHandler.install()

      LoggerHandler.remove()
    end
  end

  describe "remove/0" do
    test "removes the handler idempotently" do
      LoggerHandler.install()
      assert :ok = LoggerHandler.remove()
      # Idempotent
      assert :ok = LoggerHandler.remove()
    end
  end

  describe "format_message/1" do
    test "formats string messages" do
      assert is_binary(LoggerHandler.format_message({:string, "hello"}))
    end

    test "formats report messages" do
      assert is_binary(LoggerHandler.format_message({:report, %{key: "value"}}))
    end

    test "formats format-args messages" do
      msg = LoggerHandler.format_message({"Hello ~s", ["world"]})
      assert is_binary(msg)
    end

    test "formats plain chardata" do
      assert is_binary(LoggerHandler.format_message("plain string"))
    end
  end

  describe "normalize_level/1" do
    test "normalizes known levels" do
      assert LoggerHandler.normalize_level(:debug) == :debug
      assert LoggerHandler.normalize_level(:info) == :info
      assert LoggerHandler.normalize_level(:notice) == :info
      assert LoggerHandler.normalize_level(:warn) == :warning
      assert LoggerHandler.normalize_level(:warning) == :warning
      assert LoggerHandler.normalize_level(:error) == :error
      assert LoggerHandler.normalize_level(:critical) == :critical
      assert LoggerHandler.normalize_level(:alert) == :critical
      assert LoggerHandler.normalize_level(:emergency) == :critical
    end

    test "ignores unknown levels" do
      assert LoggerHandler.normalize_level(:none) == :ignore
      assert LoggerHandler.normalize_level(:all) == :ignore
    end
  end
end
