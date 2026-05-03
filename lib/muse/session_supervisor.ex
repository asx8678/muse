defmodule Muse.SessionSupervisor do
  @moduledoc """
  `DynamicSupervisor` that manages per-session `Muse.SessionServer`
  processes.

  Started by `Muse.Application` via both `base_children/0` and
  `runtime_children/1`. New session servers are started by
  `Muse.SessionRouter` calling `start_child/2`.
  """

  use DynamicSupervisor

  # -- Public API ---------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Callbacks ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
