defmodule Muse.StartupBannerTest do
  use ExUnit.Case, async: true

  alias Muse.StartupBanner

  defp app_version do
    case Application.spec(:muse, :vsn) do
      vsn when is_binary(vsn) -> vsn
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.1.0"
    end
  end

  # -- Default (web + repl + hot reload) ----------------------------------------

  describe "format/1 — default (web + repl + hot reload)" do
    test "produces a single-line banner" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :repl,
          logs: :warning
        )

      # Single line — no newlines
      refute banner =~ "\n"

      assert banner =~ "Muse "
      assert banner =~ "workspace=/tmp/proj"
      assert banner =~ "web=http://127.0.0.1:4000"
      assert banner =~ "ui=repl"
      assert banner =~ "reload=on"
      assert banner =~ "logs=warning+"
    end
  end

  # -- No-web mode --------------------------------------------------------------

  describe "format/1 — no-web mode" do
    test "shows web=off" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: false,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :repl,
          logs: :warning
        )

      assert banner =~ "web=off"
      refute banner =~ "http://"
      assert banner =~ "ui=repl"
    end
  end

  # -- UI modes -----------------------------------------------------------------

  describe "format/1 — UI modes" do
    test "ui=repl when UI is repl" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :repl,
          logs: :warning
        )

      assert banner =~ "ui=repl"
    end

    test "ui=tui when UI is tui" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :tui,
          logs: :warning
        )

      assert banner =~ "ui=tui"
    end

    test "ui=none when CLI is disabled (web-only)" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "0.0.0.0",
          port: 8080,
          watch?: true,
          ui: :none,
          logs: :warning
        )

      assert banner =~ "ui=none"
    end
  end

  # -- No hot-reload ------------------------------------------------------------

  describe "format/1 — no hot reload" do
    test "shows reload=off" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: false,
          ui: :repl,
          logs: :warning
        )

      assert banner =~ "reload=off"
    end
  end

  # -- io_puts/1 ----------------------------------------------------------------

  describe "io_puts/1" do
    test "writes banner to stdout" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert StartupBanner.io_puts(
                   workspace: "/tmp/proj",
                   web?: true,
                   host: "127.0.0.1",
                   port: 4000,
                   watch?: true,
                   ui: :repl,
                   logs: :warning
                 ) == :ok
        end)

      assert output =~ "Muse #{app_version()}"
    end
  end

  # -- Custom port --------------------------------------------------------------

  describe "format/1 — custom port" do
    test "uses the specified port number" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 9999,
          watch?: true,
          ui: :repl,
          logs: :debug
        )

      assert banner =~ "web=http://127.0.0.1:9999"
    end
  end

  # -- Logs level ---------------------------------------------------------------

  describe "format/1 — logs level" do
    test "reflects the console log level" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :repl,
          logs: :debug
        )

      assert banner =~ "logs=debug+"
    end

    test "shows logs=error+ for error level" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :repl,
          logs: :error
        )

      assert banner =~ "logs=error+"
    end
  end

  # -- Version ------------------------------------------------------------------

  describe "format/1 — version" do
    test "includes version from Application.spec" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true,
          ui: :repl,
          logs: :warning
        )

      # Should start with "Muse " followed by a version-like string
      assert banner =~ ~r/^Muse \d+\.\d+\.\d+ /
    end

    test "does not hard-code the application version" do
      assert Muse.StartupBanner.format(
               workspace: "/tmp/proj",
               web?: true,
               host: "127.0.0.1",
               port: 4000,
               watch?: true,
               ui: :repl,
               logs: :warning
             ) =~ "Muse #{app_version()}"
    end
  end
end
