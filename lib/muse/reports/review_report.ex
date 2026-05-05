defmodule Muse.Reports.ReviewReport do
  @moduledoc """
  Structured review report for Reviewing Muse output.

  Reviewing Muse inspects diffs and project context, then reports
  findings and recommendations. This struct normalizes the review
  output into a deterministic, capped, and redacted report.

  ## Fields

    * `:decision`        — `:approve`, `:revise`, or `:reject`
    * `:confidence`      — `:high`, `:medium`, or `:low`
    * `:findings`        — list of finding maps (severity, issue, evidence, recommendation)
    * `:validation_gaps` — list of gap maps (gap, suggested_validation)
    * `:final_recommendation` — one-sentence reasoning

  ## Capping

  All string fields are capped. Raw diff content is never stored
  verbatim in findings — only summaries and evidence excerpts.
  """

  @max_string_len 500
  @max_findings 20
  @max_gaps 10

  @enforce_keys [:decision]

  defstruct [
    :decision,
    confidence: :medium,
    findings: [],
    validation_gaps: [],
    final_recommendation: nil
  ]

  @type decision :: :approve | :revise | :reject
  @type confidence :: :high | :medium | :low
  @type severity :: :critical | :high | :medium | :low | :info

  @type finding :: %{
          severity: severity(),
          issue: String.t(),
          evidence: String.t(),
          recommendation: String.t()
        }

  @type gap :: %{
          gap: String.t(),
          suggested_validation: String.t()
        }

  @type t :: %__MODULE__{
          decision: decision(),
          confidence: confidence(),
          findings: [finding()],
          validation_gaps: [gap()],
          final_recommendation: String.t() | nil
        }

  @doc """
  Create a new review report with validation.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    decision = Keyword.get(opts, :decision, :revise)
    confidence = Keyword.get(opts, :confidence, :medium)
    findings = Keyword.get(opts, :findings, []) |> cap_findings()
    gaps = Keyword.get(opts, :validation_gaps, []) |> cap_gaps()
    recommendation = Keyword.get(opts, :final_recommendation) |> cap_string(@max_string_len)

    %__MODULE__{
      decision: validate_decision(decision),
      confidence: validate_confidence(confidence),
      findings: findings,
      validation_gaps: gaps,
      final_recommendation: recommendation
    }
  end

  @doc """
  Render the report as a human-readable string.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = report) do
    lines = [
      "REVIEW SUMMARY",
      "- Decision: #{report.decision}",
      "- Confidence: #{report.confidence}"
    ]

    lines =
      case report.findings do
        [] ->
          lines ++ ["FINDINGS: none"]

        findings ->
          lines ++
            ["FINDINGS"] ++
            Enum.map(findings, fn f ->
              "  - [#{f[:severity] || f["severity"]}] #{f[:issue] || f["issue"]}" <>
                "\n    Evidence: #{cap_string(f[:evidence] || f["evidence"] || "none", 200)}" <>
                "\n    Recommendation: #{cap_string(f[:recommendation] || f["recommendation"] || "none", 200)}"
            end)
      end

    lines =
      case report.validation_gaps do
        [] ->
          lines ++ ["VALIDATION GAPS: none"]

        gaps ->
          lines ++
            ["VALIDATION GAPS"] ++
            Enum.map(gaps, fn g ->
              "  - Gap: #{cap_string(g[:gap] || g["gap"] || "unspecified", 200)}" <>
                "\n    Suggested validation: #{cap_string(g[:suggested_validation] || g["suggested_validation"] || "unspecified", 200)}"
            end)
      end

    lines =
      if report.final_recommendation do
        lines ++ ["FINAL RECOMMENDATION", report.final_recommendation]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Convert to a safe summary map for event emission.
  """
  @spec to_summary(t()) :: map()
  def to_summary(%__MODULE__{} = report) do
    %{
      decision: report.decision,
      confidence: report.confidence,
      finding_count: length(report.findings),
      gap_count: length(report.validation_gaps),
      final_recommendation: report.final_recommendation
    }
  end

  # -- Private ------------------------------------------------------------------

  defp validate_decision(d) when d in [:approve, :revise, :reject], do: d
  defp validate_decision("approve"), do: :approve
  defp validate_decision("revise"), do: :revise
  defp validate_decision("reject"), do: :reject
  defp validate_decision(_), do: :revise

  defp validate_confidence(c) when c in [:high, :medium, :low], do: c
  defp validate_confidence("high"), do: :high
  defp validate_confidence("medium"), do: :medium
  defp validate_confidence("low"), do: :low
  defp validate_confidence(_), do: :medium

  defp cap_findings(findings) when is_list(findings) do
    findings
    |> Enum.take(@max_findings)
    |> Enum.map(&cap_finding/1)
  end

  defp cap_findings(_), do: []

  defp cap_finding(%{} = f) do
    %{
      severity: validate_severity(f[:severity] || f["severity"]),
      issue: cap_string(f[:issue] || f["issue"], @max_string_len),
      evidence: cap_string(f[:evidence] || f["evidence"], @max_string_len),
      recommendation: cap_string(f[:recommendation] || f["recommendation"], @max_string_len)
    }
  end

  defp cap_finding(other),
    do: %{
      severity: :info,
      issue: cap_string(inspect(other), @max_string_len),
      evidence: "",
      recommendation: ""
    }

  defp validate_severity(s) when s in [:critical, :high, :medium, :low, :info], do: s
  defp validate_severity("critical"), do: :critical
  defp validate_severity("high"), do: :high
  defp validate_severity("medium"), do: :medium
  defp validate_severity("low"), do: :low
  defp validate_severity("info"), do: :info
  defp validate_severity(_), do: :info

  defp cap_gaps(gaps) when is_list(gaps) do
    gaps
    |> Enum.take(@max_gaps)
    |> Enum.map(&cap_gap/1)
  end

  defp cap_gaps(_), do: []

  defp cap_gap(%{} = g) do
    %{
      gap: cap_string(g[:gap] || g["gap"], @max_string_len),
      suggested_validation:
        cap_string(g[:suggested_validation] || g["suggested_validation"], @max_string_len)
    }
  end

  defp cap_gap(other),
    do: %{gap: cap_string(inspect(other), @max_string_len), suggested_validation: ""}

  defp cap_string(nil, _max), do: nil

  defp cap_string(s, max) when is_binary(s) and byte_size(s) > max do
    String.slice(s, 0, max) <> "..."
  end

  defp cap_string(s, _max) when is_binary(s), do: s

  defp cap_string(s, max),
    do: s |> inspect(limit: 10, printable_limit: max) |> String.slice(0, max)
end
