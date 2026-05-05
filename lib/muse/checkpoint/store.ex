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

      with {:ok, _} <- safe_write_file(patch_path, fetch_patch_diff(checkpoint)),
           {:ok, _} <- write_manifest(Path.join(chk_dir, "manifest.json"), checkpoint) do
        {:ok, checkpoint}
      else
        {:error, reason} -> {:error, reason}
      end
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

    with :ok <- validate_path_component(session_id, "session_id"),
         :ok <- validate_path_component(checkpoint_id, "checkpoint_id") do
      chk_dir = checkpoint_dir(base_dir, session_id, checkpoint_id)
      manifest_path = Path.join(chk_dir, "manifest.json")

      with {:ok, content} <- File.read(manifest_path),
           {:ok, decoded} <- Jason.decode(content) do
        checkpoint = Checkpoint.from_map(decoded)

        # Verify loaded identity matches requested ids
        if checkpoint.session_id == session_id and checkpoint.id == checkpoint_id do
          {:ok, checkpoint}
        else
          {:error,
           {:identity_mismatch,
            %{
              requested_session_id: session_id,
              requested_checkpoint_id: checkpoint_id,
              loaded_session_id: checkpoint.session_id,
              loaded_checkpoint_id: checkpoint.id
            }}}
        end
      else
        {:error, :enoent} -> {:error, :checkpoint_not_found}
        {:error, reason} -> {:error, {:manifest_corrupt, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update the checkpoint manifest on disk (e.g. after status transition).
  """
  @spec update_manifest(Checkpoint.t(), keyword()) :: {:ok, :ok} | {:error, term()}
  def update_manifest(%Checkpoint{} = checkpoint, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, @default_base_dir)

    with :ok <- validate_path_component(checkpoint.session_id, "session_id"),
         :ok <- validate_path_component(checkpoint.id, "checkpoint_id") do
      manifest_path =
        checkpoint_dir(base_dir, checkpoint.session_id, checkpoint.id)
        |> Path.join("manifest.json")

      write_manifest(manifest_path, checkpoint)
    else
      {:error, reason} -> {:error, {:manifest_path_invalid, reason}}
    end
  end

  @doc """
  Restore files from a checkpoint, returning the workspace to its pre-apply state.

  For each affected file:
    - If the file existed before (snapshot exists), restore its content.
    - If the file did not exist before, delete it.

  After restoration, update the checkpoint manifest status to `:rolled_back`.
  """
  @spec rollback(Checkpoint.t(), keyword()) ::
          {:ok, Checkpoint.t()} | {:error, {:rollback_failed, [term()]}}
  def rollback(%Checkpoint{} = checkpoint, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, @default_base_dir)
    workspace = checkpoint.workspace

    # Validate IDs before any I/O
    with :ok <- validate_path_component(checkpoint.session_id, "session_id"),
         :ok <- validate_path_component(checkpoint.id, "checkpoint_id"),
         {:ok, chk_dir} <-
           validate_checkpoint_dir(
             base_dir,
             checkpoint.session_id,
             checkpoint.id
           ) do
      snapshots_dir = Path.join(chk_dir, "snapshots")

      # Restore FIRST; only transition to :rolled_back on success
      restore_results =
        checkpoint.file_snapshots
        |> Enum.map(fn snapshot ->
          restore_file_snapshot(snapshot, workspace, snapshots_dir, base_dir)
        end)

      errors =
        Enum.filter(restore_results, fn
          {:error, _} -> true
          _ -> false
        end)

      if errors == [] do
        # All restores succeeded — now transition
        {:ok, rolled_back} = Checkpoint.transition(checkpoint, :rolled_back)

        case update_manifest(rolled_back, base_dir: base_dir) do
          {:ok, _} -> {:ok, rolled_back}
          {:error, reason} -> {:error, {:rollback_failed, [reason]}}
        end
      else
        # Restore failed — mark checkpoint as :failed (not :rolled_back)
        error_details = Enum.map(errors, fn {:error, e} -> e end)

        {:ok, failed} =
          Checkpoint.transition(checkpoint, :failed, failure_reason: "rollback restore failed")

        _ = update_manifest(failed, base_dir: base_dir)
        {:error, {:rollback_failed, error_details}}
      end
    else
      {:error, reason} ->
        {:error, {:rollback_failed, [reason]}}
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
    with :ok <- validate_snapshot_path(rel_path, workspace),
         {:ok, safe_abs} <- safe_resolve_restore_path(rel_path, workspace) do
      # Check for symlink escape at capture time
      with :ok <- reject_symlink_at(safe_abs, workspace),
           :ok <- reject_symlink_components_in_path(safe_abs, workspace) do
        if File.exists?(safe_abs) do
          case File.read(safe_abs) do
            {:ok, content} ->
              content_hash =
                :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

              # Write snapshot content — use safe_snapshot_abs to validate
              # the snapshot path has no symlink parent components
              snapshot_rel = snapshot_file_path(rel_path)

              case safe_snapshot_abs(snapshot_rel, snapshots_dir) do
                {:ok, snapshot_abs} ->
                  case safe_mkdir_p(Path.dirname(snapshot_abs)) do
                    {:ok, _} ->
                      case safe_write_file(snapshot_abs, content) do
                        {:ok, _} ->
                          {:ok,
                           %{
                             path: rel_path,
                             existed: true,
                             content_hash: content_hash,
                             snapshot_path: snapshot_rel
                           }}

                        {:error, reason} ->
                          {:error, {:snapshot_write_failed, rel_path, reason}}
                      end

                    {:error, reason} ->
                      {:error, {:snapshot_mkdir_failed, rel_path, reason}}
                  end

                {:error, reason} ->
                  {:error, {:snapshot_write_failed, rel_path, reason}}
              end

            {:error, reason} ->
              {:error, {:read_failed, rel_path, reason}}
          end
        else
          # File does not exist before patch — rollback should delete it
          # Parent dirs already validated by reject_symlink_components_in_path
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
  end

  # Check symlink components in the full path to the file (including parent dirs).
  # This prevents git apply from writing through symlink parents.
  defp reject_symlink_components_in_path(abs_path, workspace) do
    ws = Path.expand(workspace)

    # Walk from workspace root to the parent of abs_path
    parent = Path.dirname(abs_path)

    if parent_safe_for_capture?(parent, ws) do
      :ok
    else
      {:error, {:symlink_component_in_path, abs_path}}
    end
  end

  # For capture, we allow existing safe symlinks that resolve inside workspace
  # but block any symlink that could let git write outside.
  defp parent_safe_for_capture?(target, ws) do
    ws_parts = Path.split(ws)
    target_parts = Path.split(target)

    Enum.reduce_while(
      Enum.drop(target_parts, length(ws_parts)),
      ws,
      fn part, acc ->
        candidate = Path.join(acc, part)

        case File.lstat(candidate) do
          {:ok, %{type: :symlink}} ->
            # Block any symlink component for captures — conservative
            {:halt, false}

          {:error, :enoent} ->
            {:cont, candidate}

          {:error, _} ->
            {:halt, false}

          {:ok, _} ->
            {:cont, candidate}
        end
      end
    )
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

  defp restore_file_snapshot(
         %{existed: false, path: rel_path},
         workspace,
         _snapshots_dir,
         _base_dir
       ) do
    with :ok <- validate_restore_path(rel_path, workspace),
         {:ok, safe_abs} <- safe_resolve_restore_path(rel_path, workspace) do
      # Reject if the target path is a symlink (don't delete through symlinks)
      case File.lstat(safe_abs) do
        {:ok, %{type: :symlink}} ->
          {:error, {:symlink_delete_target, rel_path}}

        {:ok, _} ->
          case File.rm(safe_abs) do
            :ok -> :ok
            {:error, reason} -> {:error, {:delete_failed, rel_path, reason}}
          end

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, {:delete_lstat_failed, rel_path, reason}}
      end
    end
  end

  defp restore_file_snapshot(
         %{existed: true, path: rel_path, snapshot_path: snap_rel, content_hash: expected_hash},
         workspace,
         snapshots_dir,
         _base_dir
       ) do
    with :ok <- validate_restore_path(rel_path, workspace),
         {:ok, safe_abs} <- safe_resolve_restore_path(rel_path, workspace),
         {:ok, snapshot_abs} <- safe_snapshot_abs(snap_rel, snapshots_dir),
         :ok <- reject_snapshot_symlink(snapshot_abs, snap_rel),
         :ok <- require_valid_content_hash(expected_hash, rel_path) do
      case File.read(snapshot_abs) do
        {:ok, content} ->
          # Verify content hash
          with :ok <- verify_snapshot_hash(content, expected_hash, rel_path),
               :ok <- reject_symlink_at(safe_abs, _workspace = nil),
               {:ok, _} <- safe_mkdir_p(Path.dirname(safe_abs)),
               {:ok, _} <- safe_write_file(safe_abs, content) do
            :ok
          else
            {:error, {:hash_mismatch, _path, _expected, _actual} = reason} -> {:error, reason}
            {:error, reason} -> {:error, {:restore_write_failed, rel_path, reason}}
          end

        {:error, reason} ->
          {:error, {:snapshot_read_failed, rel_path, reason}}
      end
    end
  end

  defp restore_file_snapshot(_, _workspace, _snapshots_dir, _base_dir), do: :ok

  # -- Private: restore-time path safety ----------------------------------------

  defp validate_restore_path(rel_path, workspace) do
    try do
      Workspace.safe_resolve!(rel_path, workspace, allow_hidden: true)

      abs = Path.join(workspace, rel_path) |> Path.expand()
      ws = Path.expand(workspace)

      cond do
        not String.starts_with?(abs, ws <> "/") and abs != ws ->
          {:error, {:restore_path_escape, rel_path}}

        Workspace.secret_path?(abs, ws) ->
          {:error, {:restore_secret_path, rel_path}}

        true ->
          :ok
      end
    rescue
      e -> {:error, {:restore_path_unsafe, rel_path, Exception.message(e)}}
    end
  end

  # Returns a safe resolved absolute path for the restore target.
  # Walks parent components checking for symlink escapes.
  defp safe_resolve_restore_path(rel_path, workspace) do
    abs = Path.join(workspace, rel_path) |> Path.expand()
    ws = Path.expand(workspace)

    # Check each existing parent for symlink escape
    parent = Path.dirname(abs)

    if parent_safe?(parent, ws) do
      {:ok, abs}
    else
      {:error, {:restore_path_symlink_component, rel_path}}
    end
  end

  # Walk from workspace root toward the parent dir, checking each existing
  # component via lstat to ensure no symlink escapes.
  defp parent_safe?(target, ws) do
    ws_parts = Path.split(ws)
    target_parts = Path.split(target)

    # Only check components between workspace root and target parent
    Enum.reduce_while(
      Enum.drop(target_parts, length(ws_parts)),
      ws,
      fn part, acc ->
        candidate = Path.join(acc, part)

        case File.lstat(candidate) do
          {:ok, %{type: :symlink}} ->
            # Symlink component found — check if it resolves inside workspace
            case File.stat(candidate) do
              {:ok, _} ->
                resolved = Path.expand(candidate)

                if String.starts_with?(resolved, ws <> "/") or resolved == ws do
                  # Symlink points inside workspace — still block for writes
                  {:halt, false}
                else
                  {:halt, false}
                end

              {:error, _} ->
                {:halt, false}
            end

          {:error, :enoent} ->
            # Non-existent component — safe to proceed (we'll create it)
            {:cont, candidate}

          {:error, _} ->
            {:halt, false}

          {:ok, _} ->
            {:cont, candidate}
        end
      end
    )
  end

  # Resolve a snapshot relative path to a safe absolute path under snapshots_dir.
  # Returns {:ok, abs_path} or {:error, reason}. Never raises.
  #
  # Steps:
  #   1. Require binary/non-empty snap_rel
  #   2. Lexical boundary check: expanded path must be strictly under snapshots_dir
  #   3. Walk each existing parent component from snapshots_dir to target parent,
  #      rejecting any symlink component (prevents redirected reads/writes)
  #   4. For read, reject final path symlink (caller checks separately)
  @spec safe_snapshot_abs(term(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp safe_snapshot_abs(snap_rel, snapshots_dir) do
    with :ok <- require_valid_snapshot_rel(snap_rel),
         {:ok, abs_path, snapshots_expanded} <-
           resolve_and_check_boundary(snap_rel, snapshots_dir),
         :ok <- walk_parent_components(abs_path, snapshots_expanded) do
      {:ok, abs_path}
    end
  end

  defp require_valid_snapshot_rel(snap_rel) when is_binary(snap_rel) and snap_rel != "", do: :ok
  defp require_valid_snapshot_rel(snap_rel), do: {:error, {:invalid_snapshot_path, snap_rel}}

  # Resolve snap_rel under snapshots_dir to an expanded absolute path,
  # verify lexical boundary, and return both the expanded snapshot path
  # and the expanded snapshots_dir for the component walk.
  # Always returns expanded (absolute) paths so that relative snapshots_dir
  # (the default ".muse/sessions/...") does not break component walks.
  defp resolve_and_check_boundary(snap_rel, snapshots_dir) do
    snapshots_expanded = Path.expand(snapshots_dir)
    snapshot_abs = Path.expand(Path.join(snapshots_dir, snap_rel))

    cond do
      snapshot_abs == snapshots_expanded ->
        {:error, {:snapshot_path_escape, snap_rel}}

      not String.starts_with?(snapshot_abs, snapshots_expanded <> "/") ->
        {:error, {:snapshot_path_escape, snap_rel}}

      true ->
        {:ok, snapshot_abs, snapshots_expanded}
    end
  end

  # Walk from snapshots_expanded root to the parent of abs_path, checking each
  # existing component via lstat. Rejects any symlink component.
  # Returns :ok on success, {:error, reason} on failure.
  # Both abs_path and snapshots_expanded MUST be absolute (expanded) paths.
  defp walk_parent_components(abs_path, snapshots_expanded) do
    parent = Path.dirname(abs_path)
    s_parts = Path.split(snapshots_expanded)
    p_parts = Path.split(parent)

    result =
      Enum.reduce_while(
        Enum.drop(p_parts, length(s_parts)),
        {:ok, snapshots_expanded},
        fn part, {:ok, acc} ->
          candidate = Path.join(acc, part)

          case File.lstat(candidate) do
            {:ok, %{type: :symlink}} ->
              {:halt, {:error, {:snapshot_symlink_component, candidate}}}

            {:error, :enoent} ->
              {:cont, {:ok, candidate}}

            {:error, _reason} ->
              {:halt, {:error, {:snapshot_component_stat_failed, candidate}}}

            {:ok, _} ->
              {:cont, {:ok, candidate}}
          end
        end
      )

    case result do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Also check the snapshot file itself is not a symlink (for read path).
  defp reject_snapshot_symlink(snapshot_abs, snap_rel) do
    case File.lstat(snapshot_abs) do
      {:ok, %{type: :symlink}} ->
        {:error, {:snapshot_symlink, snap_rel}}

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Verify snapshot content hash matches the recorded hash.
  # For existed=true snapshots, content_hash must be non-blank binary.
  defp require_valid_content_hash(hash, _rel_path) when is_binary(hash) and hash != "", do: :ok

  defp require_valid_content_hash(_hash, rel_path) do
    {:error, {:invalid_snapshot_hash, rel_path}}
  end

  defp verify_snapshot_hash(content, expected_hash, rel_path)
       when is_binary(expected_hash) and expected_hash != "" do
    actual = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    if String.equivalent?(actual, expected_hash) do
      :ok
    else
      {:error, {:hash_mismatch, rel_path, expected_hash, actual}}
    end
  end

  defp verify_snapshot_hash(_content, _expected, _rel_path), do: :ok

  # Reject if the target path is a symlink (for both workspace and snapshot paths).
  defp reject_symlink_at(abs_path, _workspace) do
    case File.lstat(abs_path) do
      {:ok, %{type: :symlink}} ->
        {:error, {:symlink_target, abs_path}}

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

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

  # -- Private: safe I/O helpers ------------------------------------------------

  defp safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, {:mkdir_failed, reason, path}}
    end
  end

  defp safe_write_file(path, content) do
    case File.write(path, content) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, {:write_failed, reason, path}}
    end
  end

  # Validate checkpoint dir exists and that session_id/checkpoint_id
  # didn't get tampered since creation.
  defp validate_checkpoint_dir(base_dir, session_id, checkpoint_id) do
    with :ok <- validate_path_component(session_id, "session_id"),
         :ok <- validate_path_component(checkpoint_id, "checkpoint_id") do
      dir = checkpoint_dir(base_dir, session_id, checkpoint_id)

      if File.dir?(dir) do
        {:ok, dir}
      else
        {:error, {:checkpoint_not_found, dir}}
      end
    end
  end

  # -- Private: manifest persistence -------------------------------------------

  defp write_manifest(path, %Checkpoint{} = checkpoint) do
    data = Checkpoint.to_map(checkpoint)

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        case atomic_write(path, json) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
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
