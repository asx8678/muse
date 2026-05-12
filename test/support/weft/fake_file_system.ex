defmodule Muse.Weft.Test.FakeFileSystem do
  @moduledoc """
  Fake FileSystem GenServer for testing WatchChannel without real
  file system watchers.

  Subscribe callers and replay `:file_event` messages on demand.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def subscribe(pid) do
    GenServer.call(pid, {:subscribe, self()})
  end

  def send_event(pid, path, events) do
    GenServer.cast(pid, {:send_event, path, events})
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscribers: []}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_cast({:send_event, path, events}, state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:file_event, self(), {path, events}})
    end)

    {:noreply, state}
  end
end
