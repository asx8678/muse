defmodule Muse.WorkspaceProfile do
  @moduledoc """
  Workspace profiles for multi-project session isolation.

  Each workspace profile defines a root directory and derives a
  per-workspace session store path, ensuring sessions from different
  projects never share state.

  ## Layout

      <global_muse_dir>/
        profiles.json          # Registry of workspace profiles
        <profile_name>/
          .muse/
            sessions/          # Per-workspace session store

  ## Security

  - Profile names are validated to block path traversal characters.
  - Session directories are scoped under the profile's workspace root.
  - No secrets are stored in profiles.json.

  ## Profile Structure

  A profile map contains:

    * `:name`         — unique profile name (string)
    * `:root_path`    — absolute workspace root path
    * `:sessions_dir` — derived: `<root_path>/.muse/sessions`
    * `:created_at`   — ISO 8601 timestamp
    * `:updated_at`   — ISO 8601 timestamp
  """

  @default_muse_dir ".muse"
  @profiles_filename "profiles.json"

  # Characters that would allow path traversal in profile names
  @path_traversal_chars ~r([/\\\0])

  # ── Types ──────────────────────────────────────────────────────────────

  @type profile :: %{
          name: String.t(),
          root_path: String.t(),
          sessions_dir: String.t(),
          created_at: String.t(),
          updated_at: String.t()
        }

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns the global Muse directory path.

  Defaults to `.muse` relative to the current directory.
  Can be overridden via the `MUSE_DIR` environment variable or
  the `:muse_dir` application config key.
  """
  @spec global_muse_dir() :: String.t()
  def global_muse_dir do
    env = System.get_env("MUSE_DIR")
    app = Application.get_env(:muse, :muse_dir)

    cond do
      is_binary(env) and env != "" -> Path.expand(env)
      is_binary(app) and app != "" -> Path.expand(app)
      true -> Path.expand(@default_muse_dir)
    end
  end

  @doc """
  Returns the path to the profiles registry file.
  """
  @spec profiles_path() :: String.t()
  def profiles_path do
    Path.join(global_muse_dir(), @profiles_filename)
  end

  @doc """
  Creates a new workspace profile.

  Options:
    * `:name`      — profile name (required)
    * `:root_path` — workspace root path (required)
    * `:muse_dir`  — override the global muse directory

  The `sessions_dir` is derived as `<root_path>/.muse/sessions`.

  Returns `{:ok, profile}` on success, or `{:error, reason}` on failure.
  """
  @spec create(keyword()) :: {:ok, profile()} | {:error, term()}
  def create(opts) do
    name = Keyword.get(opts, :name)
    root_path = Keyword.get(opts, :root_path)
    muse_dir = Keyword.get(opts, :muse_dir) || global_muse_dir()

    with {:ok, name} <- validate_profile_name(name),
         {:ok, root_path} <- validate_root_path(root_path) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      sessions_dir = Path.join(root_path, ".muse/sessions")

      profile = %{
        name: name,
        root_path: root_path,
        sessions_dir: sessions_dir,
        created_at: now,
        updated_at: now
      }

      case save_profile(muse_dir, profile) do
        :ok -> {:ok, profile}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Lists all workspace profiles.

  Returns `{:ok, profiles}` where profiles is a list of profile maps,
  or `{:error, reason}` on failure.
  """
  @spec list_profiles() :: {:ok, [profile()]} | {:error, term()}
  def list_profiles do
    list_profiles(global_muse_dir())
  end

  @spec list_profiles(String.t()) :: {:ok, [profile()]} | {:error, term()}
  def list_profiles(muse_dir) do
    path = Path.join(muse_dir, @profiles_filename)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, profiles} when is_list(profiles) -> {:ok, profiles}
          {:ok, _} -> {:ok, []}
          {:error, _} -> {:ok, []}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a workspace profile by name.

  Returns `{:ok, profile}` or `{:error, :not_found}`.
  """
  @spec get_profile(String.t()) :: {:ok, profile()} | {:error, :not_found | term()}
  def get_profile(name) do
    get_profile(name, global_muse_dir())
  end

  @spec get_profile(String.t(), String.t()) :: {:ok, profile()} | {:error, :not_found | term()}
  def get_profile(name, muse_dir) do
    case list_profiles(muse_dir) do
      {:ok, profiles} ->
        case Enum.find(profiles, fn p ->
               Map.get(p, "name") == name or Map.get(p, :name) == name
             end) do
          nil -> {:error, :not_found}
          profile -> {:ok, normalize_profile(profile)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a workspace profile by name.

  Returns `:ok` on success, `{:error, :not_found}` if the profile
  does not exist, or `{:error, reason}` on failure.

  Note: this does NOT delete the workspace directory or its sessions.
  It only removes the profile from the registry.
  """
  @spec delete_profile(String.t()) :: :ok | {:error, term()}
  def delete_profile(name) do
    delete_profile(name, global_muse_dir())
  end

  @spec delete_profile(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_profile(name, muse_dir) do
    case list_profiles(muse_dir) do
      {:ok, profiles} ->
        remaining =
          Enum.reject(profiles, fn p ->
            Map.get(p, "name") == name or Map.get(p, :name) == name
          end)

        if length(remaining) == length(profiles) do
          {:error, :not_found}
        else
          write_profiles(muse_dir, remaining)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the sessions directory for a given profile name.

  Looks up the profile and returns its `sessions_dir`, or falls back
  to `<root_path>/.muse/sessions` if the profile has no explicit
  sessions_dir.

  Returns `{:ok, sessions_dir}` or `{:error, reason}`.

  ## Options

    * `:muse_dir` — override the global muse directory for profile lookup
  """
  @spec sessions_dir_for(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sessions_dir_for(profile_name, opts \\ []) do
    muse_dir = Keyword.get(opts, :muse_dir) || global_muse_dir()

    case get_profile(profile_name, muse_dir) do
      {:ok, profile} ->
        dir = Map.get(profile, :sessions_dir) || derived_sessions_dir(profile.root_path)
        {:ok, dir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Derives a sessions directory from a workspace root path.

  Always returns `<root_path>/.muse/sessions`.
  """
  @spec sessions_dir_from_root(String.t()) :: String.t()
  def sessions_dir_from_root(root_path) do
    Path.join(root_path, ".muse/sessions")
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp validate_profile_name(nil), do: {:error, :name_required}
  defp validate_profile_name(""), do: {:error, :name_required}

  defp validate_profile_name(name) when is_binary(name) do
    cond do
      name in [".", ".."] ->
        {:error, {:invalid_profile_name, name}}

      Regex.match?(@path_traversal_chars, name) ->
        {:error, {:invalid_profile_name, name}}

      true ->
        {:ok, name}
    end
  end

  defp validate_profile_name(other), do: {:error, {:invalid_profile_name, other}}

  defp validate_root_path(nil), do: {:error, :root_path_required}
  defp validate_root_path(""), do: {:error, :root_path_required}
  defp validate_root_path(path) when is_binary(path), do: {:ok, Path.expand(path)}
  defp validate_root_path(other), do: {:error, {:invalid_root_path, other}}

  defp save_profile(muse_dir, profile) do
    case File.mkdir_p(muse_dir) do
      :ok ->
        case list_profiles(muse_dir) do
          {:ok, profiles} ->
            # Replace existing profile with same name or append
            updated =
              profiles
              |> Enum.reject(fn p ->
                Map.get(p, "name") == profile.name or Map.get(p, :name) == profile.name
              end)
              |> Kernel.++([encode_profile(profile)])

            write_profiles(muse_dir, updated)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp write_profiles(muse_dir, profiles) do
    path = Path.join(muse_dir, @profiles_filename)
    content = Jason.encode!(profiles, pretty: true)

    # Atomic write
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  defp derived_sessions_dir(root_path) when is_binary(root_path),
    do: sessions_dir_from_root(root_path)

  defp derived_sessions_dir(_root_path), do: nil

  # Encode profile map with string keys for JSON
  defp encode_profile(profile) do
    %{
      "name" => profile.name,
      "root_path" => profile.root_path,
      "sessions_dir" => profile.sessions_dir,
      "created_at" => profile.created_at,
      "updated_at" => profile.updated_at
    }
  end

  # Normalize a profile from JSON (string keys) to atom keys
  defp normalize_profile(profile) when is_map(profile) do
    root_path = Map.get(profile, "root_path") || Map.get(profile, :root_path)

    %{
      name: Map.get(profile, "name") || Map.get(profile, :name),
      root_path: root_path,
      sessions_dir:
        Map.get(profile, "sessions_dir") || Map.get(profile, :sessions_dir) ||
          derived_sessions_dir(root_path),
      created_at: Map.get(profile, "created_at") || Map.get(profile, :created_at),
      updated_at: Map.get(profile, "updated_at") || Map.get(profile, :updated_at)
    }
  end
end
