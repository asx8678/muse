defmodule Muse.CLI.StreamPrinterTest do
  use ExUnit.Case, async: false

  alias Muse.CLI.StreamPrinter
  alias Muse.State

  # -- Setup --------------------------------------------------------------------

  setup do
    # Ensure State is running
    case Process.whereis(Muse.State) do
      nil ->
        {:ok, pid} = State.start_link([])
        Process.unlink(pid)

      _pid ->
        :ok
    end

    # Ensure PubSub and session infrastructure are running
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

      _ ->
        :ok
    end

    # Clean up sessions
    clean_sessions()

    on_exit(fn ->
      clean_sessions()

      case Process.whereis(Muse.State) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end)

    :ok
  end

  defp clean_sessions do
    case Process.whereis(Muse.SessionSupervisor) do
      nil ->
        :ok

      pid ->
        pid
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            try do
              DynamicSupervisor.terminate_child(Muse.SessionSupervisor, child_pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end)

        Process.sleep(10)
    end
  end

  # -- print_delta/1 ------------------------------------------------------------

  describe "print_delta/1" do
    test "prints chunk without newline" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          StreamPrinter.print_delta("Hello")
        end)

      assert output == "Hello"
    end

    test "prints empty string" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          StreamPrinter.print_delta("")
        end)

      assert output == ""
    end
  end

  # -- print_final/1 ------------------------------------------------------------

  describe "print_final/1" do
    test "prints assistant> prefix with text" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          StreamPrinter.print_final("Hello world")
        end)

      assert output == "assistant> Hello world\n"
    end
  end

  # -- streamed?/1 --------------------------------------------------------------

  describe "streamed?/1" do
    test "returns true when data has streamed?: true" do
      assert StreamPrinter.streamed?(%{data: %{streamed?: true}}) == true
    end

    test "returns true when data has \"streamed?\" => true (string key)" do
      assert StreamPrinter.streamed?(%{data: %{"streamed?" => true}}) == true
    end

    test "returns false when data has streamed?: false" do
      assert StreamPrinter.streamed?(%{data: %{streamed?: false}}) == false
    end

    test "returns false for non-map data" do
      assert StreamPrinter.streamed?(%{data: "string"}) == false
    end
  end

  # -- stream_submit/3 ----------------------------------------------------------

  describe "stream_submit/3" do
    test "default path returns ok and prints streamed output" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, text} = StreamPrinter.stream_submit(:cli, "hello world")
          assert text =~ "Placeholder response"
        end)

      # Should contain the streamed text (printed via deltas)
      assert output =~ "Placeholder response"
    end

    test "streamed output does not duplicate final message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, _text} = StreamPrinter.stream_submit(:cli, "no dupe")
        end)

      # Count how many times "Placeholder response" appears
      # Should be exactly 1 (printed once via deltas), not twice
      count =
        output
        |> String.split("Placeholder response")
        |> length()
        |> Kernel.-(1)

      assert count == 1, "Expected exactly 1 occurrence of streamed text, got #{count}"
    end

    test "custom session_id routes correctly" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, text} =
                   StreamPrinter.stream_submit(:cli, "custom session", session_id: "custom-1")

          assert text =~ "Placeholder response"
        end)

      assert output =~ "Placeholder response"

      # Events should have been routed to the custom session
      events = State.events()
      session_ids = Enum.map(events, & &1.session_id) |> Enum.uniq()
      assert "custom-1" in session_ids
    end

    test "unrelated session events do not affect output" do
      # Submit to a different session first to populate State
      {:ok, _} = Muse.SessionRouter.submit("other-session", :cli, "other message")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, text} =
                   StreamPrinter.stream_submit(:cli, "my message", session_id: "isolated-1")

          # Should only see our message, not the other session's
          assert text =~ "my message"
          refute text =~ "other message"
        end)

      # Output should contain our message but not the other session's text
      assert output =~ "my message"
    end

    test "timeout path does not crash" do
      # Use a very short timeout — the synchronous placeholder should
      # still complete in time, but this verifies the timeout path is wired
      ExUnit.CaptureIO.capture_io(fn ->
        result = StreamPrinter.stream_submit(:cli, "timeout test", timeout: 50)
        # With the synchronous placeholder, this should still succeed
        assert match?({:ok, _}, result)
      end)
    end

    test "task success without deltas returns actual text, not empty" do
      # This tests the no-PubSub/no-event race: the task completes with
      # {:ok, text} but no :assistant_delta PubSub messages arrive in time.
      # The stream printer should return and print the real text.
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, text} = StreamPrinter.stream_submit(:cli, "task result test")
        # Must return the actual placeholder text, not empty string
        assert text != ""
        assert text =~ "Placeholder response"
        assert text =~ "task result test"
      end)
    end
  end
end
