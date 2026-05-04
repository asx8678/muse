defmodule Muse.Approval do
  @moduledoc """
  Struct representing an approval record for a Muse Plan.

  Approval records capture who approved or rejected a plan, when, why,
  and any associated metadata. They are persisted as part of session
  snapshots and restored safely on restart.

  ## Construction

      iex> approval = Muse.Approval.new(plan_id: "plan_1", kind: :plan, status: :approved, source: :cli)
      iex> approval.status
      :approved
      iex> approval.kind
      :plan

  For deterministic tests, pass `id:` and `created_at:`:

      iex> approval = Muse.Approval.new(id: "appr_1", plan_id: "p1", kind: :plan,
      ...>   status: :approved, source: :system, created_at: ~U[2025-01-01 00:00:00Z])
      iex> approval.id
      "appr_1"

  ## JSON round-trip

  `to_map/1` and `from_map/1` provide safe serialization/deserialization.
  Atom values (status, kind, source) are converted to/from strings using
  explicit allowlists — no `String.to_atom` on arbitrary input.

      iex> map = Muse.Approval.to_map(approval)
      iex> restored = Muse.Approval.from_map(map)
      iex> restored.status == approval.status
      true
  """

  @enforce_keys [:id, :plan_id, :kind, :status, :source, :created_at]

  defstruct [
    :id,
    :plan_id,
    :kind,
    :status,
    :source,
    :reason,
    :metadata,
    :created_at
  ]

  @type kind :: :plan | :shell | :patch
  @type status :: :approved | :rejected
  @type source :: atom()

  @type t :: %__MODULE__{
          id: String.t(),
          plan_id: String.t(),
          kind: kind(),
          status: status(),
          source: source(),
          reason: String.t() | nil,
          metadata: map() | nil,
          created_at: DateTime.t()
        }

  # ── Allowlists for safe atom conversion ──────────────────────────────────

  @kinds [:plan, :shell, :patch]
  @statuses [:approved, :rejected]

  @kind_map %{
    "plan" => :plan,
    "shell" => :shell,
    "patch" => :patch
  }

  @status_map %{
    "approved" => :approved,
    "rejected" => :rejected
  }

  @doc """
  Return the canonical list of approval kinds.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Return the canonical list of approval statuses.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Check whether the given kind is valid.
  """
  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @doc """
  Check whether the given status is valid.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  # ── Construction ────────────────────────────────────────────────────────

  @doc """
  Create a new `%Muse.Approval{}` from a keyword list or map.

  ## Options

    * `:id`          — approval identifier (auto-generated if absent)
    * `:plan_id`     — **required** plan being approved/rejected
    * `:kind`        — **required** approval kind (`:plan`, `:shell`, `:patch`)
    * `:status`      — **required** `:approved` or `:rejected`
    * `:source`      — **required** who performed the action (`:cli`, `:web`, etc.)
    * `:reason`      — optional reason for the approval/rejection
    * `:metadata`    — optional bounded metadata map
    * `:created_at`  — override timestamp (for deterministic tests)
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)

    kind = normalize_kind(Map.get(normalized, :kind))
    status = normalize_status(Map.get(normalized, :status))
    source = normalize_source(Map.get(normalized, :source))

    %__MODULE__{
      id: Map.get(normalized, :id) || generate_id(),
      plan_id: to_string(Map.get(normalized, :plan_id, "")),
      kind: kind,
      status: status,
      source: source,
      reason: normalize_reason(Map.get(normalized, :reason)),
      metadata: normalize_metadata(Map.get(normalized, :metadata)),
      created_at: Map.get(normalized, :created_at, DateTime.utc_now())
    }
  end

  # ── Serialization ───────────────────────────────────────────────────────

  @doc """
  Convert an `%Muse.Approval{}` to a plain map suitable for JSON serialization.

  Atom values are converted to strings; `DateTime` values to ISO 8601.
  Nil values are dropped for compact JSON.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = approval) do
    approval
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), encode_value(v)} end)
  end

  @doc """
  Construct an `%Muse.Approval{}` from a plain map (e.g. decoded JSON).

  Uses safe atom conversion via allowlists — never creates dynamic atoms.
  Unknown kind/status values default to safe fallbacks.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    new(parse_created_at(map))
  end

  # Parse ISO 8601 created_at string into DateTime before passing to new/1.
  # If created_at is already a DateTime, keep it. If unparseable, remove it
  # so new/1 defaults to DateTime.utc_now().
  defp parse_created_at(map) do
    value = Map.get(map, "created_at") || Map.get(map, :created_at)

    case value do
      nil ->
        map

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} ->
            # Replace both string and atom keys with the parsed DateTime
            map
            |> Map.delete("created_at")
            |> Map.put(:created_at, dt)

          _ ->
            # Unparseable: remove so new/1 defaults to current time
            map
            |> Map.delete("created_at")
            |> Map.delete(:created_at)
        end

      %DateTime{} = dt ->
        map
        |> Map.delete("created_at")
        |> Map.put(:created_at, dt)

      _ ->
        map
        |> Map.delete("created_at")
        |> Map.delete(:created_at)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp generate_id do
    hex =
      :crypto.strong_rand_bytes(6)
      |> Base.encode16(case: :lower)

    "appr_#{hex}"
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  @known_keys MapSet.new([
                :id,
                :plan_id,
                :kind,
                :status,
                :source,
                :reason,
                :metadata,
                :created_at
              ])

  defp safe_atom(key) when is_binary(key) do
    if MapSet.member?(@known_keys, String.to_existing_atom(key)) do
      String.to_existing_atom(key)
    else
      key
    end
  rescue
    ArgumentError -> key
  end

  defp normalize_kind(kind) when kind in @kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    Map.get(@kind_map, kind, :plan)
  end

  defp normalize_kind(_), do: :plan

  defp normalize_status(status) when status in @statuses, do: status

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_map, status, :approved)
  end

  defp normalize_status(_), do: :approved

  # Source atoms are limited to small known values; we use
  # String.to_existing_atom for safety. If the atom doesn't exist yet
  # (shouldn't happen since :cli, :web, :system, :api are compiled elsewhere),
  # fall back to :system.
  defp normalize_source(source) when is_atom(source), do: source

  defp normalize_source(source) when is_binary(source) do
    try do
      String.to_existing_atom(source)
    rescue
      ArgumentError -> :system
    end
  end

  defp normalize_source(_), do: :system

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(other), do: to_string(other)

  defp normalize_metadata(nil), do: nil
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: nil

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value
end
