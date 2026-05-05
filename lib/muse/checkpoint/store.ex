defmodule Muse.Checkpoint.Store do
  @moduledoc """
  Persistence layer for Muse checkpoints.

  Each checkpoint lives under the session directory:

      .muse/sessions/<session_id>/checkpoints/<checkpoint_id>/
        manifest.json      # checkpoint metadata (atomic write)
        patch.diff          # the approved diff that was applied
        snapshots/          # per-file content snapshots before apply
          <safe_relative_path>  # file content as-is

  ## Safety

  - Session IDs and checkpoint IDs are validated for path traversal.
  - File paths are validated via `Muse.Workspace.safe_resolve!/3` before
    snapshot; secret paths, absolute paths, and traversal are denied.
  - File content is read and written as raw bytes; no encoding transforms.

  ## Atomicity

  `manifest.json` is written atomically (write to .tmp, rename). Snapshot
  files are written before the manifest; on crash, an incomplete manifest
  is detectable (it won't exist or will be malformed).
  """

  alias Muse.{Checkpoint, Workspace}

  @default_base_dir ".muse/sessions"

  # -- Public API ---------------------------------------------------------------

  @doc """
  Create a checkpoint on disk: capture file snapshots and git metadata
  before applying a patch.

  Returns `{:ok, %Checkpoint{}}` on success, `{:error, reason}` on failure.
  If checkpoint creation fails, the caller MUST NOT apply the patch.

  ## Options

    * `:base_dir` — override the sessions base directory
    * `:capture_git_stash` — attempt `git stash create` for backup (default: true)
  """
  @spec create(Checkpoint.t(), keyword()) :: {:ok, Checkpoint.t()} | {:error, term()}
  def create(%Checkpoint{} = checkpoint, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, @default_base_dir)
    workspace = checkpoint.workspace

    with {:ok, _} <- validate_ids(checkpoint),
         {:ok, chk_dir} <- ensure_checkpoint_dir(base_dir, checkpoint.session_id, checkpoint.id),
         {:ok, snapshots_dir} <- ensure_snapshots_dir(chk_dir),
         {:ok, file_snapshots} <-
           capture_file_snapshots(checkpoint.affected_files, workspace, snapshots_dir),
         {:ok, git_meta} <- capture_git_metadata(workspace, opts) do
      checkpoint = %{checkpoint | file_snapshots: file_snapshots, git_metadata: git_meta}

      # Persist the patch diff
      patch_path = Path.join(chk_dir, "patch.diff")
      :ok = File.write(patch_path, fetch_patch_diff(checkpoint))

      # Persist the manifest atomically
      manifest_path = Path.join(chk_dir, "manifest.json")
      :ok = write_manifest(manifest_path, checkpoint)

      {:ok, checkpoint}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load a checkpoint by ID from disk.

  Returns `{:ok, %Checkpoint{}}` or `{:error, reason}`.
  """
  @spec load(String.t(), String.t(), keyword()) ::
          {:ok, Checkpoint.t()} | {:error, term()}
  def load(session_id, checkpoint_id, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, @default_base_dir)
    chk_dir = checkpoint_dir(base_dir, session_id, checkpoint_id)
    manifest_path = Path.join(chk_dir, "manifest.json")

    with {:ok, content} <- File.read(manifest_path),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, Checkpoint.from_map(decoded)}
    else
      {:error, :enoent} -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, {:manifest_corrupt, reason}}
    end
  end

  @doc """
  Update the checkpoint manifest on disk (e.g. after status transition).
  """
  @spec update_manifest(Checkpoint.t(), keyword()) :: :ok | {:error, term()}
  def update_manifest(%Checkpoint{} = checkpoint, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, @default_base_dir)

    manifest_path =
      checkpoint_dir(base_dir, checkpoint.session_id, checkpoint.id)
      |> Path.join("manifest.json")

    write_manifest(manifest_path, checkpoint)
  end

  @doc """
  Restore files from a checkpoint, returning the workspace to its pre-apply state.

  For each affected file:
    - If the file existed before (snapshot exists), restore its content.
    - If the file did not exist before, delete it.

  After restoration, update the checkpoint manifest status to `:rolled_back`.
  """
  @spec rollback(Checkpoint.t(), keyword()) :: {:ok, Checkpoint.t()} | {:error, term()}
  def rollback(%Checkpoint{} = checkpoint, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, @default_base_dir)
    workspace = checkpoint.workspace
    chk_dir = checkpoint_dir(base_dir, checkpoint.session_id, checkpoint.id)
    snapshots_dir = Path.join(chk_dir, "snapshots")

    with {:ok, checkpoint} <- Checkpoint.transition(checkpoint, :rolled_back) do
      # Restore each file from snapshot
      restore_results =
        checkpoint.file_snapshots
        |> Enum.map(fn snapshot -> restore_file_snapshot(snapshot, workspace, snapshots_dir) end)

      errors =
        Enum.filter(restore_results, fn
          {:error, _} -> true
          _ -> false
        end)

      if errors == [] do
        :ok = update_manifest(checkpoint, base_dir: base_dir)
        {:ok, checkpoint}
      else
        # Some files failed to restore — still mark as rolled_back but record errors
        checkpoint = %{
          checkpoint
          | metadata:
              Map.put(
                checkpoint.metadata,
                :rollback_errors,
                Enum.map(errors, fn {:error, e} -> e end)
              )
        }

        :ok = update_manifest(checkpoint, base_dir: base_dir)
        {:ok, checkpoint}
      end
    end
  end

  @doc """
  Return the checkpoint directory path.
  """
  @spec checkpoint_dir(String.t(), String.t(), String.t()) :: String.t()
  def checkpoint_dir(base_dir, session_id, checkpoint_id) do
    Path.join([base_dir, session_id, "checkpoints", checkpoint_id])
  end

  # -- Private: validation ------------------------------------------------------

  defp validate_ids(%Checkpoint{session_id: s_id, id: c_id}) do
    with :ok <- validate_path_component(s_id, "session_id"),
         :ok <- validate_path_component(c_id, "checkpoint_id") do
      {:ok, :ok}
    end
  end

  defp validate_path_component(value, label) when is_binary(value) do
    cond do
      value == "" -> {:error, {:invalid_id, label}}
      value in [".", ".."] -> {:error, {:invalid_id, label}}
      String.contains?(value, "/") -> {:error, {:path_traversal, label}}
      String.contains?(value, "\\") -> {:error, {:path_traversal, label}}
      String.contains?(value, "\0") -> {:error, {:path_traversal, label}}
      true -> :ok
    end
  end

  defp validate_path_component(nil, label), do: {:error, {:missing_id, label}}
  defp validate_path_component(_, label), do: {:error, {:invalid_id, label}}

  # -- Private: directory management --------------------------------------------

  defp ensure_checkpoint_dir(base_dir, session_id, checkpoint_id) do
    dir = checkpoint_dir(base_dir, session_id, checkpoint_id)

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, {:mkdir_failed, reason, dir}}
    end
  end

  defp ensure_snapshots_dir(chk_dir) do
    dir = Path.join(chk_dir, "snapshots")

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, {:mkdir_failed, reason, dir}}
    end
  end

  # -- Private: file snapshots --------------------------------------------------

  defp capture_file_snapshots(affected_files, workspace, snapshots_dir) do
    snapshots =
      affected_files
      |> Enum.map(fn rel_path ->
        capture_single_snapshot(rel_path, workspace, snapshots_dir)
      end)

    errors =
      Enum.filter(snapshots, fn
        {:error, _} -> true
        _ -> false
      end)

    if errors == [] do
      {:ok, Enum.map(snapshots, fn {:ok, s} -> s end)}
    else
      {:error, {:snapshot_failed, Enum.map(errors, fn {:error, e} -> e end)}}
    end
  end

  defp capture_single_snapshot(rel_path, workspace, snapshots_dir) do
    # Validate the path is safe for snapshot (no secrets, no traversal)
    with :ok <- validate_snapshot_path(rel_path, workspace) do
      abs_path = Path.join(workspace, rel_path)

      if File.exists?(abs_path) do
        case File.read(abs_path) do
          {:ok, content} ->
            content_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
            # Write snapshot content
            snapshot_rel = snapshot_file_path(rel_path)
            snapshot_abs = Path.join(snapshots_dir, snapshot_rel)
            :ok = File.mkdir_p!(Path.dirname(snapshot_abs))
            :ok = File.write(snapshot_abs, content)

            {:ok,
             %{
               path: rel_path,
               existed: true,
               content_hash: content_hash,
               snapshot_path: snapshot_rel
             }}

          {:error, reason} ->
            {:error, {:read_failed, rel_path, reason}}
        end
      else
        # File does not exist before patch — rollback should delete it
        {:ok,
         %{
           path: rel_path,
           existed: false,
           content_hash: nil,
           snapshot_path: nil
         }}
      end
    end
  end

  defp validate_snapshot_path(rel_path, workspace) do
    try do
      Workspace.safe_resolve!(rel_path, workspace, allow_hidden: true)
      :ok
    rescue
      e -> {:error, {:unsafe_snapshot_path, rel_path, Exception.message(e)}}
    end
  end

  defp snapshot_file_path(rel_path) do
    # Preserve directory structure in snapshot
    rel_path
  end

  # -- Private: restore from snapshot ------------------------------------------

  defp restore_file_snapshot(%{existed: false, path: rel_path}, workspace, _snapshots_dir) do
    abs_path = Path.join(workspace, rel_path)

    if File.exists?(abs_path) do
      case File.rm(abs_path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:delete_failed, rel_path, reason}}
      end
    else
      :ok
    end
  end

  defp restore_file_snapshot(
         %{existed: true, path: rel_path, snapshot_path: snap_rel},
         workspace,
         snapshots_dir
       ) do
    snapshot_abs = Path.join(snapshots_dir, snap_rel)
    abs_path = Path.join(workspace, rel_path)

    case File.read(snapshot_abs) do
      {:ok, content} ->
        :ok = File.mkdir_p!(Path.dirname(abs_path))

        case File.write(abs_path, content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:restore_write_failed, rel_path, reason}}
        end

      {:error, reason} ->
        {:error, {:snapshot_read_failed, rel_path, reason}}
    end
  end

  defp restore_file_snapshot(_, _workspace, _snapshots_dir), do: :ok

  # -- Private: git metadata ----------------------------------------------------

  defp capture_git_metadata(workspace, opts) do
    if Keyword.get(opts, :capture_git_stash, true) and is_binary(workspace) do
      git_meta = %{
        stash_ref: try_git_stash_create(workspace),
        head_sha: try_git_rev_parse(workspace),
        branch: try_git_branch(workspace),
        dirty: try_git_dirty?(workspace)
      }

      {:ok, git_meta}
    else
      {:ok, %{stash_ref: nil, head_sha: nil, branch: nil, dirty: nil}}
    end
  end

  defp try_git_stash_create(workspace) do
    case System.cmd("git", ["stash", "create"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} when is_binary(output) -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp try_git_rev_parse(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp try_git_branch(workspace) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp try_git_dirty?(workspace) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- Private: patch diff ------------------------------------------------------

  defp fetch_patch_diff(%Checkpoint{} = checkpoint) do
    checkpoint.metadata[:diff] || checkpoint.metadata["diff"] || ""
  end

  # -- Private: manifest persistence -------------------------------------------

  defp write_manifest(path, %Checkpoint{} = checkpoint) do
    data = Checkpoint.to_map(checkpoint)

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> atomic_write(path, json)
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp atomic_write(path, content) do
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
end
