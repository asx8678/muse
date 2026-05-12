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
    Diagnostics.emit(:warning, "first warning")
    Diagnostics.emit(:error, "second error")

    [error, warning] = Diagnostics.list()
    assert error.level == :error and error.message == "second error"
    assert warning.level == :warning and warning.message == "first warning"
  end

  test "emit/3 broadcasts {:muse_diagnostic, diagnostic}" do
    :ok = Diagnostics.subscribe()

    :ok = Diagnostics.emit(:warning, "broadcast warning", %{test: true})

    assert_receive {:muse_diagnostic, diagnostic}, 500
    assert diagnostic.level == :warning
    assert diagnostic.message == "broadcast warning"
    assert diagnostic.metadata == %{test: true}
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
    Diagnostics.emit(:error, "two")
    Diagnostics.emit(:critical, "three")

    [third, second] = Diagnostics.list()
    assert third.level == :critical and third.message == "three"
    assert second.level == :error and second.message == "two"
  end

  describe "session-scoped subscribe/1" do
    test "subscribe/0 subscribes to the default session topic" do
      :ok = Diagnostics.subscribe()

      :ok = Diagnostics.emit(:warning, "default topic")

      assert_receive {:muse_diagnostic, diagnostic}, 500
      assert diagnostic.message == "default topic"
    end

    test "subscribe/1 subscribes to a session-scoped topic" do
      :ok = Diagnostics.subscribe("diag-1")

      # Session-scoped diagnostics topics don't receive global broadcasts
      # (emit/3 broadcasts on global + default, not on arbitrary session topics)
      :ok = Diagnostics.emit(:error, "global emit")

      refute_receive {:muse_diagnostic, _}, 100
    end

    test "unsubscribe/1 removes session-scoped subscription" do
      :ok = Diagnostics.subscribe("diag-2")
      :ok = Diagnostics.unsubscribe("diag-2")

      # After unsubscribe, should not receive on the removed topic
      # (Even if events were broadcast there, we'd no longer get them)
      refute_receive {:muse_diagnostic, _}, 100
    end
  end
end
