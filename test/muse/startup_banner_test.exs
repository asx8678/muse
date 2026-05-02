defmodule Muse.StartupBannerTest do
  use ExUnit.Case, async: true

  alias Muse.{BootOptions, StartupBanner}

  # -- Default (all enabled) ----------------------------------------------------

  describe "format/1 — default (CLI + Web + hot reload)" do
    test "produces the canonical 5-line banner" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          cli?: true,
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true
        )

      assert banner =~ "Muse started"
      assert banner =~ "Workspace: /tmp/proj"
      assert banner =~ "CLI: enabled"
      assert banner =~ "Web: http://127.0.0.1:4000"
      assert banner =~ "Hot reload: enabled"
    end

    test "returns exactly 5 newline-separated lines" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          cli?: true,
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: true
        )

      lines = String.split(banner, "\n")
      assert length(lines) == 5
    end
  end

  # -- No-web mode (--no-web) ---------------------------------------------------

  describe "format/1 — no-web mode" do
    test "shows Web: disabled" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          cli?: true,
          web?: false,
          host: "127.0.0.1",
          port: 4000,
          watch?: true
        )

      assert banner =~ "CLI: enabled"
      assert banner =~ "Web: disabled"
      refute banner =~ "http://"
    end
  end

  # -- No-cli mode (--no-cli / --web-only) ---------------------------------------

  describe "format/1 — no-cli mode" do
    test "shows CLI: disabled, web URL present" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          cli?: false,
          web?: true,
          host: "0.0.0.0",
          port: 8080,
          watch?: true
        )

      assert banner =~ "CLI: disabled"
      assert banner =~ "Web: http://0.0.0.0:8080"
    end
  end

  # -- No hot-reload (--no-watch / source_mode) ---------------------------------

  describe "format/1 — no hot reload" do
    test "shows Hot reload: disabled" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          cli?: true,
          web?: true,
          host: "127.0.0.1",
          port: 4000,
          watch?: false
        )

      assert banner =~ "Hot reload: disabled"
    end
  end

  # -- Accepts BootOptions struct ------------------------------------------------

  describe "format/1 — BootOptions struct input" do
    test "works with a real BootOptions struct" do
      opts = %BootOptions{
        cli?: true,
        web?: true,
        host: "127.0.0.1",
        port: 4000,
        workspace: "/tmp/proj",
        watch?: true,
        help?: false
      }

      banner = StartupBanner.format(opts)

      assert banner =~ "Muse started"
      assert banner =~ "Workspace: /tmp/proj"
      assert banner =~ "Web: http://127.0.0.1:4000"
    end
  end

  # -- io_puts/1 ----------------------------------------------------------------

  describe "io_puts/1" do
    test "writes banner to stdout" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert StartupBanner.io_puts(
                   workspace: "/tmp/proj",
                   cli?: true,
                   web?: true,
                   host: "127.0.0.1",
                   port: 4000,
                   watch?: true
                 ) == :ok
        end)

      assert output =~ "Muse started"
    end
  end

  # -- Edge cases ---------------------------------------------------------------

  describe "format/1 — custom port" do
    test "uses the specified port number" do
      banner =
        StartupBanner.format(
          workspace: "/tmp/proj",
          cli?: true,
          web?: true,
          host: "127.0.0.1",
          port: 9999,
          watch?: true
        )

      assert banner =~ "Web: http://127.0.0.1:9999"
    end
  end
end
