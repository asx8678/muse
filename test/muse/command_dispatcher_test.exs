defmodule Muse.CommandDispatcherTest do
  use ExUnit.Case, async: true

  alias Muse.CommandDispatcher

  # Most dispatch tests are pure — no process dependencies needed
  # because context provides data and Backend is only called for
  # side-effect commands (clear_logs, connect_runtime, etc.)

  describe "dispatch/3 — :help" do
    test "returns help text" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:help, nil, %{})
      assert output =~ "Available commands"
      assert effects == []
    end
  end

  describe "dispatch/3 — :events" do
    test "counts events from context" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "hi"}
        }
      ]

      {:ok, output, effects} = CommandDispatcher.dispatch(:events, nil, %{events: events})
      assert output =~ "1 event(s)"
      assert effects == []
    end

    test "returns 0 when context has no events key" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:events, nil, %{})
      assert output =~ "0 event(s)"
    end

    test "shows per-event details for small lists" do
      events = [
        %Muse.Event{
          id: 1,
          timestamp: DateTime.utc_now(),
          source: :cli,
          type: :user_message,
          data: %{text: "hi"}
        }
      ]

      {:ok, output, _effects} = CommandDispatcher.dispatch(:events, nil, %{events: events})
      assert output =~ "[cli]"
      assert output =~ "hi"
    end
  end

  describe "dispatch/3 — :agents" do
    test "reports unavailable when agent_snapshot is :unavailable" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:agents, nil, %{agent_snapshot: :unavailable})

      assert output =~ "unavailable"
    end

    test "reports agent count from snapshot" do
      snapshot = %{agents: [%{name: :a}, %{name: :b}]}

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:agents, nil, %{agent_snapshot: snapshot})

      assert output =~ "2 Muses"
    end
  end

  describe "dispatch/3 — :workspace" do
    test "uses workspace from context" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:workspace, nil, %{workspace: "/tmp/proj"})

      assert output =~ "/tmp/proj"
    end

    test "falls back to Backend.safe_workspace_root" do
      # Backend returns "unknown" when Workspace not running
      {:ok, output, _effects} = CommandDispatcher.dispatch(:workspace, nil, %{})
      assert is_binary(output)
    end
  end

  describe "dispatch/3 — :stats" do
    test "returns BEAM stats summary" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:stats, nil, %{})
      assert output =~ "BEAM Stats:"
      assert output =~ "processes"
      assert output =~ "memory"
      assert {:refresh, :stats} in effects
    end
  end

  describe "dispatch/3 — :diagnostics" do
    test "reports no diagnostics" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:diagnostics, nil, %{diagnostics: []})
      assert output =~ "No diagnostics"
    end

    test "reports diagnostic counts by level" do
      d1 = %{id: 1, level: :error, message: "boom", timestamp: DateTime.utc_now(), metadata: %{}}

      d2 = %{
        id: 2,
        level: :warning,
        message: "careful",
        timestamp: DateTime.utc_now(),
        metadata: %{}
      }

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:diagnostics, nil, %{diagnostics: [d1, d2]})

      assert output =~ "2"
      assert output =~ "1 error"
      assert output =~ "1 warning"
    end
  end

  describe "dispatch/3 — :reload_status" do
    test "shows unavailable when status is unavailable" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:reload_status, nil, %{reload_status: %{status: :unavailable}})

      assert output =~ "Unavailable"
    end

    test "shows active with generation" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:reload_status, nil, %{
          reload_status: %{status: :active, generation: 5}
        })

      assert output =~ "Active"
      assert output =~ "gen 5"
    end
  end

  describe "dispatch/3 — :runtime" do
    test "shows disconnected status" do
      runtime = %{status: :disconnected, endpoint: "http://localhost:8080"}

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:runtime, nil, %{agent_runtime: runtime})

      assert output =~ "Disconnected"
      assert output =~ "localhost"
    end

    test "shows connected status" do
      runtime = %{status: :connected, endpoint: "http://localhost:8080"}

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:runtime, nil, %{agent_runtime: runtime})

      assert output =~ "Connected"
    end

    test "falls back to Backend snapshot when not in context" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:runtime, nil, %{})
      assert is_binary(output)
    end
  end

  describe "dispatch/3 — :clear_events" do
    test "returns cleared message with refresh effect" do
      start_supervised!({Muse.State, []})

      {:ok, output, effects} = CommandDispatcher.dispatch(:clear_events, nil, %{})
      assert output =~ "Events cleared"
      assert {:refresh, :events} in effects
      assert {:toast, :info, "Events cleared"} in effects
    end
  end

  describe "dispatch/3 — :search_events" do
    test "without args returns usage" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:search_events, nil, %{})
      assert output =~ "Usage:"
      assert {:switch_tab, "events"} in effects
    end

    test "with args sets search and switches tab" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:search_events, "hello", %{})
      assert output =~ "hello"
      assert {:set_event_search, "hello"} in effects
      assert {:switch_tab, "events"} in effects
    end
  end

  describe "dispatch/3 — :filter_events" do
    test "without args shows current filter" do
      {:ok, output, effects} =
        CommandDispatcher.dispatch(:filter_events, nil, %{event_filter: "errors"})

      assert output =~ "current: Errors"
      assert {:switch_tab, "events"} in effects
    end

    test "valid filter sets effect" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:filter_events, "errors", %{})
      assert output =~ "Errors"
      assert {:set_event_filter, "errors"} in effects
    end

    test "invalid filter returns error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:filter_events, "bogus", %{})
      assert output =~ "Unknown filter"
      assert {:switch_tab, "events"} in effects
    end

    test "singular 'error' normalizes to 'errors'" do
      {:ok, _output, effects} = CommandDispatcher.dispatch(:filter_events, "error", %{})
      assert {:set_event_filter, "errors"} in effects
    end
  end

  describe "dispatch/3 — :search_logs" do
    test "with args sets log search" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:search_logs, "warn", %{})
      assert output =~ "warn"
      assert {:set_log_search, "warn"} in effects
      assert {:switch_tab, "logs"} in effects
    end
  end

  describe "dispatch/3 — :filter_logs" do
    test "valid filter sets effect" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:filter_logs, "debug", %{})
      assert output =~ "Debug"
      assert {:set_log_filter, "debug"} in effects
    end

    test "invalid filter returns error" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:filter_logs, "nope", %{})
      assert output =~ "Unknown filter"
    end
  end

  describe "dispatch/3 — open tabs" do
    test "open_events switches tab" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:open_events, nil, %{})
      assert output =~ "Events tab"
      assert {:switch_tab, "events"} in effects
    end

    test "open_logs switches tab" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:open_logs, nil, %{})
      assert output =~ "Logs tab"
      assert {:switch_tab, "logs"} in effects
    end
  end

  describe "dispatch/3 — :logs" do
    test "counts logs from context" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:logs, nil, %{logs: [%{}, %{}, %{}]})
      assert output =~ "3 log entry(s)"
    end
  end

  describe "dispatch/3 — :copy_diagnostics" do
    test "returns error when context lacks diagnostics" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:copy_diagnostics, nil, %{})
      assert output =~ "not available"
    end

    test "returns clipboard effect when diagnostics present" do
      ctx = %{
        diagnostics: [],
        workspace: "/tmp",
        reload_status: %{status: :active, generation: 1},
        logs: [],
        beam_stats: %{}
      }

      {:ok, output, effects} = CommandDispatcher.dispatch(:copy_diagnostics, nil, ctx)
      assert output =~ "copied"
      assert Enum.any?(effects, &match?({:copy_to_clipboard, _, _}, &1))
    end
  end

  describe "dispatch/3 — :export_events" do
    test "returns error when context lacks events" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:export_events, nil, %{})
      assert output =~ "not available"
    end

    test "returns clipboard effect with JSON" do
      event = %Muse.Event{
        id: 1,
        timestamp: DateTime.utc_now(),
        source: :cli,
        type: :user_message,
        data: %{text: "hello"}
      }

      ctx = %{events: [event], event_filter: "all", event_search: ""}

      {:ok, output, effects} = CommandDispatcher.dispatch(:export_events, nil, ctx)
      assert output =~ "1 events exported"
      assert Enum.any?(effects, &match?({:copy_to_clipboard, _, _}, &1))
    end
  end

  describe "dispatch/3 — :export_logs" do
    test "returns error when context lacks logs" do
      {:error, output, _effects} = CommandDispatcher.dispatch(:export_logs, nil, %{})
      assert output =~ "not available"
    end

    test "returns clipboard effect with JSON" do
      log = %Muse.LogEntry{
        id: 1,
        timestamp: DateTime.utc_now(),
        level: :info,
        source: :app,
        message: "test"
      }

      ctx = %{logs: [log], log_filter: "all", log_search: ""}

      {:ok, output, effects} = CommandDispatcher.dispatch(:export_logs, nil, ctx)
      assert output =~ "1 logs exported"
      assert Enum.any?(effects, &match?({:copy_to_clipboard, _, _}, &1))
    end
  end

  describe "dispatch/3 — :clear_history" do
    test "returns cleared message" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:clear_history, nil, %{})
      assert output =~ "Command history cleared"
      assert effects == []
    end
  end

  describe "dispatch/3 — catch-all" do
    test "unknown action returns error" do
      {:error, output, effects} = CommandDispatcher.dispatch(:nonexistent, nil, %{})
      assert output =~ "Unknown command action"
      assert effects == []
    end
  end

  describe "normalize_filter/1" do
    test "accepts valid filters" do
      for f <- ~w(errors warnings info all) do
        assert {:ok, ^f} = CommandDispatcher.normalize_filter(f)
      end
    end

    test "normalizes singular" do
      assert {:ok, "errors"} = CommandDispatcher.normalize_filter("error")
      assert {:ok, "warnings"} = CommandDispatcher.normalize_filter("warning")
    end

    test "rejects invalid" do
      assert {:error, "invalid"} = CommandDispatcher.normalize_filter("invalid")
    end
  end

  describe "normalize_log_filter/1" do
    test "accepts valid log filters" do
      for f <- ~w(all errors warnings info debug) do
        assert {:ok, ^f} = CommandDispatcher.normalize_log_filter(f)
      end
    end

    test "normalizes singular" do
      assert {:ok, "errors"} = CommandDispatcher.normalize_log_filter("error")
      assert {:ok, "warnings"} = CommandDispatcher.normalize_log_filter("warning")
    end

    test "rejects invalid" do
      assert {:error, "invalid"} = CommandDispatcher.normalize_log_filter("invalid")
    end
  end
end
