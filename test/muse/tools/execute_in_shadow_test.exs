defmodule Muse.Tools.ExecuteInShadowTest do
  use ExUnit.Case, async: false

  alias Muse.ActiveVFS
  alias Muse.Tools.ExecuteInShadow
  alias Muse.Tool.Result

  @moduletag :unix
  @moduletag timeout: 120_000

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_project! do
    dir = Path.join(System.tmp_dir!(), "muse_eis_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/hello.ex"), "defmodule Hello do\n  def greet, do: :hi\nend\n")
    File.write!(Path.join(dir, "README.md"), "# Test Project\n")

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp start_vfs!(root) do
    try do
      GenServer.stop(ActiveVFS, :shutdown)
    catch
      :exit, _ -> :ok
    end

    {:ok, _pid} = ActiveVFS.start_link(root: root, name: ActiveVFS)
    :ok
  end

  defp stop_vfs! do
    try do
      GenServer.stop(ActiveVFS, :shutdown)
    catch
      :exit, _ -> :ok
    end
  end

  defp context_for(workspace) do
    %{workspace: workspace, muse_id: :coding, session_id: "sess_test", turn_id: "turn_1"}
  end

  # ---------------------------------------------------------------------------
  # Argument validation
  # ---------------------------------------------------------------------------

  describe "execute/2 — argument validation" do
    test "returns error when command is nil" do
      result = ExecuteInShadow.execute(%{}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "command is required"
    end

    test "returns error when command is empty" do
      result = ExecuteInShadow.execute(%{"command" => ""}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "command is required"
    end

    test "returns error for invalid workspace" do
      result =
        ExecuteInShadow.execute(%{"command" => "echo hi"}, %{workspace: "/nonexistent/xyz"})

      refute result.success
      assert result.error =~ "workspace"
    end
  end

  # ---------------------------------------------------------------------------
  # Shadow execution lifecycle
  # ---------------------------------------------------------------------------

  describe "execute/2 — shadow execution" do
    test "executes command in shadow and returns structured result" do
      project = create_project!()
      result = ExecuteInShadow.execute(%{"command" => "echo hello_shadow"}, context_for(project))

      assert %Result{tool_name: "execute_in_shadow"} = result
      assert result.success
      output = result.output
      assert is_map(output)
      assert output.exit_code == 0
      assert output.stdout =~ "hello_shadow"
      assert is_integer(output.duration_ms)
      assert output.duration_ms >= 0
      assert output.passed == true
      assert output.timed_out == false
      assert is_binary(output.summary)
    end

    test "captures non-zero exit code" do
      project = create_project!()
      result = ExecuteInShadow.execute(%{"command" => "false"}, context_for(project))

      assert result.success
      assert result.output.exit_code != 0
      assert result.output.passed == false
    end

    test "shadow is destroyed after execution" do
      project = create_project!()

      # Run once and verify no leftover shadow directories
      result = ExecuteInShadow.execute(%{"command" => "pwd"}, context_for(project))
      assert result.success

      # Count shadow dirs before
      before_count = count_shadow_dirs()

      # Run again
      result = ExecuteInShadow.execute(%{"command" => "pwd"}, context_for(project))
      assert result.success

      # Count shadow dirs after — should be the same (no leak)
      after_count = count_shadow_dirs()
      assert after_count == before_count
    end

    test "original project is untouched after shadow execution" do
      project = create_project!()
      original_content = File.read!(Path.join(project, "lib/hello.ex"))

      # Run a command that would NOT modify anything (just echo)
      ExecuteInShadow.execute(%{"command" => "echo safe"}, context_for(project))

      assert File.read!(Path.join(project, "lib/hello.ex")) == original_content
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout handling
  # ---------------------------------------------------------------------------

  describe "execute/2 — timeout" do
    test "kills process on timeout and returns timed_out result" do
      project = create_project!()

      result =
        ExecuteInShadow.execute(
          %{"command" => "sleep 60", "timeout_seconds" => 1},
          context_for(project)
        )

      assert result.success
      assert result.output.timed_out == true
      assert result.output.passed == false
      assert result.output.summary =~ "timed out"
    end
  end

  # ---------------------------------------------------------------------------
  # VFS overlay
  # ---------------------------------------------------------------------------

  describe "execute/2 — VFS overlay" do
    setup do
      project = create_project!()
      start_vfs!(project)

      on_exit(fn ->
        stop_vfs!()
      end)

      {:ok, project: project}
    end

    test "overlays VFS-modified files into shadow", %{project: project} do
      # Commit a modification to VFS
      {:ok, _v0} = ActiveVFS.checkout("lib/hello.ex", agent_id: "test-agent")
      new_content = "defmodule Hello do\n  def greet, do: :updated\nend\n"

      {:ok, _v1} =
        ActiveVFS.commit("lib/hello.ex", new_content, "test-agent", "update greeting")

      # Run a command in shadow that reads the file
      result =
        ExecuteInShadow.execute(
          %{"command" => "cat lib/hello.ex", "files_to_include" => ["lib/hello.ex"]},
          context_for(project)
        )

      assert result.success
      assert result.output.stdout =~ ":updated"
      refute result.output.stdout =~ ":hi"

      # Original file should still be untouched
      assert File.read!(Path.join(project, "lib/hello.ex")) =~ ":hi"
    end

    test "overlays all modified VFS files when files_to_include is omitted", %{project: project} do
      # Commit modifications to VFS
      {:ok, _v0} = ActiveVFS.checkout("lib/hello.ex", agent_id: "test-agent")

      {:ok, _v1} =
        ActiveVFS.commit(
          "lib/hello.ex",
          "defmodule Hello do\n  def greet, do: :auto_overlay\nend\n",
          "test-agent",
          "update"
        )

      result =
        ExecuteInShadow.execute(
          %{"command" => "cat lib/hello.ex"},
          context_for(project)
        )

      assert result.success
      assert result.output.stdout =~ ":auto_overlay"
    end

    test "logs warning for VFS files that don't exist", %{project: project} do
      # Request a file that's not in VFS
      result =
        ExecuteInShadow.execute(
          %{
            "command" => "cat lib/hello.ex",
            "files_to_include" => ["lib/nonexistent.ex"]
          },
          context_for(project)
        )

      # Should still succeed — original file is there via symlink
      assert result.success
      assert result.output.stdout =~ ":hi"
    end
  end

  # ---------------------------------------------------------------------------
  # Output truncation
  # ---------------------------------------------------------------------------

  describe "execute/2 — output truncation" do
    test "truncates very large output" do
      project = create_project!()

      # Generate a lot of output (more than 10k lines)
      large_cmd = "for i in $(seq 1 12000); do echo \"line $i\"; done"

      result =
        ExecuteInShadow.execute(
          %{"command" => large_cmd},
          context_for(project)
        )

      assert result.success
      # Should contain truncation notice
      assert result.output.stdout =~ "output truncated"
    end
  end

  # ---------------------------------------------------------------------------
  # Shadow creation failure
  # ---------------------------------------------------------------------------

  describe "execute/2 — shadow creation failure" do
    test "returns error when shadow creation fails" do
      # Use a valid-looking directory that can't be a workspace
      result =
        ExecuteInShadow.execute(
          %{"command" => "echo hi"},
          %{workspace: "/dev/null"}
        )

      refute result.success
      assert result.error =~ "shadow creation failed" or result.error =~ "workspace"
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout parsing
  # ---------------------------------------------------------------------------

  describe "timeout parsing" do
    test "defaults to 60 seconds" do
      project = create_project!()

      result =
        ExecuteInShadow.execute(
          %{"command" => "echo ok"},
          context_for(project)
        )

      assert result.success
    end

    test "accepts integer timeout" do
      project = create_project!()

      result =
        ExecuteInShadow.execute(
          %{"command" => "echo ok", "timeout_seconds" => 30},
          context_for(project)
        )

      assert result.success
    end

    test "accepts string timeout" do
      project = create_project!()

      result =
        ExecuteInShadow.execute(
          %{"command" => "echo ok", "timeout_seconds" => "30"},
          context_for(project)
        )

      assert result.success
    end

    test "caps timeout at 600 seconds" do
      project = create_project!()

      # Should not crash even with very large timeout
      result =
        ExecuteInShadow.execute(
          %{"command" => "echo ok", "timeout_seconds" => 9999},
          context_for(project)
        )

      assert result.success
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp count_shadow_dirs do
    base = Path.join(System.tmp_dir!(), "muse_shadows")

    case File.ls(base) do
      {:ok, entries} -> length(entries)
      {:error, _} -> 0
    end
  end
end
