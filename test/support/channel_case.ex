defmodule MuseWeb.ChannelCase do
  @moduledoc """
  Test case for MuseWeb Phoenix Channels.

  Sets up required GenServers (PubSub, State) and provides helpers
  for building test events.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import MuseWeb.ChannelCase.Helpers

      @endpoint MuseWeb.Endpoint
    end
  end

  setup _context do
    # Ensure PubSub is running (tests run with start_runtime_children?: false)
    if Process.whereis(Muse.PubSub) do
      :ok
    else
      {:ok, _} =
        Supervisor.start_link(
          [{Phoenix.PubSub, name: Muse.PubSub}],
          strategy: :one_for_one
        )
    end

    # Ensure Muse.State is running for subscribe/0 and replay
    if Process.whereis(Muse.State) do
      # Reset to empty state for test isolation
      Muse.State.clear()
    else
      {:ok, _} = Muse.State.start_link([])
    end

    # Ensure external WS config is enabled for channel tests
    original_ws = Application.get_env(:muse, :external_ws)
    Application.put_env(:muse, :external_ws, enabled: true, replay_limit: 50)

    on_exit(fn ->
      if original_ws do
        Application.put_env(:muse, :external_ws, original_ws)
      else
        Application.delete_env(:muse, :external_ws)
      end
    end)

    :ok
  end
end

defmodule MuseWeb.ChannelCase.Helpers do
  @moduledoc false

  alias Muse.Event

  @doc "Create a test event with sensible defaults."
  def build_event(opts \\ []) do
    Event.new(
      Keyword.get(opts, :source, :test),
      Keyword.get(opts, :type, :info),
      Keyword.get(opts, :data, %{}),
      Keyword.delete(opts, :source)
      |> Keyword.delete(:type)
      |> Keyword.delete(:data)
    )
  end
end
