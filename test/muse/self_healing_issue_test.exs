defmodule Muse.SelfHealingIssueTest do
  use ExUnit.Case, async: true

  alias Muse.{Diagnostic, SelfHealingIssue}

  describe "from_diagnostic/1" do
    test "creates an issue from a diagnostic" do
      diagnostic = Diagnostic.new(:warning, "test warning", %{source: :test})
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.id > 0
      assert issue.diagnostic_id == diagnostic.id
      assert issue.status == :queued
      assert issue.level == :warning
      assert issue.message == "test warning"
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "extracts source from diagnostic metadata with atom key" do
      diagnostic = Diagnostic.new(:error, "backend error", %{source: :dev_reloader})
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.source == :dev_reloader
    end

    test "extracts source from diagnostic metadata with string key" do
      diagnostic = Diagnostic.new(:error, "string source", %{"source" => "web_handler"})
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.source == "web_handler"
    end

    test "prefers atom key over string key for source" do
      metadata = Map.put(%{"source" => "string_source"}, :source, :atom_source)
      diagnostic = Diagnostic.new(:error, "both keys", metadata)
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.source == :atom_source
    end

    test "handles diagnostic without source in metadata" do
      diagnostic = Diagnostic.new(:critical, "critical issue", %{file: "test.ex"})
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.source == nil
    end

    test "normalizes :warn level from diagnostic" do
      diagnostic = Diagnostic.new(:warn, "deprecated")
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.level == :warning
    end

    test "truncates long messages" do
      long = String.duplicate("x", 2_100)
      diagnostic = Diagnostic.new(:error, long)
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert String.length(issue.message) <= 2_000
    end

    test "preserves map metadata as-is" do
      diagnostic =
        Diagnostic.new(:warning, "meta test", %{file: "lib/muse.ex", line: 42, module: Muse})

      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert issue.metadata == %{file: "lib/muse.ex", line: 42, module: Muse}
    end

    test "wraps non-map metadata in inspected map" do
      diagnostic = Diagnostic.new(:error, "non-map meta", {:tuple, "data"})
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert is_map(issue.metadata)
      assert issue.metadata[:metadata] =~ "{:tuple"
    end
  end

  describe "with_status/2" do
    test "updates status and updated_at" do
      diagnostic = Diagnostic.new(:warning, "test")
      issue = SelfHealingIssue.from_diagnostic(diagnostic)
      updated = SelfHealingIssue.with_status(issue, :in_progress)

      assert updated.status == :in_progress
      assert DateTime.compare(updated.updated_at, issue.updated_at) in [:gt, :eq]
    end

    test "accepts all valid statuses" do
      diagnostic = Diagnostic.new(:warning, "test")
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      for status <- [:queued, :in_progress, :fixed, :failed, :ignored] do
        updated = SelfHealingIssue.with_status(issue, status)
        assert updated.status == status
      end
    end

    test "raises ArgumentError for invalid status" do
      diagnostic = Diagnostic.new(:warning, "test")
      issue = SelfHealingIssue.from_diagnostic(diagnostic)

      assert_raise ArgumentError, ~r/unsupported self-healing issue status/, fn ->
        SelfHealingIssue.with_status(issue, :bogus)
      end
    end
  end

  describe "with_failure/2" do
    test "marks as failed with reason" do
      diagnostic = Diagnostic.new(:error, "failing")
      issue = SelfHealingIssue.from_diagnostic(diagnostic)
      updated = SelfHealingIssue.with_failure(issue, "compilation error")

      assert updated.status == :failed
      assert updated.failure_reason == "compilation error"
    end
  end
end
