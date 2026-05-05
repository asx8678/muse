defmodule Muse.Reports.ReviewReportTest do
  use ExUnit.Case, async: true

  alias Muse.Reports.ReviewReport

  describe "new/1" do
    test "creates a review report with defaults" do
      report = ReviewReport.new(decision: :approve)
      assert report.decision == :approve
      assert report.confidence == :medium
      assert report.findings == []
      assert report.validation_gaps == []
    end

    test "creates a review report with findings" do
      findings = [
        %{
          severity: :high,
          issue: "SQL injection risk",
          evidence: "unparameterized query",
          recommendation: "use parameterized queries"
        },
        %{
          severity: :low,
          issue: "Missing docs",
          evidence: "no @moduledoc",
          recommendation: "add module documentation"
        }
      ]

      report = ReviewReport.new(decision: :revise, confidence: :high, findings: findings)
      assert report.decision == :revise
      assert report.confidence == :high
      assert length(report.findings) == 2
    end

    test "creates a review report with validation gaps" do
      gaps = [%{gap: "no integration tests", suggested_validation: "add integration test suite"}]
      report = ReviewReport.new(decision: :revise, validation_gaps: gaps)
      assert length(report.validation_gaps) == 1
    end

    test "accepts string decision values" do
      report = ReviewReport.new(decision: "approve")
      assert report.decision == :approve
    end

    test "defaults to :revise for invalid decision" do
      report = ReviewReport.new(decision: :maybe)
      assert report.decision == :revise
    end

    test "caps findings at maximum" do
      many_findings =
        for i <- 1..30 do
          %{severity: :info, issue: "issue #{i}", evidence: "evidence", recommendation: "fix it"}
        end

      report = ReviewReport.new(decision: :reject, findings: many_findings)
      assert length(report.findings) <= 20
    end

    test "caps string fields at reasonable lengths" do
      long_string = String.duplicate("x", 10_000)

      report =
        ReviewReport.new(
          decision: :reject,
          findings: [
            %{
              severity: :high,
              issue: long_string,
              evidence: long_string,
              recommendation: long_string
            }
          ]
        )

      finding = hd(report.findings)
      # 500 + "..."
      assert byte_size(finding.issue) <= 503
      assert byte_size(finding.evidence) <= 503
      assert byte_size(finding.recommendation) <= 503
    end

    test "includes final_recommendation" do
      report =
        ReviewReport.new(decision: :approve, final_recommendation: "Ship it — all checks pass")

      assert report.final_recommendation == "Ship it — all checks pass"
    end
  end

  describe "render/1" do
    test "renders an approve report" do
      report =
        ReviewReport.new(decision: :approve, confidence: :high, final_recommendation: "All clear")

      rendered = ReviewReport.render(report)
      assert rendered =~ "REVIEW SUMMARY"
      assert rendered =~ "approve"
      assert rendered =~ "high"
      assert rendered =~ "All clear"
    end

    test "renders a revise report with findings" do
      report =
        ReviewReport.new(
          decision: :revise,
          confidence: :medium,
          findings: [
            %{severity: :high, issue: "bug", evidence: "stack trace", recommendation: "fix bug"}
          ]
        )

      rendered = ReviewReport.render(report)
      assert rendered =~ "revise"
      assert rendered =~ "FINDINGS"
      assert rendered =~ "bug"
    end

    test "renders a reject report with validation gaps" do
      report =
        ReviewReport.new(
          decision: :reject,
          validation_gaps: [%{gap: "no tests", suggested_validation: "add unit tests"}]
        )

      rendered = ReviewReport.render(report)
      assert rendered =~ "reject"
      assert rendered =~ "VALIDATION GAPS"
      assert rendered =~ "no tests"
    end
  end

  describe "to_summary/1" do
    test "returns safe summary map" do
      report =
        ReviewReport.new(
          decision: :revise,
          confidence: :medium,
          findings: [%{severity: :high, issue: "bug", evidence: "e", recommendation: "r"}],
          final_recommendation: "fix the bug"
        )

      summary = ReviewReport.to_summary(report)
      assert is_map(summary)
      assert summary.decision == :revise
      assert summary.confidence == :medium
      assert summary.finding_count == 1
      assert summary.gap_count == 0
      assert summary.final_recommendation == "fix the bug"
    end

    test "summary never contains raw evidence" do
      report =
        ReviewReport.new(
          decision: :revise,
          findings: [
            %{
              severity: :high,
              issue: "secret leak",
              evidence: "API key sk-12345 exposed",
              recommendation: "redact"
            }
          ]
        )

      summary = ReviewReport.to_summary(report)
      refute Map.has_key?(summary, :findings)
      refute Map.has_key?(summary, :evidence)
    end
  end
end
