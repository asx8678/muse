defmodule Muse.Workspace do
  @moduledoc """
  Stores workspace root once at boot; provides safe path resolution.

  The Agent is globally named `__MODULE__` so the rest of the app can call
  `root/0` and `resolve!/1` without carrying a pid.

  `resolve!/1` guarantees the resolved path never escapes the workspace root,
  using separator-aware prefix checking (no `/tmp/foo` vs `/tmp/foobar` bugs)
  and validating existing path components through symlink resolution so symlinks
  inside the workspace cannot redirect operations outside the workspace.
  """

  use Agent

  @max_symlink_expansions 40

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

  # -- Private -----------------------------------------------------------------

  # A path is inside the workspace if it is exactly the root *or* the root
  # is a proper directory prefix.  This avoids the sibling-prefix trap where
  # "/tmp/foo" would falsely match "/tmp/foobar/file".
  defp inside_workspace?(resolved, root) do
    resolved == root or String.starts_with?(resolved, root_prefix(root))
  end

  defp root_prefix(root) do
    if String.ends_with?(root, "/"), do: root, else: root <> "/"
  end

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
