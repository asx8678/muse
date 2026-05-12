defmodule Muse.Weft.Test.ChannelCase do
  @moduledoc """
  Test case for Weft Phoenix Channels.

  Sets up required GenServers (PubSub, State, Endpoint), configures
  external WS with test token hashes, and provides tidewave-style
  convenience helpers via `Muse.Weft.Test.FakeWsTransport`.

  ## Usage

      defmodule MyWeftChannelTest do
        use Muse.Weft.Test.ChannelCase, async: false

        test "join and push" do
          {:ok, _user_socket, channel_socket} = join_channel("session:abc")
          push(channel_socket, "my_event", %{})
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import Muse.Weft.Test.FakeWsTransport

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
      Muse.State.clear()
    else
      {:ok, _} = Muse.State.start_link([])
    end

    # Ensure the Endpoint is running (required by subscribe_and_join)
    if Process.whereis(MuseWeb.Endpoint) do
      :ok
    else
      {:ok, _} = MuseWeb.Endpoint.start_link()
    end

    # Configure external WS for tests with test token hashes
    original_ws = Application.get_env(:muse, :external_ws)

    test_token_hash =
      :crypto.hash(:sha256, "test-token-16chars-ok")
      |> Base.encode16(case: :lower)

    restricted_token_hash =
      :crypto.hash(:sha256, "test-restricted-token")
      |> Base.encode16(case: :lower)

    Application.put_env(
      :muse,
      :external_ws,
      enabled: true,
      replay_limit: 50,
      token_hashes: [
        %{
          id: "test-token",
          hash: test_token_hash,
          scopes: ["events:read"],
          allowed_sessions: :all
        },
        %{
          id: "test-restricted",
          hash: restricted_token_hash,
          scopes: ["events:read"],
          allowed_sessions: ["sess-allowed"]
        }
      ]
    )

    on_exit(fn ->
      if original_ws do
        Application.put_env(:muse, :external_ws, original_ws)
      else
        Application.delete_env(:muse, :external_ws)
      end

      # Stop processes we started so other tests get clean state
      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.State)
    end)

    :ok
  end

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
end
