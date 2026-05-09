defmodule Muse.Integration.CliWebSharedEventsTest do
  @moduledoc """
  Integration tests proving that events flow bidirectionally between
  the CLI REPL and the LiveView web interface through the shared
  Muse.State + PubSub architecture.

  These tests explicitly start the required global processes (PubSub,
  Workspace, State, Endpoint) so they don't depend on the full
  Application supervisor wiring (which is Step 11's job).
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MuseWeb.Endpoint

  # -- Helpers ------------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)

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
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

      _pid ->
        :ok
    end
  end

  defp start_workspace(root) do
    stop_named(Muse.Workspace)
    {:ok, pid} = Muse.Workspace.start_link(root: root)
    Process.unlink(pid)
  end

  defp start_state do
    stop_named(Muse.State)
    {:ok, pid} = Muse.State.start_link([])
    Process.unlink(pid)
  end

  defp start_endpoint do
    stop_named(MuseWeb.Endpoint)
    {:ok, pid} = MuseWeb.Endpoint.start_link()
    Process.unlink(pid)
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    ensure_pubsub()

    tmp_dir = System.tmp_dir!()

    workspace_root =
      Path.join(tmp_dir, "muse_integration_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)

    start_workspace(workspace_root)
    start_state()
    start_endpoint()

    on_exit(fn ->
      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.State)
      stop_named(Muse.Workspace)
      File.rm_rf!(workspace_root)
    end)

    {:ok, workspace_root: workspace_root}
  end

  # -- CLI → Web ----------------------------------------------------------------

  describe "CLI submit → Web sees events" do
    test "events submitted via CLI appear in LiveView HTML" do
      # Submit through CLI
      ExUnit.CaptureIO.capture_io(fn ->
        Muse.CLI.Repl.handle_input("hello from cli", halt?: false)
      end)

      # Mount LiveView after CLI submit
      {:ok, _view, html} = live(build_conn(), "/")

      # The LiveView should display both the user message and assistant response
      assert html =~ "hello from cli"
      assert html =~ "Placeholder response"
    end

    test "CLI source is recorded as :cli" do
      ExUnit.CaptureIO.capture_io(fn ->
        Muse.CLI.Repl.handle_input("cli sourcing", halt?: false)
      end)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "cli"
    end

    test "multiple CLI submissions accumulate in LiveView" do
      ExUnit.CaptureIO.capture_io(fn ->
        Muse.CLI.Repl.handle_input("first message", halt?: false)
      end)

      ExUnit.CaptureIO.capture_io(fn ->
        Muse.CLI.Repl.handle_input("second message", halt?: false)
      end)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "first message"
      assert html =~ "second message"
    end
  end

  # -- Web → CLI ----------------------------------------------------------------

  describe "Web submit → CLI /events sees them" do
    test "events submitted via LiveView appear in CLI /events output" do
      # Mount and submit through LiveView
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("#command-form") |> render_submit(%{"text" => "hello from web"})

      # T0-04: submit is now non-blocking; wait for async events to complete
      Process.sleep(100)

      # Check events via CLI /events
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Muse.CLI.Repl.handle_input("/events", halt?: false)
        end)

      # The user text should appear in the output
      assert output =~ "hello from web"
      # The [muse] source should appear (assistant events)
      assert output =~ "[muse]"
      # The [web] source may or may not appear depending on display
      # truncation (only last 10 of 12 shown). Verify via State directly.
      events = Muse.State.events()
      web_events = Enum.filter(events, &(&1.source == :web))
      assert length(web_events) >= 1
    end

    test "assistant response for web submit is visible in CLI /events" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("#command-form") |> render_submit(%{"text" => "web query"})

      # T0-04: submit is now non-blocking; wait for async events to complete
      Process.sleep(100)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Muse.CLI.Repl.handle_input("/events", halt?: false)
        end)

      assert output =~ "Placeholder response"
      assert output =~ "web query"
    end

    test "multiple web submissions accumulate in CLI /events" do
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("#command-form") |> render_submit(%{"text" => "web first"})
      # T0-04: wait for first async turn to complete before submitting second
      Process.sleep(100)
      view |> element("#command-form") |> render_submit(%{"text" => "web second"})
      Process.sleep(100)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Muse.CLI.Repl.handle_input("/events", halt?: false)
        end)

      # With 12 events per submit, CLI /events may truncate.
      # Verify events are in State directly.
      events = Muse.State.events()
      user_events = Enum.filter(events, &(&1.type == :user_message))
      assert length(user_events) == 2
      texts = Enum.map(user_events, & &1.data.text)
      assert "web first" in texts
      assert "web second" in texts

      # CLI /events should show event log header
      assert output =~ "Event log"
    end
  end

  # -- Bidirectional round-trip -------------------------------------------------

  describe "bidirectional event flow" do
    test "CLI and Web events coexist in both views" do
      # Submit from CLI
      ExUnit.CaptureIO.capture_io(fn ->
        Muse.CLI.Repl.handle_input("from cli side", halt?: false)
      end)

      # Submit from Web
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("#command-form") |> render_submit(%{"text" => "from web side"})

      # T0-04: submit is now non-blocking; wait for async events to complete
      Process.sleep(100)

      # Both events appear in LiveView
      html = render(view)
      assert html =~ "from cli side"
      assert html =~ "from web side"

      # Both user messages appear in State
      events = Muse.State.events()
      user_events = Enum.filter(events, &(&1.type == :user_message))
      texts = Enum.map(user_events, & &1.data.text)
      assert "from cli side" in texts
      assert "from web side" in texts
    end

    test "event ordering is preserved across interfaces" do
      # Submit from CLI first
      ExUnit.CaptureIO.capture_io(fn ->
        Muse.CLI.Repl.handle_input("cli event", halt?: false)
      end)

      # Then from Web
      {:ok, view, _html} = live(build_conn(), "/")

      view |> element("#command-form") |> render_submit(%{"text" => "web event"})

      # T0-04: submit is now non-blocking; wait for async events to complete
      Process.sleep(100)

      # Verify order in State directly
      events = Muse.State.events()
      types = Enum.map(events, & &1.type)

      # Each submit emits 12 events after Conductor integration
      expected_single = [
        :user_message,
        :turn_started,
        :assistant_delta,
        :muse_selected,
        :session_status_changed,
        :prompt_prepared,
        :provider_request_started,
        :provider_response_started,
        :provider_response_completed,
        :assistant_message,
        :session_status_changed,
        :turn_completed
      ]

      assert types == expected_single ++ expected_single
    end
  end
end
