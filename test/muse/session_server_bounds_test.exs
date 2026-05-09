defmodule Muse.SessionServerBoundsTest do
  @moduledoc """
  T1-14: Tests for per-session event cap enforcement in SessionServer.

  Verifies that state.events stays within the configured
  Muse.Bounds.session_events() cap, even after many turns.
  """
  use ExUnit.Case, async: false

  alias Muse.{Event, SessionServer}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp start_dependencies(workspace_root) do
    if Process.whereis(Muse.PubSub) == nil do
      {:ok, _} =
        Supervisor.start_link([{Phoenix.PubSub, name: Muse.PubSub}], strategy: :one_for_one)
    end

    stop_named(Muse.TaskSupervisor)
    {:ok, _} = Task.Supervisor.start_link(name: Muse.TaskSupervisor)

    stop_named(Muse.SessionRegistry)
    {:ok, _} = Registry.start_link(keys: :unique, name: Muse.SessionRegistry)

    stop_named(Muse.Workspace)
    {:ok, _} = Muse.Workspace.start_link(root: workspace_root)

    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])

    stop_named(Muse.Diagnostics)
    {:ok, _} = Muse.Diagnostics.start_link(install_logger_handler?: false)

    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = Muse.SelfHealingQueue.start_link([])

    stop_named(Muse.AgentRegistry)
    {:ok, _} = Muse.AgentRegistry.start_link([])
  end

  defp stop_dependencies do
    stop_named(Muse.AgentRegistry)
    stop_named(Muse.SelfHealingQueue)
    stop_named(Muse.Diagnostics)
    stop_named(Muse.State)
    stop_named(Muse.Workspace)
    stop_named(Muse.SessionRegistry)
    stop_named(Muse.TaskSupervisor)
  end

  defp tmp_workspace do
    dir = Path.join(System.tmp_dir!(), "muse_ss_bounds_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  setup do
    workspace = tmp_workspace()
    start_dependencies(workspace)

    on_exit(fn ->
      stop_dependencies()
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  # ---------------------------------------------------------------------------
  # Event cap enforcement
  # ---------------------------------------------------------------------------

  describe "per-session event cap" do
    test "status event_count reflects bounded events after many completed turns" do
      cap = Muse.Bounds.session_events()

      {:ok, pid} =
        SessionServer.start_link(
          session_id: "bounds_test",
          store_base_dir: Path.join(tmp_workspace(), "sessions")
        )

      for i <- 1..20 do
        assert {:ok, text} = SessionServer.submit(pid, :test, "message #{i}")
        assert is_binary(text)
      end

      final_state = :sys.get_state(pid)
      status = SessionServer.status(pid)

      assert status.event_count == length(final_state.events)
      assert length(final_state.events) == cap

      assert Enum.map(final_state.events, & &1.seq) ==
               Enum.to_list((final_state.seq - cap + 1)..final_state.seq)

      GenServer.stop(pid, :normal, 1_000)
    end

    test "append_session_events trims to cap via Bounds helper" do
      cap = Muse.Bounds.session_events()

      # Directly test the Bounds.trim_newest_first helper which is what
      # append_session_events now uses
      events =
        for i <- 1..(cap + 100) do
          Event.new(:test, :test, %{i: i}, id: i, seq: i)
        end

      trimmed = Muse.Bounds.trim_newest_first(events, cap)
      assert length(trimmed) == cap

      # Newest events survive
      assert List.last(trimmed).seq == cap + 100
      # Oldest events dropped
      assert hd(trimmed).seq == 101
    end
  end
end
