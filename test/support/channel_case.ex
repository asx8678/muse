defmodule MuseWeb.ChannelCase do
  @moduledoc """
  Test helpers for Phoenix Channel tests in the Muse web layer.

  Sets up `Muse.PubSub` and `Muse.State` before each test, provides a
  `socket_connect/0` helper, and imports `Phoenix.ChannelTest`.

  ## Usage

      defmodule MuseWeb.SessionChannelTest do
        use MuseWeb.ChannelCase, async: true
        # ...
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint MuseWeb.Endpoint

      import MuseWeb.ChannelCase

      # Alias for convenience in tests
      alias Muse.{Event, State}
    end
  end

  setup do
    ensure_pubsub()
    start_clean_endpoint()
    start_clean_state()
    :ok
  end

  @doc """
  Starts `Muse.PubSub` if not already running.
  """
  def ensure_pubsub do
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

  @doc """
  Starts a clean `MuseWeb.Endpoint` (stops any existing one first).
  """
  def start_clean_endpoint do
    stop_named(MuseWeb.Endpoint)
    {:ok, _} = MuseWeb.Endpoint.start_link([])
    :ok
  end

  @doc """
  Starts a clean `Muse.State` (stops any existing one first).
  """
  def start_clean_state do
    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])
    :ok
  end

  @doc """
  Stops a registered process by name, if running. Swallows exits.
  """
  def stop_named(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop_pid(pid)
    end
  end

  defp stop_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end
end
