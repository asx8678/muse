defmodule Muse.Tool.RunnerTest do
  use ExUnit.Case, async: false

  alias Muse.Tool.Runner
  alias Muse.State

  setup do
    root = Path.join(System.tmp_dir!(), "muse_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    # Create some test files
    File.write!(Path.join(root, "hello.ex"), "defmodule Hello do\n  def world, do: :ok\nend\n")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do\nend\n")

    # Start State GenServer for event emission tests
    start_state()

    on_exit(fn ->
      File.rm_rf(root)
      stop_state()
    end)

    context = %{
      workspace: root,
      muse_id: :planning,
      session_id: "sess_test",
      turn_id: "turn_1"
    }

    {:ok, root: root, context: context}
  end

  # -- Blocked tools -------------------------------------------------------------

  describe "run/3 — blocked tools" do
    test "blocks write_file for planning muse", %{context: context} do
      result = Runner.run("write_file", %{"path" => "foo.ex", "content" => "x"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "blocks shell_command for planning muse", %{context: context} do
      result = Runner.run("shell_command", %{"command" => "rm -rf /"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "blocks network_call", %{context: context} do
      result = Runner.run("network_call", %{"url" => "http://evil.com"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "blocks delete_file", %{context: context} do
      result = Runner.run("delete_file", %{"path" => "foo.ex"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "blocks replace_in_file", %{context: context} do
      result = Runner.run("replace_in_file", %{"path" => "foo.ex"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "blocks patch_apply", %{context: context} do
      result = Runner.run("patch_apply", %{"patch" => "xxx"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "blocks destructive-looking unknown tool shapes", %{context: context} do
      for tool_name <- ["apply_patch", "run_shell", "http_request", "remote_exec"] do
        State.clear()
        result = Runner.run(tool_name, %{"payload" => "API_KEY=sk-test-runner-secret"}, context)

        refute result.success
        assert result.error =~ "blocked"

        events = State.events()
        types = Enum.map(events, & &1.type)
        assert :tool_call_blocked in types

        for event <- events do
          refute inspect(event.data) =~ "sk-test-runner-secret"
        end
      end
    end

    test "blocks remote_execution", %{context: context} do
      result = Runner.run("remote_execution", %{"cmd" => "ls"}, context)
      refute result.success
      assert result.error =~ "blocked"
    end

    test "plan approval context does not unlock destructive tool names", %{context: context} do
      approved_plan_context =
        Map.merge(context, %{
          plan_status: :approved,
          approval_scope: :plan,
          approvals: [%{scope: :plan, status: :approved}]
        })

      for tool_name <- [
            "write_file",
            "shell_command",
            "network_call",
            "patch_apply",
            "delete_file"
          ] do
        result = Runner.run(tool_name, %{"payload" => "x"}, approved_plan_context)

        refute result.success
        assert result.error =~ "blocked"
      end
    end
  end

  # -- Unknown tools -------------------------------------------------------------

  describe "run/3 — unknown tools" do
    test "returns error for completely unknown tool", %{context: context} do
      result = Runner.run("totally_unknown_tool", %{}, context)
      refute result.success
      assert result.error =~ "unknown tool"
    end

    test "redacts secret-like provider input in failed results and events", %{context: context} do
      secret_tool_name = "unknown_api_key=sk-test-runner-secret"

      State.clear()
      result = Runner.run(secret_tool_name, %{}, context)

      refute result.success
      assert result.error =~ "unknown tool"
      refute result.error =~ "sk-test-runner-secret"
      refute result.tool_name =~ "sk-test-runner-secret"
      assert result.error =~ "[REDACTED]"
      assert result.tool_name =~ "[REDACTED]"

      events = State.events()
      assert Enum.any?(events, &(&1.type == :tool_call_failed))

      for event <- events do
        refute inspect(event.data) =~ "sk-test-runner-secret"
      end
    end
  end

  # -- Muse permission checks ----------------------------------------------------

  describe "run/3 — muse permission" do
    test "allows read_file for planning muse", %{root: _root, context: context} do
      result = Runner.run("read_file", %{"path" => "hello.ex"}, context)
      assert result.success
      assert result.output.path == "hello.ex"
    end

    test "blocks read-only tool for muse not in allowed_muses" do
      # Create a fake context with a muse_id that's not in allowed_muses
      context = %{workspace: "/tmp", muse_id: :unknown_muse, session_id: "s1", turn_id: "t1"}
      result = Runner.run("read_file", %{"path" => "test.ex"}, context)
      refute result.success
      assert result.error =~ "not allowed" or result.error =~ "blocked"
    end

    test "allows tools when muse_id is nil (no muse check)", %{root: root} do
      context = %{workspace: root, muse_id: nil, session_id: "s1", turn_id: "t1"}
      result = Runner.run("list_muses", %{}, context)
      assert result.success
    end
  end

  # -- Required args validation --------------------------------------------------

  describe "run/3 — required args" do
    test "returns error when required path is missing for read_file", %{context: context} do
      result = Runner.run("read_file", %{}, context)
      refute result.success
      assert result.error =~ "missing required"
    end

    test "returns error when required pattern is missing for repo_search", %{context: context} do
      result = Runner.run("repo_search", %{}, context)
      refute result.success
      assert result.error =~ "missing required"
    end
  end

  # -- Workspace safety enforcement ----------------------------------------------

  describe "run/3 — workspace safety" do
    test "returns error when workspace is missing from context" do
      result = Runner.run("read_file", %{"path" => "test.ex"}, %{muse_id: :planning})
      refute result.success
      assert result.error =~ "workspace"
    end

    test "returns error for path escaping workspace", %{root: _root, context: context} do
      result = Runner.run("read_file", %{"path" => "../../etc/passwd"}, context)
      refute result.success
    end

    test "returns error for secret path", %{root: _root, context: context} do
      result = Runner.run("read_file", %{"path" => ".env"}, context)
      refute result.success
    end
  end

  # -- Read-only tools work without model calls ----------------------------------

  describe "run/3 — read-only tools work" do
    test "list_files returns entries", %{root: root, context: context} do
      result = Runner.run("list_files", %{"allow_hidden" => true}, context)
      assert result.success
      assert is_list(result.output.entries)
      assert result.output.root == root
    end

    test "read_file returns content", %{root: _root, context: context} do
      result = Runner.run("read_file", %{"path" => "hello.ex"}, context)
      assert result.success
      assert result.output.content =~ "Hello"
    end

    test "read-only tools still run with approved plan context", %{root: _root, context: context} do
      approved_plan_context = Map.put(context, :plan_status, :approved)

      result = Runner.run("read_file", %{"path" => "hello.ex"}, approved_plan_context)

      assert result.success
      assert result.output.content =~ "Hello"
    end

    test "list_muses returns muses", %{context: context} do
      result = Runner.run("list_muses", %{}, context)
      assert result.success
      assert result.output.count == 2
    end

    test "list_skills returns empty list", %{context: context} do
      result = Runner.run("list_skills", %{}, context)
      assert result.success
      assert result.output.skills == []
    end

    test "ask_user_question returns answered: false", %{context: context} do
      result = Runner.run("ask_user_question", %{"question" => "What should we do?"}, context)
      assert result.success
      assert result.output.answered == false
    end
  end

  # -- Always returns Result struct -----------------------------------------------

  describe "run/3 — always returns Result" do
    test "success result has correct tool_name", %{root: _root, context: context} do
      result = Runner.run("list_files", %{}, context)
      assert result.tool_name == "list_files"
    end

    test "blocked result has correct tool_name", %{context: context} do
      result = Runner.run("write_file", %{}, context)
      assert result.tool_name == "write_file"
    end

    test "unknown tool result has correct tool_name" do
      result = Runner.run("unknown", %{}, %{workspace: "/tmp"})
      assert result.tool_name == "unknown"
    end
  end

  # -- Event emission ------------------------------------------------------------

  describe "run/3 — event emission" do
    test "emits tool_call_started and tool_call_completed events on success", %{context: context} do
      State.clear()
      _result = Runner.run("list_muses", %{}, context)

      events = State.events()
      types = Enum.map(events, & &1.type)

      assert :tool_call_started in types
      assert :tool_call_completed in types
    end

    test "emits tool_call_blocked event when tool is blocked", %{context: context} do
      State.clear()
      _result = Runner.run("write_file", %{"path" => "foo"}, context)

      events = State.events()
      types = Enum.map(events, & &1.type)

      assert :tool_call_blocked in types
    end

    test "emits tool_call_failed event for unknown tool", %{context: context} do
      State.clear()
      _result = Runner.run("nonexistent_tool", %{}, context)

      events = State.events()
      types = Enum.map(events, & &1.type)

      assert :tool_call_failed in types
    end

    test "events do not contain raw file contents", %{context: context} do
      State.clear()
      _result = Runner.run("read_file", %{"path" => "hello.ex"}, context)

      events = State.events()

      for event <- events do
        # Event data should never contain raw file contents
        data_str = inspect(event.data)
        refute data_str =~ "defmodule Hello"
      end
    end

    test "events include session_id and muse_id metadata", %{context: context} do
      State.clear()
      _result = Runner.run("list_muses", %{}, context)

      events = State.events()
      completed = Enum.find(events, &(&1.type == :tool_call_completed))

      assert completed != nil
      assert completed.session_id == "sess_test"
      assert completed.muse_id == "planning"
    end

    test "events include safe summaries only", %{context: context} do
      State.clear()
      _result = Runner.run("list_muses", %{}, context)

      events = State.events()
      started = Enum.find(events, &(&1.type == :tool_call_started))
      completed = Enum.find(events, &(&1.type == :tool_call_completed))

      assert started.data.tool_name == "list_muses"
      assert started.data.muse_id == :planning
      assert is_binary(started.data.tool_call_id)

      assert completed.data.tool_name == "list_muses"
      assert is_binary(completed.data.tool_call_id)
      assert is_integer(completed.data.elapsed_ms)
    end
  end

  # -- Output capping & redaction regression (PR06 Blocker 1) --------------------

  describe "run/3 — output capping and redaction" do
    test "read_file output is capped for large files", %{root: root, context: context} do
      # Create a file larger than the read_file spec's output_limit (100_000)
      large_content = String.duplicate("line of text\n", 20_000)
      File.write!(Path.join(root, "large.ex"), large_content)

      result = Runner.run("read_file", %{"path" => "large.ex"}, context)
      assert result.success

      # Output should be bounded — never the full raw content
      output_size = byte_size(result.output.content)
      assert output_size <= 100_000 + 10_000
    end

    test "map output capping uses Map.put — no KeyError on plain maps", %{
      context: context
    } do
      # list_files returns a map with entries — the output cap path for maps
      # must use Map.put not map-update to avoid KeyError on maps that
      # don't have __truncated__ / _preview keys.
      result = Runner.run("list_files", %{"max_entries" => 1}, context)
      assert result.success
      # Output should be a map (not crash)
      assert is_map(result.output)
    end

    test "large read_file through Runner never raises", %{root: root, context: context} do
      # Create a file that exceeds @max_bytes (500_000) to test bounded IO
      large_content = String.duplicate("x", 600_000)
      File.write!(Path.join(root, "huge.ex"), large_content)

      result = Runner.run("read_file", %{"path" => "huge.ex"}, context)
      assert result.success
      # The read_file tool caps at @max_bytes internally
      assert result.output.truncated == true
    end

    test "large read_file via Runner: output content byte size is under/near spec limit",
         %{root: root, context: context} do
      # Create a file large enough to trigger Runner's map cap_output.
      # read_file's output_limit is 100_000. The output map includes
      # :content which can be huge. The cap_output must truncate
      # the content value so the returned output is truly bounded.
      large_content = String.duplicate("A", 200_000)
      File.write!(Path.join(root, "very_large.ex"), large_content)

      result = Runner.run("read_file", %{"path" => "very_large.ex"}, context)
      assert result.success

      # The entire output map's inspected size should be bounded near the
      # spec's output_limit (100_000). The :content field must not retain
      # the full 200_000-byte raw string.
      output_inspected = inspect(result.output, limit: :infinity, printable_limit: :infinity)
      assert byte_size(output_inspected) <= 120_000

      # Most critically: no huge raw binary value remains
      assert byte_size(result.output.content) <= 100_000

      # Structural fields should be preserved
      assert result.output.path == "very_large.ex"
      assert result.output.__truncated__ == true
    end

    test "event data is redacted — no raw secrets in events", %{root: root, context: context} do
      # Write a file with a secret-like pattern
      File.write!(Path.join(root, "config.ex"), "DATABASE_URL=postgres://user:pass@host/db")

      State.clear()
      result = Runner.run("read_file", %{"path" => "config.ex"}, context)
      assert result.success

      events = State.events()

      for event <- events do
        data_str = inspect(event.data)
        refute data_str =~ "postgres://user:pass@host/db"
      end
    end

    test "args summary truncates long values and redacts", %{root: _root, context: context} do
      State.clear()

      secret = "sk-test-args-secret"

      _result =
        Runner.run(
          "read_file",
          %{"path" => "hello.ex", "extra" => String.duplicate("x", 200), "token" => secret},
          context
        )

      events = State.events()
      started = Enum.find(events, &(&1.type == :tool_call_started))

      # The args_summary should truncate long values and redact secrets
      assert is_binary(started.data.args_summary)
      assert String.length(started.data.args_summary) < 500
      refute started.data.args_summary =~ secret
      assert started.data.args_summary =~ "[REDACTED]"
    end

    test "list_files with many entries: output is reliably capped to spec limit",
         %{root: root, context: context} do
      # Create enough files with long enough names that the entries list
      # exceeds list_files' output_limit (50_000). 300 files × ~200-char
      # names ≈ 60 000 bytes of entries, well above the limit.
      long_prefix = String.duplicate("component_with_long_name_", 8)

      for i <- 1..300 do
        name = "#{long_prefix}#{i}.ex"
        File.write!(Path.join(root, name), "x")
      end

      # Request more entries than default so the tool returns all of them
      # before Runner capping kicks in.
      result = Runner.run("list_files", %{"max_entries" => 1000}, context)
      assert result.success

      output = result.output
      assert is_map(output)
      assert is_list(output.entries)

      # The entries list must be reduced — fewer than the 300+ we created
      total_files =
        root
        |> File.ls!()
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> length()

      assert length(output.entries) < total_files

      # Marker must indicate truncation happened
      assert output.__truncated__ == true or
               :__truncated__ in output.entries or
               output.truncated == true

      # The full inspected size must be within spec limit + small overhead
      full_size =
        output
        |> inspect(limit: :infinity, printable_limit: :infinity)
        |> byte_size()

      # list_files output_limit is 50_000; allow small marker overhead
      assert full_size <= 50_000 + 500
    end
  end

  # -- Patch propose permission gating -----------------------------------------

  describe "run/3 — patch_propose permission gating" do
    @valid_diff "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"

    defp approved_plan_and_hash do
      plan =
        Muse.Plan.new(
          id: "plan_1",
          session_id: "sess_test",
          version: 1,
          status: :approved,
          objective: "Test objective"
        )

      hash = Muse.PlanBinding.content_hash(plan)
      {plan, hash}
    end

    defp approved_context(context_overrides \\ []) do
      {_plan, hash} = approved_plan_and_hash()

      base = %{
        workspace: "/tmp",
        muse_id: :coding,
        session_id: "sess_test",
        turn_id: "turn_1",
        active_plan_id: "plan_1",
        approvals: [
          %{
            id: "ap_1",
            kind: :plan,
            status: :approved,
            plan_id: "plan_1",
            scope: :plan,
            plan_version: 1,
            plan_hash: hash,
            content_hash: hash,
            session_id: "sess_test"
          }
        ],
        plans: %{
          "plan_1" => %{
            id: "plan_1",
            session_id: "sess_test",
            status: :approved,
            version: 1,
            objective: "Test objective"
          }
        }
      }

      Map.merge(base, Map.new(context_overrides))
    end

    test "blocks patch_propose for planning muse (not in allowed_muses)", %{context: context} do
      result = Runner.run("patch_propose", %{"diff" => @valid_diff}, context)
      refute result.success
      assert result.error =~ "not allowed" or result.error =~ "blocked"
    end

    test "blocks patch_propose for coding muse without approved plan" do
      context = %{
        workspace: "/tmp",
        muse_id: :coding,
        session_id: "sess_test",
        turn_id: "turn_1"
      }

      result = Runner.run("patch_propose", %{"diff" => @valid_diff}, context)
      refute result.success
      assert result.error =~ "requires explicit" or result.error =~ "approval"
    end

    test "blocks patch_propose for coding muse with unapproved plan" do
      context = %{
        workspace: "/tmp",
        muse_id: :coding,
        session_id: "sess_test",
        turn_id: "turn_1",
        active_plan_id: "plan_1",
        approvals: [
          %{
            id: "ap_1",
            kind: :plan,
            status: :pending,
            plan_id: "plan_1",
            scope: :plan,
            session_id: "sess_test"
          }
        ],
        plans: %{
          "plan_1" => %{
            id: "plan_1",
            session_id: "sess_test",
            status: :awaiting_approval,
            objective: "Test"
          }
        }
      }

      result = Runner.run("patch_propose", %{"diff" => @valid_diff}, context)
      refute result.success
      assert result.error =~ "requires an approved plan" or result.error =~ "approval"
    end

    test "blocks patch_propose for coding muse with rejected plan" do
      context = %{
        workspace: "/tmp",
        muse_id: :coding,
        session_id: "sess_test",
        turn_id: "turn_1",
        active_plan_id: "plan_1",
        approvals: [
          %{
            id: "ap_1",
            kind: :plan,
            status: :rejected,
            plan_id: "plan_1",
            scope: :plan,
            session_id: "sess_test"
          }
        ],
        plans: %{
          "plan_1" => %{
            id: "plan_1",
            session_id: "sess_test",
            status: :rejected,
            objective: "Test"
          }
        }
      }

      result = Runner.run("patch_propose", %{"diff" => @valid_diff}, context)
      refute result.success
      assert result.error =~ "requires an approved plan" or result.error =~ "approval"
    end

    test "allows patch_propose for coding muse with approved plan" do
      result = Runner.run("patch_propose", %{"diff" => @valid_diff}, approved_context())
      assert result.success
      assert result.output.patch_id =~ "patch_"
      assert result.output.approval_required == true
    end

    test "blocks patch_propose with malformed diff even with approved plan" do
      result = Runner.run("patch_propose", %{"diff" => "not a diff"}, approved_context())
      refute result.success
      assert result.error =~ "does not appear"
    end

    test "blocks patch_propose with dangerous diff even with approved plan" do
      result =
        Runner.run(
          "patch_propose",
          %{"diff" => "--- a/x\n+++ b/x\n+sudo rm -rf /"},
          approved_context()
        )

      refute result.success
      assert result.error =~ "dangerous"
    end

    test "approved plan context does not unlock other write tools", %{context: context} do
      {_plan, hash} = approved_plan_and_hash()

      approved_context =
        Map.merge(context, %{
          muse_id: :coding,
          active_plan_id: "plan_1",
          approvals: [
            %{
              id: "ap_1",
              kind: :plan,
              status: :approved,
              plan_id: "plan_1",
              scope: :plan,
              session_id: "sess_test",
              plan_version: 1,
              plan_hash: hash,
              content_hash: hash
            }
          ],
          plans: %{
            "plan_1" => %{
              id: "plan_1",
              session_id: "sess_test",
              status: :approved,
              version: 1,
              objective: "Test objective"
            }
          }
        })

      for tool_name <- [
            "write_file",
            "shell_command",
            "network_call",
            "patch_apply",
            "delete_file"
          ] do
        result = Runner.run(tool_name, %{"payload" => "x"}, approved_context)
        refute result.success, "expected #{tool_name} to be blocked even with approved plan"
        assert result.error =~ "blocked"
      end
    end

    test "events for patch_propose include safe summaries only", %{context: context} do
      {_plan, hash} = approved_plan_and_hash()

      approved_context =
        Map.merge(context, %{
          muse_id: :coding,
          active_plan_id: "plan_1",
          approvals: [
            %{
              id: "ap_1",
              kind: :plan,
              status: :approved,
              plan_id: "plan_1",
              scope: :plan,
              session_id: "sess_test",
              plan_version: 1,
              plan_hash: hash,
              content_hash: hash
            }
          ],
          plans: %{
            "plan_1" => %{
              id: "plan_1",
              session_id: "sess_test",
              status: :approved,
              version: 1,
              objective: "Test objective"
            }
          }
        })

      State.clear()
      _result = Runner.run("patch_propose", %{"diff" => @valid_diff}, approved_context)

      events = State.events()
      started = Enum.find(events, &(&1.type == :tool_call_started))
      assert started != nil
      assert started.data.tool_name == "patch_propose"
      refute started.data.args_summary =~ @valid_diff

      completed = Enum.find(events, &(&1.type == :tool_call_completed))
      assert completed != nil
      assert completed.data.success == true
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp start_state do
    case Process.whereis(Muse.State) do
      nil ->
        {:ok, _} = State.start_link()

      pid ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end

        {:ok, _} = State.start_link()
    end
  end

  defp stop_state do
    case Process.whereis(Muse.State) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
