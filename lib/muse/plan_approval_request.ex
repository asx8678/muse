defmodule Muse.PlanApprovalRequest do
  @moduledoc """
  Helper for plan approval-request metadata.

  This intentionally stays as a small map-based helper so the approval-gate
  integration can later map the data to `Muse.Approval` without changing the
  Planning Muse finalization path.
  """

  alias Muse.Plan

  @kind "plan"
  @status "pending"
  @hash_algorithm "sha256"
  @hash_short_length 12

  @hash_ignored_plan_keys [
    :status,
    :created_at,
    :updated_at,
    :approved_at,
    :rejected_at,
    :completed_at,
    :approvals,
    :metadata
  ]

  @request_keys [
    :kind,
    :status,
    :plan_id,
    :version,
    :content_hash,
    :content_hash_algorithm,
    :content_hash_short
  ]

  @doc """
  Build safe approval-request metadata for a finalized plan.

  The content hash binds the reviewable plan payload while excluding mutable
  lifecycle timestamps/status and approval metadata to avoid recursive hashes.
  """
  @spec build(Plan.t()) :: map()
  def build(%Plan{} = plan) do
    content_hash = content_hash(plan)

    %{
      kind: @kind,
      status: @status,
      plan_id: plan.id,
      version: plan.version,
      content_hash: content_hash,
      content_hash_algorithm: @hash_algorithm,
      content_hash_short: short_content_hash(content_hash)
    }
  end

  @doc """
  Attach approval-request metadata to `plan.metadata` and return both values.
  """
  @spec attach(Plan.t()) :: {Plan.t(), map()}
  def attach(%Plan{} = plan) do
    request = build(plan)
    metadata = Map.put(plan.metadata || %{}, :approval_request, request)

    {%{plan | metadata: metadata}, request}
  end

  @doc """
  Fetch approval-request metadata from a plan, accepting atom or string keys.
  """
  @spec get(Plan.t()) :: map() | nil
  def get(%Plan{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :approval_request) || Map.get(metadata, "approval_request") do
      request when is_map(request) -> normalize_request(request)
      _other -> nil
    end
  end

  def get(%Plan{}), do: nil

  @doc """
  Render a concise approval binding for user review.

  This deliberately avoids raw JSON while exposing enough data for a user or
  audit trail to bind an approval to a specific plan revision and content hash.
  """
  @spec render_binding(Plan.t(), map() | nil) :: String.t() | nil
  def render_binding(%Plan{} = plan, request \\ nil) do
    request = request || get(plan) || %{}
    plan_id = value(request, :plan_id) || plan.id
    version = value(request, :version) || plan.version
    kind = value(request, :kind) || @kind
    status = value(request, :status) || @status

    hash_short =
      value(request, :content_hash_short) ||
        (value(request, :content_hash) && short_content_hash(value(request, :content_hash)))

    if present?(plan_id) and not is_nil(version) and present?(hash_short) do
      "Approval binding:\n" <>
        "- Approval: #{kind} #{status}\n" <>
        "- Plan id: #{plan_id}\n" <>
        "- Version: #{version}\n" <>
        "- Content hash: #{@hash_algorithm}:#{hash_short}"
    else
      nil
    end
  end

  @doc """
  Compute the full SHA-256 content hash for the reviewable plan payload.
  """
  @spec content_hash(Plan.t()) :: String.t()
  def content_hash(%Plan{} = plan) do
    plan
    |> Plan.to_map()
    |> Map.drop(@hash_ignored_plan_keys)
    |> canonical_encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Return the short display form of a full content hash.
  """
  @spec short_content_hash(String.t()) :: String.t()
  def short_content_hash(hash) when is_binary(hash) do
    String.slice(hash, 0, @hash_short_length)
  end

  defp normalize_request(request) do
    Enum.reduce(@request_keys, %{}, fn key, acc ->
      case value(request, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp canonical_encode(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_iso8601()
    |> Jason.encode!()
  end

  defp canonical_encode(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> canonical_encode()
  end

  defp canonical_encode(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {canonical_key(key), canonical_encode(value)} end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, encoded_value} -> Jason.encode!(key) <> ":" <> encoded_value end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_encode/1) <> "]"
  end

  defp canonical_encode(nil), do: "null"

  defp canonical_encode(value) when is_boolean(value) or is_number(value) or is_binary(value) do
    Jason.encode!(value)
  end

  defp canonical_encode(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> Jason.encode!()
  end

  defp canonical_encode(value) do
    value
    |> inspect(limit: 10, printable_limit: 500)
    |> Jason.encode!()
  end

  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key), do: inspect(key, limit: 5, printable_limit: 100)
end
