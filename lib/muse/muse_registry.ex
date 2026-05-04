defmodule Muse.MuseRegistry do
  @moduledoc """
  Static registry of built-in Muse profiles.

  All profiles are defined at compile time. Lookup is by `:id` atom or string.

  ## API

    * `all/0`       — all registered profiles in deterministic order
    * `get/1`       — profile or `nil`
    * `fetch/1`     — `{:ok, profile}` or `{:error, :not_found}`
    * `ids/0`       — list of registered profile id atoms
    * `summaries/0` — command-friendly maps for each profile

  ## Registered profiles

    * **Planning Muse** (`:planning`) — read-only, creates approval-gated plans
    * **Coding Muse** (`:coding`)    — implements approved plans via patches

  """

  alias Muse.MuseProfile

  # -- Registered profiles (deterministic order by id) -------------------------

  @planning %MuseProfile{
    id: :planning,
    display_name: "Planning Muse",
    role: :planning,
    description: "Inspects the workspace and creates approval-gated implementation plans.",
    prompt:
      "You are the Planning Muse. Inspect the workspace and create approval-gated implementation plans. Do not write code or modify files.",
    tools: [
      "list_files",
      "read_file",
      "repo_search",
      "git_status",
      "git_diff_readonly",
      "ask_user_question",
      "list_muses",
      "list_skills"
    ],
    permissions: %{
      read: true,
      write: false,
      shell: false,
      network: false,
      can_create_plan: true,
      can_execute_plan: false
    },
    output_schema: Muse.Plan,
    response_mode: :plan,
    can_write?: false,
    requires_plan_approval?: false,
    handoff_targets: [:coding],
    style: %{}
  }

  @coding %MuseProfile{
    id: :coding,
    display_name: "Coding Muse",
    role: :coding,
    description: "Implements approved plans by proposing and applying patches.",
    prompt:
      "You are the Coding Muse. Implement approved plans by proposing and applying patches. Wait for plan approval before writing.",
    tools: [
      "list_files",
      "read_file",
      "repo_search",
      "git_status",
      "git_diff_readonly",
      "patch_propose",
      "patch_apply",
      "test_runner"
    ],
    permissions: %{
      read: true,
      write: :approval_required,
      shell: :approval_required,
      network: false,
      can_create_plan: false,
      can_execute_plan: true
    },
    response_mode: :patch,
    can_write?: true,
    requires_plan_approval?: true,
    handoff_targets: [:planning],
    style: %{}
  }

  # Ordered by id for deterministic listing.  Add new profiles here and
  # in @profiles_by_id below.
  @ordered_ids [:planning, :coding]

  @profiles_by_id %{
    planning: @planning,
    coding: @coding
  }

  # -- Public API ---------------------------------------------------------------

  @doc """
  Returns all registered Muse profiles in deterministic order (by id).

  ## Examples

      iex> length(Muse.MuseRegistry.all())
      2

      iex> hd(Muse.MuseRegistry.all()).id
      :planning

  """
  @spec all() :: [MuseProfile.t()]
  def all do
    Enum.map(@ordered_ids, &Map.fetch!(@profiles_by_id, &1))
  end

  @doc """
  Returns the Muse profile with the given id, or `nil` if not found.

  Accepts atoms (`:planning`) or strings (`"planning"`).

  ## Examples

      iex> Muse.MuseRegistry.get(:planning).display_name
      "Planning Muse"

      iex> Muse.MuseRegistry.get("coding").display_name
      "Coding Muse"

      iex> Muse.MuseRegistry.get(:unknown)
      nil

  """
  @spec get(MuseProfile.id() | String.t()) :: MuseProfile.t() | nil
  def get(id) when is_atom(id) do
    Map.get(@profiles_by_id, id)
  end

  def get(id) when is_binary(id) do
    case String.to_existing_atom(id) do
      atom -> Map.get(@profiles_by_id, atom)
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns `{:ok, profile}` or `{:error, :not_found}`.

  Accepts atoms or strings, same as `get/1`.

  ## Examples

      iex> Muse.MuseRegistry.fetch(:planning)
      {:ok, %Muse.MuseProfile{id: :planning}}

      iex> Muse.MuseRegistry.fetch(:unknown)
      {:error, :not_found}

  """
  @spec fetch(MuseProfile.id() | String.t()) :: {:ok, MuseProfile.t()} | {:error, :not_found}
  def fetch(id) do
    case get(id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Returns the list of registered profile id atoms in deterministic order.

  ## Examples

      iex> Muse.MuseRegistry.ids()
      [:planning, :coding]

  """
  @spec ids() :: [MuseProfile.id()]
  def ids do
    @ordered_ids
  end

  @doc """
  Returns a list of command-friendly summary maps for all profiles.

  Each map contains `:id`, `:display_name`, `:role`, `:description`,
  `:tools`, and `:permissions` — safe for JSON encoding and command output.

  ## Examples

      iex> summaries = Muse.MuseRegistry.summaries()
      iex> hd(summaries).display_name
      "Planning Muse"

      iex> hd(summaries)[:name]
      nil

  """
  @spec summaries() :: [map()]
  def summaries do
    Enum.map(all(), &MuseProfile.summary/1)
  end
end
