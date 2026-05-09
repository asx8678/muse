defmodule Muse.Checkpoint.GitMetadata do
  @moduledoc """
  Hardened git metadata retrieval for checkpoint creation.

  Replaces direct `System.cmd/3` calls with the `LocalRunner`, ensuring:

    * **Finite timeouts** — git commands cannot hang indefinitely
    * **Sanitized environment** — only allowlisted env vars are inherited;
      secrets (API keys, tokens, etc.) are never passed to git subprocesses
    * **Process-group cleanup** — on timeout, the full process tree is
      terminated (Unix) or the port is closed (Windows)
    * **Explicit failure handling** — failures return safe fallback values
      (`nil`) without crashing the checkpoint flow
    * **Redacted diagnostics** — output is redacted via `Prompt.Redactor`
      before inclusion in logs or result structs

  ## Fallback behavior

  When git is unavailable, times out, or returns a non-zero exit code,
  each metadata field falls back to `nil`. The checkpoint flow continues
  with partial metadata — no crash, no exception propagation.

  ## Timeout

  Default timeout is 5 seconds per git command, configurable via
  `:git_timeout_ms` option. This is generous for local git operations
  (`rev-parse`, `stash create`, `status --porcelain`) which normally
  complete in under 100ms.
  """

  require Logger

  alias Muse.Execution.{Command, LocalRunner, Result}

  @default_git_timeout_ms 5_000
  @fallback_metadata %{stash_ref: nil, head_sha: nil, branch: nil, dirty: nil}

  @doc """
  Capture git metadata for a workspace using the hardened runner.

  Returns `{:ok, metadata_map}` where the map contains:
    * `:stash_ref` — result of `git stash create` (SHA string or `""` or `nil`)
    * `:head_sha` — current HEAD commit SHA (`nil` on failure)
    * `:branch` — current branch name (`nil` on failure)
    * `:dirty` — whether the working tree has changes (`nil` on failure)

  ## Options

    * `:capture_git_stash` — attempt `git stash create` for backup (default: `true`)
    * `:git_timeout_ms` — per-command timeout in ms (default: `5_000`)

  ## Examples

      {:ok, meta} = Muse.Checkpoint.GitMetadata.capture("/path/to/repo")
      meta.head_sha  # => "abc123..." or nil
  """
  @spec capture(String.t(), keyword()) :: {:ok, map()}
  def capture(workspace, opts \\ [])

  def capture(workspace, opts) when is_binary(workspace) and is_list(opts) do
    timeout = Keyword.get(opts, :git_timeout_ms, @default_git_timeout_ms)

    if Keyword.get(opts, :capture_git_stash, true) do
      {:ok,
       %{
         stash_ref: run_git(workspace, ["stash", "create"], timeout),
         head_sha: run_git(workspace, ["rev-parse", "HEAD"], timeout),
         branch: run_git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"], timeout),
         dirty: run_git_dirty?(workspace, timeout)
       }}
    else
      {:ok, @fallback_metadata}
    end
  end

  def capture(_workspace, _opts), do: {:ok, @fallback_metadata}

  @doc """
  Return the default fallback metadata map (all fields `nil`).
  """
  @spec fallback() :: map()
  def fallback, do: @fallback_metadata

  @doc """
  Return the default per-command timeout in milliseconds.
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_git_timeout_ms

  # -- Private: hardened git execution ------------------------------------------

  defp run_git(workspace, args, timeout) do
    case build_and_run(workspace, args, timeout) do
      {:ok, output} ->
        String.trim(output)

      {:error, reason} ->
        Logger.warning("Git metadata command failed",
          args: inspect(args),
          workspace: workspace,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp run_git_dirty?(workspace, timeout) do
    case build_and_run(workspace, ["status", "--porcelain"], timeout) do
      {:ok, output} ->
        String.trim(output) != ""

      {:error, reason} ->
        Logger.warning("Git dirty check failed",
          workspace: workspace,
          reason: inspect(reason)
        )

        nil
    end
  end

  # Build a Command struct and execute via LocalRunner.
  # Returns {:ok, output_string} on success, {:error, reason} on any failure.
  # The LocalRunner enforces:
  #   - Sanitized env via Muse.Execution.Env (no secrets inherited)
  #   - Finite timeout with process-group cleanup
  #   - Output capping and secret redaction
  defp build_and_run(workspace, args, timeout) do
    with {:ok, cmd} <-
           Command.new("git",
             args: args,
             cwd: workspace,
             timeout_ms: timeout,
             # Empty env overrides — rely on Env.port_env allowlist
             # via LocalRunner. No additional env vars needed for git.
             env: %{},
             max_output_bytes: 10_000
           ),
         {:ok, %Result{status: :ok, output: output}} <- LocalRunner.run(cmd) do
      {:ok, output}
    else
      {:ok, %Result{status: :timed_out} = result} ->
        {:error, {:git_timeout, result.error, Result.safe_summary(result)}}

      {:ok, %Result{status: :error} = result} ->
        {:error, {:git_failed, result.error, result.exit_status}}

      {:ok, %Result{} = result} ->
        {:error, {:git_unexpected, result.status, Result.safe_summary(result)}}

      {:error, %Result{status: :blocked} = result} ->
        {:error, {:git_blocked, result.error}}

      {:error, reason} when is_binary(reason) ->
        # Command.new validation failure (e.g. git not in PATH)
        {:error, {:git_command_invalid, reason}}

      {:error, reason} ->
        {:error, {:git_execution_error, reason}}
    end
  end
end
