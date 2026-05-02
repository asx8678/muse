defmodule Muse.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias Muse.AgentRegistry

  # -- Helpers ------------------------------------------------------------------

  defp stop_registry do
    case Process.whereis(Muse.AgentRegistry) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
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

  defp start_registry(opts \\ []) do
    stop_registry()
    {:ok, _} = AgentRegistry.start_link(opts)
    :ok
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    ensure_pubsub()
    start_registry()

    on_exit(fn ->
      stop_registry()
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  describe "snapshot/0" do
    test "returns agents list" do
      snap = AgentRegistry.snapshot()
      assert is_map(snap)
      assert Map.has_key?(snap, :agents)
      assert is_list(snap.agents)
    end

    test "initial snapshot has no agents" do
      snap = AgentRegistry.snapshot()
      assert snap.agents == []
    end
  end

  describe "register_agent/1" do
    test "adds an agent to the registry" do
      :ok = AgentRegistry.register_agent(%{id: :coder, name: "Coder", kind: :coder})
      snap = AgentRegistry.snapshot()
      assert length(snap.agents) == 1

      agent = hd(snap.agents)
      assert agent.id == :coder
      assert agent.name == "Coder"
      assert agent.kind == :coder
      assert agent.status == :idle
    end

    test "broadcasts update via PubSub" do
      Phoenix.PubSub.subscribe(Muse.PubSub, "muse:agent_registry")
      :ok = AgentRegistry.register_agent(%{id: :test_agent})

      assert_received {:muse_agent_registry_updated, snapshot}
      assert is_map(snapshot)
      assert length(snapshot.agents) == 1
    end
  end

  describe "update_agent/2" do
    test "updates existing agent fields" do
      :ok = AgentRegistry.register_agent(%{id: :coder, name: "Coder"})

      :ok = AgentRegistry.update_agent(:coder, %{status: :busy, task: "Fixing bug"})

      snap = AgentRegistry.snapshot()
      agent = hd(snap.agents)
      assert agent.status == :busy
      assert agent.task == "Fixing bug"
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = AgentRegistry.update_agent(:nonexistent, %{status: :busy})
    end

    test "updates updated_at timestamp" do
      :ok = AgentRegistry.register_agent(%{id: :coder})
      before = AgentRegistry.snapshot().agents |> hd() |> Map.get(:updated_at)

      Process.sleep(10)
      :ok = AgentRegistry.update_agent(:coder, %{status: :busy})

      after_update = AgentRegistry.snapshot().agents |> hd() |> Map.get(:updated_at)
      assert DateTime.compare(after_update, before) in [:gt, :eq]
    end
  end

  describe "unregister_agent/1" do
    test "removes an agent from the registry" do
      :ok = AgentRegistry.register_agent(%{id: :coder})
      assert length(AgentRegistry.snapshot().agents) == 1

      :ok = AgentRegistry.unregister_agent(:coder)
      assert AgentRegistry.snapshot().agents == []
    end

    test "unregister non-existent agent is a no-op" do
      :ok = AgentRegistry.unregister_agent(:nonexistent)
      assert AgentRegistry.snapshot().agents == []
    end
  end

  describe "subscribe/0" do
    test "receives broadcast on register" do
      :ok = AgentRegistry.subscribe()
      :ok = AgentRegistry.register_agent(%{id: :watcher_test})

      assert_received {:muse_agent_registry_updated, _}
    end

    test "receives broadcast on update" do
      :ok = AgentRegistry.register_agent(%{id: :watcher_test2})
      :ok = AgentRegistry.subscribe()

      :ok = AgentRegistry.update_agent(:watcher_test2, %{status: :busy})

      assert_received {:muse_agent_registry_updated, _}
    end

    test "receives broadcast on unregister" do
      :ok = AgentRegistry.register_agent(%{id: :watcher_test3})
      :ok = AgentRegistry.subscribe()

      :ok = AgentRegistry.unregister_agent(:watcher_test3)

      assert_received {:muse_agent_registry_updated, _}
    end
  end
end
