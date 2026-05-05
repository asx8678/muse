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
