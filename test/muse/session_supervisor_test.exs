defmodule Muse.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias Muse.SessionServer

  # -- Helpers ------------------------------------------------------------------

  defp ensure_registry do
    case Process.whereis(Muse.SessionRegistry) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :unique, name: Muse.SessionRegistry)
        :ok

      _pid ->
        :ok
    end
  end

  defp ensure_supervisor do
    case Process.whereis(Muse.SessionSupervisor) do
      nil ->
        {:ok, _} =
          DynamicSupervisor.start_link(strategy: :one_for_one, name: Muse.SessionSupervisor)

        :ok

      _pid ->
        :ok
    end
  end

  defp clean_sessions do
    case Process.whereis(Muse.SessionSupervisor) do
      nil ->
        :ok

      pid ->
        pid
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            try do
              DynamicSupervisor.terminate_child(Muse.SessionSupervisor, child_pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end)

        # Wait for processes to fully exit and Registry entries to be cleaned
        Process.sleep(10)
    end
  end

  defp registry_key(session_id, base_dir \\ Muse.SessionServer.current_store_base_dir()) do
    Muse.SessionServer.registry_key(session_id, base_dir)
  end

  defp session_count do
    case Process.whereis(Muse.SessionSupervisor) do
      nil -> 0
      pid -> DynamicSupervisor.which_children(pid) |> Enum.count()
    end
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    ensure_registry()
    ensure_supervisor()
    clean_sessions()

    on_exit(fn ->
      clean_sessions()
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  describe "DynamicSupervisor" do
    test "starts with no children" do
      assert session_count() == 0
    end

    test "can start a SessionServer child" do
      assert {:ok, pid} =
               DynamicSupervisor.start_child(
                 Muse.SessionSupervisor,
                 {SessionServer, session_id: "test-1"}
               )

      assert is_pid(pid)
      assert session_count() == 1
    end

    test "can start multiple SessionServer children" do
      for id <- ["a", "b", "c"] do
        assert {:ok, _pid} =
                 DynamicSupervisor.start_child(
                   Muse.SessionSupervisor,
                   {SessionServer, session_id: id}
                 )
      end

      assert session_count() == 3
    end

    test "temporary children are not restarted on crash" do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {SessionServer, session_id: "crashy"}
        )

      assert session_count() == 1

      # Simulate a crash
      Process.exit(pid, :kill)
      Process.sleep(15)

      assert session_count() == 0
    end

    test "started children are registered in SessionRegistry" do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Muse.SessionSupervisor,
          {SessionServer, session_id: "reg-test"}
        )

      assert [{^pid, _}] = Registry.lookup(Muse.SessionRegistry, registry_key("reg-test"))
    end
  end
end
