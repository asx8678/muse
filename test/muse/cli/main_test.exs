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

  describe "--version and --help detection" do
    test "is_version_request?/1 returns true for --version" do
      assert Muse.CLI.Main.is_version_request?(["--version"]) == true
    end

    test "is_version_request?/1 returns true for -v" do
      assert Muse.CLI.Main.is_version_request?(["-v"]) == true
    end

    test "is_version_request?/1 returns false for other args" do
      assert Muse.CLI.Main.is_version_request?([]) == false
      assert Muse.CLI.Main.is_version_request?(["--help"]) == false
      assert Muse.CLI.Main.is_version_request?(["--port", "4000"]) == false
    end

    test "is_help_request?/1 returns true for --help" do
      assert Muse.CLI.Main.is_help_request?(["--help"]) == true
    end

    test "is_help_request?/1 returns true for -h" do
      assert Muse.CLI.Main.is_help_request?(["-h"]) == true
    end

    test "is_help_request?/1 returns true for help" do
      assert Muse.CLI.Main.is_help_request?(["help"]) == true
    end

    test "is_help_request?/1 returns false for other args" do
      assert Muse.CLI.Main.is_help_request?([]) == false
      assert Muse.CLI.Main.is_help_request?(["--version"]) == false
      assert Muse.CLI.Main.is_help_request?(["--port", "4000"]) == false
    end
  end

  describe "print_help/0" do
    test "includes all documented options" do
      output = ExUnit.CaptureIO.capture_io(&Muse.CLI.Main.print_help/0)

      # Options
      assert output =~ "--version, -v"
      assert output =~ "--help, -h"
      assert output =~ "--repl"
      assert output =~ "--tui"
      assert output =~ "--no-web"
      assert output =~ "--web-only"
      assert output =~ "--port"
      assert output =~ "--host"
      assert output =~ "--workspace"
      assert output =~ "--verbose"

      # Key commands
      assert output =~ "/help"
      assert output =~ "/muses"
      assert output =~ "/plan"
      assert output =~ "/approve plan"
      assert output =~ "/reject plan"
      assert output =~ "/session"
      assert output =~ "/quit"

      # Safety notes
      assert output =~ "approval"
      assert output =~ "Remote execution is denied"
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
