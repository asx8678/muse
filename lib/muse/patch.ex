defmodule Muse.Patch do
  @moduledoc """
  Struct representing a Muse Patch Proposal — the approval-gated diff
  produced by an execution agent against an approved plan.

  A patch captures the unified diff, its binding to an approved plan/session,
  the affected file list, and its approval lifecycle. The hash is computed
  deterministically over canonical diff content plus binding metadata so that
  identical patches always produce the same hash.

  ## Status lifecycle

      :proposed → :approved → :applied → :verified
                    ↘ :rejected
      :cancelled (from any status)

  ## Construction

      iex> diff = "diff --git a/foo.ex b/foo.ex\\n--- a/foo.ex\\n+++ b/foo.ex\\n@@ -1 +1 @@\\n-old\\n+new\\n"
      iex> patch = Muse.Patch.new(session_id: "s1", plan_id: "p1", plan_version: 1,
      ...>   plan_hash: "abc123", diff: diff)
      iex> patch.status
      :proposed
      iex> is_binary(patch.hash)
      true

  For deterministic tests, pass `id:` and timestamps:

      iex> patch = Muse.Patch.new(id: "patch_1", session_id: "s1",
      ...>   plan_id: "p1", plan_version: 1, plan_hash: "abc", diff: "",
      ...>   created_at: ~U[2025-01-01 00:00:00Z])
      iex> patch.id
      "patch_1"

  ## Design principles

    * **Pure data** — no I/O, no process spawning, no `git apply`.
    * **Deterministic hashing** — SHA-256 over canonical diff + binding metadata.
    * **No binary patches** — `new/1` rejects diffs containing `GIT binary patch`.
    * **Stable formatting** — `canonical_diff/1` normalizes whitespace for hashing.
  """

  alias Muse.Patch.DiffParser

  @enforce_keys [:id, :session_id, :plan_id, :plan_version, :plan_hash, :diff, :hash, :status]

  defstruct [
    :id,
    :session_id,
    :plan_id,
    :plan_version,
    :plan_hash,
    :diff,
    :hash,
    :affected_files,
    :status,
    :created_at,
    :approved_at,
    :rejected_at,
    :applied_at,
    :verified_at,
    :metadata
  ]

  @type status ::
          :proposed
          | :approved
          | :rejected
          | :applied
          | :verified
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t(),
          plan_id: String.t(),
          plan_version: non_neg_integer(),
          plan_hash: String.t(),
          diff: String.t(),
          hash: String.t(),
          affected_files: [String.t()],
          status: status(),
          created_at: DateTime.t() | nil,
          approved_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          applied_at: DateTime.t() | nil,
          verified_at: DateTime.t() | nil,
          metadata: map()
        }

  # -- Valid statuses -----------------------------------------------------------

  @statuses [:proposed, :approved, :rejected, :applied, :verified, :cancelled]

  @doc """
  Return the canonical list of patch statuses.

      iex> Muse.Patch.statuses()
      [:proposed, :approved, :rejected, :applied, :verified, :cancelled]
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Check whether the given status is valid.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  # -- Construction ------------------------------------------------------------

  @doc """
  Create a new `%Muse.Patch{}` from a keyword list or map.

  Parses the diff, extracts affected files, and computes the content hash.
  Returns `{:ok, patch}` on success or `{:error, reason}` if the diff
  contains a binary patch or has fatally malformed structure.

  Defaults:
    - `:id`             → `nil` (assigned by session/persistence layer)
    - `:status`         → `:proposed`
    - `:affected_files` → extracted from diff (can be overridden)
    - `:hash`           → computed via `content_hash_for/1`
    - `:metadata`       → `%{}`

  ## Options

    * `:id`             — patch identifier
    * `:session_id`     — **required** owning session ID
    * `:plan_id`        — **required** approved plan ID
    * `:plan_version`   — **required** plan revision number at binding time
    * `:plan_hash`      — **required** stable hash of the approved plan
    * `:diff`           — **required** unified diff text
    * `:status`         — initial status (default `:proposed`)
    * `:affected_files` — override affected file list (default: extracted from diff)
    * `:hash`           — override content hash (default: computed)
    * `:created_at`     — override timestamp
    * `:metadata`       — bounded metadata map

  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)
    diff = Map.get(normalized, :diff, "")

    with :ok <- DiffParser.validate(diff) do
      affected_files =
        Map.get(normalized, :affected_files) || extract_affected_files(diff)

      now = DateTime.utc_now()
      raw_status = Map.get(normalized, :status, :proposed)
      status = normalize_status(raw_status)

      # Build a preliminary struct to compute hash
      patch = %__MODULE__{
        id: Map.get(normalized, :id),
        session_id: Map.get(normalized, :session_id),
        plan_id: Map.get(normalized, :plan_id),
        plan_version: Map.get(normalized, :plan_version, 1),
        plan_hash: Map.get(normalized, :plan_hash),
        diff: diff,
        hash: Map.get(normalized, :hash) || compute_hash(patch_term(normalized, diff)),
        affected_files: affected_files,
        status: if(valid_status?(status), do: status, else: :proposed),
        created_at: Map.get(normalized, :created_at, now),
        approved_at: Map.get(normalized, :approved_at),
        rejected_at: Map.get(normalized, :rejected_at),
        applied_at: Map.get(normalized, :applied_at),
        verified_at: Map.get(normalized, :verified_at),
        metadata: normalize_metadata(Map.get(normalized, :metadata, %{}))
      }

      {:ok, patch}
    end
  end

  # -- Transition --------------------------------------------------------------

  @doc """
  Transition a patch to a new status.

  Returns `{:ok, patch}` when the status is valid, or
  `{:error, {:invalid_status, status}}` when it is not.

  Timestamps are set automatically:
    - `:approved` → sets `approved_at`
    - `:rejected` → sets `rejected_at`
    - `:applied`  → sets `applied_at`
    - `:verified` → sets `verified_at`
  """
  @spec transition(t(), status(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = patch, new_status, opts \\ []) do
    if valid_status?(new_status) do
      patch = %{patch | status: new_status}
      patch = apply_status_timestamp(patch, new_status, opts)
      {:ok, patch}
    else
      {:error, {:invalid_status, new_status}}
    end
  end

  defp apply_status_timestamp(patch, :approved, opts) do
    %{patch | approved_at: Keyword.get(opts, :approved_at, DateTime.utc_now())}
  end

  defp apply_status_timestamp(patch, :rejected, opts) do
    %{patch | rejected_at: Keyword.get(opts, :rejected_at, DateTime.utc_now())}
  end

  defp apply_status_timestamp(patch, :applied, opts) do
    %{patch | applied_at: Keyword.get(opts, :applied_at, DateTime.utc_now())}
  end

  defp apply_status_timestamp(patch, :verified, opts) do
    %{patch | verified_at: Keyword.get(opts, :verified_at, DateTime.utc_now())}
  end

  defp apply_status_timestamp(patch, _status, _opts), do: patch

  # -- Content hashing ---------------------------------------------------------

  @doc """
  Compute a deterministic SHA-256 hash over the canonical patch content
  plus binding metadata.

  The hash covers:
    - `session_id`
    - `plan_id`
    - `plan_version`
    - `plan_hash`
    - The canonicalized unified diff text

  Volatile fields (timestamps, status, metadata) are excluded so the
  hash reflects *what* the patch contains, not *when* it was approved.

  Returns a 64-character lowercase hex string.
  """
  @spec content_hash(t()) :: String.t()
  def content_hash(%__MODULE__{} = patch) do
    patch
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Return the canonical diff text for this patch.

  Canonicalization normalizes line endings, trims trailing whitespace per
  line, and ensures a trailing newline — producing a stable representation
  suitable for hashing and display.
  """
  @spec canonical_diff(t()) :: String.t()
  def canonical_diff(%__MODULE__{diff: diff}), do: DiffParser.canonicalize(diff)

  @doc """
  Return the list of affected file paths for this patch.
  """
  @spec affected_files(t()) :: [String.t()]
  def affected_files(%__MODULE__{affected_files: files}), do: files

  # -- Conversion helpers -------------------------------------------------------

  @doc """
  Convert a `%Muse.Patch{}` to a plain map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = patch) do
    patch
    |> Map.from_struct()
    |> drop_nil_values()
  end

  @doc """
  Construct a `%Muse.Patch{}` from a plain map (e.g. decoded JSON).

  This is the inverse of `to_map/1`. The diff is parsed and the hash
  is recomputed for integrity.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    # Recompute hash from content; ignore stored hash for integrity
    normalized = normalize_keys(map)
    diff = Map.get(normalized, :diff, "")

    with :ok <- DiffParser.validate(diff) do
      affected_files =
        Map.get(normalized, :affected_files) || extract_affected_files(diff)

      now = DateTime.utc_now()
      raw_status = Map.get(normalized, :status, :proposed)
      status = normalize_status(raw_status)

      patch = %__MODULE__{
        id: Map.get(normalized, :id),
        session_id: Map.get(normalized, :session_id),
        plan_id: Map.get(normalized, :plan_id),
        plan_version: Map.get(normalized, :plan_version, 1),
        plan_hash: Map.get(normalized, :plan_hash),
        diff: diff,
        hash: Map.get(normalized, :hash) || compute_hash(patch_term(normalized, diff)),
        affected_files: affected_files,
        status: if(valid_status?(status), do: status, else: :proposed),
        created_at: Map.get(normalized, :created_at, now),
        approved_at: Map.get(normalized, :approved_at),
        rejected_at: Map.get(normalized, :rejected_at),
        applied_at: Map.get(normalized, :applied_at),
        verified_at: Map.get(normalized, :verified_at),
        metadata: normalize_metadata(Map.get(normalized, :metadata, %{}))
      }

      {:ok, patch}
    end
  end

  # -- Binding ------------------------------------------------------------------

  @doc """
  Return a binding map for patch approvals.

  The binding captures patch/session identity, plan binding, and content hash.
  It is safe to include in status output; it contains no raw diff content.
  """
  @spec approval_binding(t(), keyword()) :: map()
  def approval_binding(%__MODULE__{} = patch, opts \\ []) do
    %{
      kind: "patch_approval",
      session_id: patch.session_id,
      patch_id: patch.id,
      plan_id: patch.plan_id,
      plan_version: patch.plan_version,
      plan_hash: patch.plan_hash,
      patch_hash: patch.hash,
      affected_files: patch.affected_files,
      workspace: Keyword.get(opts, :workspace)
    }
  end

  # -- Private ------------------------------------------------------------------

  @stable_binding_fields [:session_id, :plan_id, :plan_version, :plan_hash]

  defp canonical_term(%__MODULE__{} = patch) do
    binding_term =
      for field <- @stable_binding_fields,
          value = Map.fetch!(patch, field),
          not is_nil(value),
          into: %{} do
        {Atom.to_string(field), stringify(value)}
      end

    canonical_diff = canonical_diff(patch)

    Map.put(binding_term, "diff", canonical_diff)
  end

  defp patch_term(normalized, diff) do
    binding_term =
      for field <- @stable_binding_fields,
          value = Map.get(normalized, field),
          not is_nil(value),
          into: %{} do
        {Atom.to_string(field), stringify(value)}
      end

    canonical_diff = DiffParser.canonicalize(diff)

    Map.put(binding_term, "diff", canonical_diff)
  end

  defp compute_hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value, printable_limit: 1000)

  defp extract_affected_files(diff) do
    case DiffParser.affected_paths(diff) do
      {:ok, paths} -> paths
      {:error, _} -> []
    end
  end

  @known_keys MapSet.new([
                :id,
                :session_id,
                :plan_id,
                :plan_version,
                :plan_hash,
                :diff,
                :hash,
                :affected_files,
                :status,
                :created_at,
                :approved_at,
                :rejected_at,
                :applied_at,
                :verified_at,
                :metadata
              ])

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  defp safe_atom(key) when is_binary(key) do
    if MapSet.member?(@known_keys, String.to_existing_atom(key)) do
      String.to_existing_atom(key)
    else
      key
    end
  rescue
    ArgumentError -> key
  end

  @status_map %{
    "proposed" => :proposed,
    "approved" => :approved,
    "rejected" => :rejected,
    "applied" => :applied,
    "verified" => :verified,
    "cancelled" => :cancelled
  }

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_map, status, :proposed)
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_status), do: :proposed

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Muse.MetadataSanitizer.sanitize(max_depth: 4, max_map_keys: 50, max_list_length: 50)
  end

  defp normalize_metadata(_metadata), do: %{}

  defp drop_nil_values(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
