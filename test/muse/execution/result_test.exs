defmodule Muse.Execution.ResultTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.Result

  describe "ok/3" do
    test "creates successful result" do
      result = Result.ok("cmd_123", "output", exit_status: 0, duration_ms: 100)

      assert result.command_id == "cmd_123"
      assert result.output == "output"
      assert result.status == :ok
      assert result.exit_status == 0
      assert result.duration_ms == 100
      assert result.timed_out == false
    end
  end

  describe "error/3" do
    test "creates error result" do
      result = Result.error("cmd_123", "exit status 1", exit_status: 1)

      assert result.command_id == "cmd_123"
      assert result.status == :error
      assert result.exit_status == 1
      assert result.error =~ "exit status 1"
    end

    test "redacts secrets in error message" do
      result = Result.error("cmd_123", "API_KEY=sk-test-secret-failed")

      refute result.error =~ "sk-test-secret"
    end
  end

  describe "timed_out/2" do
    test "creates timed out result" do
      result = Result.timed_out("cmd_123", duration_ms: 5000)

      assert result.command_id == "cmd_123"
      assert result.status == :timed_out
      assert result.timed_out == true
      assert result.error == "command timed out"
    end
  end

  describe "denied/3" do
    test "creates denied result" do
      result = Result.denied("cmd_123", "remote execution denied")

      assert result.command_id == "cmd_123"
      assert result.status == :denied
      assert result.error =~ "remote execution denied"
    end
  end

  describe "blocked/3" do
    test "creates blocked result" do
      result = Result.blocked("cmd_123", "unsafe executable")

      assert result.command_id == "cmd_123"
      assert result.status == :blocked
      assert result.error =~ "unsafe executable"
    end
  end

  describe "ok?/1" do
    test "returns true for ok status" do
      result = Result.ok("cmd_123", "output")
      assert Result.ok?(result)
    end

    test "returns false for error status" do
      result = Result.error("cmd_123", "failed")
      refute Result.ok?(result)
    end
  end

  describe "failed?/1" do
    test "returns true for non-ok status" do
      result = Result.error("cmd_123", "failed")
      assert Result.failed?(result)

      result2 = Result.timed_out("cmd_123")
      assert Result.failed?(result2)

      result3 = Result.denied("cmd_123", "denied")
      assert Result.failed?(result3)
    end

    test "returns false for ok status" do
      result = Result.ok("cmd_123", "output")
      refute Result.failed?(result)
    end
  end

  describe "timed_out?/1" do
    test "returns true for timed out result" do
      result = Result.timed_out("cmd_123")
      assert Result.timed_out?(result)
    end

    test "returns false for non-timed out result" do
      result = Result.ok("cmd_123", "output")
      refute Result.timed_out?(result)
    end
  end

  describe "denied?/1" do
    test "returns true for denied result" do
      result = Result.denied("cmd_123", "denied")
      assert Result.denied?(result)
    end

    test "returns false for non-denied result" do
      result = Result.ok("cmd_123", "output")
      refute Result.denied?(result)
    end
  end

  describe "safe_summary/1" do
    test "returns safe map without raw output" do
      result = Result.ok("cmd_123", "line1\nline2\nline3\nAPI_KEY=sk-test-secret")
      summary = Result.safe_summary(result)

      assert summary.command_id == "cmd_123"
      assert summary.status == :ok
      assert Map.has_key?(summary, :output_preview)
      # The preview should be redacted/capped
      refute inspect(summary) =~ "sk-test-secret"
    end

    test "includes duration and exit_status when present" do
      result = Result.ok("cmd_123", "output", duration_ms: 150, exit_status: 0)
      summary = Result.safe_summary(result)

      assert summary.duration_ms == 150
      assert summary.exit_status == 0
    end

    test "redacts argv_display" do
      result = Result.ok("cmd_123", "output", argv_display: "mix test API_KEY=sk-test-secret")
      summary = Result.safe_summary(result)

      refute inspect(summary) =~ "sk-test-secret"
    end
  end

  describe "to_map/1" do
    test "converts result to map" do
      result = Result.ok("cmd_123", "output", duration_ms: 100)
      map = Result.to_map(result)

      assert is_map(map)
      assert map.command_id == "cmd_123"
      assert map.status == :ok
      assert map.duration_ms == 100
    end

    test "drops nil values" do
      result = Result.ok("cmd_123", "output")
      map = Result.to_map(result)

      # exit_status is 0, not nil, so it's included
      # timed_out is false, included
      refute Map.has_key?(map, :error)
    end

    test "redacts secrets in output" do
      result = Result.ok("cmd_123", "DATABASE_URL=postgres://user:pass@host/db")
      map = Result.to_map(result)

      refute inspect(map) =~ "postgres://user:pass@host/db"
    end
  end
end
