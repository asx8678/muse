defmodule Muse.Approval do
  @moduledoc """
  Explicit approval record used by approval gates.

  Approval records are intentionally data-only: they bind a user decision to a
  concrete session/resource identity and can be serialized into session
  snapshots.  PR09 currently uses `:plan` approvals; later patch/shell/network
  gates can reuse the same struct with additional binding fields.
  """

  @enforce_keys [:id, :session_id, :kind, :scope, :status, :created_at]

  defstruct [
    :id,
    :type,
    :kind,
    :status,
    :session_id,
    :plan_id,
    :plan_version,
    :content_hash,
    :task_id,
    :patch_id,
    :patch_hash,
    :tool_call_id,
    :workspace,
    :scope,
    :requested_by,
    :approved_by,
    :rejected_by,
    :created_at,
    :approved_at,
    :rejected_at,
    :reason,
    :expires_at,
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
          | atom()

  @type status :: :pending | :approved | :rejected | :expired | :superseded

  @type t :: %__MODULE__{
          id: String.t(),
          type: kind() | nil,
          kind: kind(),
          status: status(),
          session_id: String.t(),
          plan_id: String.t() | nil,
          plan_version: non_neg_integer() | nil,
          content_hash: String.t() | nil,
          task_id: String.t() | nil,
          patch_id: String.t() | nil,
          patch_hash: String.t() | nil,
          tool_call_id: String.t() | nil,
          workspace: String.t() | nil,
          scope: atom() | String.t() | map(),
          requested_by: String.t() | nil,
          approved_by: String.t() | nil,
          rejected_by: String.t() | nil,
          created_at: DateTime.t(),
          approved_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          reason: String.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: map()
        }

  @statuses [:pending, :approved, :rejected, :expired, :superseded]

  @doc "Returns the canonical approval statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Checks whether an approval status is valid."
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc """
  Builds a new approval record from atom or string keyed attributes.

  Missing `:id` values are generated locally.  This keeps legacy snapshots and
  tests ergonomic while still making persisted approvals auditable.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)
    now = DateTime.utc_now()
    kind = normalize_kind(Map.get(normalized, :kind, Map.get(normalized, :type, :plan)))
    status = normalize_status(Map.get(normalized, :status, :pending))
    created_at = normalize_datetime(Map.get(normalized, :created_at)) || now

    %__MODULE__{
      id: Map.get(normalized, :id) || generated_id(kind),
      type: normalize_optional_kind(Map.get(normalized, :type)),
      kind: kind,
      status: if(valid_status?(status), do: status, else: :pending),
      session_id: normalize_string(Map.get(normalized, :session_id, "")),
      plan_id: normalize_string_or_nil(Map.get(normalized, :plan_id)),
      plan_version: normalize_non_neg_integer(Map.get(normalized, :plan_version)),
      content_hash: normalize_string_or_nil(Map.get(normalized, :content_hash)),
      task_id: normalize_string_or_nil(Map.get(normalized, :task_id)),
      patch_id: normalize_string_or_nil(Map.get(normalized, :patch_id)),
      patch_hash: normalize_string_or_nil(Map.get(normalized, :patch_hash)),
      tool_call_id: normalize_string_or_nil(Map.get(normalized, :tool_call_id)),
      workspace: normalize_string_or_nil(Map.get(normalized, :workspace)),
      scope: Map.get(normalized, :scope, kind),
      requested_by: normalize_actor(Map.get(normalized, :requested_by)),
      approved_by: normalize_actor(Map.get(normalized, :approved_by)),
      rejected_by: normalize_actor(Map.get(normalized, :rejected_by)),
      created_at: created_at,
      approved_at: normalize_datetime(Map.get(normalized, :approved_at)),
      rejected_at: normalize_datetime(Map.get(normalized, :rejected_at)),
      reason: normalize_string_or_nil(Map.get(normalized, :reason)),
      expires_at: normalize_datetime(Map.get(normalized, :expires_at)),
      metadata: normalize_metadata(Map.get(normalized, :metadata, %{}))
    }
  end

  @doc """
  Transitions an approval to a terminal or lifecycle status.

  `:approved` sets `approved_at` and optionally `approved_by`.
  `:rejected` sets `rejected_at`, optionally `rejected_by`, and preserves a
  bounded safe reason if supplied.
  """
  @spec transition(t(), status(), keyword()) :: {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = approval, new_status, opts \\ []) do
    if valid_status?(new_status) do
      now = Keyword.get(opts, :decided_at, DateTime.utc_now())

      approval = %{approval | status: new_status}
      {:ok, apply_status_fields(approval, new_status, now, opts)}
    else
      {:error, {:invalid_status, new_status}}
    end
  end

  @doc "Converts an approval to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = approval) do
    approval
    |> Map.from_struct()
    |> Map.update!(:metadata, &normalize_metadata/1)
    |> drop_nil_values()
  end

  @doc "Restores an approval from a decoded map."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  @doc "Normalizes a list of approval maps/structs and drops invalid entries."
  @spec normalize_list(term()) :: [t()]
  def normalize_list(values) when is_list(values) do
    Enum.flat_map(values, fn
      %__MODULE__{} = approval -> [approval]
      attrs when is_map(attrs) -> [from_map(attrs)]
      _other -> []
    end)
  rescue
    _ -> []
  end

  def normalize_list(_values), do: []

  # -- Private -----------------------------------------------------------------

  defp apply_status_fields(approval, :approved, now, opts) do
    %{
      approval
      | approved_at: Keyword.get(opts, :approved_at, now),
        approved_by: normalize_actor(Keyword.get(opts, :approved_by, Keyword.get(opts, :actor)))
    }
  end

  defp apply_status_fields(approval, :rejected, now, opts) do
    reason = Keyword.get(opts, :reason, approval.reason)

    %{
      approval
      | rejected_at: Keyword.get(opts, :rejected_at, now),
        rejected_by: normalize_actor(Keyword.get(opts, :rejected_by, Keyword.get(opts, :actor))),
        reason: normalize_string_or_nil(reason)
    }
  end

  defp apply_status_fields(approval, _status, _now, _opts), do: approval

  @status_map %{
    "pending" => :pending,
    "approved" => :approved,
    "rejected" => :rejected,
    "expired" => :expired,
    "superseded" => :superseded
  }

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_map, status, :pending)
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_status), do: :pending

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

  defp normalize_kind(kind) when is_binary(kind) do
    Map.get(@kind_map, String.trim(kind), :plan)
  end

  defp normalize_kind(kind) when is_atom(kind), do: kind
  defp normalize_kind(_kind), do: :plan

  defp normalize_optional_kind(nil), do: nil
  defp normalize_optional_kind(kind), do: normalize_kind(kind)

  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

  defp normalize_string_or_nil(nil), do: nil

  defp normalize_string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp normalize_string_or_nil(value) when is_atom(value) and value not in [nil, true, false] do
    Atom.to_string(value)
  end

  defp normalize_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string_or_nil(_value), do: nil

  defp normalize_actor(value), do: normalize_string_or_nil(value)

  defp normalize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(value) when is_integer(value), do: 0

  defp normalize_non_neg_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp normalize_non_neg_integer(_value), do: nil

  defp normalize_datetime(%DateTime{} = datetime), do: datetime
  defp normalize_datetime(nil), do: nil

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

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

  @known_keys MapSet.new([
                :id,
                :type,
                :kind,
                :status,
                :session_id,
                :plan_id,
                :plan_version,
                :content_hash,
                :task_id,
                :patch_id,
                :patch_hash,
                :tool_call_id,
                :workspace,
                :scope,
                :requested_by,
                :approved_by,
                :rejected_by,
                :created_at,
                :approved_at,
                :rejected_at,
                :reason,
                :expires_at,
                :metadata
              ])

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {safe_atom(key), value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  end

  defp safe_atom(key) when is_binary(key) do
    atom = String.to_existing_atom(key)

    if MapSet.member?(@known_keys, atom), do: atom, else: key
  rescue
    ArgumentError -> key
  end

  defp generated_id(kind) do
    suffix =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)

    "approval_#{normalize_string(kind)}_#{suffix}"
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
