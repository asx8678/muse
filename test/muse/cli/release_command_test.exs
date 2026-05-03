defmodule Muse.CLI.ReleaseCommandTest do
  use ExUnit.Case, async: true

  describe "release command help" do
    test "Application.help_text documents all CLI flags" do
      help = Muse.Application.help_text()
      # All BootOptions flags should be documented
      assert help =~ "--repl"
      assert help =~ "--tui"
      assert help =~ "--no-web"
      assert help =~ "--web-only"
      assert help =~ "--no-cli"
      assert help =~ "--port"
      assert help =~ "--host"
      assert help =~ "--workspace"
      assert help =~ "--no-watch"
      assert help =~ "--verbose"
      assert help =~ "--help"
    end
  end

  describe "BootOptions.parse! with release-compatible flags" do
    test "parses --tui --no-web" do
      opts = Muse.BootOptions.parse!(["--tui", "--no-web"])
      assert opts.cli_ui == :tui
      assert opts.web? == false
    end

    test "parses --tui --no-web --no-watch" do
      opts = Muse.BootOptions.parse!(["--tui", "--no-web", "--no-watch"])
      assert opts.cli_ui == :tui
      assert opts.web? == false
      assert opts.watch? == false
    end

    test "parses --repl" do
      opts = Muse.BootOptions.parse!(["--repl"])
      assert opts.cli_ui == :repl
    end
  end
end
