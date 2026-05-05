defmodule Muse.Checkpoint do
  @moduledoc """
  First-class checkpoint record for patch apply/rollback safety.

  A checkpoint captures enough workspace state to reliably restore the
  working tree to its pre-apply condition — even when `git stash` is
  unavailable. Each checkpoint records affected-file snapshots (path,
  whether the file existed, and its content hash), git metadata, and
  full binding identity (session, plan, patch).

  ## Status lifecycle

      :created → :active → :rolled_back
                ↘ :failed

  ## Persistence

  Checkpoints are persisted under the session directory:

      .muse/sessions/<session_id>/checkpoints/<checkpoint_id>/
        manifest.json      # checkpoint metadata (atomic write)
        patch.diff          # the approved diff that was applied
        snapshots/          # per-file content snapshots before apply

  Snapshots capture file content only for non-secret, workspace-relative
  paths. Secret paths, absolute paths, and traversal paths are never
  snapshotted. File content is stored as-is (no encoding transforms).
  Files that did not exist before the patch get a special `:did_not_exist`
  marker so rollback can remove them.

  ## Design principles

    * **Pure data** — no I/O in struct construction; all I/O is in
      `Muse.Checkpoint.Store`.
    * **Deterministic identity** — checkpoint id is derived from
      session + patch hash + timestamp.
    * **Safe snapshots** — secret paths are never captured; workspace
      safety is enforced at snapshot time.
    * **Audit-friendly** — every transition and result is persisted.
  """

  @enforce_keys [:id, :session_id, :plan_id, :patch_id, :patch_hash, :status]

  defstruct [
    :id,
    :session_id,
    :plan_id,
    :plan_version,
    :plan_hash,
    :patch_id,
    :patch_hash,
    :workspace,
    :strategy,
    :affected_files,
    :file_snapshots,
    :git_metadata,
    :status,
    :created_at,
    :applied_at,
    :rolled_back_at,
    :failed_at,
    :failure_reason,
    :metadata
  ]

  @type status :: :created | :active | :rolled_back | :failed

  @type file_snapshot :: %{
          path: String.t(),
          existed: boolean(),
          content_hash: String.t() | nil,
          snapshot_path: String.t() | nil
        }

  @type git_metadata :: %{
          stash_ref: String.t() | nil,
          head_sha: String.t() | nil,
          branch: String.t() | nil,
          dirty: boolean() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          plan_id: String.t(),
          plan_version: non_neg_integer() | nil,
          plan_hash: String.t() | nil,
          patch_id: String.t(),
          patch_hash: String.t(),
          workspace: String.t() | nil,
          strategy: :git_apply | :elixir_fallback,
          affected_files: [String.t()],
          file_snapshots: [file_snapshot()],
          git_metadata: git_metadata() | nil,
          status: status(),
          created_at: DateTime.t() | nil,
          applied_at: DateTime.t() | nil,
          rolled_back_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          failure_reason: String.t() | nil,
          metadata: map()
        }

  @statuses [:created, :active, :rolled_back, :failed]

  @doc "Return the canonical list of checkpoint statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Check whether the given status is valid."
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc """
  Create a new checkpoint struct.

  Required keys: `:session_id`, `:plan_id`, `:patch_id`, `:patch_hash`.

  The `:id` is auto-generated if not provided. Timestamps default to now.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    # Normalize string-valued fields that should be atoms
    status = normalize_status(Map.get(attrs, :status) || Map.get(attrs, "status"))

    %__MODULE__{
      id:
        Map.get(attrs, :id) || Map.get(attrs, "id") ||
          generate_id(
            Map.get(attrs, :session_id, "") || Map.get(attrs, "session_id", ""),
            Map.get(attrs, :patch_hash, "") || Map.get(attrs, "patch_hash", "")
          ),
      session_id: Map.get(attrs, :session_id) || Map.get(attrs, "session_id"),
      plan_id: Map.get(attrs, :plan_id) || Map.get(attrs, "plan_id"),
      plan_version: Map.get(attrs, :plan_version) || Map.get(attrs, "plan_version"),
      plan_hash: Map.get(attrs, :plan_hash) || Map.get(attrs, "plan_hash"),
      patch_id: Map.get(attrs, :patch_id) || Map.get(attrs, "patch_id"),
      patch_hash: Map.get(attrs, :patch_hash) || Map.get(attrs, "patch_hash"),
      workspace: Map.get(attrs, :workspace) || Map.get(attrs, "workspace"),
      strategy: normalize_strategy(Map.get(attrs, :strategy) || Map.get(attrs, "strategy")),
      affected_files: Map.get(attrs, :affected_files) || Map.get(attrs, "affected_files", []),
      file_snapshots: Map.get(attrs, :file_snapshots) || Map.get(attrs, "file_snapshots", []),
      git_metadata: Map.get(attrs, :git_metadata) || Map.get(attrs, "git_metadata"),
      status: status,
      created_at: Map.get(attrs, :created_at) || Map.get(attrs, "created_at", now),
      applied_at: Map.get(attrs, :applied_at) || Map.get(attrs, "applied_at"),
      rolled_back_at: Map.get(attrs, :rolled_back_at) || Map.get(attrs, "rolled_back_at"),
      failed_at: Map.get(attrs, :failed_at) || Map.get(attrs, "failed_at"),
      failure_reason: Map.get(attrs, :failure_reason) || Map.get(attrs, "failure_reason"),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata", %{})
    }
  end

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(status) when is_binary(status), do: String.to_atom(status)
  defp normalize_status(_), do: :created

  defp normalize_strategy(strategy) when is_atom(strategy), do: strategy
  defp normalize_strategy(strategy) when is_binary(strategy), do: String.to_atom(strategy)
  defp normalize_strategy(_), do: :git_apply

  @doc "Transition a checkpoint to a new status."
  @spec transition(t(), status(), keyword()) :: {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(checkpoint, new_status, opts \\ [])

  def transition(%__MODULE__{} = checkpoint, :active, opts) do
    {:ok,
     %{
       checkpoint
       | status: :active,
         applied_at: Keyword.get(opts, :applied_at, DateTime.utc_now())
     }}
  end

  def transition(%__MODULE__{} = checkpoint, :rolled_back, opts) do
    {:ok,
     %{
       checkpoint
       | status: :rolled_back,
         rolled_back_at: Keyword.get(opts, :rolled_back_at, DateTime.utc_now())
     }}
  end

  def transition(%__MODULE__{} = checkpoint, :failed, opts) do
    {:ok,
     %{
       checkpoint
       | status: :failed,
         failed_at: Keyword.get(opts, :failed_at, DateTime.utc_now()),
         failure_reason: Keyword.get(opts, :failure_reason)
     }}
  end

  def transition(%__MODULE__{} = checkpoint, new_status, _opts) do
    if valid_status?(new_status) do
      {:ok, %{checkpoint | status: new_status}}
    else
      {:error, {:invalid_status, new_status}}
    end
  end

  @doc "Convert a checkpoint to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = checkpoint) do
    checkpoint
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "Construct a checkpoint from a plain map (e.g. decoded JSON)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    # Normalize file_snapshots from JSON (string keys → atom keys)
    normalized_snapshots =
      (Map.get(map, "file_snapshots") || Map.get(map, :file_snapshots) || [])
      |> Enum.map(&normalize_snapshot_keys/1)

    map = Map.put(map, :file_snapshots, normalized_snapshots)

    new(map)
  end

  defp normalize_snapshot_keys(snapshot) when is_map(snapshot) do
    Enum.reduce(snapshot, %{}, fn
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_atom(k), v)
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp normalize_snapshot_keys(snapshot), do: snapshot

  @doc "Return a safe summary for events (no file content, no raw diff)."
  @spec event_summary(t()) :: map()
  def event_summary(%__MODULE__{} = checkpoint) do
    %{
      checkpoint_id: checkpoint.id,
      session_id: checkpoint.session_id,
      patch_id: checkpoint.patch_id,
      patch_hash: checkpoint.patch_hash,
      plan_id: checkpoint.plan_id,
      strategy: checkpoint.strategy,
      affected_files: checkpoint.affected_files,
      file_count: length(checkpoint.affected_files),
      status: checkpoint.status,
      created_at: checkpoint.created_at
    }
  end

  # -- Private ------------------------------------------------------------------

  defp generate_id(session_id, patch_hash) do
    raw = "#{session_id}:#{patch_hash}:#{System.system_time(:nanosecond)}"
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    "chk_#{String.slice(hash, 0, 16)}"
  end
end
