defmodule Muse.Approval do
  @moduledoc """
  First-class approval record for gated Muse actions.

  `:kind` is the canonical discriminator. `:type` is kept as a synchronized
  compatibility alias for older payloads and JSON APIs that use `type`.

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
    :workspace,
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
          workspace: String.t() | nil,
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
    "shell_command" => :shell_command,
    "network" => :network,
    "delete" => :delete,
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
    "hash" => :hash,
    "workspace" => :workspace,
    "requested_by" => :requested_by,
    "requestedBy" => :requested_by,
    "approved_by" => :approved_by,
    "approvedBy" => :approved_by,
    "rejected_by" => :rejected_by,
    "rejectedBy" => :rejected_by,
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
    "at" => :at
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

    %__MODULE__{
      id: normalize_id(Map.get(normalized, :id)) || generate_id(),
      session_id: normalize_optional_string(Map.get(normalized, :session_id)),
      kind: kind,
      type: kind,
      status: normalize_status(Map.get(normalized, :status), :pending),
      scope: normalize_scope(Map.get(normalized, :scope)),
      plan_id: normalize_optional_string(Map.get(normalized, :plan_id)),
      plan_version:
        normalize_plan_version(Map.get(normalized, :plan_version, Map.get(normalized, :version))),
      plan_hash:
        normalize_optional_string(Map.get(normalized, :plan_hash, Map.get(normalized, :hash))),
      workspace: normalize_optional_string(Map.get(normalized, :workspace)),
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
          |> canonicalize_discriminator()
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

  The comparison is conservative: a field only participates when both the
  approval and the current plan provide a comparable value.
  """
  @spec stale?(t(), map() | struct() | nil) :: boolean()
  def stale?(%__MODULE__{status: :stale}, _current_plan), do: true
  def stale?(%__MODULE__{}, nil), do: false

  def stale?(%__MODULE__{} = approval, current_plan) when is_map(current_plan) do
    current = plan_comparison_map(current_plan)

    mismatch?(approval.plan_id, fetch_any(current, [:plan_id, :id])) ||
      mismatch?(approval.plan_version, fetch_any(current, [:plan_version, :version])) ||
      mismatch?(approval.plan_hash, fetch_any(current, [:plan_hash, :hash]))
  end

  def stale?(%__MODULE__{}, _current_plan), do: false

  @doc """
  Convert an approval to a plain map suitable for JSON serialization.

  `:kind` and `:type` are both emitted and synchronized. Metadata is sanitized
  again at the boundary. Nil optional fields are omitted.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = approval) do
    approval
    |> canonicalize_discriminator()
    |> Map.from_struct()
    |> Map.update!(:metadata, &normalize_metadata/1)
    |> drop_nil_values()
  end

  @doc "Construct an approval from a plain map, such as decoded JSON."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

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
      datetime_from_attrs(opts, :at) || datetime_from_attrs(opts, :approved_at) ||
        DateTime.utc_now()

  defp transition_time(opts, :rejected),
    do:
      datetime_from_attrs(opts, :at) || datetime_from_attrs(opts, :rejected_at) ||
        DateTime.utc_now()

  defp transition_time(opts, _status), do: datetime_from_attrs(opts, :at) || DateTime.utc_now()

  defp canonicalize_discriminator(%__MODULE__{} = approval) do
    kind = normalize_kind(%{kind: approval.kind, type: approval.type})
    %{approval | kind: kind, type: kind}
  end

  defp apply_common_transition_fields(%__MODULE__{} = approval, opts) do
    approval
    |> maybe_put_optional_string(:reason, Map.get(opts, :reason))
    |> maybe_merge_metadata(Map.get(opts, :metadata))
  end

  defp apply_status_transition_fields(%__MODULE__{} = approval, :approved, opts, now) do
    %{
      approval
      | approved_at: datetime_from_attrs(opts, :approved_at, now),
        approved_by:
          normalize_optional_string(Map.get(opts, :approved_by)) || approval.approved_by
    }
  end

  defp apply_status_transition_fields(%__MODULE__{} = approval, :rejected, opts, now) do
    %{
      approval
      | rejected_at: datetime_from_attrs(opts, :rejected_at, now),
        rejected_by:
          normalize_optional_string(Map.get(opts, :rejected_by)) || approval.rejected_by,
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
  defp normalize_metadata_value(value) when is_map(value), do: normalize_metadata_map(value)

  defp normalize_metadata_value(value) when is_list(value),
    do: Enum.map(value, &normalize_metadata_value/1)

  defp normalize_metadata_value(nil), do: nil
  defp normalize_metadata_value(value) when is_boolean(value), do: value
  defp normalize_metadata_value(value) when is_binary(value), do: value
  defp normalize_metadata_value(value) when is_number(value), do: value
  defp normalize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_metadata_value(value), do: inspect(value, printable_limit: 100)

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

  defp comparable(nil), do: nil
  defp comparable(value) when is_binary(value), do: value
  defp comparable(value) when is_atom(value), do: Atom.to_string(value)
  defp comparable(value) when is_integer(value), do: Integer.to_string(value)
  defp comparable(value) when is_float(value), do: Float.to_string(value)
  defp comparable(value), do: inspect(value, printable_limit: 100)

  defp generate_id do
    "approval_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
