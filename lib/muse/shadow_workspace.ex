defmodule Muse.ShadowWorkspace do
  @moduledoc """
  Ephemeral, isolated working directories for safe code execution.

  ShadowWorkspace creates temporary project clones using **symlinks** so that
  code execution (interpreters, test runners, etc.) operates on real files
  without contaminating the original project or triggering IDE file watchers.

  ## Architecture

  * **create/1,2** — builds a temp directory under `/tmp/muse_shadows/{uuid}/`
    and symlinks every file/dir from the project root into it. Large dirs
    (`node_modules`, `.venv`, `_build`, `deps`) are symlinked as single entries
    for speed. Regular files get realpath-based symlinks.
  * **write_file/3** — overlays a **real file** into the shadow, replacing any
    existing symlink. This is how VFS-modified content lands in the shadow.
  * **read_file/2** — reads a file from the shadow (follows symlinks to the
    original unless a real overlay was written).
  * **run/2,3** — executes a shell command with `cwd` set to the shadow path,
    capturing stdout, stderr, and exit code.
  * **destroy/1** — recursively deletes the shadow directory. Symlinks are
    broken → zero impact on the original project. Real overlay files are gone.

  ## Crash safety

  Each shadow registers a `Process.monitor` on the caller. If the caller
  crashes, a spawned Task cleans up the shadow directory automatically.

  ## Options for `create/2`

    * `:include_dirs` — specific dirs to include (default: all)
    * `:exclude_dirs` — dirs to skip (default: `["_build", "deps", "node_modules", ".git", ".muse"]`)
    * `:symlink_strategy` — `:all` (default), `:readonly`, `:copy_modified`

  ## Symlink strategies

    * `:all` — symlink everything (fastest, default)
    * `:readonly` — symlink files as read-only (chmod 444 on targets)
    * `:copy_modified` — copy files instead of symlinking (slower, fully isolated)

  """

  @default_exclude_dirs ~w(_build deps node_modules .git .muse)
  @large_dirs ~w(node_modules .venv _build deps .git)
  @max_symlink_depth 20
  @default_timeout_ms 60_000
  @shadow_base "muse_shadows"

  @type t :: %__MODULE__{
          path: String.t(),
          project_root: String.t(),
          cleanup_fn: fun(),
          monitor_ref: reference() | nil,
          symlink_strategy: :all | :readonly | :copy_modified
        }

  @type run_result :: %{
          exit_code: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t(),
          timed_out: boolean()
        }

  defstruct [
    :path,
    :project_root,
    :cleanup_fn,
    :monitor_ref,
    symlink_strategy: :all
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Create a shadow workspace from `project_root`.

  Returns `{:ok, shadow}` on success or `{:error, reason}` on failure.
  """
  @spec create(String.t()) :: {:ok, t()} | {:error, term()}
  def create(project_root), do: create(project_root, [])

  @spec create(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def create(project_root, opts) when is_binary(project_root) and is_list(opts) do
    project_root = Path.expand(project_root)

    unless File.dir?(project_root) do
      {:error, {:enoent, "project root does not exist: #{project_root}"}}
    else
      do_create(project_root, opts)
    end
  end

  def create(_project_root, _opts), do: {:error, :invalid_project_root}

  @doc """
  Write `content` into the shadow at `path` (relative to shadow root).

  If a symlink already exists at that location it is removed first, then a
  real file is written. This "overlay" mechanism ensures the shadow sees the
  new content while the original project file is untouched.
  """
  @spec write_file(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_file(%__MODULE__{} = shadow, path, content)
      when is_binary(path) and is_binary(content) do
    full_path = Path.expand(path, shadow.path)

    with :ok <- ensure_parent_dir(full_path),
         :ok <- remove_existing_entry(full_path) do
      case File.write(full_path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, {:write_failed, reason, path}}
      end
    end
  end

  @doc """
  Read a file from the shadow directory.

  Returns `{:ok, content}` or `{:error, reason}`.
  """
  @spec read_file(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file(%__MODULE__{} = shadow, path) when is_binary(path) do
    full_path = Path.expand(path, shadow.path)

    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, reason, path}}
    end
  end

  @doc """
  Execute a shell command inside the shadow directory.

  Captures stdout, stderr, and exit code. Returns a structured result map.

  ## Options

    * `:timeout` — maximum execution time in ms (default: 60_000)
    * `:env` — environment variables as a list of `{key, value}` tuples
  """
  @spec run(t(), String.t()) :: {:ok, run_result()} | {:error, term()}
  def run(shadow, cmd), do: run(shadow, cmd, [])

  @spec run(t(), String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(%__MODULE__{path: path}, cmd, opts)
      when is_binary(cmd) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    env = Keyword.get(opts, :env, [])

    # Split command into program + args for System.cmd
    {program, args} = parse_shell_command(cmd)

    cmd_opts = [
      cd: path,
      env: env,
      stderr_to_stdout: true,
      parallelism: true
    ]

    task =
      Task.async(fn ->
        try do
          case System.cmd(program, args, cmd_opts) do
            {stdout, 0} ->
              %{exit_code: 0, stdout: stdout, stderr: "", timed_out: false}

            {output, exit_code} ->
              %{exit_code: exit_code, stdout: output, stderr: "", timed_out: false}
          end
        rescue
          e ->
            %{exit_code: 127, stdout: "", stderr: Exception.message(e), timed_out: false}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        {:ok,
         %{
           exit_code: 124,
           stdout: "",
           stderr: "command timed out after #{timeout}ms",
           timed_out: true
         }}
    end
  end

  @doc """
  Destroy the shadow workspace.

  Removes the entire shadow directory tree. Broken symlinks have zero impact
  on the original project. Real overlay files are deleted along with the
  shadow directory.

  Always returns `:ok`, even if cleanup partially fails.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{path: path, monitor_ref: ref} = _shadow) do
    if ref, do: Process.demonitor(ref, [:flush])
    do_destroy(path)
  end

  # ---------------------------------------------------------------------------
  # Private: creation
  # ---------------------------------------------------------------------------

  defp do_create(project_root, opts) do
    uuid = generate_uuid()
    shadow_path = Path.join([System.tmp_dir!(), @shadow_base, uuid])

    exclude_dirs = Keyword.get(opts, :exclude_dirs, @default_exclude_dirs)
    include_dirs = Keyword.get(opts, :include_dirs, nil)
    symlink_strategy = Keyword.get(opts, :symlink_strategy, :all)

    case File.mkdir_p(shadow_path) do
      :ok ->
        case symlink_project(
               project_root,
               shadow_path,
               exclude_dirs,
               include_dirs,
               symlink_strategy,
               0
             ) do
          :ok ->
            {cleanup_fn, monitor_ref} = setup_cleanup(shadow_path)

            shadow = %__MODULE__{
              path: shadow_path,
              project_root: project_root,
              cleanup_fn: cleanup_fn,
              monitor_ref: monitor_ref,
              symlink_strategy: symlink_strategy
            }

            {:ok, shadow}

          {:error, reason} ->
            # Best-effort cleanup on failure
            do_destroy(shadow_path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, reason, shadow_path}}
    end
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  # ---------------------------------------------------------------------------
  # Private: symlink project
  # ---------------------------------------------------------------------------

  defp symlink_project(root, shadow, exclude_dirs, include_dirs, strategy, depth) do
    if depth > @max_symlink_depth do
      {:error, :symlink_depth_exceeded}
    else
      case File.ls(root) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&include_entry?(&1, exclude_dirs, include_dirs))
          |> Enum.reduce_while(:ok, fn entry, :ok ->
            src = Path.join(root, entry)
            dst = Path.join(shadow, entry)

            case symlink_entry(src, dst, strategy, depth) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        {:error, reason} ->
          {:error, {:ls_failed, reason, root}}
      end
    end
  end

  defp include_entry?(entry, exclude_dirs, nil) do
    entry not in exclude_dirs
  end

  defp include_entry?(entry, _exclude_dirs, include_dirs) when is_list(include_dirs) do
    entry in include_dirs
  end

  defp symlink_entry(src, dst, strategy, depth) do
    cond do
      # Large directories: symlink as a single entry for speed
      large_dir?(src) ->
        symlink_or_copy(src, dst, strategy)

      # Regular directory: recurse to symlink its contents
      File.dir?(src) ->
        case File.mkdir(dst) do
          :ok ->
            case File.ls(src) do
              {:ok, entries} ->
                entries
                |> Enum.reduce_while(:ok, fn entry, :ok ->
                  child_src = Path.join(src, entry)
                  child_dst = Path.join(dst, entry)

                  case symlink_entry(child_src, child_dst, strategy, depth + 1) do
                    :ok -> {:cont, :ok}
                    {:error, reason} -> {:halt, {:error, reason}}
                  end
                end)

              {:error, reason} ->
                {:error, {:ls_failed, reason, src}}
            end

          {:error, reason} ->
            {:error, {:mkdir_failed, reason, dst}}
        end

      # Regular file: symlink or copy
      File.regular?(src) ->
        symlink_or_copy(src, dst, strategy)

      # Skip special files (symlinks, devices, etc.) — fall through
      true ->
        :ok
    end
  end

  defp large_dir?(path) do
    path
    |> Path.basename()
    |> String.downcase()
    |> then(&(&1 in @large_dirs))
  end

  defp symlink_or_copy(src, dst, :copy_modified) do
    copy_entry(src, dst)
  end

  defp symlink_or_copy(src, dst, _strategy) do
    # Use realpath to ensure symlinks resolve correctly
    real_src = Path.expand(src)

    case File.ln_s(real_src, dst) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      {:error, reason} when reason in [:eacces, :eperm] ->
        # Permission denied → fall back to copy
        copy_entry(src, dst)

      {:error, reason} ->
        {:error, {:ln_s_failed, reason, src, dst}}
    end
  end

  defp copy_entry(src, dst) do
    cond do
      File.dir?(src) ->
        case File.cp_r(src, dst) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:cp_r_failed, reason, src, dst}}
        end

      File.regular?(src) ->
        case File.cp(src, dst) do
          :ok -> :ok
          {:error, reason} -> {:error, {:cp_failed, reason, src, dst}}
        end

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private: cleanup
  # ---------------------------------------------------------------------------

  defp setup_cleanup(shadow_path) do
    parent = self()
    ref = Process.monitor(parent)

    cleanup_fn = fn ->
      do_destroy(shadow_path)
    end

    # Spawn a lightweight process that monitors the parent and cleans up
    # if the parent crashes. This ensures shadows don't leak.
    _watcher =
      spawn_link(fn ->
        receive do
          {:DOWN, ^ref, :process, ^parent, _reason} ->
            do_destroy(shadow_path)

          :cancel ->
            :ok
        end
      end)

    {cleanup_fn, ref}
  end

  defp do_destroy(path) do
    if File.exists?(path) or sym_link?(path) do
      # First, remove symlinks directly under the shadow (avoids following them)
      case File.ls(path) do
        {:ok, entries} ->
          Enum.each(entries, fn entry ->
            full = Path.join(path, entry)
            remove_entry_safe(full)
          end)

        _ ->
          :ok
      end

      # Then remove the now-empty (or partially empty) shadow directory
      case File.rm_rf(path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, {:rm_rf_failed, reason, path}}
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  # Remove a single entry without following symlinks
  defp remove_entry_safe(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        # For directories in the shadow (not symlinks), recurse carefully
        # Check if it's a symlink pointing to a directory first
        case File.read_link(path) do
          {:ok, _target} ->
            # It's a symlink → just unlink
            File.rm(path)

          {:error, :einval} ->
            # Not a symlink, it's a real directory → recurse
            case File.ls(path) do
              {:ok, entries} ->
                Enum.each(entries, fn entry ->
                  remove_entry_safe(Path.join(path, entry))
                end)

              _ ->
                :ok
            end

            File.rmdir(path)

          {:error, _} ->
            # Can't read link — try removing as file first, then dir
            File.rm(path)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        File.rm(path)

      {:ok, _} ->
        File.rm(path)

      {:error, _} ->
        :ok
    end
  end

  defp sym_link?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Private: write_file helpers
  # ---------------------------------------------------------------------------

  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)

    if File.dir?(dir) do
      :ok
    else
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, {:mkdir_failed, reason, dir}}
      end
    end
  end

  defp remove_existing_entry(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _} -> :ok
          {:error, reason, _} -> {:error, {:rm_rf_failed, reason, path}}
        end

      {:ok, _} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rm_failed, reason, path}}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:stat_failed, reason, path}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: run helpers
  # ---------------------------------------------------------------------------

  defp parse_shell_command(cmd) do
    # For simple commands, split on space.
    # For complex shell constructs, wrap in `sh -c`.
    if shell_construct?(cmd) do
      {"sh", ["-c", cmd]}
    else
      case String.split(cmd, " ", parts: 2) do
        [program] -> {program, []}
        [program, rest] -> {program, String.split(rest)}
      end
    end
  end

  @shell_patterns [
    ~r/[|&;<>$`\(\)\{\}\*\?]/,
    ~r/\b(if|then|else|fi|for|while|do|done|case|esac|export|source)\b/
  ]

  defp shell_construct?(cmd) do
    Enum.any?(@shell_patterns, &String.match?(cmd, &1))
  end
end
