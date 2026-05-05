defmodule Muse.CommandsTest do
  use ExUnit.Case, async: true

  alias Muse.Commands

  describe "parse/1" do
    test "parses /help" do
      assert Commands.parse("/help") == {:command, :help}
    end

    test "parses /plan" do
      assert Commands.parse("/plan") == {:command, :plan}
    end

    test "parses /plan with args" do
      assert Commands.parse("/plan extra") == {:command, :plan, "extra"}
    end

    test "parses /plans" do
      assert Commands.parse("/plans") == {:command, :plans}
    end

    test "parses /plan history" do
      assert Commands.parse("/plan history") == {:command, :plan_history}
    end

    test "parses /plan status" do
      assert Commands.parse("/plan status") == {:command, :plan_status}
    end

    test "parses /plan show with id" do
      assert Commands.parse("/plan show abc") == {:command, :plan_show, "abc"}
    end

    test "longer /plan subcommands match before /plan" do
      assert Commands.parse("/plan history extra") == {:command, :plan_history, "extra"}
      assert Commands.parse("/plan status extra") == {:command, :plan_status, "extra"}
      assert Commands.parse("/plan show abc extra") == {:command, :plan_show, "abc extra"}
    end

    test "parses /approve plan" do
      assert Commands.parse("/approve plan") == {:command, :approve_plan}
    end

    test "parses /approve plan with args" do
      assert Commands.parse("/approve plan now") == {:command, :approve_plan, "now"}
    end

    test "parses /reject plan" do
      assert Commands.parse("/reject plan") == {:command, :reject_plan}
    end

    test "parses /reject plan with args" do
      assert Commands.parse("/reject plan because") == {:command, :reject_plan, "because"}
    end

    test "/approve and /reject alone are unknown" do
      assert Commands.parse("/approve") == {:unknown, "/approve"}
      assert Commands.parse("/reject") == {:unknown, "/reject"}
    end

    test "parses /events" do
      assert Commands.parse("/events") == {:command, :events}
    end

    test "parses /muses" do
      assert Commands.parse("/muses") == {:command, :muses}
    end

    test "/agents legacy alias parses to :muses" do
      assert Commands.parse("/agents") == {:command, :muses}
    end

    test "parses /simulate event" do
      assert Commands.parse("/simulate event") == {:command, :simulate_event}
    end

    test "parses /simulate backend-error" do
      assert Commands.parse("/simulate backend-error") == {:command, :simulate_backend_error}
    end

    test "parses /clear" do
      assert Commands.parse("/clear") == {:command, :clear_history}
    end

    test "parses /clear events" do
      assert Commands.parse("/clear events") == {:command, :clear_events}
    end

    test "parses /reload-status" do
      assert Commands.parse("/reload-status") == {:command, :reload_status}
    end

    test "parses /workspace" do
      assert Commands.parse("/workspace") == {:command, :workspace}
    end

    test "parses /stats" do
      assert Commands.parse("/stats") == {:command, :stats}
    end

    test "parses /diagnostics" do
      assert Commands.parse("/diagnostics") == {:command, :diagnostics}
    end

    test "parses /copy diagnostics" do
      assert Commands.parse("/copy diagnostics") == {:command, :copy_diagnostics}
    end

    test "parses /export events" do
      assert Commands.parse("/export events") == {:command, :export_events}
    end

    test "parses /search events with query" do
      assert Commands.parse("/search events my query") == {:command, :search_events, "my query"}
    end

    test "parses /search events without query" do
      assert Commands.parse("/search events") == {:command, :search_events}
    end

    test "parses /filter events with severity" do
      assert Commands.parse("/filter events errors") == {:command, :filter_events, "errors"}
      assert Commands.parse("/filter events warnings") == {:command, :filter_events, "warnings"}
      assert Commands.parse("/filter events info") == {:command, :filter_events, "info"}
      assert Commands.parse("/filter events all") == {:command, :filter_events, "all"}
    end

    test "parses /filter events without severity" do
      assert Commands.parse("/filter events") == {:command, :filter_events}
    end

    test "parses /open commands" do
      assert Commands.parse("/open events") == {:command, :open_events}
      assert Commands.parse("/open files") == {:command, :open_files}
      assert Commands.parse("/open muses") == {:command, :open_agents}
      assert Commands.parse("/open agents") == {:command, :open_agents}
      assert Commands.parse("/open stats") == {:command, :open_stats}
      assert Commands.parse("/open settings") == {:command, :open_settings}
      assert Commands.parse("/open logs") == {:command, :open_logs}
    end

    test "/open agents legacy alias parses to :open_agents" do
      assert Commands.parse("/open agents") == {:command, :open_agents}
    end

    test "does not match /open with unknown tab" do
      assert Commands.parse("/open unknown") == {:unknown, "/open unknown"}
    end

    test "parses /logs" do
      assert Commands.parse("/logs") == {:command, :logs}
    end

    test "parses /clear logs" do
      assert Commands.parse("/clear logs") == {:command, :clear_logs}
    end

    test "parses /export logs" do
      assert Commands.parse("/export logs") == {:command, :export_logs}
    end

    test "parses /search logs with query" do
      assert Commands.parse("/search logs test query") == {:command, :search_logs, "test query"}
    end

    test "parses /search logs without query" do
      assert Commands.parse("/search logs") == {:command, :search_logs}
    end

    test "parses /filter logs with severity" do
      assert Commands.parse("/filter logs errors") == {:command, :filter_logs, "errors"}
      assert Commands.parse("/filter logs warnings") == {:command, :filter_logs, "warnings"}
      assert Commands.parse("/filter logs info") == {:command, :filter_logs, "info"}
      assert Commands.parse("/filter logs debug") == {:command, :filter_logs, "debug"}
      assert Commands.parse("/filter logs all") == {:command, :filter_logs, "all"}
    end

    test "parses /filter logs without severity" do
      assert Commands.parse("/filter logs") == {:command, :filter_logs}
    end

    test "parses /runtime" do
      assert Commands.parse("/runtime") == {:command, :runtime}
    end

    test "parses /connect runtime" do
      assert Commands.parse("/connect runtime") == {:command, :connect_runtime}
    end

    test "parses /connect runtime with endpoint" do
      assert Commands.parse("/connect runtime ws://localhost:9999") ==
               {:command, :connect_runtime, "ws://localhost:9999"}
    end

    test "parses /disconnect runtime" do
      assert Commands.parse("/disconnect runtime") == {:command, :disconnect_runtime}
    end

    test "parses /reload" do
      assert Commands.parse("/reload") == {:command, :reload}
    end

    test "parses /prompt preview" do
      assert Commands.parse("/prompt preview") == {:command, :prompt_preview}
    end

    test "parses /prompt preview with args" do
      assert Commands.parse("/prompt preview some text") ==
               {:command, :prompt_preview, "some text"}
    end

    test "parses /prompt-preview alias" do
      assert Commands.parse("/prompt-preview") == {:command, :prompt_preview}
    end

    test "parses /prompt-preview alias with args" do
      assert Commands.parse("/prompt-preview some text") ==
               {:command, :prompt_preview, "some text"}
    end

    test "parses /rollback" do
      assert Commands.parse("/rollback") == {:command, :rollback}
    end

    test "parses /auth status" do
      assert Commands.parse("/auth status") == {:command, :auth_status}
      assert Commands.parse("/auth status extra") == {:command, :auth_status, "extra"}
    end

    test "returns :empty for blank input" do
      assert Commands.parse("") == :empty
      assert Commands.parse("   ") == :empty
    end

    test "returns {:message, text} for non-slash input" do
      assert Commands.parse("hello world") == {:message, "hello world"}
    end

    test "returns {:unknown, cmd} for unknown slash commands" do
      assert Commands.parse("/unknown-cmd") == {:unknown, "/unknown-cmd"}
    end

    test "does not match longer strings starting with a command" do
      # /clearance starts with /clear but is not the /clear command
      assert Commands.parse("/clearance") == {:unknown, "/clearance"}
      # /eventsfoo starts with /events but is not the /events command
      assert Commands.parse("/eventsfoo") == {:unknown, "/eventsfoo"}
      # /helper starts with /help but is not /help
      assert Commands.parse("/helper") == {:unknown, "/helper"}
      # /workspacees is not /workspace
      assert Commands.parse("/workspacees") == {:unknown, "/workspacees"}
    end

    test "matches command followed by space and args" do
      # /simulate with trailing text should match and capture args
      assert Commands.parse("/simulate event extra") == {:command, :simulate_event, "extra"}
      # Exact match still works (no trailing args → 2-tuple)
      assert Commands.parse("/help") == {:command, :help}
      assert Commands.parse("/events") == {:command, :events}
      # Commands with optional args: exact match returns 2-tuple
      assert Commands.parse("/stats") == {:command, :stats}
      # Commands with required args: trailing text captured
      assert Commands.parse("/search events foo") == {:command, :search_events, "foo"}
      assert Commands.parse("/filter events errors") == {:command, :filter_events, "errors"}
      # /open events is an exact match (no trailing args)
      assert Commands.parse("/open events") == {:command, :open_events}
    end

    test "trims whitespace before parsing" do
      # Trimming makes "/help  " become "/help" which is an exact match
      assert Commands.parse("  /help  ") == {:command, :help}
      assert Commands.parse("  /events  ") == {:command, :events}
    end
  end

  describe "help_text/0" do
    test "lists all commands" do
      text = Commands.help_text()
      assert text =~ "/help"
      assert text =~ "/plan"
      assert text =~ "/plans"
      assert text =~ "/plan history"
      assert text =~ "/plan status"
      assert text =~ "/plan show"
      assert text =~ "/approve plan"
      assert text =~ "/reject plan"
      assert text =~ "/muses"
      assert text =~ "/events"
      assert text =~ "/muses"
      assert text =~ "/simulate event"
      assert text =~ "/simulate backend-error"
      assert text =~ "/clear"
      assert text =~ "/clear events"
      assert text =~ "/reload-status"
      assert text =~ "/reload"
      assert text =~ "/rollback"
      assert text =~ "/workspace"
      assert text =~ "/stats"
      assert text =~ "/diagnostics"
      assert text =~ "/copy diagnostics"
      assert text =~ "/export events"
      assert text =~ "/search events"
      assert text =~ "/filter events"
      assert text =~ "/open events"
      assert text =~ "/logs"
      assert text =~ "/clear logs"
      assert text =~ "/export logs"
      assert text =~ "/search logs"
      assert text =~ "/filter logs"
      assert text =~ "/open logs"
      assert text =~ "/runtime"
      assert text =~ "/connect runtime"
      assert text =~ "/disconnect runtime"
      assert text =~ "/prompt preview"
      assert text =~ "/prompt-preview"
      assert text =~ "/auth status"
    end

    test "includes /muses but not /agents legacy alias" do
      text = Commands.help_text()
      assert text =~ "/muses"
      refute text =~ "/agents"
    end

    test "uses Muse-first language" do
      text = Commands.help_text()
      # /muses description should reference Muses, not Agents/Bots
      refute text =~ ~r/\bAgent\b.*command/i
      refute text =~ ~r/\bBot\b.*command/i
      # /plan should appear with Muse Plan description
      assert text =~ "/plan"
    end
  end

  describe "slash_commands/0" do
    test "returns list of {command, description} tuples" do
      cmds = Commands.slash_commands()
      assert is_list(cmds)
      assert length(cmds) == 43

      for {cmd, desc} <- cmds do
        assert is_binary(cmd)
        assert is_binary(desc)
        assert String.starts_with?(cmd, "/")
      end
    end

    test "includes /muses but not /agents legacy alias" do
      cmds = Commands.slash_commands()
      cmd_names = Enum.map(cmds, fn {cmd, _desc} -> cmd end)
      assert "/muses" in cmd_names
      refute "/agents" in cmd_names
      assert "/prompt preview" in cmd_names
      assert "/prompt-preview" in cmd_names
      assert "/plan" in cmd_names
      assert "/plans" in cmd_names
      assert "/plan history" in cmd_names
      assert "/plan status" in cmd_names
      assert "/plan show" in cmd_names
      assert "/approve plan" in cmd_names
      assert "/reject plan" in cmd_names
      assert "/auth status" in cmd_names
    end
  end

  describe "slash_commands_json/0" do
    test "returns list of maps with command and description keys" do
      cmds = Commands.slash_commands_json()
      assert is_list(cmds)
      assert length(cmds) == 43

      for cmd <- cmds do
        assert Map.has_key?(cmd, :command)
        assert Map.has_key?(cmd, :description)
        assert String.starts_with?(cmd.command, "/")
      end
    end

    test "includes /muses but not /agents legacy alias" do
      cmds = Commands.slash_commands_json()
      cmd_names = Enum.map(cmds, & &1.command)
      assert "/muses" in cmd_names
      refute "/agents" in cmd_names
      assert "/prompt preview" in cmd_names
      assert "/prompt-preview" in cmd_names
      assert "/plan" in cmd_names
      assert "/plans" in cmd_names
      assert "/plan history" in cmd_names
      assert "/plan status" in cmd_names
      assert "/plan show" in cmd_names
      assert "/auth status" in cmd_names
    end
  end
end
