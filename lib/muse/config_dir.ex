defmodule Muse.ConfigDir do
  @moduledoc """
  Resolves the effective Muse configuration directory for profiles, secrets,
  and local OAuth material.

  Search precedence (highest first):

    1. `MUSE_CONFIG_DIR` environment variable (explicit override)
    2. `~/Documents/.muse` — convenient macOS / iCloud-sync friendly location
    3. `~/.muse` — legacy / cross-platform default

  When loading configuration (`config.json`), the first directory in the list
  that contains a readable `config.json` wins. When initializing, the
  highest-precedence candidate is used.

  This allows users to keep all personal model configs, secrets, and OAuth
  tokens (e.g. `auth.json`) under one portable tree such as
  `~/Documents/.muse/`.

  ## Usage

      iex> dir = Muse.ConfigDir.config_dir()
      iex> Muse.ConfigDir.config_path()
      "/Users/adam2/Documents/.muse/config.json"

  The directory can be overridden at runtime via the environment for tests
  or multi-profile workflows.
  """

  @doc """
  Returns the ordered list of candidate configuration directories.

  Callers can use this for diagnostics or to implement custom resolution.
  """
  @spec candidates() :: [Path.t()]
  def candidates do
    explicit = System.get_env("MUSE_CONFIG_DIR")
    docs = Path.expand("~/Documents/.muse")
    home = Path.expand("~/.muse")

    [explicit, docs, home]
    |> Enum.reject(fn
      nil -> true
      path -> String.trim(path) == ""
    end)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq_by(&Path.absname/1)
  end

  @doc """
  Returns the directory that should be used for reading/writing Muse
  configuration (`config.json`, `secrets.json`, `auth.json`, etc.).

  Resolution rules:
    * If any candidate already contains a `config.json`, the first such
      directory wins (so an existing `~/Documents/.muse` takes precedence
      over `~/.muse`).
    * Otherwise the highest-precedence candidate is returned (respecting
      `MUSE_CONFIG_DIR` > Documents > home).

  This function is pure with respect to the current environment and file
  system state at call time.
  """
  @spec config_dir() :: Path.t()
  def config_dir do
    case Enum.find(candidates(), &has_config_json?/1) do
      nil -> preferred_init_dir()
      dir -> dir
    end
  end

  @doc "Full path to `config.json` inside the effective config dir."
  @spec config_path() :: Path.t()
  def config_path, do: Path.join(config_dir(), "config.json")

  @doc "Full path to `secrets.json` inside the effective config dir."
  @spec secrets_path() :: Path.t()
  def secrets_path, do: Path.join(config_dir(), "secrets.json")

  @doc """
  Full path to the preferred OAuth / auth cache file inside the effective
  config dir (`auth.json`). This is the location users should place
  Codex-style or OpenAI OAuth bearer token material when they want it
  managed alongside their Muse profiles.
  """
  @spec oauth_path() :: Path.t()
  def oauth_path, do: Path.join(config_dir(), "auth.json")

  @doc """
  Returns the directory that `ensure_initialized/0` will create files in
  when no existing `config.json` is present anywhere.
  """
  @spec preferred_init_dir() :: Path.t()
  def preferred_init_dir do
    case candidates() do
      [] -> Path.expand("~/.muse")
      [first | _] -> Path.expand(first)
    end
  end

  @doc """
  True if the given directory contains a readable `config.json`.
  Used during discovery to prefer an already-populated tree.
  """
  @spec has_config_json?(Path.t()) :: boolean()
  def has_config_json?(dir) when is_binary(dir) do
    File.exists?(Path.join(dir, "config.json"))
  end

  def has_config_json?(_), do: false

  @doc """
  Ensures the effective config directory exists (and is a directory).

  Does not create `config.json` / `secrets.json` — that is the
  responsibility of `ProfileLoader.ensure_initialized/0`.
  """
  @spec ensure_dir_exists(Path.t() | nil) :: :ok | {:error, term()}
  def ensure_dir_exists(dir \\ nil) do
    target_dir = dir || preferred_init_dir()

    case File.mkdir_p(target_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
