defmodule MuseWeb.ConsoleCommandTest do
  use ExUnit.Case, async: true

  alias MuseWeb.ConsoleCommand

  describe "normalize_filter/1" do
    test "accepts valid filter names" do
      for filter <- ~w(errors warnings info all) do
        assert {:ok, ^filter} = ConsoleCommand.normalize_filter(filter)
      end
    end

    test "normalizes singular to plural for errors" do
      assert ConsoleCommand.normalize_filter("error") == {:ok, "errors"}
    end

    test "normalizes singular to plural for warnings" do
      assert ConsoleCommand.normalize_filter("warning") == {:ok, "warnings"}
    end

    test "returns error for invalid filter" do
      assert ConsoleCommand.normalize_filter("invalid") == {:error, "invalid"}
    end
  end

  describe "palette_actions/0" do
    test "returns list of palette action maps" do
      actions = ConsoleCommand.palette_actions()
      assert is_list(actions)
      assert length(actions) > 0

      for action <- actions do
        assert Map.has_key?(action, :id)
        assert Map.has_key?(action, :label)
        assert Map.has_key?(action, :icon)
      end
    end

    test "includes expected palette actions" do
      actions = ConsoleCommand.palette_actions()
      ids = Enum.map(actions, & &1.id)

      assert "open_events" in ids
      assert "open_files" in ids
      assert "open_agents" in ids
      assert "open_stats" in ids
      assert "open_settings" in ids
      assert "open_logs" in ids
      assert "simulate_event" in ids
      assert "clear_events" in ids
      assert "export_events" in ids
      assert "copy_diagnostics" in ids
      assert "clear_logs" in ids
      assert "export_logs" in ids
      assert "connect_runtime" in ids
      assert "disconnect_runtime" in ids
    end
  end

  describe "normalize_log_filter/1" do
    test "accepts valid log filter names" do
      for filter <- ~w(all errors warnings info debug) do
        assert {:ok, ^filter} = ConsoleCommand.normalize_log_filter(filter)
      end
    end

    test "normalizes singular to plural for errors" do
      assert ConsoleCommand.normalize_log_filter("error") == {:ok, "errors"}
    end

    test "normalizes singular to plural for warnings" do
      assert ConsoleCommand.normalize_log_filter("warning") == {:ok, "warnings"}
    end

    test "returns error for invalid filter" do
      assert ConsoleCommand.normalize_log_filter("invalid") == {:error, "invalid"}
    end
  end
end
