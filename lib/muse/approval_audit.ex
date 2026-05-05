defmodule Muse.ApprovalAudit do
  @moduledoc """
  Read-only helpers for rendering plan approval/rejection audit details.

  This module intentionally does not depend on a `Muse.Approval` struct. PR09
  integration work may add one later; for now these helpers tolerate plain maps,
  future structs converted with `Map.from_struct/1`, and missing records.
  """

  alias Muse.Plan

  @approval_missing "not available (no approval id/hash found)."
  @rejection_missing "not available (no rejection id/hash found)."

  @doc """
  Renders the `/approve plan` result.

  The message is deliberately explicit that approval is only a recorded decision
  and never starts Coding Muse execution, shell commands, file writes, or patch
  application.
  """
  @spec approval_message(Plan.t()) :: String.t()
  def approval_message(%Plan{} = plan) do
    [
      "Plan approved.",
      "",
      "- Plan id: #{display_plan_id(plan)}",
      "- Version: #{plan.version}",
      "- Approval status: approved",
      "- Approval record: #{record_summary(plan, :approval) || @approval_missing}",
      "- No implementation started: approval recorded the plan only; no Coding Muse turn, shell command, file write, or patch application was started."
    ]
    |> Enum.join("\n")
  end

  @doc """
  Renders the `/reject plan` result with revision guidance.
  """
  @spec rejection_message(Plan.t()) :: String.t()
  def rejection_message(%Plan{} = plan) do
    [
      "Plan rejected.",
      "",
      "- Plan id: #{display_plan_id(plan)}",
      "- Version: #{plan.version}",
      "- Rejection status: rejected",
      "- Rejection record: #{record_summary(plan, :rejection) || @rejection_missing}",
      "- No implementation started: rejection recorded the decision only; no Coding Muse turn, shell command, file write, or patch application was started.",
      "- Next: ask Planning Muse for a revised plan before approving implementation."
    ]
    |> Enum.join("\n")
  end

  @doc """
  Returns `/plan status` audit lines for the plan approval lifecycle.
  """
  @spec status_lines(Plan.t()) :: [String.t()]
  def status_lines(%Plan{} = plan) do
    [
      "- Approval status: #{approval_status(plan)}",
      status_record_line(plan)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp status_record_line(%Plan{status: :rejected} = plan) do
    "- Rejection record: #{record_summary(plan, :rejection) || @rejection_missing}"
  end

  defp status_record_line(%Plan{} = plan) do
    case record_summary(plan, :approval) do
      nil -> "- Approval record: #{@approval_missing}"
      summary -> "- Approval record: #{summary}"
    end
  end

  defp approval_status(%Plan{status: :awaiting_approval}), do: "awaiting approval"
  defp approval_status(%Plan{status: nil}), do: "unknown"
  defp approval_status(%Plan{status: status}), do: safe_to_string(status)

  defp record_summary(%Plan{} = plan, decision) do
    plan
    |> find_record(decision)
    |> summarize_record(decision)
  end

  defp find_record(%Plan{} = plan, decision) do
    find_matching_record(records_from(plan.approvals), decision) ||
      find_matching_record(metadata_records(plan.metadata, decision), decision)
  end

  defp find_matching_record(records, decision) do
    records
    |> Enum.reverse()
    |> Enum.find(&record_matches?(&1, decision))
  end

  defp metadata_records(metadata, :approval) do
    metadata
    |> metadata_values([:approval, :approval_record, :approval_audit, :approvals])
    |> Enum.flat_map(&records_from/1)
  end

  defp metadata_records(metadata, :rejection) do
    metadata
    |> metadata_values([:rejection, :rejection_record, :rejection_audit, :rejections])
    |> Enum.flat_map(&records_from/1)
  end

  defp metadata_values(metadata, keys) when is_map(metadata) do
    Enum.map(keys, fn key -> map_get_any(metadata, [key, Atom.to_string(key)]) end)
  end

  defp metadata_values(_metadata, _keys), do: []

  defp records_from(nil), do: []

  defp records_from(records) when is_list(records) do
    Enum.flat_map(records, &records_from/1)
  end

  defp records_from(%{__struct__: _} = record), do: [Map.from_struct(record)]
  defp records_from(record) when is_map(record), do: [record]
  defp records_from(_record), do: []

  defp record_matches?(record, decision) when is_map(record) do
    classifier =
      record
      |> map_get_any([
        :decision,
        "decision",
        :action,
        "action",
        :status,
        "status",
        :kind,
        "kind",
        :type,
        "type"
      ])
      |> normalize_classifier()

    cond do
      classifier && classifier_matches?(classifier, decision) -> true
      classifier -> false
      has_decision_key?(record, decision) -> true
      audit_identity?(record) -> true
      true -> false
    end
  end

  defp record_matches?(_record, _decision), do: false

  defp classifier_matches?(classifier, :approval) do
    String.contains?(classifier, "approv") or classifier in ["accepted", "accept"]
  end

  defp classifier_matches?(classifier, :rejection) do
    String.contains?(classifier, "reject") or classifier in ["rejected", "denied", "deny"]
  end

  defp has_decision_key?(record, :approval) do
    record_value(record, [:approval_id, "approval_id", :approval_hash, "approval_hash"]) != nil
  end

  defp has_decision_key?(record, :rejection) do
    record_value(record, [:rejection_id, "rejection_id", :rejection_hash, "rejection_hash"]) !=
      nil
  end

  defp audit_identity?(record) do
    record_value(record, [:id, "id", :record_id, "record_id", :hash, "hash"]) != nil
  end

  defp summarize_record(nil, _decision), do: nil

  defp summarize_record(record, decision) when is_map(record) do
    id = record_id(record, decision)
    hash = record_hash(record, decision)

    case {id, hash} do
      {nil, nil} -> "present, but no id/hash found."
      {id, nil} -> "id=#{id}"
      {nil, hash} -> "hash=#{hash}"
      {id, hash} -> "id=#{id}, hash=#{hash}"
    end
  end

  defp record_id(record, :approval) do
    record_value(record, [
      :approval_id,
      "approval_id",
      :id,
      "id",
      :record_id,
      "record_id",
      :uuid,
      "uuid"
    ])
  end

  defp record_id(record, :rejection) do
    record_value(record, [
      :rejection_id,
      "rejection_id",
      :id,
      "id",
      :record_id,
      "record_id",
      :uuid,
      "uuid"
    ])
  end

  defp record_hash(record, :approval) do
    record_value(record, [
      :approval_hash,
      "approval_hash",
      :hash,
      "hash",
      :content_hash,
      "content_hash",
      :plan_hash,
      "plan_hash",
      :audit_hash,
      "audit_hash",
      :digest,
      "digest"
    ])
  end

  defp record_hash(record, :rejection) do
    record_value(record, [
      :rejection_hash,
      "rejection_hash",
      :hash,
      "hash",
      :content_hash,
      "content_hash",
      :plan_hash,
      "plan_hash",
      :audit_hash,
      "audit_hash",
      :digest,
      "digest"
    ])
  end

  defp record_value(record, keys) do
    record
    |> map_get_any(keys)
    |> normalize_value()
  end

  defp normalize_classifier(nil), do: nil

  defp normalize_classifier(value) do
    value
    |> safe_to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      classifier -> classifier
    end
  end

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_value(value) when is_float(value), do: Float.to_string(value)
  defp normalize_value(_value), do: nil

  defp display_plan_id(%Plan{id: nil}), do: "(no id)"
  defp display_plan_id(%Plan{id: id}), do: safe_to_string(id)

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp map_get_any(_map, _keys), do: nil

  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value), do: inspect(value)
end
