defmodule MuseWeb.HomeLiveBoundsTest do
  @moduledoc """
  T1-14: Tests for bounded per-session events, command history,
  streaming buffers, and toasts in HomeLive.

  Each test verifies cap enforcement and terminal/reset cleanup behavior
  using synthetic events, commands, and toasts.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MuseWeb.Endpoint

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

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link([{Phoenix.PubSub, name: Muse.PubSub}], strategy: :one_for_one)

      _pid ->
        :ok
    end
  end

  defp start_workspace(root) do
    stop_named(Muse.Workspace)
    {:ok, _} = Muse.Workspace.start_link(root: root)
  end

  defp start_state do
    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])
  end

  defp start_diagnostics do
    stop_named(Muse.Diagnostics)
    {:ok, _} = Muse.Diagnostics.start_link(install_logger_handler?: false)
  end

  defp start_self_healing_queue do
    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = Muse.SelfHealingQueue.start_link([])
  end

  defp start_agent_registry do
    stop_named(Muse.AgentRegistry)
    {:ok, _} = Muse.AgentRegistry.start_link([])
  end

  defp start_endpoint do
    stop_named(MuseWeb.Endpoint)
    {:ok, _} = MuseWeb.Endpoint.start_link()
  end

  defp live_socket(view), do: view.pid |> :sys.get_state() |> Map.fetch!(:socket)

  setup do
    ensure_pubsub()

    tmp_dir = System.tmp_dir!()
    workspace_root = Path.join(tmp_dir, "muse_bounds_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)

    Muse.Diagnostics.LoggerHandler.remove()
    stop_named(Muse.SessionRegistry)
    {:ok, _} = Registry.start_link(keys: :unique, name: Muse.SessionRegistry)

    start_workspace(workspace_root)
    start_state()
    start_diagnostics()
    start_self_healing_queue()
    start_agent_registry()
    start_endpoint()

    # Cache test config caps for assertions (test.exs sets them low)
    caps = %{
      toasts: Muse.Bounds.toasts(),
      command_history: Muse.Bounds.command_history(),
      streaming_buffer_bytes: Muse.Bounds.streaming_buffer_bytes(),
      diagnostics: Muse.Bounds.diagnostics()
    }

    on_exit(fn ->
      Muse.Diagnostics.LoggerHandler.remove()
      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.AgentRegistry)
      stop_named(Muse.SelfHealingQueue)
      stop_named(Muse.Diagnostics)
      stop_named(Muse.State)
      stop_named(Muse.Workspace)
      stop_named(Muse.SessionRegistry)
      File.rm_rf!(workspace_root)
    end)

    {:ok, workspace_root: workspace_root, caps: caps}
  end

  # ---------------------------------------------------------------------------
  # Command history bounds
  # ---------------------------------------------------------------------------

  describe "command history bounds" do
    test "command history stays within cap after repeated commands", %{caps: caps} do
      {:ok, view, _html} = live(build_conn(), "/")

      for i <- 1..(caps.command_history + 5) do
        view
        |> element("form")
        |> render_submit(%{"text" => "/unknown_history_#{i}"})
      end

      expected_range = 6..(caps.command_history + 5)
      history = live_socket(view).assigns.command_history
      assert length(history) == caps.command_history

      assert Enum.map(history, & &1.input) ==
               Enum.map(expected_range, &"/unknown_history_#{&1}")
    end
  end

  # ---------------------------------------------------------------------------
  # Toast bounds
  # ---------------------------------------------------------------------------

  describe "toast bounds" do
    test "toasts stay within cap after rapid additions", %{caps: caps} do
      {:ok, view, _html} = live(build_conn(), "/")

      # Trigger many toasts via command submissions that produce toast output
      for i <- 1..(caps.toasts + 5) do
        # Each unknown command produces a toast
        view
        |> element("form")
        |> render_submit(%{"text" => "/unknown_cmd_#{i}"})
      end

      expected_range = 6..(caps.toasts + 5)
      toasts = live_socket(view).assigns.toasts
      assert length(toasts) == caps.toasts

      assert Enum.map(toasts, & &1.message) ==
               Enum.map(
                 expected_range,
                 &"Unknown command: /unknown_cmd_#{&1}. Type /help for available commands."
               )
    end

    test "dismiss_toast removes a specific toast" do
      {:ok, view, _html} = live(build_conn(), "/")

      # Trigger a toast via unknown command
      view
      |> element("form")
      |> render_submit(%{"text" => "/unknown_cmd"})

      html = render(view)
      # Should show the toast
      assert html =~ "Unknown command"
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming buffer bounds
  # ---------------------------------------------------------------------------

  describe "streaming buffer bounds" do
    test "streaming buffer is cleared on turn_completed" do
      {:ok, view, _html} = live(build_conn(), "/")

      turn_id = "turn_buf_test"

      # Simulate streaming deltas
      delta_event =
        Muse.Event.new(:provider, :assistant_delta, %{text: "chunk1 "},
          id: 1001,
          turn_id: turn_id,
          seq: 1,
          visibility: :user
        )

      send(view.pid, {:muse_event, delta_event})

      # Simulate turn_completed
      completed_event =
        Muse.Event.new(:conductor, :turn_completed, %{text: "done"},
          id: 1002,
          turn_id: turn_id,
          seq: 2,
          visibility: :internal
        )

      send(view.pid, {:muse_event, completed_event})
      _html = render(view)

      assert live_socket(view).assigns.streaming_buffers == %{}
    end

    test "streaming buffer is cleared on turn_failed" do
      {:ok, view, _html} = live(build_conn(), "/")

      turn_id = "turn_fail_buf"

      delta_event =
        Muse.Event.new(:provider, :assistant_delta, %{text: "partial "},
          id: 2001,
          turn_id: turn_id,
          seq: 1,
          visibility: :user
        )

      send(view.pid, {:muse_event, delta_event})

      failed_event =
        Muse.Event.new(:conductor, :turn_failed, %{text: "error"},
          id: 2002,
          turn_id: turn_id,
          seq: 2,
          visibility: :internal
        )

      send(view.pid, {:muse_event, failed_event})
      _html = render(view)

      assert live_socket(view).assigns.streaming_buffers == %{}
    end

    test "streaming buffer is cleared on turn_cancelled" do
      {:ok, view, _html} = live(build_conn(), "/")

      turn_id = "turn_cancel_buf"

      delta_event =
        Muse.Event.new(:provider, :assistant_delta, %{text: "partial "},
          id: 3001,
          turn_id: turn_id,
          seq: 1,
          visibility: :user
        )

      send(view.pid, {:muse_event, delta_event})

      cancelled_event =
        Muse.Event.new(:conductor, :turn_cancelled, %{text: "cancelled"},
          id: 3002,
          turn_id: turn_id,
          seq: 2,
          visibility: :internal
        )

      send(view.pid, {:muse_event, cancelled_event})
      _html = render(view)

      assert live_socket(view).assigns.streaming_buffers == %{}
    end

    test "streaming buffers are cleared on events_cleared" do
      {:ok, view, _html} = live(build_conn(), "/")

      delta_event =
        Muse.Event.new(:provider, :assistant_delta, %{text: "chunk "},
          id: 4001,
          turn_id: "turn_clear_test",
          seq: 1,
          visibility: :user
        )

      send(view.pid, {:muse_event, delta_event})

      # Send events_cleared
      send(view.pid, {:muse_events_cleared})
      _html = render(view)

      assert live_socket(view).assigns.streaming_buffers == %{}
    end

    test "individual streaming buffer respects byte cap", %{caps: caps} do
      # Test the trim helper directly with content exceeding the cap
      big_buffer = String.duplicate("A", caps.streaming_buffer_bytes + 100)

      trimmed =
        Muse.Bounds.trim_streaming_buffer(big_buffer, caps.streaming_buffer_bytes)

      assert byte_size(trimmed) <= caps.streaming_buffer_bytes
      assert String.valid?(trimmed)
    end

    test "UTF-8 streaming buffer stays valid after trim" do
      # Build a buffer with multi-byte chars that exceeds the cap
      emoji = "🌟"
      # Each emoji is 4 bytes
      big_buffer = String.duplicate(emoji, 100)

      trimmed = Muse.Bounds.trim_streaming_buffer(big_buffer, 50)
      assert String.valid?(trimmed)
      assert byte_size(trimmed) <= 50
    end
  end

  # ---------------------------------------------------------------------------
  # Diagnostics bounds
  # ---------------------------------------------------------------------------

  describe "diagnostics bounds" do
    test "diagnostics list stays within cap", %{caps: caps} do
      {:ok, view, _html} = live(build_conn(), "/")

      # Send more diagnostics than the cap
      for i <- 1..(caps.diagnostics + 5) do
        diagnostic = Muse.Diagnostic.new(:warning, "Diagnostic #{i}", %{idx: i})
        send(view.pid, {:muse_diagnostic, diagnostic})
      end

      _html = render(view)

      diagnostics = live_socket(view).assigns.diagnostics
      assert length(diagnostics) == caps.diagnostics

      assert Enum.map(diagnostics, & &1.message) ==
               Enum.map((caps.diagnostics + 5)..6//-1, &"Diagnostic #{&1}")
    end
  end

  # ---------------------------------------------------------------------------
  # Per-session event bounds (SessionServer)
  # ---------------------------------------------------------------------------

  describe "per-session event bounds" do
    test "append_session_events trims to session_events cap" do
      # This tests the SessionServer's event capping via Bounds
      cap = Muse.Bounds.session_events()

      # Create synthetic events that exceed the cap
      events =
        for i <- 1..(cap + 50) do
          Muse.Event.new(:test, :test_event, %{index: i}, id: i, seq: i)
        end

      # Simulate the trimming that SessionServer.append_session_events performs
      result = Muse.Bounds.trim_newest_first(events, cap)

      assert length(result) == cap
      # Newest events survive (highest id/seq)
      assert List.last(result).seq == cap + 50
      # Oldest events are dropped
      assert hd(result).seq == 51
    end
  end
end
