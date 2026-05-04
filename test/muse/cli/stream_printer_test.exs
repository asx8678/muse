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

    on_exit(fn ->
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

    test "returns false when data has streamed?: false" do
      assert StreamPrinter.streamed?(%{data: %{streamed?: false}}) == false
    end

    test "returns false for non-map data" do
      assert StreamPrinter.streamed?(%{data: "string"}) == false
    end
  end
end
