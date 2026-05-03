defmodule MuseWeb.ExportJSONTest do
  use ExUnit.Case, async: true

  alias MuseWeb.ExportJSON

  # -- json_safe/1 tests ----

  describe "json_safe/1" do
    test "passes through strings" do
      assert ExportJSON.json_safe("hello") == "hello"
    end

    test "passes through booleans" do
      assert ExportJSON.json_safe(true) == true
      assert ExportJSON.json_safe(false) == false
    end

    test "passes through numbers" do
      assert ExportJSON.json_safe(42) == 42
      assert ExportJSON.json_safe(3.14) == 3.14
    end

    test "passes through nil" do
      assert ExportJSON.json_safe(nil) == nil
    end

    test "converts atoms to strings" do
      assert ExportJSON.json_safe(:error) == "error"
    end

    test "converts DateTimes to ISO8601" do
      {:ok, dt} = DateTime.new(~D[2025-01-15], ~T[10:30:00], "Etc/UTC")
      assert ExportJSON.json_safe(dt) == "2025-01-15T10:30:00Z"
    end

    test "converts Dates to ISO8601" do
      assert ExportJSON.json_safe(~D[2025-01-15]) == "2025-01-15"
    end

    test "converts Times to ISO8601" do
      assert ExportJSON.json_safe(~T[10:30:00]) == "10:30:00"
    end

    test "converts tuples to lists" do
      assert ExportJSON.json_safe({1, 2, 3}) == [1, 2, 3]
    end

    test "converts lists recursively" do
      assert ExportJSON.json_safe([:a, :b]) == ["a", "b"]
    end

    test "converts maps with atom keys to string keys" do
      result = ExportJSON.json_safe(%{foo: "bar"})
      assert result == %{"foo" => "bar"}
    end

    test "converts structs with __struct__ key" do
      result = ExportJSON.json_safe(%{__struct__: MyModule, value: 42})
      assert result["__struct__"] == "Elixir.MyModule"
      assert result["value"] == 42
    end

    test "inspects PIDs as fallback" do
      pid = self()
      result = ExportJSON.json_safe(pid)
      assert is_binary(result)
      assert String.contains?(result, "#PID")
    end
  end

  # -- json_key/1 tests ----

  describe "json_key/1" do
    test "passes through string keys" do
      assert ExportJSON.json_key("foo") == "foo"
    end

    test "converts atom keys to strings" do
      assert ExportJSON.json_key(:foo) == "foo"
    end

    test "converts number keys to strings" do
      assert ExportJSON.json_key(42) == "42"
    end

    test "converts DateTime keys to ISO8601" do
      {:ok, dt} = DateTime.new(~D[2025-01-15], ~T[10:30:00], "Etc/UTC")
      assert ExportJSON.json_key(dt) == "2025-01-15T10:30:00Z"
    end

    test "inspects unknown key types" do
      result = ExportJSON.json_key({1, 2})
      assert is_binary(result)
    end
  end

  # -- build_diagnostics_payload/1 tests ----

  describe "build_diagnostics_payload/1" do
    test "builds a valid map from assigns" do
      assigns = %{
        workspace: "/test/path",
        reload_status: %{status: :active},
        state: %{events: []},
        diagnostics: [],
        beam_stats: %{process_count: 100}
      }

      result = ExportJSON.build_diagnostics_payload(assigns)

      assert result["app"] == "Muse"
      assert result["workspace"] == "/test/path"
      assert result["backend_status"] == "connected"
      assert result["reload_status"] == "active"
      assert result["events_count"] == 0
      assert result["diagnostics_count"] == 0
      assert result["diagnostics"] == []
    end

    test "payload is JSON-encodable" do
      assigns = %{
        workspace: "/test",
        reload_status: %{status: :active},
        state: %{events: []},
        diagnostics: [],
        beam_stats: %{process_count: 100}
      }

      payload = ExportJSON.build_diagnostics_payload(assigns)
      json = Jason.encode!(payload)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["app"] == "Muse"
    end

    test "empty map returns payload with defaults instead of raising" do
      result = ExportJSON.build_diagnostics_payload(%{})

      assert result["workspace"] == "unknown"
      assert result["reload_status"] == "unknown"
      assert result["events_count"] == 0
      assert result["diagnostics_count"] == 0
      assert result["diagnostics"] == []
      assert result["beam_stats"] == %{}
    end

    test "empty map payload is JSON-encodable" do
      payload = ExportJSON.build_diagnostics_payload(%{})
      json = Jason.encode!(payload)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["app"] == "Muse"
      assert decoded["workspace"] == "unknown"
    end

    test "partial assigns use defaults for missing keys" do
      result = ExportJSON.build_diagnostics_payload(%{workspace: "/custom"})

      assert result["workspace"] == "/custom"
      assert result["reload_status"] == "unknown"
      assert result["events_count"] == 0
    end

    test "state with missing events key defaults to empty list" do
      result = ExportJSON.build_diagnostics_payload(%{state: %{}})
      assert result["events_count"] == 0
    end

    test "includes logs_count when logs present" do
      log = %{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :info,
        source: :app,
        message: "test",
        metadata: %{}
      }

      result = ExportJSON.build_diagnostics_payload(%{logs: [log]})
      assert result["logs_count"] == 1
      assert length(result["logs_sample"]) == 1
    end

    test "logs_count defaults to 0 when logs not in assigns" do
      result = ExportJSON.build_diagnostics_payload(%{})
      assert result["logs_count"] == 0
      assert result["logs_sample"] == []
    end

    test "logs_sample capped at 20 entries" do
      logs =
        for i <- 1..25,
            do: %{
              id: i,
              timestamp: DateTime.utc_now(),
              level: :info,
              source: :app,
              message: "log #{i}",
              metadata: %{}
            }

      result = ExportJSON.build_diagnostics_payload(%{logs: logs})
      assert result["logs_count"] == 25
      assert length(result["logs_sample"]) == 20
    end

    test "includes agent_runtime snapshot when present" do
      runtime = %{
        status: :disconnected,
        endpoint: "ws://localhost:4000",
        last_error: nil,
        health: :inactive
      }

      result = ExportJSON.build_diagnostics_payload(%{agent_runtime: runtime})
      assert result["agent_runtime"]["status"] == "disconnected"
    end

    test "agent_runtime defaults to empty map" do
      result = ExportJSON.build_diagnostics_payload(%{})
      assert result["agent_runtime"] == %{}
    end

    test "logs_sample filters out nil entries from malformed logs" do
      logs = [%{id: 1, level: :info, message: "ok"}, "not a map", nil]
      result = ExportJSON.build_diagnostics_payload(%{logs: logs})
      # log_entry_to_safe_map returns nil for non-maps, so they should be filtered
      assert result["logs_count"] == 3
      assert length(result["logs_sample"]) == 1
    end
  end
end
