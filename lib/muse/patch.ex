defmodule Muse.Patch do
  @moduledoc """
  Struct representing a Muse Patch Proposal — an approval-gated change
  description that binds to an approved plan within a session.

  A patch proposal captures what should change (summary, affected files),
  which approved plan it implements, and tracks its approval lifecycle.
  It does **not** apply changes, write files, or modify the workspace.

  ## Status lifecycle

      :proposed → :awaiting_approval → :approved
                                   ↘ :rejected

  `:proposed` is the initial status when a patch is first created.
  `:awaiting_approval` is entered when the patch is submitted for approval.
  `:approved` / `:rejected` are terminal decisions (no apply side effects).

  ## Plan binding

  A patch proposal MUST bind to an approved plan via `plan_id`, `plan_version`,
  and `plan_hash`. This ensures patches can only be proposed against plans
  that have already been approved by the user.

  ## Construction

      iex> patch = Muse.Patch.new(
      ...>   session_id: "sess_1",
      ...>   plan_id: "plan_1",
      ...>   plan_version: 1,
      ...>   plan_hash: "abc123",
      ...>   workspace: "/tmp/project",
      ...>   summary: "Add /version command"
      ...> )
      iex> patch.status
      :proposed

  For deterministic tests, pass `id:` and `created_at:` / `updated_at:`.
  """

  @enforce_keys [:id, :session_id, :plan_id, :plan_version, :plan_hash, :status]
  defstruct [
    :id,
    :session_id,
    :plan_id,
    :plan_version,
    :plan_hash,
    :workspace,
    :status,
    :summary,
    :description,
    :diff_summary,
    :affected_files,
    :created_by,
    :created_at,
    :updated_at,
    :approved_at,
    :rejected_at,
    approvals: [],
    metadata: %{}
  ]

  @type status ::
          :proposed
          | :awaiting_approval
          | :approved
          | :rejected

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          plan_id: String.t(),
          plan_version: non_neg_integer(),
          plan_hash: String.t(),
          workspace: String.t() | nil,
          status: status(),
          summary: String.t() | nil,
          description: String.t() | nil,
          diff_summary: String.t() | nil,
          affected_files: [String.t()],
          created_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          approved_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          approvals: [map()],
          metadata: map()
        }

  @statuses [:proposed, :awaiting_approval, :approved, :rejected]

  @status_map %{
    "proposed" => :proposed,
    "awaiting_approval" => :awaiting_approval,
    "approved" => :approved,
    "rejected" => :rejected
  }

  @doc "Return the canonical list of patch statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Check whether the given status is valid."
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc """
  Create a new `%Muse.Patch{}` from a keyword list or map.

  Accepts both atom and string keys.

  Defaults:
    - `:id`           → auto-generated
    - `:status`        → `:proposed`
    - `:plan_version`  → `1`
    - `:affected_files` → `[]`
    - `:approvals`     → `[]`
    - `:metadata`      → `%{}`

  The `:plan_id`, `:plan_version`, and `:plan_hash` fields are required for
  binding to an approved plan.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)
    now = DateTime.utc_now()

    %__MODULE__{
      id: Map.get(normalized, :id) || generate_id(),
      session_id: to_string(Map.get(normalized, :session_id, "")),
      plan_id: to_string(Map.get(normalized, :plan_id, "")),
      plan_version: normalize_version(Map.get(normalized, :plan_version, 1)),
      plan_hash: to_string(Map.get(normalized, :plan_hash, "")),
      workspace: normalize_optional_string(Map.get(normalized, :workspace)),
      status: normalize_status(Map.get(normalized, :status, :proposed)),
      summary: normalize_optional_string(Map.get(normalized, :summary)),
      description: normalize_optional_string(Map.get(normalized, :description)),
      diff_summary: normalize_optional_string(Map.get(normalized, :diff_summary)),
      affected_files: normalize_string_list(Map.get(normalized, :affected_files, [])),
      created_by: normalize_optional_string(Map.get(normalized, :created_by)),
      created_at: normalize_datetime(Map.get(normalized, :created_at, now)),
      updated_at: normalize_datetime(Map.get(normalized, :updated_at, now)),
      approved_at: normalize_datetime(Map.get(normalized, :approved_at)),
      rejected_at: normalize_datetime(Map.get(normalized, :rejected_at)),
      approvals: Map.get(normalized, :approvals, []),
      metadata: normalize_metadata(Map.get(normalized, :metadata, %{}))
    }
  end

  @doc """
  Transition a patch to a new status.

  Returns `{:ok, patch}` when the status is valid, or
  `{:error, {:invalid_status, status}}` when it is not.

  Timestamps are set automatically based on target status:
  - `:approved` sets `approved_at`
  - `:rejected` sets `rejected_at`
  """
  @spec transition(t(), status(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = patch, new_status, opts \\ []) do
    if valid_status?(new_status) do
      now = Keyword.get(opts, :updated_at, DateTime.utc_now())

      patch =
        patch
        |> Map.put(:status, new_status)
        |> Map.put(:updated_at, now)
        |> apply_status_timestamp(new_status, opts)

      {:ok, patch}
    else
      {:error, {:invalid_status, new_status}}
    end
  end

  @doc "Converts a patch to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = patch) do
    patch
    |> Map.from_struct()
    |> Map.update!(:metadata, &normalize_metadata/1)
    |> drop_nil_values()
  end

  @doc "Construct a patch from a plain map (e.g. decoded JSON)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  @doc """
  Compute a deterministic SHA-256 content hash over the stable content of a patch.

  The hash covers session_id, plan_id, plan_version, plan_hash, workspace,
  summary, description, diff_summary, and affected_files. It does NOT cover
  timestamps, status, approvals, or metadata.
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
  Return a binding map for patch approvals.

  The binding captures patch/session/plan identity and stable content hash.
  It is safe to include in status output and session snapshots.
  """
  @spec approval_binding(t(), keyword()) :: map()
  def approval_binding(%__MODULE__{} = patch, opts \\ []) do
    %{
      kind: "patch_approval",
      session_id: patch.session_id,
      plan_id: patch.plan_id,
      plan_version: patch.plan_version,
      plan_hash: patch.plan_hash,
      patch_id: patch.id,
      patch_hash: content_hash(patch),
      workspace: Keyword.get(opts, :workspace) || patch.workspace
    }
  end

  @doc """
  Validate that a patch proposal has the required plan binding fields.

  Returns `:ok` when all binding fields are present and non-empty, or
  `{:error, reason}` describing which field is missing.
  """
  @spec validate_plan_binding(t()) :: :ok | {:error, term()}
  def validate_plan_binding(%__MODULE__{} = patch) do
    cond do
      missing?(patch.session_id) -> {:error, :missing_session_id}
      missing?(patch.plan_id) -> {:error, :missing_plan_id}
      missing?(patch.plan_version) -> {:error, :missing_plan_version}
      missing?(patch.plan_hash) -> {:error, :missing_plan_hash}
      true -> :ok
    end
  end

  # -- Private helpers ---------------------------------------------------------

  defp apply_status_timestamp(patch, :approved, opts) do
    Map.put(patch, :approved_at, Keyword.get(opts, :approved_at, DateTime.utc_now()))
  end

  defp apply_status_timestamp(patch, :rejected, opts) do
    patch =
      Map.put(patch, :rejected_at, Keyword.get(opts, :rejected_at, DateTime.utc_now()))

    if opts[:reason] do
      metadata = Map.put(patch.metadata || %{}, :rejection_reason, opts[:reason])
      Map.put(patch, :metadata, metadata)
    else
      patch
    end
  end

  defp apply_status_timestamp(patch, _status, _opts), do: patch

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_status(status) when is_atom(status),
    do: if(valid_status?(status), do: status, else: :proposed)

  defp normalize_status(status) when is_binary(status) do
    case Map.fetch(@status_map, String.downcase(String.trim(status))) do
      {:ok, parsed} -> parsed
      :error -> :proposed
    end
  end

  defp normalize_status(_), do: :proposed

  defp normalize_version(v) when is_integer(v) and v >= 0, do: v

  defp normalize_version(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_version(_), do: 1

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(v) when is_binary(v), do: String.trim(v)
  defp normalize_optional_string(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_optional_string(_), do: nil

  defp normalize_string_list(list) when is_list(list) do
    Enum.flat_map(list, fn
      s when is_binary(s) -> [String.trim(s)]
      s when is_atom(s) -> [Atom.to_string(s)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_), do: []

  defp normalize_datetime(%DateTime{} = dt), do: dt

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp missing?(nil), do: true
  defp missing?(""), do: true
  defp missing?(_), do: false

  defp canonical_term(%__MODULE__{} = patch) do
    for field <- [
          :session_id,
          :plan_id,
          :plan_version,
          :plan_hash,
          :workspace,
          :summary,
          :description,
          :diff_summary,
          :affected_files
        ],
        value = Map.fetch!(patch, field),
        not is_nil(value),
        into: %{} do
      {Atom.to_string(field), canonicalize_value(field, value)}
    end
  end

  defp canonicalize_value(:affected_files, files) when is_list(files) do
    Enum.sort(files)
  end

  defp canonicalize_value(_field, value), do: stringify_keys(value)

  defp stringify_keys(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_keys(%_{} = struct), do: struct |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(map) when is_map(map) do
    map
    |> Map.new(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
      {k, v} -> {inspect(k), stringify_keys(v)}
    end)
    |> drop_nil_values()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify_keys(value), do: value

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end

  defp generate_id do
    "patch_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
