defmodule Muse.HealthTest do
  use ExUnit.Case, async: false

  alias Muse.{Health, State, Workspace}

  # -- Helpers ------------------------------------------------------------------

  defp stop_workspace do
    case Process.whereis(Muse.Workspace) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp stop_state do
    case Process.whereis(Muse.State) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    try do
      # Use :normal reason so linked test process doesn't also exit
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp fresh_workspace do
    tmp_dir = System.tmp_dir!()
    root = Path.join(tmp_dir, "muse_health_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    root = fresh_workspace()
    stop_workspace()
    stop_state()
    Workspace.start_link(root: root)
    State.start_link()

    on_exit(fn ->
      stop_workspace()
      stop_state()
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # -- Tests --------------------------------------------------------------------

  describe "check!/0" do
    test "returns :ok when all checks pass" do
      assert Health.check!() == :ok
    end

    test "raises when Muse.Workspace is not running" do
      stop_workspace()

      assert_raise RuntimeError, ~r/Muse\.Workspace process not running/, fn ->
        Health.check!()
      end
    end

    test "raises when workspace root is not a directory" do
      stop_workspace()
      Workspace.start_link(root: "/nonexistent/muse_health_bad_path")

      assert_raise RuntimeError, ~r/is not a directory/, fn ->
        Health.check!()
      end
    end

    test "raises when Muse.State is not running" do
      stop_state()

      assert_raise RuntimeError, ~r/Muse\.State/, fn ->
        Health.check!()
      end
    end
  end
end
