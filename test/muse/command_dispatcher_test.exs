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

  describe "dispatch/3 — :muses" do
    test "lists Muses from Muse.MuseRegistry" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert output =~ "Muse registry"
      assert output =~ "2 Muses available"
    end

    test "includes Planning Muse with registry description" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert output =~ "Planning Muse"
      assert output =~ "approval-gated implementation plans"
    end

    test "includes Coding Muse with registry description" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert output =~ "Coding Muse"
      assert output =~ "proposing and applying patches"
    end

    test "uses Muse-first language — no Agent/Bot/Code Puppy labels" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      refute output =~ ~r/\bAgent\b/
      refute output =~ ~r/\bBot\b/
      refute output =~ ~r/Code Puppy/
    end

    test "ignores agent_snapshot context when registry is available" do
      # Even with an agent_snapshot, the registry is the source of truth
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:muses, nil, %{agent_snapshot: :unavailable})

      assert output =~ "Planning Muse"
      assert output =~ "Coding Muse"
    end
  end

  describe "dispatch/3 — :agents (legacy alias)" do
    test "delegates to :muses and shows registry output" do
      {:ok, agents_output, _effects} = CommandDispatcher.dispatch(:agents, nil, %{})
      {:ok, muses_output, _effects} = CommandDispatcher.dispatch(:muses, nil, %{})

      assert agents_output == muses_output
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

  describe "dispatch/3 — :prompt_preview" do
    test "returns prompt bundle preview with expected sections" do
      {:ok, output, effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})

      assert output =~ "Prompt bundle"
      assert output =~ "Active Muse: Planning Muse"
      assert output =~ "Layers:"
      assert output =~ "Tools:"
      assert output =~ "Blocked tools:"
      assert effects == []
    end

    test "defaults to Planning Muse when no active muse in context" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})
      assert output =~ "Planning Muse"
    end

    test "uses prompt_bundle from context when available" do
      session =
        Muse.Session.new(
          workspace: "/tmp/test",
          id: "sess_dispatch_test",
          status: :idle
        )

      profile =
        Muse.MuseProfile.new!(
          id: :coding,
          display_name: "Coding Muse",
          role: :coding,
          prompt: "You are the Coding Muse.",
          tools: ["read_file", "patch_propose"]
        )

      bundle =
        Muse.Prompt.Assembler.build(session, profile, "test message",
          id: "pb_dispatch_ctx",
          blocked_tools: ["shell_command", "network_call"],
          project_rules?: false
        )

      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{prompt_bundle: bundle})

      assert output =~ "Coding Muse"
    end

    test "uses workspace from context in bundle" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: "/custom/workspace"})

      # Workspace appears in internal layers (not shown in preview content)
      # but the bundle should be built successfully without crashing
      assert output =~ "Prompt bundle"
      assert output =~ "Planning Muse"
    end

    test "uses active_muse from context" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{active_muse: :coding})

      assert output =~ "Coding Muse"
    end

    test "includes blocked tools in preview" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})

      assert output =~ "shell_command"
      assert output =~ "network_call"
    end

    test "does not crash with sparse context" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: "/tmp"})

      assert is_binary(output)
      assert output =~ "Prompt bundle"
    end

    test "passes args as user message" do
      {:ok, output, _effects} =
        CommandDispatcher.dispatch(:prompt_preview, "check my project", %{})

      # The user message layer should appear in the layers section
      assert output =~ "current_user_message"
    end

    test "no user-facing Agent/Bot/Code Puppy labels in preview output" do
      {:ok, output, _effects} = CommandDispatcher.dispatch(:prompt_preview, nil, %{})

      refute output =~ ~r/\bAgent\b/
      refute output =~ ~r/\bBot\b/
      refute output =~ ~r/Code Puppy/
    end

    test "does not leak raw secrets from project rules" do
      # Temp workspace with MUSE.md containing a secret
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_secret_test_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)

      :ok =
        File.write!(Path.join(tmp_dir, "MUSE.md"), "DATABASE_URL=postgres://user:pass@host/db")

      try do
        # No project_rules_home needed — project rules enabled by default
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, "sk-test-12345", %{
            workspace: tmp_dir
          })

        # Raw secrets must not appear
        refute output =~ "postgres://user:pass@host/db"
        refute output =~ "sk-test-12345"
        # Redaction marker must be present
        assert output =~ "[REDACTED]"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "project rules appear in preview when workspace has MUSE.md (no project_rules_home)" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_project_rules_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)
      :ok = File.write!(Path.join(tmp_dir, "MUSE.md"), "Always write tests first.")

      try do
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: tmp_dir})

        # project_rules layer must appear — no project_rules_home override needed
        assert output =~ "project_rules"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "project_rules?: false in context disables project rules layer" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_no_rules_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)
      :ok = File.write!(Path.join(tmp_dir, "MUSE.md"), "Should not appear.")

      try do
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, nil, %{
            workspace: tmp_dir,
            project_rules?: false
          })

        refute output =~ "project_rules"
        refute output =~ "Should not appear."
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "user-provided Agent content in project rules does not cause dispatch error" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "muse_preview_agents_md_#{:erlang.unique_integer([:positive])}"
        )

      :ok = File.mkdir_p!(tmp_dir)

      :ok =
        File.write!(Path.join(tmp_dir, "AGENTS.md"), "This is a legacy AGENTS.md file.")

      try do
        # Legacy AGENTS.md contains "Agent" — must not cause dispatch to return :error
        {:ok, output, _effects} =
          CommandDispatcher.dispatch(:prompt_preview, nil, %{workspace: tmp_dir})

        # Output may contain "Agent" from user content, but dispatch succeeds
        assert is_binary(output)
        assert output =~ "project_rules"
      after
        File.rm_rf!(tmp_dir)
      end
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
