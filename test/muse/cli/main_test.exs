defmodule Muse.CLI.MainTest do
  use ExUnit.Case, async: false

  # We toggle app env, so async: false

  setup do
    original_boot_args = Application.get_env(:muse, :boot_args)
    original_source_mode = Application.get_env(:muse, :source_mode?)

    on_exit(fn ->
      if original_boot_args do
        Application.put_env(:muse, :boot_args, original_boot_args)
      else
        Application.delete_env(:muse, :boot_args)
      end

      if original_source_mode != nil do
        Application.put_env(:muse, :source_mode?, original_source_mode)
      else
        Application.delete_env(:muse, :source_mode?)
      end
    end)

    :ok
  end

  describe "boot/3 — escript mode (source_mode? = false)" do
    test "stores boot_args in application env" do
      boot_and_capture(["--no-web"], false, noop_sleep())

      assert Application.get_env(:muse, :boot_args) == ["--no-web"]
    end

    test "sets source_mode? to false" do
      boot_and_capture(["--no-web"], false, noop_sleep())

      assert Application.get_env(:muse, :source_mode?) == false
    end

    test "starts the :muse application successfully" do
      {:ok, _started} = boot_and_capture([], false, noop_sleep())
    end

    test "Muse.PubSub process exists after boot" do
      boot_and_capture([], false, noop_sleep())

      assert Process.whereis(Muse.PubSub) != nil
    end

    test "calls sleep_fun with :infinity" do
      parent = self()

      sleep_fun = fn :infinity ->
        send(parent, :sleep_called)
        :ok
      end

      boot_and_capture(["--port", "4100"], false, sleep_fun)

      assert_received :sleep_called
    end
  end

  describe "boot/3 — source mode (source_mode? = true)" do
    test "stores boot_args in application env" do
      boot_and_capture(["--workspace", "/tmp/test"], true, noop_sleep())

      assert Application.get_env(:muse, :boot_args) == ["--workspace", "/tmp/test"]
    end

    test "sets source_mode? to true" do
      boot_and_capture(["--workspace", "/tmp/test"], true, noop_sleep())

      assert Application.get_env(:muse, :source_mode?) == true
    end
  end

  describe "boot/3 — argument propagation" do
    test "empty args list is stored correctly" do
      boot_and_capture([], false, noop_sleep())

      assert Application.get_env(:muse, :boot_args) == []
    end

    test "multiple args are stored in order" do
      args = ["--no-web", "--port", "4100", "--host", "0.0.0.0"]
      boot_and_capture(args, false, noop_sleep())

      assert Application.get_env(:muse, :boot_args) == args
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp boot_and_capture(args, source_mode?, sleep_fun) do
    # Stop the app first so ensure_all_started has something to do
    Application.stop(:muse)

    result = Muse.CLI.Main.boot(args, source_mode?, sleep_fun)

    # Restart for subsequent tests
    Application.ensure_all_started(:muse)

    result
  end

  defp noop_sleep, do: fn :infinity -> :ok end
end
