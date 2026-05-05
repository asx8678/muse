defmodule Muse.Approval do
  @moduledoc """
  First-class approval record for gated Muse actions.

  Approval records are intentionally data-only. They bind a user decision to a
  concrete session/resource identity and can be serialized into session
  snapshots and event payloads without granting runtime authority by themselves.

  `:kind` is the canonical discriminator. `:type` is kept as a synchronized
  compatibility alias for older payloads and JSON APIs that use `type`.
  Likewise, `:plan_hash` is canonical for plan binding while `:content_hash` is
  retained as a compatibility alias for lanes and persisted snapshots that used
  that name.

  String keys, statuses, and kinds from JSON are matched against explicit maps.
  Unknown values fall back to safe defaults without calling `String.to_atom/1` or
  creating atoms from user/LLM/persisted input.
  """

  @enforce_keys [:id, :kind, :type, :status, :created_at]
  defstruct [
    :id,
    :session_id,
    :kind,
    :type,
    :status,
    :scope,
    :plan_id,
    :plan_version,
    :plan_hash,
    :content_hash,
    :task_id,
    :patch_id,
    :patch_hash,
    :tool_call_id,
    :workspace,
    :source,
    :requested_by,
    :approved_by,
    :rejected_by,
    :created_at,
    :approved_at,
    :rejected_at,
    :expires_at,
    :reason,
    metadata: %{}
  ]

  @type kind ::
          :plan
          | :patch
          | :write
          | :shell
          | :shell_command
          | :network
          | :delete
          | :restore
          | :restore_checkpoint
          | :remote_execution

  @type status :: :pending | :approved | :rejected | :expired | :stale | :superseded

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t() | nil,
          kind: kind(),
          type: kind(),
          status: status(),
          scope: term() | nil,
          plan_id: String.t() | nil,
          plan_version: non_neg_integer() | nil,
          plan_hash: String.t() | nil,
          content_hash: String.t() | nil,
          task_id: String.t() | nil,
          patch_id: String.t() | nil,
          patch_hash: String.t() | nil,
          tool_call_id: String.t() | nil,
          workspace: String.t() | nil,
          source: String.t() | nil,
          requested_by: String.t() | nil,
          approved_by: String.t() | nil,
          rejected_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          approved_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          reason: String.t() | nil,
          metadata: map()
        }

  @kinds [
    :plan,
    :patch,
    :write,
    :shell,
    :shell_command,
    :network,
    :delete,
    :restore,
    :restore_checkpoint,
    :remote_execution
  ]

  @statuses [:pending, :approved, :rejected, :expired, :stale, :superseded]

  @kind_map %{
    "plan" => :plan,
    "patch" => :patch,
    "patch_apply" => :patch,
    "patch_propose" => :patch,
    "write" => :write,
    "write_file" => :write,
    "shell" => :shell,
    "shell_command" => :shell_command,
    "network" => :network,
    "network_call" => :network,
    "delete" => :delete,
    "delete_file" => :delete,
    "restore" => :restore,
    "restore_checkpoint" => :restore_checkpoint,
    "remote_execution" => :remote_execution
  }

  @status_map %{
    "pending" => :pending,
    "approved" => :approved,
    "rejected" => :rejected,
    "expired" => :expired,
    "stale" => :stale,
    "superseded" => :superseded
  }

  @key_map %{
    "id" => :id,
    "session_id" => :session_id,
    "sessionId" => :session_id,
    "kind" => :kind,
    "type" => :type,
    "status" => :status,
    "scope" => :scope,
    "plan_id" => :plan_id,
    "planId" => :plan_id,
    "plan_version" => :plan_version,
    "planVersion" => :plan_version,
    "version" => :version,
    "plan_hash" => :plan_hash,
    "planHash" => :plan_hash,
    "content_hash" => :content_hash,
    "contentHash" => :content_hash,
    "hash" => :hash,
    "task_id" => :task_id,
    "taskId" => :task_id,
    "patch_id" => :patch_id,
    "patchId" => :patch_id,
    "patch_hash" => :patch_hash,
    "patchHash" => :patch_hash,
    "tool_call_id" => :tool_call_id,
    "toolCallId" => :tool_call_id,
    "workspace" => :workspace,
    "source" => :source,
    "requested_by" => :requested_by,
    "requestedBy" => :requested_by,
    "approved_by" => :approved_by,
    "approvedBy" => :approved_by,
    "rejected_by" => :rejected_by,
    "rejectedBy" => :rejected_by,
    "actor" => :actor,
    "created_at" => :created_at,
    "createdAt" => :created_at,
    "approved_at" => :approved_at,
    "approvedAt" => :approved_at,
    "rejected_at" => :rejected_at,
    "rejectedAt" => :rejected_at,
    "expires_at" => :expires_at,
    "expiresAt" => :expires_at,
    "reason" => :reason,
    "metadata" => :metadata,
    "at" => :at,
    "decided_at" => :decided_at,
    "decidedAt" => :decided_at
  }

  @raw_content_keys ~w(
    content
    diff
    file_content
    file_contents
    patch
    plan
    plan_json
    raw_content
    raw_file
    raw_file_content
    raw_file_contents
    raw_json
    raw_plan
    raw_plan_json
  )

  @type content_ref :: %{
          label: String.t(),
          algorithm: String.t(),
          hash: String.t(),
          bytes: non_neg_integer()
        }

  @doc "Return the canonical approval kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Return the canonical approval types. Alias for `kinds/0`."
  @spec types() :: [kind()]
  def types, do: @kinds

  @doc "Return the canonical approval statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Check whether `kind` is a canonical approval kind."
  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @doc "Check whether `type` is a canonical approval type."
  @spec valid_type?(term()) :: boolean()
  def valid_type?(type), do: valid_kind?(type)

  @doc "Check whether `status` is a canonical approval status."
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc """
  Create a new `%Muse.Approval{}` from a keyword list or map.

  Accepts atom keys, snake_case JSON string keys, and selected legacy camelCase
  keys. Unknown string keys are ignored and never converted to atoms.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)
    now = DateTime.utc_now()
    kind = normalize_kind(normalized)
    plan_hash = normalize_optional_string(first_present(normalized, [:plan_hash, :content_hash, :hash]))
    content_hash = normalize_optional_string(first_present(normalized, [:content_hash, :plan_hash, :hash]))

    %__MODULE__{
      id: normalize_id(Map.get(normalized, :id)) || generate_id(),
      session_id: normalize_optional_string(Map.get(normalized, :session_id)),
      kind: kind,
      type: kind,
      status: normalize_status(Map.get(normalized, :status), :pending),
      scope: normalize_scope(Map.get(normalized, :scope, kind)),
      plan_id: normalize_optional_string(Map.get(normalized, :plan_id)),
      plan_version:
        normalize_plan_version(Map.get(normalized, :plan_version, Map.get(normalized, :version))),
      plan_hash: plan_hash,
      content_hash: content_hash || plan_hash,
      task_id: normalize_optional_string(Map.get(normalized, :task_id)),
      patch_id: normalize_optional_string(Map.get(normalized, :patch_id)),
      patch_hash: normalize_optional_string(Map.get(normalized, :patch_hash)),
      tool_call_id: normalize_optional_string(Map.get(normalized, :tool_call_id)),
      workspace: normalize_optional_string(Map.get(normalized, :workspace)),
      source: normalize_optional_string(Map.get(normalized, :source)),
      requested_by: normalize_optional_string(Map.get(normalized, :requested_by)),
      approved_by: normalize_optional_string(Map.get(normalized, :approved_by)),
      rejected_by: normalize_optional_string(Map.get(normalized, :rejected_by)),
      created_at: datetime_from_attrs(normalized, :created_at, now),
      approved_at: datetime_from_attrs(normalized, :approved_at),
      rejected_at: datetime_from_attrs(normalized, :rejected_at),
      expires_at: datetime_from_attrs(normalized, :expires_at),
      reason: normalize_optional_string(Map.get(normalized, :reason)),
      metadata: normalize_metadata(Map.get(normalized, :metadata, %{}))
    }
  end

  @doc """
  Transition an approval to a valid status.

  `new_status` may be a canonical atom or a known JSON string. Options may use
  atom, string, snake_case, or camelCase keys. Supported options include `:at`,
  `:approved_at`, `:approved_by`, `:rejected_at`, `:rejected_by`, `:reason`, and
  `:metadata`.
  """
  @spec transition(t(), status() | String.t(), keyword() | map()) ::
          {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = approval, new_status, attrs \\ [])
      when is_list(attrs) or is_map(attrs) do
    case parse_status(new_status) do
      {:ok, status} ->
        opts = normalize_options(attrs)
        now = transition_time(opts, status)

        approval =
          approval
          |> canonicalize_aliases()
          |> Map.put(:status, status)
          |> apply_common_transition_fields(opts)
          |> apply_status_transition_fields(status, opts, now)

        {:ok, approval}

      :error ->
        {:error, {:invalid_status, new_status}}
    end
  end

  @doc """
  Approve a pending approval.

  The second argument may be an approver identifier or an option map/keyword
  list. Returns `{:error, :expired}` for expired approvals and
  `{:error, {:invalid_transition, current, :approved}}` when no longer pending.
  """
  @spec approve(t(), String.t() | atom() | keyword() | map() | nil) ::
          {:ok, t()} | {:error, :expired | {:invalid_transition, status(), :approved}}
  def approve(approval, attrs \\ [])

  def approve(%__MODULE__{} = approval, approved_by)
      when is_binary(approved_by) or is_atom(approved_by) do
    approve(approval, %{approved_by: approved_by})
  end

  def approve(%__MODULE__{} = approval, attrs) when is_list(attrs) or is_map(attrs) do
    opts = normalize_options(attrs)
    now = transition_time(opts, :approved)

    cond do
      expired?(approval, now) -> {:error, :expired}
      approval.status != :pending -> {:error, {:invalid_transition, approval.status, :approved}}
      true -> transition(approval, :approved, Map.put(opts, :at, now))
    end
  end

  @doc """
  Reject a pending approval.

  The second argument may be a rejection reason or an option map/keyword list.
  """
  @spec reject(t(), String.t() | atom() | keyword() | map() | nil) ::
          {:ok, t()} | {:error, :expired | {:invalid_transition, status(), :rejected}}
  def reject(approval, attrs \\ [])

  def reject(%__MODULE__{} = approval, reason) when is_binary(reason) or is_atom(reason) do
    reject(approval, %{reason: reason})
  end

  def reject(%__MODULE__{} = approval, attrs) when is_list(attrs) or is_map(attrs) do
    opts = normalize_options(attrs)
    now = transition_time(opts, :rejected)

    cond do
      expired?(approval, now) -> {:error, :expired}
      approval.status != :pending -> {:error, {:invalid_transition, approval.status, :rejected}}
      true -> transition(approval, :rejected, Map.put(opts, :at, now))
    end
  end

  @doc "Return true when the approval is marked expired or is past `expires_at`."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{} = approval), do: expired?(approval, DateTime.utc_now())

  @doc "Return true when the approval is expired at the supplied time."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{status: :expired}, _now), do: true
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now) do
    expires_at = normalize_datetime(expires_at)
    now = normalize_datetime(now) || DateTime.utc_now()

    case expires_at do
      %DateTime{} -> DateTime.compare(expires_at, now) != :gt
      nil -> false
    end
  end

  @doc """
  Return true when an approval no longer matches the supplied current plan.

  The comparison is conservative for identity fields: a field only participates
  when both the approval and the current plan provide a comparable value. For
  `%Muse.Plan{}` structs the content hash is computed through `Muse.PlanBinding`
  so semantic plan edits are detected even when the plan map has no stored hash.
  """
  @spec stale?(t(), map() | struct() | nil) :: boolean()
  def stale?(%__MODULE__{status: :stale}, _current_plan), do: true
  def stale?(%__MODULE__{}, nil), do: false

  def stale?(%__MODULE__{} = approval, current_plan) when is_map(current_plan) do
    current = plan_comparison_map(current_plan)

    mismatch?(approval.plan_id, fetch_any(current, [:plan_id, :id])) ||
      mismatch?(approval.plan_version, fetch_any(current, [:plan_version, :version])) ||
      mismatch?(approval_hash(approval), current_plan_hash(current_plan, current))
  end

  @doc "Converts an approval to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = approval) do
    approval
    |> canonicalize_aliases()
    |> Map.from_struct()
    |> Map.update!(:metadata, &normalize_metadata/1)
    |> drop_nil_values()
  end

  @doc "Construct an approval from a plain map, such as decoded JSON."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  @doc "Normalizes a list of approval maps/structs and drops invalid entries."
  @spec normalize_list(term()) :: [t()]
  def normalize_list(values) when is_list(values) do
    Enum.flat_map(values, fn
      %__MODULE__{} = approval -> [canonicalize_aliases(approval)]
      attrs when is_map(attrs) -> [from_map(attrs)]
      _other -> []
    end)
  rescue
    _ -> []
  end

  def normalize_list(_values), do: []

  @doc """
  Build a redacted, event-safe approval payload.

  Any raw-content keys are removed and summarized under `:content_refs`.
  Non-raw fields such as `:reason` and `:metadata` are recursively redacted.
  """
  @spec event_payload(map() | keyword() | t()) :: map()
  def event_payload(%__MODULE__{} = approval), do: approval |> to_map() |> event_payload()

  def event_payload(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> event_payload()
  end

  def event_payload(attrs) when is_map(attrs) do
    {payload, content_refs} = strip_raw_content(attrs)

    payload
    |> Muse.EventPayloadRedactor.redact()
    |> put_content_refs(content_refs)
  end

  @doc """
  Return a redacted approval record suitable for persistence.

  This is currently equivalent to `event_payload/1`; it is named separately so
  future persistence rules can evolve without changing callers.
  """
  @spec safe_record(map() | keyword() | t()) :: map()
  def safe_record(attrs), do: event_payload(attrs)

  @doc """
  Compute a stable SHA-256 content hash for approval binding.

  The returned value is only the lowercase hex digest. Callers should store this
  hash (or `content_ref/2`), not raw plan JSON/file contents, in approval events.
  """
  @spec content_hash(term()) :: String.t()
  def content_hash(content) do
    content
    |> canonical_binary()
    |> sha256()
  end

  @doc "Build a content reference containing hash metadata but no raw content."
  @spec content_ref(atom() | String.t(), term()) :: content_ref()
  def content_ref(label, content) do
    canonical = canonical_binary(content)

    %{
      label: to_string(label),
      algorithm: "sha256",
      hash: sha256(canonical),
      bytes: byte_size(canonical)
    }
  end

  defp normalize_options(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_keys()
  defp normalize_options(attrs) when is_map(attrs), do: normalize_keys(attrs)

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {Map.get(@key_map, key, key), value}
      {key, value} when is_atom(key) -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_kind(normalized) do
    case parse_kind(Map.get(normalized, :kind)) do
      {:ok, kind} -> kind
      :error -> normalize_kind(Map.get(normalized, :type), :plan)
    end
  end

  defp normalize_kind(kind, default) do
    case parse_kind(kind) do
      {:ok, parsed} -> parsed
      :error -> default
    end
  end

  defp parse_kind(kind) when is_atom(kind),
    do: if(valid_kind?(kind), do: {:ok, kind}, else: :error)

  defp parse_kind(kind) when is_binary(kind) do
    case Map.fetch(@kind_map, string_lookup_key(kind)) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_kind(_kind), do: :error

  defp normalize_status(status, default) do
    case parse_status(status) do
      {:ok, parsed} -> parsed
      :error -> default
    end
  end

  defp parse_status(status) when is_atom(status),
    do: if(valid_status?(status), do: {:ok, status}, else: :error)

  defp parse_status(status) when is_binary(status) do
    case Map.fetch(@status_map, string_lookup_key(status)) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_status(_status), do: :error

  defp string_lookup_key(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_id(value) do
    case normalize_optional_string(value) do
      "" -> nil
      id -> id
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(true), do: nil
  defp normalize_optional_string(false), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_plan_version(version) when is_integer(version) and version >= 0, do: version

  defp normalize_plan_version(version) when is_binary(version) do
    case Integer.parse(String.trim(version)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp normalize_plan_version(_version), do: nil

  defp datetime_from_attrs(attrs, key, default \\ nil) do
    if Map.has_key?(attrs, key), do: normalize_datetime(Map.get(attrs, key)), else: default
  end

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp transition_time(opts, :approved),
    do:
      datetime_from_attrs(opts, :at) || datetime_from_attrs(opts, :decided_at) ||
        datetime_from_attrs(opts, :approved_at) || DateTime.utc_now()

  defp transition_time(opts, :rejected),
    do:
      datetime_from_attrs(opts, :at) || datetime_from_attrs(opts, :decided_at) ||
        datetime_from_attrs(opts, :rejected_at) || DateTime.utc_now()

  defp transition_time(opts, _status),
    do: datetime_from_attrs(opts, :at) || datetime_from_attrs(opts, :decided_at) || DateTime.utc_now()

  defp canonicalize_aliases(%__MODULE__{} = approval) do
    kind = normalize_kind(%{kind: approval.kind, type: approval.type})
    hash = approval.plan_hash || approval.content_hash

    %{approval | kind: kind, type: kind, plan_hash: hash, content_hash: approval.content_hash || hash}
  end

  defp apply_common_transition_fields(%__MODULE__{} = approval, opts) do
    approval
    |> maybe_put_optional_string(:reason, Map.get(opts, :reason))
    |> maybe_put_optional_string(:source, Map.get(opts, :source))
    |> maybe_merge_metadata(Map.get(opts, :metadata))
  end

  defp apply_status_transition_fields(%__MODULE__{} = approval, :approved, opts, now) do
    %{
      approval
      | approved_at: datetime_from_attrs(opts, :approved_at, now),
        approved_by:
          normalize_optional_string(
            first_present(opts, [:approved_by, :actor, :source])
          ) || approval.approved_by,
        rejected_by: nil,
        rejected_at: nil
    }
  end

  defp apply_status_transition_fields(%__MODULE__{} = approval, :rejected, opts, now) do
    %{
      approval
      | rejected_at: datetime_from_attrs(opts, :rejected_at, now),
        rejected_by:
          normalize_optional_string(
            first_present(opts, [:rejected_by, :actor, :source])
          ) || approval.rejected_by,
        reason: normalize_optional_string(Map.get(opts, :reason)) || approval.reason
    }
  end

  defp apply_status_transition_fields(%__MODULE__{} = approval, _status, _opts, _now),
    do: approval

  defp maybe_put_optional_string(approval, _key, nil), do: approval

  defp maybe_put_optional_string(approval, key, value) do
    case normalize_optional_string(value) do
      nil -> approval
      normalized -> Map.put(approval, key, normalized)
    end
  end

  defp maybe_merge_metadata(%__MODULE__{} = approval, metadata) when is_map(metadata) do
    %{
      approval
      | metadata: Map.merge(normalize_metadata(approval.metadata), normalize_metadata(metadata))
    }
  end

  defp maybe_merge_metadata(%__MODULE__{} = approval, _metadata), do: approval

  defp normalize_scope(nil), do: nil
  defp normalize_scope(value) when is_binary(value), do: value
  defp normalize_scope(value) when is_number(value), do: value
  defp normalize_scope(value) when is_boolean(value), do: value
  defp normalize_scope(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_scope(value) when is_map(value) or is_list(value) or is_tuple(value) do
    value
    |> Muse.MetadataSanitizer.sanitize(max_depth: 4, max_map_keys: 50, max_list_length: 50)
    |> normalize_metadata_value()
  end

  defp normalize_scope(value), do: inspect(value, printable_limit: 100)

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Muse.MetadataSanitizer.sanitize(max_depth: 4, max_map_keys: 50, max_list_length: 50)
    |> normalize_metadata_map()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp normalize_metadata_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_metadata_key(key), normalize_metadata_value(value)}
    end)
  end

  defp normalize_metadata_key(key) when is_binary(key) or is_atom(key), do: key
  defp normalize_metadata_key(key), do: inspect(key, printable_limit: 100)
  defp normalize_metadata_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_metadata_value(value) when is_map(value), do: normalize_metadata_map(value)

  defp normalize_metadata_value(value) when is_list(value),
    do: Enum.map(value, &normalize_metadata_value/1)

  defp normalize_metadata_value(nil), do: nil
  defp normalize_metadata_value(value) when is_boolean(value), do: value
  defp normalize_metadata_value(value) when is_binary(value), do: value
  defp normalize_metadata_value(value) when is_number(value), do: value
  defp normalize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_metadata_value(value), do: inspect(value, printable_limit: 100)

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp plan_comparison_map(%_{} = struct), do: struct |> Map.from_struct() |> normalize_keys()
  defp plan_comparison_map(map) when is_map(map), do: normalize_keys(map)

  defp fetch_any(map, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp mismatch?(expected, actual) do
    expected = comparable(expected)
    actual = comparable(actual)
    not is_nil(expected) and not is_nil(actual) and expected != actual
  end

  defp approval_hash(%__MODULE__{} = approval), do: approval.plan_hash || approval.content_hash

  defp current_plan_hash(current_plan, current) do
    fetch_any(current, [:plan_hash, :content_hash, :hash]) || compute_current_plan_hash(current_plan)
  end

  defp compute_current_plan_hash(%Muse.Plan{} = plan), do: Muse.PlanBinding.content_hash(plan)
  defp compute_current_plan_hash(_), do: nil

  defp comparable(nil), do: nil
  defp comparable(value) when is_binary(value), do: value
  defp comparable(value) when is_atom(value), do: Atom.to_string(value)
  defp comparable(value) when is_integer(value), do: Integer.to_string(value)
  defp comparable(value) when is_float(value), do: Float.to_string(value)
  defp comparable(value), do: inspect(value, printable_limit: 100)

  defp strip_raw_content(map) when is_map(map) do
    map
    |> Enum.reduce({%{}, []}, fn {key, value}, {acc, refs} ->
      if raw_content_key?(key) do
        {acc, refs ++ [content_ref(key, value)]}
      else
        {safe_value, nested_refs} = strip_raw_value(value)
        {Map.put(acc, key, safe_value), refs ++ nested_refs}
      end
    end)
  end

  defp strip_raw_value(value) when is_map(value) and not is_struct(value) do
    strip_raw_content(value)
  end

  defp strip_raw_value(value) when is_list(value) do
    {values, refs} =
      Enum.reduce(value, {[], []}, fn item, {items, refs} ->
        {safe_item, nested_refs} = strip_raw_value(item)
        {[safe_item | items], refs ++ nested_refs}
      end)

    {Enum.reverse(values), refs}
  end

  defp strip_raw_value(value) when is_tuple(value) do
    {values, refs} =
      value
      |> Tuple.to_list()
      |> Enum.reduce({[], []}, fn item, {items, refs} ->
        {safe_item, nested_refs} = strip_raw_value(item)
        {[safe_item | items], refs ++ nested_refs}
      end)

    {values |> Enum.reverse() |> List.to_tuple(), refs}
  end

  defp strip_raw_value(value), do: {value, []}

  defp raw_content_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace("-", "_")
    |> then(&(&1 in @raw_content_keys))
  end

  defp put_content_refs(payload, []), do: payload
  defp put_content_refs(payload, refs), do: Map.put(payload, :content_refs, refs)

  defp canonical_binary(content) do
    content
    |> normalize_for_hash()
    |> Jason.encode!()
  rescue
    _ -> inspect(content, limit: :infinity, printable_limit: :infinity)
  end

  defp normalize_for_hash(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_for_hash(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_for_hash(%Time{} = time), do: Time.to_iso8601(time)
  defp normalize_for_hash(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp normalize_for_hash(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, inspect(struct.__struct__))
    |> normalize_for_hash()
  end

  defp normalize_for_hash(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      [normalize_hash_key(key), normalize_for_hash(value)]
    end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp normalize_for_hash(list) when is_list(list) do
    Enum.map(list, &normalize_for_hash/1)
  end

  defp normalize_for_hash(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_for_hash/1)
  end

  defp normalize_for_hash(nil), do: nil
  defp normalize_for_hash(bool) when is_boolean(bool), do: bool
  defp normalize_for_hash(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_for_hash(binary) when is_binary(binary), do: binary
  defp normalize_for_hash(number) when is_number(number), do: number
  defp normalize_for_hash(pid) when is_pid(pid), do: inspect(pid)
  defp normalize_for_hash(ref) when is_reference(ref), do: inspect(ref)
  defp normalize_for_hash(fun) when is_function(fun), do: inspect(fun)
  defp normalize_for_hash(other), do: inspect(other, limit: :infinity, printable_limit: :infinity)

  defp normalize_hash_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_hash_key(key) when is_binary(key), do: key
  defp normalize_hash_key(key), do: inspect(key, printable_limit: 100)

  defp sha256(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp generate_id do
    "approval_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
