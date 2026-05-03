defmodule Muse.CommandsTest do
  use ExUnit.Case, async: true

  alias Muse.Commands

  describe "parse/1" do
    test "parses /help" do
      assert Commands.parse("/help") == {:command, :help}
    end

    test "parses /events" do
      assert Commands.parse("/events") == {:command, :events}
    end

    test "parses /agents" do
      assert Commands.parse("/agents") == {:command, :agents}
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
      assert Commands.parse("/open agents") == {:command, :open_agents}
      assert Commands.parse("/open stats") == {:command, :open_stats}
      assert Commands.parse("/open settings") == {:command, :open_settings}
      assert Commands.parse("/open logs") == {:command, :open_logs}
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
      assert text =~ "/events"
      assert text =~ "/agents"
      assert text =~ "/simulate event"
      assert text =~ "/simulate backend-error"
      assert text =~ "/clear"
      assert text =~ "/clear events"
      assert text =~ "/reload-status"
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
    end
  end

  describe "slash_commands/0" do
    test "returns list of {command, description} tuples" do
      cmds = Commands.slash_commands()
      assert is_list(cmds)
      assert length(cmds) == 29

      for {cmd, desc} <- cmds do
        assert is_binary(cmd)
        assert is_binary(desc)
        assert String.starts_with?(cmd, "/")
      end
    end
  end

  describe "slash_commands_json/0" do
    test "returns list of maps with command and description keys" do
      cmds = Commands.slash_commands_json()
      assert is_list(cmds)
      assert length(cmds) == 29

      for cmd <- cmds do
        assert Map.has_key?(cmd, :command)
        assert Map.has_key?(cmd, :description)
        assert String.starts_with?(cmd.command, "/")
      end
    end
  end
end
