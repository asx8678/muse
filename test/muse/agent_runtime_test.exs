defmodule Muse.AgentRuntimeTest do
  use ExUnit.Case, async: false

  alias Muse.AgentRuntime

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

  defp stop_agent_runtime do
    case Process.whereis(Muse.AgentRuntime) do
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

  setup do
    ensure_pubsub()
    stop_agent_runtime()

    {:ok, _} = AgentRuntime.start_link([])

    on_exit(fn ->
      stop_agent_runtime()
    end)

    :ok
  end

  describe "snapshot/0" do
    test "returns initial disconnected state" do
      snap = AgentRuntime.snapshot()
      assert snap.status == :disconnected
      assert snap.health == :inactive
      assert snap.last_error == nil
      assert snap.last_attempt_at == nil
    end
  end

  describe "connect/1" do
    test "transitions to error state with transport message" do
      result = AgentRuntime.connect("ws://localhost:4000")
      assert {:error, "Runtime transport not configured"} = result

      snap = AgentRuntime.snapshot()
      assert snap.status == :error
      assert snap.last_error == "Runtime transport not configured"
      assert snap.last_attempt_at != nil
    end
  end

  describe "retry/0" do
    test "transitions to error state with transport message" do
      result = AgentRuntime.retry()
      assert {:error, "Runtime transport not configured"} = result

      snap = AgentRuntime.snapshot()
      assert snap.status == :error
      assert snap.last_error == "Runtime transport not configured"
    end
  end

  describe "disconnect/0" do
    test "resets to disconnected state" do
      # First connect (to error), then disconnect
      AgentRuntime.connect(nil)
      {:ok, snap} = AgentRuntime.disconnect()

      assert snap.status == :disconnected
      assert snap.health == :inactive
      assert snap.last_error == nil
      assert snap.last_attempt_at == nil
    end
  end

  describe "set_endpoint/1" do
    test "updates endpoint" do
      :ok = AgentRuntime.set_endpoint("ws://example.com:4001")
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://example.com:4001"
    end
  end

  describe "normalize_endpoint/2" do
    test "trims whitespace from endpoint" do
      :ok = AgentRuntime.set_endpoint("  ws://host:4000  ")
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://host:4000"
    end

    test "nil endpoint keeps current" do
      :ok = AgentRuntime.set_endpoint("ws://custom:4000")
      :ok = AgentRuntime.set_endpoint(nil)
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://custom:4000"
    end

    test "blank/empty endpoint keeps current" do
      :ok = AgentRuntime.set_endpoint("ws://custom:4000")
      :ok = AgentRuntime.set_endpoint("")
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://custom:4000"
    end

    test "whitespace-only endpoint keeps current" do
      :ok = AgentRuntime.set_endpoint("ws://custom:4000")
      :ok = AgentRuntime.set_endpoint("   ")
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://custom:4000"
    end

    test "non-binary endpoint is stringified" do
      :ok = AgentRuntime.set_endpoint(12345)
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "12345"
    end

    test "blank endpoint with blank current falls back to default" do
      # Disconnect resets endpoint? No, just test via fresh state.
      # Set to blank, then blank again
      :ok = AgentRuntime.set_endpoint("")
      snap = AgentRuntime.snapshot()
      # Should fall back to default since state was disconnected with default
      assert snap.endpoint == "ws://localhost:4000"
    end

    test "tuple endpoint is inspected and does not raise" do
      :ok = AgentRuntime.set_endpoint({:host, 123})
      snap = AgentRuntime.snapshot()
      assert is_binary(snap.endpoint)
      assert snap.endpoint =~ "host"
    end
  end

  describe "connect/1 endpoint normalization" do
    test "connect with nil uses current endpoint" do
      :ok = AgentRuntime.set_endpoint("ws://custom:9999")
      {:error, _} = AgentRuntime.connect(nil)
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://custom:9999"
    end

    test "connect with endpoint trims whitespace" do
      {:error, _} = AgentRuntime.connect("  ws://host:1234  ")
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://host:1234"
    end

    test "connect with blank endpoint keeps current" do
      :ok = AgentRuntime.set_endpoint("ws://original:4000")
      {:error, _} = AgentRuntime.connect("")
      snap = AgentRuntime.snapshot()
      assert snap.endpoint == "ws://original:4000"
    end
  end

  describe "subscribe/0" do
    test "broadcasts runtime updates" do
      :ok = AgentRuntime.subscribe()

      AgentRuntime.connect("ws://localhost:9999")

      assert_received {:muse_agent_runtime_updated, snapshot}
      assert snapshot.status == :error
    end

    test "broadcasts disconnect updates" do
      :ok = AgentRuntime.subscribe()

      AgentRuntime.disconnect()

      assert_received {:muse_agent_runtime_updated, snapshot}
      assert snapshot.status == :disconnected
    end
  end
end
