defmodule Muse.Weft.Test.FakePort do
  @moduledoc """
  Fake Port module for testing TerminalChannel without real shell processes.

  Spawns a lightweight GenServer that accepts `{caller, {:command, data}}`
  and replies with `{self(), {:data, data}}` (echo behaviour).
  """

  use GenServer

  def open({:spawn_executable, _path}, _opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [])
    pid
  end

  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 100)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init([]) do
    {:ok, nil}
  end

  @impl true
  def handle_info({from, {:command, data}}, state) do
    send(from, {self(), {:data, data}})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
