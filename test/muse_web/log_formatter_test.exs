defmodule MuseWeb.LogFormatterTest do
  use ExUnit.Case, async: true

  alias MuseWeb.LogFormatter
  alias Muse.LogEntry

  # -- Helpers ------------------------------------------------------------------

  defp make_entry(level, message, metadata \\ %{}, source \\ :app) do
    LogEntry.new(level, message, metadata, source)
  end

  # -- Filtering ----------------------------------------------------------------

  describe "filtered_logs/3" do
    test "returns all logs with filter 'all'" do
      logs = [
        make_entry(:info, "info msg"),
        make_entry(:error, "error msg"),
        make_entry(:debug, "debug msg")
      ]

      result = LogFormatter.filtered_logs(logs, "all", "")
      assert length(result) == 3
    end

    test "filters by level" do
      logs = [
        make_entry(:info, "info msg"),
        make_entry(:error, "error msg"),
        make_entry(:warning, "warn msg"),
        make_entry(:critical, "critical msg"),
        make_entry(:debug, "debug msg")
      ]

      assert length(LogFormatter.filtered_logs(logs, "errors", "")) == 2
      assert length(LogFormatter.filtered_logs(logs, "warnings", "")) == 1
      assert length(LogFormatter.filtered_logs(logs, "info", "")) == 1
      assert length(LogFormatter.filtered_logs(logs, "debug", "")) == 1
    end

    test "errors filter includes critical" do
      logs = [make_entry(:error, "err"), make_entry(:critical, "crit"), make_entry(:info, "inf")]
      result = LogFormatter.filtered_logs(logs, "errors", "")
      assert length(result) == 2
    end

    test "searches by level, source, message, metadata" do
      logs = [
        make_entry(:info, "hello world", %{}, :runtime),
        make_entry(:error, "something failed", %{code: 500}, :app),
        make_entry(:debug, "debug trace", %{}, :app)
      ]

      # Search by message
      assert length(LogFormatter.filtered_logs(logs, "all", "hello")) == 1
      # Search by source
      assert length(LogFormatter.filtered_logs(logs, "all", "runtime")) == 1
      # Search by level
      assert length(LogFormatter.filtered_logs(logs, "all", "error")) == 1
      # Search by metadata
      assert length(LogFormatter.filtered_logs(logs, "all", "500")) == 1
    end

    test "combines filter and search" do
      logs = [
        make_entry(:error, "connection failed"),
        make_entry(:error, "timeout"),
        make_entry(:info, "connection ok")
      ]

      result = LogFormatter.filtered_logs(logs, "errors", "connection")
      assert length(result) == 1
    end

    test "empty search returns all" do
      logs = [make_entry(:info, "a"), make_entry(:error, "b")]
      assert length(LogFormatter.filtered_logs(logs, "all", "")) == 2
      assert length(LogFormatter.filtered_logs(logs, "all", nil)) == 2
    end
  end

  # -- Valid log filters --------------------------------------------------------

  describe "valid_log_filter?/1" do
    test "accepts valid filters" do
      for f <- ~w(all errors warnings info debug) do
        assert LogFormatter.valid_log_filter?(f)
      end
    end

    test "rejects invalid filters" do
      refute LogFormatter.valid_log_filter?("invalid")
      refute LogFormatter.valid_log_filter?("warning")
      refute LogFormatter.valid_log_filter?("error")
    end
  end

  # -- Display helpers ----------------------------------------------------------

  describe "log_level_display/1" do
    test "capitalizes level names" do
      assert LogFormatter.log_level_display(:debug) == "Debug"
      assert LogFormatter.log_level_display(:info) == "Info"
      assert LogFormatter.log_level_display(:warning) == "Warning"
      assert LogFormatter.log_level_display(:error) == "Error"
      assert LogFormatter.log_level_display(:critical) == "Critical"
    end
  end

  describe "log_badge_class/1" do
    test "returns badge class per level" do
      assert LogFormatter.log_badge_class(:debug) == "log-badge log-badge-debug"
      assert LogFormatter.log_badge_class(:info) == "log-badge log-badge-info"
      assert LogFormatter.log_badge_class(:warning) == "log-badge log-badge-warning"
      assert LogFormatter.log_badge_class(:error) == "log-badge log-badge-error"
      assert LogFormatter.log_badge_class(:critical) == "log-badge log-badge-critical"
    end
  end

  describe "log_row_class/1" do
    test "error/critical rows get error class" do
      assert LogFormatter.log_row_class(:error) == "log-row log-row-error"
      assert LogFormatter.log_row_class(:critical) == "log-row log-row-error"
    end

    test "warning rows get warning class" do
      assert LogFormatter.log_row_class(:warning) == "log-row log-row-warning"
    end

    test "other levels get default class" do
      assert LogFormatter.log_row_class(:info) == "log-row"
      assert LogFormatter.log_row_class(:debug) == "log-row"
    end
  end

  describe "log_timestamp/1" do
    test "formats DateTime to HH:MM:SS" do
      {:ok, dt} = DateTime.new(~D[2025-01-15], ~T[10:30:45], "Etc/UTC")
      assert LogFormatter.log_timestamp(dt) == "10:30:45"
    end

    test "returns dash for nil" do
      assert LogFormatter.log_timestamp(nil) == "—"
    end
  end

  # -- JSON formatting ---------------------------------------------------------

  describe "format_log_json/1" do
    test "produces valid JSON for a log entry" do
      entry = make_entry(:info, "test log", %{key: "val"})
      json = LogFormatter.format_log_json(entry)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["level"] == "info"
      assert decoded["message"] == "test log"
      assert decoded["metadata"]["key"] == "val"
    end
  end

  describe "format_logs_json/1" do
    test "produces valid JSON for a list of logs" do
      logs = [
        make_entry(:info, "first"),
        make_entry(:error, "second")
      ]

      json = LogFormatter.format_logs_json(logs)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["total_count"] == 2
      assert length(decoded["logs"]) == 2
    end
  end

  describe "log_entry_to_map/1" do
    test "converts entry to JSON-safe map" do
      entry = make_entry(:error, "fail", %{code: 500}, :runtime)
      map = LogFormatter.log_entry_to_map(entry)

      assert map["level"] == "error"
      assert map["source"] == "runtime"
      assert map["message"] == "fail"
      assert map["metadata"]["code"] == 500
    end

    test "handles entry with non-DateTime timestamp gracefully" do
      entry = %Muse.LogEntry{make_entry(:info, "bad ts") | timestamp: "not-a-datetime"}
      map = LogFormatter.log_entry_to_map(entry)
      assert map["timestamp"] == "not-a-datetime"
    end

    test "handles entry with nil timestamp" do
      entry = %Muse.LogEntry{make_entry(:info, "nil ts") | timestamp: nil}
      map = LogFormatter.log_entry_to_map(entry)
      assert map["timestamp"] == nil
    end

    test "handles entry with tuple source without raising" do
      entry = %Muse.LogEntry{make_entry(:info, "tuple src") | source: {:host, :runtime}}
      map = LogFormatter.log_entry_to_map(entry)
      assert is_binary(map["source"])
      assert map["source"] =~ "host"
    end

    test "handles fully malformed entry without raising" do
      entry = %Muse.LogEntry{
        id: 99,
        timestamp: {:not, :a_datetime},
        level: {:weird, :level},
        source: {:tuple, :source},
        message: {:not, :a, :string},
        metadata: %{}
      }

      map = LogFormatter.log_entry_to_map(entry)
      assert is_binary(map["level"])
      assert is_binary(map["source"])
      assert is_binary(map["message"])
      assert is_binary(map["timestamp"])

      json = LogFormatter.format_log_json(entry)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["id"] == 99
    end
  end

  describe "log_matches_search? source robustness" do
    test "search works with binary source" do
      entry = %Muse.LogEntry{make_entry(:info, "hello") | source: "my_source"}
      result = LogFormatter.filtered_logs([entry], "all", "my_source")
      assert length(result) == 1
    end

    test "search works with atom source" do
      entry = make_entry(:info, "hello", %{}, :runtime)
      result = LogFormatter.filtered_logs([entry], "all", "runtime")
      assert length(result) == 1
    end
  end
end
