defmodule Muse.ActiveWorkspace do
  @moduledoc """
  Tracks the active workspace profile for the Muse runtime.

  Provides the current `store_base_dir` (sessions directory) and `root_path`
  used by `SessionServer` for persistence isolation. When a workspace profile
  is switched via `/workspace switch <name>`, the active workspace state is
  updated so that **newly started** sessions use the new workspace's session
  store directory. Already-running sessions retain the `store_base_dir` they
  captured at init time, so they are never redirected mid-lifetime.

  ## Default state

  When no profile is active, the store_base_dir falls back to
  `<workspace_root>/.muse/sessions` where `workspace_root` comes from the
  `Muse.Workspace` agent, or `".muse/sessions"` if the agent is unavailable.

  ## Process safety

  This is a named GenServer. Tests must start/stop it explicitly or call
  `reset/0` in setup to avoid leaking state between tests.

  ## Security

  Profile names are validated through `Muse.WorkspaceProfile.get_profile/1`
  before switching. Path traversal is blocked at the profile layer.
  No secrets are stored in this process.
  """

  use GenServer

  @default_store_base_dir ".muse/sessions"

  # ── Types ──────────────────────────────────────────────────────────────

  @type state :: %{
          profile_name: String.t() | nil,
          root_path: String.t(),
          store_base_dir: String.t()
        }

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Starts the ActiveWorkspace GenServer.

  ## Options

    * `:root_path` — initial workspace root path (default: from `Muse.Workspace` agent)
    * `:store_base_dir` — initial sessions dir (default: derived from root_path)
    * `:name` — GenServer name (default: `__MODULE__`)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    root_path = Keyword.get(opts, :root_path) || safe_workspace_root()
    store_base_dir = Keyword.get(opts, :store_base_dir) || derive_store_base_dir(root_path)

    init_state = %{
      profile_name: nil,
      root_path: root_path,
      store_base_dir: store_base_dir
    }

    GenServer.start_link(__MODULE__, init_state, name: name)
  end

  @doc """
  Returns the full active workspace state map.
  """
  @spec get() :: state()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc """
  Returns the current active workspace profile name, or `nil` if default.
  """
  @spec profile_name() :: String.t() | nil
  def profile_name do
    GenServer.call(__MODULE__, :profile_name)
  end

  @doc """
  Returns the current store base directory for sessions.
  """
  @spec store_base_dir() :: String.t()
  def store_base_dir do
    GenServer.call(__MODULE__, :store_base_dir)
  end

  @doc """
  Returns the current workspace root path.
  """
  @spec root_path() :: String.t()
  def root_path do
    GenServer.call(__MODULE__, :root_path)
  end

  @doc """
  Switches the active workspace to the named profile.

  Validates the profile exists via `Muse.WorkspaceProfile.get_profile/1`.
  Only newly started sessions will use the new workspace; existing sessions
  keep the `store_base_dir` they captured at init.

  Returns `{:ok, profile}` on success, or `{:error, reason}` on failure.

  ## Options

    * `:muse_dir` — override the global muse directory for profile lookup
  """
  @spec switch(String.t(), keyword()) ::
          {:ok, Muse.WorkspaceProfile.profile()} | {:error, term()}
  def switch(profile_name, opts \\ []) when is_binary(profile_name) do
    GenServer.call(__MODULE__, {:switch, profile_name, opts})
  end

  @doc """
  Resets the active workspace to default (no profile active).

  The store_base_dir falls back to the Workspace agent root or
  `.muse/sessions`.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Sets the active workspace state directly without profile lookup.

  Used for testing or programmatic control. Prefer `switch/1` for
  command-driven switching.
  """
  @spec set(String.t() | nil, String.t()) :: :ok
  def set(root_path, store_base_dir) when is_binary(store_base_dir) do
    GenServer.call(__MODULE__, {:set, root_path, store_base_dir})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:profile_name, _from, state) do
    {:reply, state.profile_name, state}
  end

  @impl true
  def handle_call(:store_base_dir, _from, state) do
    {:reply, state.store_base_dir, state}
  end

  @impl true
  def handle_call(:root_path, _from, state) do
    {:reply, state.root_path, state}
  end

  @impl true
  def handle_call({:switch, profile_name, opts}, _from, state) do
    muse_dir = Keyword.get(opts, :muse_dir) || Muse.WorkspaceProfile.global_muse_dir()

    case Muse.WorkspaceProfile.get_profile(profile_name, muse_dir) do
      {:ok, profile} ->
        new_state = %{
          profile_name: profile.name,
          root_path: profile.root_path,
          store_base_dir: profile.sessions_dir
        }

        {:reply, {:ok, profile}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    root_path = safe_workspace_root()

    new_state = %{
      profile_name: nil,
      root_path: root_path,
      store_base_dir: derive_store_base_dir(root_path)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set, root_path, store_base_dir}, _from, _state) do
    new_state = %{
      profile_name: nil,
      root_path: root_path,
      store_base_dir: store_base_dir
    }

    {:reply, :ok, new_state}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp safe_workspace_root do
    case Process.whereis(Muse.Workspace) do
      nil -> nil
      pid -> if Process.alive?(pid), do: Muse.Workspace.root(), else: nil
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :safe_workspace_root, e)
      nil
  end

  defp derive_store_base_dir(nil), do: @default_store_base_dir

  defp derive_store_base_dir(root_path),
    do: Muse.WorkspaceProfile.sessions_dir_from_root(root_path)
end
