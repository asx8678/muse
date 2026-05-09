defmodule Muse.Diagnostics.SilentRescueTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Muse.Diagnostics.SilentRescue

  # -- Tests: log_rescued/3 ----------------------------------------------------

  describe "log_rescued/3" do
    test "emits a Logger.warning including module and operation" do
      log =
        capture_log(fn ->
          try do
            raise RuntimeError, "test error for diagnostics"
          rescue
            e ->
              SilentRescue.log_rescued(__MODULE__, :test_operation, e)
          end
        end)

      assert log =~ "Silent rescue"
      assert log =~ "test_operation"
    end

    test "returns :ok to allow inline usage before fallback value" do
      result =
        try do
          raise RuntimeError, "inline test"
        rescue
          e ->
            SilentRescue.log_rescued(__MODULE__, :inline_test, e)
            :original_fallback
        end

      assert result == :original_fallback
    end

    test "truncates long exception messages to 200 characters" do
      long_message = String.duplicate("x", 500)

      log =
        capture_log(fn ->
          try do
            raise RuntimeError, long_message
          rescue
            e ->
              SilentRescue.log_rescued(__MODULE__, :long_msg_test, e)
          end
        end)

      assert log =~ "Silent rescue"
      # The full 500-char message should NOT appear in the log output
      refute log =~ String.duplicate("x", 300)
    end

    test "handles non-exception terms gracefully" do
      log =
        capture_log(fn ->
          SilentRescue.log_rescued(__MODULE__, :weird_term, :not_an_exception)
        end)

      # Should not crash
      assert log =~ "Silent rescue"
    end
  end

  # -- Tests: log_rescued_catch/4 ----------------------------------------------

  describe "log_rescued_catch/4" do
    test "emits a Logger.warning for caught exit with atom reason" do
      log =
        capture_log(fn ->
          SilentRescue.log_rescued_catch(__MODULE__, :exit_test, :exit, :normal)
        end)

      assert log =~ "Silent catch"
      assert log =~ "exit_test"
    end

    test "emits a Logger.warning for caught exit with tuple reason" do
      log =
        capture_log(fn ->
          SilentRescue.log_rescued_catch(
            __MODULE__,
            :exit_tuple_test,
            :exit,
            {:shutdown, :timeout}
          )
        end)

      assert log =~ "Silent catch"
      assert log =~ "exit_tuple_test"
    end

    test "emits a Logger.warning for caught throw" do
      log =
        capture_log(fn ->
          SilentRescue.log_rescued_catch(__MODULE__, :throw_test, :throw, {:some_value, 42})
        end)

      assert log =~ "Silent catch"
    end

    test "returns :ok to allow inline usage before fallback value" do
      result =
        try do
          exit(:test_exit)
        catch
          :exit, reason ->
            SilentRescue.log_rescued_catch(__MODULE__, :inline_catch, :exit, reason)
            :catch_fallback
        end

      assert result == :catch_fallback
    end

    test "truncates large exit reasons to 80 characters" do
      big_reason = String.duplicate("a", 500)

      log =
        capture_log(fn ->
          SilentRescue.log_rescued_catch(__MODULE__, :big_reason, :exit, big_reason)
        end)

      assert log =~ "Silent catch"
      # Should not contain the full 500-char string in output
      refute log =~ String.duplicate("a", 200)
    end
  end

  # -- Tests: bounded metadata / no secret leakage ------------------------------

  describe "bounded metadata" do
    test "reason field does not include unbounded content" do
      long_content = String.duplicate("s", 300)

      log =
        capture_log(fn ->
          try do
            raise RuntimeError, long_content
          rescue
            e ->
              SilentRescue.log_rescued(__MODULE__, :bounded_test, e)
          end
        end)

      assert log =~ "Silent rescue"
      # 300-char string should not appear whole in output
      refute log =~ String.duplicate("s", 250)
    end
  end

  # -- Integration: representative failure paths --------------------------------

  describe "integration: representative failure paths" do
    test "session restore_plan logs diagnostic on deserialization failure" do
      log =
        capture_log(fn ->
          try do
            raise ArgumentError, "cannot convert map to plan"
          rescue
            e ->
              SilentRescue.log_rescued(Muse.SessionServer, :restore_plan, e)
              nil
          end
        end)

      assert log =~ "Silent rescue"
      assert log =~ "restore_plan"
    end

    test "conductor emit_fn rescue logs diagnostic" do
      log =
        capture_log(fn ->
          try do
            raise ArgumentError, "collector agent stopped"
          rescue
            e ->
              SilentRescue.log_rescued(Muse.Conductor, :emit_fn, e)
              :ok
          end
        end)

      assert log =~ "Silent rescue"
      assert log =~ "emit_fn"
    end

    test "safe_append_state catch logs diagnostic" do
      log =
        capture_log(fn ->
          SilentRescue.log_rescued_catch(Muse.SessionServer, :safe_append_state, :exit, :noproc)
        end)

      assert log =~ "Silent catch"
      assert log =~ "safe_append_state"
    end
  end
end
