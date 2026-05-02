defmodule Muse.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias Muse.Diagnostics

  # -- Helpers -----------------------------------------------------------------

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
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp start_diagnostics(opts \\ []) do
    stop_named(Muse.Diagnostics)

    opts = Keyword.put_new(opts, :install_logger_handler?, false)
    {:ok, _} = Diagnostics.start_link(opts)
    :ok
  end

  # -- Setup -------------------------------------------------------------------

  setup do
    ensure_pubsub()
    Muse.Diagnostics.LoggerHandler.remove()
    start_diagnostics()

    on_exit(fn ->
      Muse.Diagnostics.LoggerHandler.remove()
      stop_named(Muse.Diagnostics)
    end)

    :ok
  end

  # -- Tests -------------------------------------------------------------------

  test "starts empty" do
    assert Diagnostics.list() == []
  end

  test "emit/3 stores diagnostics newest first" do
    warning = Diagnostics.emit(:warning, "first warning")
    error = Diagnostics.emit(:error, "second error")

    assert Diagnostics.list() == [error, warning]
  end

  test "emit/3 broadcasts {:muse_diagnostic, diagnostic}" do
    :ok = Diagnostics.subscribe()

    diagnostic = Diagnostics.emit(:warning, "broadcast warning", %{test: true})

    assert_received {:muse_diagnostic, ^diagnostic}
  end

  test "clear/0 empties diagnostics and broadcasts" do
    Diagnostics.emit(:error, "stored")
    :ok = Diagnostics.subscribe()

    assert :ok = Diagnostics.clear()

    assert Diagnostics.list() == []
    assert_received {:muse_diagnostics_cleared}
  end

  test "keeps a bounded newest-first list" do
    start_diagnostics(max: 2)

    Diagnostics.emit(:warning, "one")
    second = Diagnostics.emit(:error, "two")
    third = Diagnostics.emit(:critical, "three")

    assert Diagnostics.list() == [third, second]
  end
end
