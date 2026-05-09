defmodule Muse.Execution.ProcessGroupTest do
  use ExUnit.Case, async: false

  alias Muse.Execution.ProcessGroup

  describe "platform_supported?/0" do
    test "returns boolean matching OS type" do
      result = ProcessGroup.platform_supported?()
      # On Unix this should be true; on Windows false
      assert is_boolean(result)

      case :os.type() do
        {:unix, _} -> assert result == true
        {:win32, _} -> assert result == false
      end
    end
  end

  describe "get_os_pid/1" do
    @tag :unix
    test "returns OS PID for a running port" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          {:args, ["30"]},
          :use_stdio,
          :exit_status
        ])

      pid = ProcessGroup.get_os_pid(port)
      assert is_integer(pid)
      assert pid > 0

      Port.close(port)
    end

    test "returns nil for a closed port" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          {:args, ["1"]},
          :use_stdio,
          :exit_status
        ])

      Port.close(port)
      # Small delay to let the port fully close
      Process.sleep(50)

      assert ProcessGroup.get_os_pid(port) == nil
    end
  end

  describe "read_pgid/1" do
    @tag :unix
    test "returns PGID for a running process on Unix" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          {:args, ["30"]},
          :use_stdio,
          :exit_status
        ])

      os_pid = ProcessGroup.get_os_pid(port)
      assert is_integer(os_pid)

      {:ok, pgid} = ProcessGroup.read_pgid(os_pid)
      # On Unix, the spawned process should be a process group leader
      assert pgid == os_pid

      Port.close(port)
    end

    @tag :unix
    test "returns error for a non-existent PID" do
      # Use a very large PID that likely doesn't exist
      {:error, _reason} = ProcessGroup.read_pgid(999_999_999)
    end
  end

  describe "terminate_group/2" do
    @tag :unix
    test "terminates process group on Unix and returns diagnostic" do
      # Spawn bash with children
      port =
        Port.open({:spawn_executable, System.find_executable("bash")}, [
          {:args, ["-c", "sleep 30 & sleep 30 & echo started; wait"]},
          :use_stdio,
          :stderr_to_stdout,
          :binary,
          :exit_status
        ])

      # Wait for bash to start children
      receive do
        {^port, {:data, "started" <> _}} -> :ok
      after
        2000 -> flunk("bash did not start within 2s")
      end

      Process.sleep(200)

      os_pid = ProcessGroup.get_os_pid(port)
      assert is_integer(os_pid)

      # Verify children exist
      {:ok, pgid} = ProcessGroup.read_pgid(os_pid)
      {children_output, 0} = System.cmd("pgrep", ["-g", to_string(pgid)])
      pids_before = children_output |> String.trim() |> String.split("\n", trim: true)
      # Should have at least bash + 2 sleeps
      assert length(pids_before) >= 3

      # Terminate the group
      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 0)

      assert diagnostic.platform == :unix
      assert diagnostic.pgid_available == true
      assert diagnostic.os_pid == os_pid
      assert diagnostic.pgid == pgid

      # Verify all processes in the group are gone
      Process.sleep(200)
      {remaining, _} = System.cmd("pgrep", ["-g", to_string(pgid)], stderr_to_stdout: true)
      assert String.trim(remaining) == ""
    end

    @tag :unix
    test "handles already-exited process gracefully" do
      # Spawn a process that exits quickly
      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          {:args, ["-e", "IO.puts(:done)"]},
          :use_stdio,
          :stderr_to_stdout,
          :binary,
          :exit_status
        ])

      # Wait for it to exit
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        5000 -> flunk("process did not exit within 5s")
      end

      # Now try to terminate — the process is already gone
      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 0)

      # Should not crash, should indicate the process already exited
      assert diagnostic.pgid_available == false
      assert diagnostic.os_pid == nil or is_integer(diagnostic.os_pid)
      assert Map.has_key?(diagnostic, :fallback_reason)
    end

    @tag :unix
    test "terminates a single process without children" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          {:args, ["30"]},
          :use_stdio,
          :exit_status
        ])

      os_pid = ProcessGroup.get_os_pid(port)
      assert is_integer(os_pid)

      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 0)

      assert diagnostic.platform == :unix
      assert diagnostic.os_pid == os_pid

      # Verify the process is gone
      Process.sleep(100)
      {result, _} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
      # kill -0 should fail because the process is dead
      assert result =~ "no process" or result =~ "No such"
    end

    @tag :unix
    test "diagnostic includes kill_result on success" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          {:args, ["30"]},
          :use_stdio,
          :exit_status
        ])

      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 0)

      assert Map.has_key?(diagnostic, :kill_result)
      assert diagnostic.kill_result == :ok
    end
  end

  describe "terminate_group/2 — force_after_ms" do
    @tag :unix
    test "sends SIGKILL after grace period when force_after_ms > 0" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          {:args, ["30"]},
          :use_stdio,
          :exit_status
        ])

      start = System.monotonic_time(:millisecond)
      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 100)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should have waited approximately 100ms
      assert elapsed >= 50
      assert diagnostic.pgid_available == true
    end
  end

  describe "child cleanup — the key scenario" do
    @tag :unix
    test "command that spawns long-lived children: all children die after timeout" do
      # This is the core acceptance test:
      # A command that spawns a long-lived child does NOT leave that child
      # alive after timeout on supported platforms.

      # Use bash to spawn background children that would outlive the parent
      port =
        Port.open({:spawn_executable, System.find_executable("bash")}, [
          {:args, ["-c", "sleep 60 & sleep 60 & echo READY; wait"]},
          :use_stdio,
          :stderr_to_stdout,
          :binary,
          :exit_status
        ])

      # Wait for READY signal
      receive do
        {^port, {:data, "READY" <> _}} -> :ok
      after
        3000 -> flunk("bash did not signal READY")
      end

      Process.sleep(200)

      # Get the PGID
      os_pid = ProcessGroup.get_os_pid(port)
      {:ok, pgid} = ProcessGroup.read_pgid(os_pid)

      # Verify children exist before cleanup
      {children_before, 0} = System.cmd("pgrep", ["-g", to_string(pgid)])
      pids = children_before |> String.trim() |> String.split("\n", trim: true)

      assert length(pids) >= 3,
             "Expected at least 3 processes (bash + 2 sleeps), got: #{inspect(pids)}"

      # Terminate the process group
      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 0)
      assert diagnostic.pgid_available == true
      assert diagnostic.pgid == pgid

      # Verify ALL processes in the group are gone
      Process.sleep(300)
      {remaining, _} = System.cmd("pgrep", ["-g", to_string(pgid)], stderr_to_stdout: true)

      assert String.trim(remaining) == "",
             "Orphaned processes still alive after process group termination"

      # Also verify the specific sleep PIDs are gone
      for child_pid_str <- pids do
        child_pid = String.to_integer(child_pid_str)

        {check_result, _} =
          System.cmd("kill", ["-0", to_string(child_pid)], stderr_to_stdout: true)

        assert check_result =~ "no process" or check_result =~ "No such",
               "Child PID #{child_pid} is still alive after cleanup"
      end
    end

    @tag :unix
    test "children with spaces in arguments are handled correctly" do
      # Test that special characters in arguments don't break the kill
      tmp_dir =
        Path.join(System.tmp_dir!(), "muse_pgrp_spaces_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      marker = Path.join(tmp_dir, "test file with spaces.txt")
      File.write!(marker, "test")

      port =
        Port.open({:spawn_executable, System.find_executable("bash")}, [
          {:args,
           [
             "-c",
             "cat '#{marker}' > /dev/null & sleep 60 & echo READY; wait"
           ]},
          :use_stdio,
          :stderr_to_stdout,
          :binary,
          :exit_status
        ])

      receive do
        {^port, {:data, "READY" <> _}} -> :ok
      after
        3000 -> flunk("bash did not signal READY")
      end

      Process.sleep(200)

      # Capture PGID while process is still alive
      os_pid = ProcessGroup.get_os_pid(port)
      {:ok, pgid} = ProcessGroup.read_pgid(os_pid)

      diagnostic = ProcessGroup.terminate_group(port, force_after_ms: 0)
      assert diagnostic.pgid_available == true

      Process.sleep(200)
      # Verify no orphaned processes in the group
      {remaining, _} = System.cmd("pgrep", ["-g", to_string(pgid)], stderr_to_stdout: true)
      assert String.trim(remaining) == ""
    end
  end
end
