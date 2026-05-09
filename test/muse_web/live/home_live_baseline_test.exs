defmodule MuseWeb.HomeLiveBaselineTest do
  @moduledoc """
  T0-00 Baseline: LiveView event rendering and EventStream integration.

  These tests verify that the LiveView can render a page with events
  and that `EventStream.chat_messages/1` produces renderable data
  for the LiveView template — without starting a full browser.

  Uses the existing LiveView test infrastructure from `home_live_test.exs`.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MuseWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Helpers (mirroring HomeLiveTest infrastructure)
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

  setup do
    ensure_pubsub()

    tmp_dir = System.tmp_dir!()
    workspace_root = Path.join(tmp_dir, "muse_lv_baseline_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)

    Muse.Diagnostics.LoggerHandler.remove()
    start_workspace(workspace_root)
    start_state()
    start_diagnostics()
    start_self_healing_queue()
    start_agent_registry()
    start_endpoint()

    on_exit(fn ->
      Muse.Diagnostics.LoggerHandler.remove()
      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.AgentRegistry)
      stop_named(Muse.SelfHealingQueue)
      stop_named(Muse.Diagnostics)
      stop_named(Muse.State)
      stop_named(Muse.Workspace)
      File.rm_rf!(workspace_root)
    end)

    {:ok, workspace_root: workspace_root}
  end

  # ---------------------------------------------------------------------------
  # LiveView renders — baseline
  # ---------------------------------------------------------------------------

  describe "LiveView rendering — baseline" do
    test "connects and renders the home page" do
      {:ok, _view, html} = live(build_conn(), "/")

      # The page should render without error
      assert html =~ "Muse" or html =~ "muse"
    end

    test "chat_messages from EventStream produce renderable maps" do
      alias Muse.Test.EventFixtures, as: EF

      events = EF.bulk_chat_turns(5, session_id: "sess_lv")

      messages = Muse.EventStream.chat_messages(events)

      # Each message should have the keys the LiveView template expects
      for msg <- messages do
        assert Map.has_key?(msg, :id)
        assert Map.has_key?(msg, :role)
        assert Map.has_key?(msg, :text)
        assert Map.has_key?(msg, :timestamp)
        assert Map.has_key?(msg, :streaming?)
        assert msg.role in [:user, :assistant, :system]
        assert is_binary(msg.text)
      end
    end

    test "streaming messages are marked with streaming?: true" do
      alias Muse.Test.EventFixtures, as: EF

      # Build an incomplete streaming turn (deltas, no final)
      events =
        EF.streaming_turn("t1", "hello", ["chunk1 ", "chunk2 "],
          base_id: 1,
          session_id: "sess_lv"
        )
        # Remove the final assistant_message to simulate an in-progress stream
        |> Enum.reject(&(&1.type == :assistant_message))

      messages = Muse.EventStream.chat_messages(events)

      # The assistant message from deltas should be streaming
      streaming_msgs = Enum.filter(messages, &(&1.streaming? == true))
      assert length(streaming_msgs) >= 1
    end
  end
end
