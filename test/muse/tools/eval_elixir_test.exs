defmodule Muse.Tools.EvalElixirTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.EvalElixir

  @ctx %{workspace: "/tmp", muse_id: :coding, session_id: "test", turn_id: "t1"}

  # ---------------------------------------------------------------------------
  # Argument validation
  # ---------------------------------------------------------------------------

  describe "execute/2 — argument validation" do
    test "returns error when code is nil" do
      result = EvalElixir.execute(%{}, @ctx)
      refute result.success
      assert result.error =~ "code is required"
    end

    test "returns error when code is empty string" do
      result = EvalElixir.execute(%{"code" => ""}, @ctx)
      refute result.success
      assert result.error =~ "code is required"
    end

    test "returns error when code is not a string" do
      result = EvalElixir.execute(%{"code" => 123}, @ctx)
      refute result.success
      assert result.error =~ "code must be a string"
    end

    test "returns error when arguments is not a list" do
      result = EvalElixir.execute(%{"code" => "1+1", "arguments" => "oops"}, @ctx)
      refute result.success
      assert result.error =~ "arguments must be a list"
    end
  end

  # ---------------------------------------------------------------------------
  # Basic evaluation
  # ---------------------------------------------------------------------------

  describe "execute/2 — basic evaluation" do
    test "basic arithmetic evaluation" do
      result = EvalElixir.execute(%{"code" => "1 + 2"}, @ctx)
      assert result.success
      assert result.output.success == true
      assert result.output.result == "3"
    end

    test "returns string result" do
      result = EvalElixir.execute(%{"code" => "\"hello\" <> \" world\""}, @ctx)
      assert result.success
      assert result.output.success == true
      assert result.output.result =~ "hello world"
    end

    test "returns list result" do
      result = EvalElixir.execute(%{"code" => "[1, 2, 3]"}, @ctx)
      assert result.success
      assert result.output.result =~ "[1, 2, 3]"
    end

    test "returns map result" do
      result = EvalElixir.execute(%{"code" => "%{a: 1, b: 2}"}, @ctx)
      assert result.success
      assert result.output.result =~ "a: 1"
    end
  end

  # ---------------------------------------------------------------------------
  # Arguments passthrough
  # ---------------------------------------------------------------------------

  describe "execute/2 — arguments passthrough" do
    test "arguments are available as args binding" do
      code = "Enum.sum(args)"
      result = EvalElixir.execute(%{"code" => code, "arguments" => [1, 2, 3]}, @ctx)
      assert result.success
      assert result.output.result == "6"
    end

    test "empty arguments list works" do
      code = "is_list(args)"
      result = EvalElixir.execute(%{"code" => code, "arguments" => []}, @ctx)
      assert result.success
      assert result.output.result == "true"
    end

    test "arguments with complex data" do
      code = "length(args)"
      result = EvalElixir.execute(%{"code" => code, "arguments" => [%{a: 1}, %{b: 2}]}, @ctx)
      assert result.success
      assert result.output.result == "2"
    end
  end

  # ---------------------------------------------------------------------------
  # IEx helpers
  # ---------------------------------------------------------------------------

  describe "execute/2 — IEx helpers" do
    test "IEx.Helpers module is available" do
      code = "Code.ensure_loaded?(IEx.Helpers)"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.result == "true"
    end

    test "IEx.Helpers import does not crash evaluation" do
      # The import is prepended automatically; verify it doesn't break normal code
      code = "Enum.map([1, 2, 3], &(&1 * 2))"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.result =~ "[2, 4, 6]"
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout
  # ---------------------------------------------------------------------------

  describe "execute/2 — timeout protection" do
    @tag timeout: 10_000
    test "timeout exceeded returns error" do
      # Sleep longer than the timeout we set
      code = "Process.sleep(5000); :done"
      result = EvalElixir.execute(%{"code" => code, "timeout" => 100}, @ctx)
      assert result.success
      assert result.output.success == false
      assert result.output.result =~ "timed out"
    end

    test "custom timeout allows completion if within bounds" do
      code = "1 + 1"
      result = EvalElixir.execute(%{"code" => code, "timeout" => 5000}, @ctx)
      assert result.success
      assert result.output.success == true
      assert result.output.result == "2"
    end
  end

  # ---------------------------------------------------------------------------
  # Syntax errors
  # ---------------------------------------------------------------------------

  describe "execute/2 — syntax error formatting" do
    test "syntax error returns formatted message" do
      # incomplete syntax
      code = "def foo("
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == false
      assert result.output.result =~ ~r/CompileError|TokenMissingError|SyntaxError/i
    end

    test "undefined variable error" do
      code = "x + 1"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == false
      # compile error or undefined function — either is acceptable
      assert result.output.result =~ ~r/CompileError|undefined|not available/i
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime exceptions
  # ---------------------------------------------------------------------------

  describe "execute/2 — runtime exception catching" do
    test "runtime exception is caught and formatted" do
      code = "1 / 0"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == false
      assert result.output.result =~ "ArithmeticError"
    end

    test "bad match error is caught" do
      code = ":ok = :error"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == false
      assert result.output.result =~ "MatchError"
    end

    test "raise with message is caught" do
      code = "raise \"something went wrong\""
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == false
      assert result.output.result =~ "RuntimeError"
      assert result.output.result =~ "something went wrong"
    end

    test "exit is caught" do
      code = "exit(:boom)"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == false
      assert result.output.result =~ ~r/Exit|:boom/i
    end
  end

  # ---------------------------------------------------------------------------
  # IO capture
  # ---------------------------------------------------------------------------

  describe "execute/2 — IO capture" do
    test "IO output captured separately from result" do
      code = "IO.puts(\"hello from IO\"); 42"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.success == true
      assert result.output.result == "42"
      assert result.output.io =~ "hello from IO"
    end

    test "IO.write captured" do
      code = "IO.write(\"partial\"); IO.write(\" output\"); :ok"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.io =~ "partial output"
    end

    test "no IO output returns empty string" do
      code = "1 + 1"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.io == ""
    end

    test "IO.inspect output captured" do
      code = "IO.inspect([1,2,3], label: \"list\"); :done"
      result = EvalElixir.execute(%{"code" => code}, @ctx)
      assert result.success
      assert result.output.io =~ "list"
    end
  end
end
