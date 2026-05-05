defmodule Muse.Workspace do
  @moduledoc """
  Stores workspace root once at boot; provides safe path resolution.

  The Agent is globally named `__MODULE__` so the rest of the app can call
  `root/0` and `resolve!/1` without carrying a pid.

  `resolve!/1` guarantees the resolved path never escapes the workspace root,
  using separator-aware prefix checking (no `/tmp/foo` vs `/tmp/foobar` bugs)
  and validating existing path components through symlink resolution so symlinks
  inside the workspace cannot redirect operations outside the workspace.

  `safe_resolve!/2` extends `resolve!/1` with additional tool-facing safety:
  secret path denylist, hidden file blocking, and ignored directory enforcement.
  It does not break existing `root/0` and `resolve!/1` tests.

  ## Secret path denylist

  The following paths are blocked by `safe_resolve!/2` and `secret_path?/2`:

    * `.env`, `.env.*`
    * `*.pem`, `*.key`, `*.p12`, `*.pfx`
    * `id_rsa`, `id_ed25519`, `id_dsa`, `id_ecdsa`
    * `.ssh/`, `.aws/`, `.gcp/`, `.gcloud/`, `.azure/`, `.docker/`, `.kube/`, `.gnupg/`
    * `.npmrc`, `.pypirc`, `.netrc`, `.git-credentials`
    * `credentials.json|yml|yaml|toml|enc`, `secrets.*`
    * `auth.json|yml|yaml|toml|enc`, cloud service-account files
    * `.git/` contents (except when `allow_git_contents: true`)

  ## Ignored directories

  The following directories are blocked by `ignored_path?/2`:

    * `.git` (except when `allow_git_contents: true`)
    * `_build`, `deps`, `node_modules`
    * Common caches
  """

  use Agent

  @max_symlink_expansions 40

  # -- Secret path patterns (compile-time) -------------------------------------

  @secret_filenames MapSet.new([
                      ".env",
                      "id_rsa",
                      "id_ed25519",
                      "id_dsa",
                      "id_ecdsa",
                      ".npmrc",
                      ".pypirc",
                      ".netrc",
                      ".git-credentials",
                      ".dockercfg",
                      "credentials",
                      "credentials.json",
                      "credentials.yml",
                      "credentials.yaml",
                      "credentials.toml",
                      "credentials.enc",
                      "auth.json",
                      "auth.yml",
                      "auth.yaml",
                      "auth.toml",
                      "auth.enc",
                      "application_default_credentials.json",
                      "service_account.json",
                      "service-account.json"
                    ])

  @secret_filename_prefixes [".env."]
  @secret_filename_suffixes [
    ".pem",
    ".key",
    ".p12",
    ".pfx",
    ".p8",
    ".pkcs8",
    ".jks",
    ".keystore",
    ".kdb"
  ]
  @secret_filename_patterns [~r/^secrets\./]

  @secret_dirnames MapSet.new([
                     ".ssh",
                     ".aws",
                     ".gcp",
                     ".gcloud",
                     ".azure",
                     ".docker",
                     ".kube",
                     ".gnupg"
                   ])

  @ignored_dirnames MapSet.new([
                      "_build",
                      "deps",
                      "node_modules"
                    ])

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

    if inside_workspace?(resolved, root) and symlink_safe_inside?(resolved, root) do
      resolved
    else
      raise ArgumentError,
            "path #{inspect(path)} escapes workspace #{inspect(root)}"
    end
  end

  @doc """
  Hardened tool-facing path resolver with full safety checks.

  Like `resolve!/1` but also enforces:

    * Secret path denylist (`.env`, `*.pem`, `.ssh/`, etc.)
    * Hidden file blocking (dot-prefixed files/dirs) unless `allow_hidden: true`
    * Ignored directory blocking (`.git/`, `_build/`, `deps/`, etc.)
    * Absolute path rejection unless `allow_absolute: true`

  Does **not** break existing `resolve!/1` tests.

  ## Options

    * `:allow_hidden` — allow hidden files/dirs (default: `false`)
    * `:allow_git_contents` — allow `.git/` directory contents for git tools (default: `false`)
    * `:allow_absolute` — allow absolute paths (default: `false`; requires high trust)

  ## Raises

  Raises `ArgumentError` if any safety check fails.
  """
  # 2-arg overload: opts only — uses Workspace.root() for the workspace
  @spec safe_resolve!(String.t(), keyword()) :: String.t()
  def safe_resolve!(path, opts) when is_binary(path) and is_list(opts) do
    safe_resolve!(path, root(), opts)
  end

  # 2-arg overload: workspace only — opts defaults to []
  @spec safe_resolve!(String.t(), String.t()) :: String.t()
  def safe_resolve!(path, workspace) when is_binary(path) and is_binary(workspace) do
    safe_resolve!(path, workspace, [])
  end

  # 3-arg: full version
  @spec safe_resolve!(String.t(), String.t(), keyword()) :: String.t()
  def safe_resolve!(path, workspace, opts)
      when is_binary(path) and is_binary(workspace) and is_list(opts) do
    workspace = Path.expand(workspace)
    allow_absolute = Keyword.get(opts, :allow_absolute, false)
    allow_hidden = Keyword.get(opts, :allow_hidden, false)
    allow_git_contents = Keyword.get(opts, :allow_git_contents, false)

    # 1. Reject absolute paths unless explicitly allowed
    if Path.type(path) == :absolute and not allow_absolute do
      raise ArgumentError,
            "absolute path #{inspect(path)} not allowed without allow_absolute: true"
    end

    # 2. Resolve against workspace
    resolved = Path.expand(path, workspace)

    # 3. Workspace boundary + symlink safety
    unless inside_workspace?(resolved, workspace) and
             symlink_safe_inside?(resolved, workspace) do
      raise ArgumentError,
            "path #{inspect(path)} escapes workspace #{inspect(workspace)}"
    end

    safety_paths = safety_check_paths(resolved, workspace)

    # 4. Hidden file check. Check both the lexical path and any existing
    # canonical symlink targets so `safe_link -> .hidden/file` cannot bypass it.
    if not allow_hidden and hidden_path?(safety_paths) do
      raise ArgumentError,
            "path #{inspect(path)} contains hidden file/directory (use allow_hidden: true to access)"
    end

    # 5. Secret path check. Canonical target checks prevent `safe_link -> .env`
    # and similar symlink aliases from exposing sensitive files.
    if secret_safety_path?(safety_paths) do
      raise ArgumentError,
            "path #{inspect(path)} is a secret/sensitive file"
    end

    # 6. Ignored path check. Canonical target checks prevent links into deps,
    # _build, node_modules, or .git from bypassing read-tool exclusions.
    if ignored_safety_path?(safety_paths, allow_git_contents: allow_git_contents) do
      raise ArgumentError,
            "path #{inspect(path)} is in an ignored directory"
    end

    resolved
  end

  @doc """
  Check if a path matches the secret file denylist.

  Returns `true` if the path (absolute, within workspace) matches any
  secret filename or directory pattern.

  ## Examples

      iex> Muse.Workspace.secret_path?("/tmp/project/.env", "/tmp/project")
      true

      iex> Muse.Workspace.secret_path?("/tmp/project/lib/muse.ex", "/tmp/project")
      false
  """
  @spec secret_path?(String.t(), String.t()) :: boolean()
  def secret_path?(resolved, workspace) when is_binary(resolved) do
    # Evaluate path relative to workspace to avoid false positives
    # from parent directory names (e.g. workspace at /tmp/.env/project/)
    rel_parts = relative_parts(resolved, workspace)

    Enum.any?(rel_parts, fn part ->
      secret_filename?(part) or secret_dirname?(part)
    end)
  end

  defp relative_parts(resolved, workspace) do
    if resolved == workspace do
      # The path IS the workspace root — no relative parts to check
      []
    else
      rel = Path.relative_to(resolved, workspace)

      if rel == resolved do
        # Path is not inside workspace — fall back to checking all parts
        Path.split(resolved)
      else
        Path.split(rel)
      end
    end
  end

  @doc """
  Check if a path is in an ignored directory.

  Ignored directories include `.git`, `_build`, `deps`, `node_modules`,
  and common caches. `.git` is allowed when `allow_git_contents: true`.

  ## Examples

      iex> Muse.Workspace.ignored_path?("/tmp/project/_build/lib/muse.ex", "/tmp/project", [])
      true

      iex> Muse.Workspace.ignored_path?("/tmp/project/lib/muse.ex", "/tmp/project", [])
      false
  """
  @spec ignored_path?(String.t(), String.t(), keyword()) :: boolean()
  def ignored_path?(resolved, workspace, opts \\ []) do
    allow_git_contents = Keyword.get(opts, :allow_git_contents, false)

    # Get relative path components
    rel_parts =
      resolved
      |> Path.relative_to(workspace)
      |> Path.split()

    Enum.any?(rel_parts, fn part ->
      ignored_dirname?(part, allow_git_contents)
    end)
  end

  # -- Private -----------------------------------------------------------------

  defp safety_check_paths(resolved, workspace) do
    lexical = [{resolved, workspace}]

    canonical =
      with {:ok, root_real} <- realpath_existing(workspace),
           {:ok, real_prefixes} <- real_existing_prefixes(resolved, workspace) do
        Enum.map(real_prefixes, &{&1, root_real})
      else
        _ -> []
      end

    lexical ++ canonical
  end

  defp hidden_path?(safety_paths) do
    Enum.any?(safety_paths, fn {resolved, workspace} ->
      contains_hidden_segment?(resolved, workspace)
    end)
  end

  defp secret_safety_path?(safety_paths) do
    Enum.any?(safety_paths, fn {resolved, workspace} ->
      secret_path?(resolved, workspace)
    end)
  end

  defp ignored_safety_path?(safety_paths, opts) do
    Enum.any?(safety_paths, fn {resolved, workspace} ->
      ignored_path?(resolved, workspace, opts)
    end)
  end

  # A path is inside the workspace if it is exactly the root *or* the root
  # is a proper directory prefix.  This avoids the sibling-prefix trap where
  # "/tmp/foo" would falsely match "/tmp/foobar/file".
  defp inside_workspace?(resolved, root) do
    resolved == root or String.starts_with?(resolved, root_prefix(root))
  end

  defp root_prefix(root) do
    if String.ends_with?(root, "/"), do: root, else: root <> "/"
  end

  # -- Secret path checks -------------------------------------------------------

  defp secret_filename?(filename) do
    filename = String.downcase(filename)

    MapSet.member?(@secret_filenames, filename) or
      Enum.any?(@secret_filename_prefixes, &String.starts_with?(filename, &1)) or
      Enum.any?(@secret_filename_suffixes, &String.ends_with?(filename, &1)) or
      Enum.any?(@secret_filename_patterns, &Regex.match?(&1, filename))
  end

  defp secret_dirname?(dirname) do
    MapSet.member?(@secret_dirnames, String.downcase(dirname))
  end

  # -- Ignored path checks ------------------------------------------------------

  defp ignored_dirname?(dirname, allow_git_contents) do
    dirname = String.downcase(dirname)

    if dirname == ".git" do
      not allow_git_contents
    else
      MapSet.member?(@ignored_dirnames, dirname)
    end
  end

  # -- Hidden file checks -------------------------------------------------------

  defp contains_hidden_segment?(resolved, workspace) do
    resolved
    |> Path.relative_to(workspace)
    |> Path.split()
    |> Enum.any?(&hidden_segment?/1)
  end

  defp hidden_segment?(<<".", rest::binary>>) when rest != "", do: true
  defp hidden_segment?(_), do: false

  # `Path.expand/2` is purely lexical; it does not resolve symlinks.  Check every
  # existing component under `resolved` through symlink resolution so a workspace-local
  # symlink cannot point reads/writes outside the canonical workspace root.  The
  # first non-existent component stops the walk, which still permits callers to
  # resolve paths for new files/directories under an existing safe parent.
  defp symlink_safe_inside?(resolved, root) do
    with {:ok, root_real} <- realpath_existing(root),
         {:ok, real_prefixes} <- real_existing_prefixes(resolved, root) do
      Enum.all?(real_prefixes, &inside_workspace?(&1, root_real))
    else
      _ -> false
    end
  end

  defp real_existing_prefixes(resolved, root) do
    root_parts = Path.split(root)

    parts =
      resolved
      |> Path.split()
      |> Enum.drop(length(root_parts))

    [root | Enum.scan(parts, root, fn part, acc -> Path.join(acc, part) end)]
    |> Enum.reduce_while({:ok, []}, fn prefix, {:ok, acc} ->
      case File.lstat(prefix) do
        {:ok, _stat} ->
          case realpath_existing(prefix) do
            {:ok, realpath} -> {:cont, {:ok, [realpath | acc]}}
            {:error, _reason} -> {:halt, :error}
          end

        {:error, reason} when reason in [:enoent, :enotdir] ->
          {:halt, {:ok, acc}}

        {:error, _reason} ->
          {:halt, :error}
      end
    end)
  end

  defp realpath_existing(path), do: realpath_existing(path, 0)

  defp realpath_existing(_path, count) when count >= @max_symlink_expansions do
    {:error, :eloop}
  end

  defp realpath_existing(path, count) do
    case Path.split(Path.expand(path)) do
      [] -> {:error, :enoent}
      [root | parts] -> realpath_parts(root, parts, count)
    end
  end

  defp realpath_parts(real_prefix, [], _count), do: {:ok, real_prefix}

  defp realpath_parts(real_prefix, [part | rest], count) do
    prefix = Path.join(real_prefix, part)

    case File.lstat(prefix) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(prefix) do
          {:ok, target} ->
            target
            |> expand_link_target(real_prefix)
            |> append_path_parts(rest)
            |> realpath_existing(count + 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _stat} ->
        realpath_parts(prefix, rest, count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_link_target(target, parent) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      _relative -> Path.expand(target, parent)
    end
  end

  defp append_path_parts(path, parts) do
    Enum.reduce(parts, path, fn part, acc -> Path.join(acc, part) end)
  end
end
