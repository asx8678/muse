defmodule Muse.Reports.VerificationReportTest do
  use ExUnit.Case, async: true

  alias Muse.Reports.VerificationReport

  describe "from_output/1" do
    test "creates report from test runner output map with atom keys" do
      output = %{
        command: "mix_test",
        status: :passed,
        exit_status: 0,
        duration_ms: 1500,
        timed_out: false,
        output_preview: "All tests passed",
        next_action: "continue_to_next_step"
      }

      report = VerificationReport.from_output(output)
      assert report.command == "mix_test"
      assert report.status == :passed
      assert report.exit_status == 0
      assert report.duration_ms == 1500
      assert report.timed_out == false
      assert report.key_output == "All tests passed"
      assert report.next_action == "continue_to_next_step"
    end

    test "creates report from test runner output map with string keys" do
      output = %{
        "command" => "mix_compile",
        "status" => "failed",
        "exit_status" => 1,
        "duration_ms" => 500,
        "output_preview" => "Compilation error",
        "next_action" => "inspect_failures_and_decide_repair"
      }

      report = VerificationReport.from_output(output)
      assert report.command == "mix_compile"
      assert report.status == :failed
      assert report.exit_status == 1
      assert report.next_action == "inspect_failures_and_decide_repair"
    end

    test "handles timed_out status" do
      output = %{
        command: "mix_test",
        status: :timed_out,
        timed_out: true,
        duration_ms: 120_000,
        next_action: "increase_timeout_or_simplify_command"
      }

      report = VerificationReport.from_output(output)
      assert report.status == :timed_out
      assert report.timed_out == true
    end

    test "extracts failure lines from output" do
      output = %{
        command: "mix_test",
        status: :failed,
        exit_status: 1,
        output_preview:
          "1) test something (MyTest)\n     ** ArgumentError\n  Failure:\n     error: something bad"
      }

      report = VerificationReport.from_output(output)
      assert is_list(report.failures)
      assert length(report.failures) > 0
    end

    test "caps long key_output" do
      long_output = String.duplicate("x", 10_000)
      output = %{command: "mix_test", status: :passed, output_preview: long_output}

      report = VerificationReport.from_output(output)
      # cap + "..."
      assert byte_size(report.key_output) <= 5_000 + 3
    end
  end

  describe "from_blocked/2" do
    test "creates blocked report" do
      report = VerificationReport.from_blocked("shell_command", "not a safe preset")
      assert report.command == "shell_command"
      assert report.status == :blocked
      assert report.next_action == "request_approval_for_command"
    end
  end

  describe "from_error/2" do
    test "creates error report" do
      report = VerificationReport.from_error("mix_test", "execution error")
      assert report.command == "mix_test"
      assert report.status == :failed
      assert report.next_action == "inspect_error_and_retry"
    end
  end

  describe "render/1" do
    test "renders a passed report" do
      report =
        VerificationReport.from_output(%{
          command: "mix_test",
          status: :passed,
          exit_status: 0,
          duration_ms: 500,
          timed_out: false,
          next_action: "continue_to_next_step"
        })

      rendered = VerificationReport.render(report)
      assert rendered =~ "VALIDATION RESULT"
      assert rendered =~ "mix_test"
      assert rendered =~ "passed"
      assert rendered =~ "500ms"
    end

    test "renders a failed report with failures" do
      report =
        VerificationReport.from_output(%{
          command: "mix_test",
          status: :failed,
          exit_status: 1,
          duration_ms: 2000,
          output_preview: "1) test fails (MyTest)\nFailure:\n     assert 1 == 2"
        })

      rendered = VerificationReport.render(report)
      assert rendered =~ "failed"
      assert rendered =~ "Failures"
    end

    test "renders a timed out report" do
      report =
        VerificationReport.from_output(%{
          command: "mix_test",
          status: :timed_out,
          timed_out: true,
          duration_ms: 120_000
        })

      rendered = VerificationReport.render(report)
      assert rendered =~ "timed_out"
      assert rendered =~ "Timed out: true"
    end
  end

  describe "to_summary/1" do
    test "returns safe summary map" do
      report =
        VerificationReport.from_output(%{
          command: "mix_test",
          status: :failed,
          exit_status: 1,
          duration_ms: 500,
          output_preview: "some failure output",
          next_action: "inspect_failures_and_decide_repair"
        })

      summary = VerificationReport.to_summary(report)
      assert is_map(summary)
      assert summary.command == "mix_test"
      assert summary.status == :failed
      assert summary.duration_ms == 500
      assert is_integer(summary.failure_count)
      assert summary.next_action == "inspect_failures_and_decide_repair"
    end

    test "summary never contains raw output" do
      report =
        VerificationReport.from_output(%{
          command: "mix_test",
          status: :failed,
          output_preview: "sensitive data: sk-12345secretkey"
        })

      summary = VerificationReport.to_summary(report)
      refute Map.has_key?(summary, :key_output)
      refute Map.has_key?(summary, :output)
    end
  end
end
