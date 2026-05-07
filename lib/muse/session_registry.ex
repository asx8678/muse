defmodule Muse.SessionRegistry do
  @moduledoc """
  Named `Registry` process for unique `{store_base_dir, session_id}` →
  `Muse.SessionServer` pid lookups.

  Started by `Muse.Application` via both `base_children/0` and
  `runtime_children/1` alongside `Muse.SessionSupervisor`. Every running
  `Muse.SessionServer` registers here with its captured store directory and
  session id as the key so that `Muse.SessionRouter` can dispatch to the
  correct workspace-scoped process without a linear scan.
  """

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    registry_opts = Keyword.merge([keys: :unique, name: __MODULE__], opts)

    %{
      id: __MODULE__,
      start: {Registry, :start_link, [registry_opts]},
      type: :supervisor
    }
  end
end
