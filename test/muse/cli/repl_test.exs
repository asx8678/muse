defmodule Muse.CLI.ReplTest do
  use ExUnit.Case, async: false

  alias Muse.{State, Workspace}
  alias Muse.CLI.Repl

  # -- Setup: State + Workspace are globally named → async: false ---------------

  setup do
    safe_stop_state()
    safe_stop_workspace()

    {:ok, state_pid} = State.start_link([])
    Process.unlink(state_pid)

    root = Path.join(System.tmp_dir!(), "muse_repl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, ws_pid} = Workspace.start_link(root: root)
    Process.unlink(ws_pid)

    on_exit(fn ->
      safe_stop_state()
      safe_stop_workspace()
    end)

    {:ok, root: root}
  end

  # -- /help --------------------------------------------------------------------

  describe "handle_input/2 — /help" do
    test "prints help text via CommandDispatcher and returns :ok" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/help", halt?: false) == :ok
        end)

      assert output =~ "Available commands"
      assert output =~ "/help"
    end
  end

  # -- empty input --------------------------------------------------------------

  describe "handle_input/2 — empty input" do
    test "returns :ok with no output" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("", halt?: false) == :ok
        end)

      assert output == ""
    end
  end

  # -- normal text submission ---------------------------------------------------

  describe "handle_input/2 — normal text" do
    test "submits via Muse.submit and prints assistant response" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("hello world", halt?: false) == :ok
        end)

      # StreamPrinter prints delta text directly without "assistant>" prefix
      assert output =~ "Placeholder response"
      assert output =~ "hello world"
    end

    test "appends events to State" do
      ExUnit.CaptureIO.capture_io(fn ->
        Repl.handle_input("test message", halt?: false)
      end)

      events = State.events()
      # 5 events: user_message, turn_started, assistant_delta, assistant_message, turn_completed
      assert length(events) == 5

      user_event = Enum.find(events, &(&1.type == :user_message))
      assistant_event = Enum.find(events, &(&1.type == :assistant_message))
      assert user_event.source == :cli
      assert user_event.type == :user_message
      assert assistant_event.source == :muse
      assert assistant_event.type == :assistant_message
    end
  end

  # -- /events ------------------------------------------------------------------

  describe "handle_input/2 — /events" do
    test "prints event count via CommandDispatcher" do
      ExUnit.CaptureIO.capture_io(fn ->
        Repl.handle_input("seed event", halt?: false)
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/events", halt?: false) == :ok
        end)

      assert output =~ "event(s) recorded"
    end
  end

  # -- /workspace ---------------------------------------------------------------

  describe "handle_input/2 — /workspace" do
    test "prints current workspace root via CommandDispatcher", %{root: root} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/workspace", halt?: false) == :ok
        end)

      assert output =~ "Workspace:"
      assert output =~ Path.expand(root)
    end
  end

  # -- /quit and :quit ----------------------------------------------------------

  describe "handle_input/2 — /quit" do
    test "prints Goodbye and returns :shutdown via shutdown(opts)" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/quit", halt?: false) == :shutdown
        end)

      assert output =~ "Goodbye!"
    end

    test "does NOT call System.halt when halt?: false" do
      # If System.halt were called, the test process would terminate.
      # Surviving this assertion proves halt?: false is respected.
      ExUnit.CaptureIO.capture_io(fn ->
        assert Repl.handle_input("/quit", halt?: false) == :shutdown
      end)
    end
  end

  describe "handle_input/2 — :quit" do
    test "prints Goodbye and returns :shutdown via shutdown(opts)" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input(":quit", halt?: false) == :shutdown
        end)

      assert output =~ "Goodbye!"
    end
  end

  # -- /reload, /rollback, /reload-status (DevReloader not running) ------------

  describe "handle_input/2 — /reload (DevReloader unavailable)" do
    test "prints reload failed message and returns :ok" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/reload", halt?: false) == :ok
        end)

      # Goes through CommandDispatcher which reports reload failure
      assert output =~ "Reload failed" or output =~ "not_running"
    end
  end

  describe "handle_input/2 — /rollback (DevReloader unavailable)" do
    test "prints rollback failed message and returns :ok" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/rollback", halt?: false) == :ok
        end)

      assert output =~ "Rollback failed" or output =~ "not_running"
    end
  end

  describe "handle_input/2 — /reload-status (DevReloader unavailable)" do
    test "prints unavailable status and returns :ok" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("/reload-status", halt?: false) == :ok
        end)

      assert output =~ "Unavailable" or output =~ "unavailable"
    end
  end

  # -- error resilience ---------------------------------------------------------

  describe "handle_input/2 — error resilience" do
    test "catches exit signals, prints [error], and returns :ok" do
      safe_stop_state()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Repl.handle_input("will crash", halt?: false) == :ok
        end)

      assert output =~ "[error]"

      # Restart State for subsequent tests
      {:ok, state_pid} = State.start_link([])
      Process.unlink(state_pid)
    end
  end

  # -- start_link ---------------------------------------------------------------

  describe "start_link/1" do
    test "returns {:ok, pid}" do
      {:ok, pid} = Repl.start_link(halt?: false)
      assert is_pid(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end

  # -- Helpers ------------------------------------------------------------------

  defp safe_stop_state do
    case Process.whereis(Muse.State) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)

        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp safe_stop_workspace do
    case Process.whereis(Muse.Workspace) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)

        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
