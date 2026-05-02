defmodule Muse.Workspace do
  @moduledoc """
  Stores workspace root once at boot; provides safe path resolution.

  The Agent is globally named `__MODULE__` so the rest of the app can call
  `root/0` and `resolve!/1` without carrying a pid.

  `resolve!/1` guarantees the resolved path never escapes the workspace root,
  using separator-aware prefix checking (no `/tmp/foo` vs `/tmp/foobar` bugs).
  """

  use Agent

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    root =
      opts
      |> Keyword.fetch!(:root)
      |> Path.expand()

    Agent.start_link(fn -> root end, name: __MODULE__)
  end

  @spec root() :: String.t()
  def root, do: Agent.get(__MODULE__, & &1)

  @spec resolve!(String.t()) :: String.t()
  def resolve!(path) do
    root = root()
    resolved = Path.expand(path, root)

    if inside_workspace?(resolved, root) do
      resolved
    else
      raise ArgumentError,
            "path #{inspect(path)} escapes workspace #{inspect(root)}"
    end
  end

  # -- Private -----------------------------------------------------------------

  # A path is inside the workspace if it is exactly the root *or* the root
  # is a proper directory prefix — meaning `resolved` starts with `root <> "/"`.
  # This avoids the sibling-prefix trap where "/tmp/foo" would falsely match
  # "/tmp/foobar/file".
  defp inside_workspace?(resolved, root) do
    resolved == root or String.starts_with?(resolved, root <> "/")
  end
end
