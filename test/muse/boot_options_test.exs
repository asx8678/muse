defmodule Muse.BootOptionsTest do
  use ExUnit.Case, async: false

  alias Muse.BootOptions

  # We toggle env vars, so async: false

  setup do
    # Capture the original env so we restore it after each test
    original = System.get_env("MUSE_WORKSPACE")
    on_exit(fn -> restore_workspace_env(original) end)
    :ok
  end

  # -- Defaults -----------------------------------------------------------------

  describe "parse!/1 defaults" do
    test "empty argv returns all defaults with cwd as workspace" do
      System.delete_env("MUSE_WORKSPACE")
      opts = BootOptions.parse!([])

      assert opts.cli? == true
      assert opts.web? == true
      assert opts.host == "127.0.0.1"
      assert opts.port == 4000
      assert opts.watch? == true
      assert opts.help? == false
      # workspace is absolute
      assert opts.workspace == File.cwd!()
      assert Path.type(opts.workspace) == :absolute
    end
  end

  # -- Workspace resolution ------------------------------------------------------

  describe "workspace resolution" do
    test "falls back to MUSE_WORKSPACE env when no --workspace flag" do
      expected = Path.expand("/tmp/muse_env_test")
      System.put_env("MUSE_WORKSPACE", "/tmp/muse_env_test")

      opts = BootOptions.parse!([])
      assert opts.workspace == expected
    after
      System.delete_env("MUSE_WORKSPACE")
    end

    test "--workspace overrides MUSE_WORKSPACE env" do
      System.put_env("MUSE_WORKSPACE", "/tmp/should_not_see_this")

      opts = BootOptions.parse!(["--workspace", "/tmp/cli_override"])
      assert opts.workspace == Path.expand("/tmp/cli_override")
    after
      System.delete_env("MUSE_WORKSPACE")
    end

    test "--workspace resolves to absolute path" do
      tmp = System.tmp_dir!()
      relative = "muse_workspace_test"

      opts = BootOptions.parse!(["--workspace", Path.join(tmp, relative)])
      expected = Path.expand(Path.join(tmp, relative))
      assert opts.workspace == expected
      assert Path.type(opts.workspace) == :absolute
    end

    test "env workspace is expanded to absolute path" do
      System.put_env("MUSE_WORKSPACE", "../tmp/muse_env_rel")
      expected = Path.expand("../tmp/muse_env_rel")

      opts = BootOptions.parse!([])
      assert opts.workspace == expected
      assert Path.type(opts.workspace) == :absolute
    after
      System.delete_env("MUSE_WORKSPACE")
    end
  end

  # -- Mode flags ----------------------------------------------------------------

  describe "--no-web" do
    test "sets cli true, web false" do
      opts = BootOptions.parse!(["--no-web"])
      assert opts.cli? == true
      assert opts.web? == false
    end
  end

  describe "--web-only" do
    test "sets cli false, web true" do
      opts = BootOptions.parse!(["--web-only"])
      assert opts.cli? == false
      assert opts.web? == true
    end
  end

  describe "--no-cli" do
    test "is an alias for --web-only: cli false, web true" do
      opts = BootOptions.parse!(["--no-cli"])
      assert opts.cli? == false
      assert opts.web? == true
    end
  end

  # -- Host & Port ---------------------------------------------------------------

  describe "--port" do
    test "sets port to the given integer" do
      opts = BootOptions.parse!(["--port", "4100"])
      assert opts.port == 4100
    end

    test "rejects non-integer port" do
      assert_raise ArgumentError, ~r/unknown or invalid/, fn ->
        BootOptions.parse!(["--port", "abc"])
      end
    end

    test "rejects out-of-range port (0)" do
      assert_raise ArgumentError, ~r/invalid port/, fn ->
        BootOptions.parse!(["--port", "0"])
      end
    end

    test "rejects out-of-range port (65536)" do
      assert_raise ArgumentError, ~r/invalid port/, fn ->
        BootOptions.parse!(["--port", "65536"])
      end
    end

    test "rejects negative port" do
      assert_raise ArgumentError, ~r/invalid port/, fn ->
        BootOptions.parse!(["--port", "-1"])
      end
    end
  end

  describe "--host" do
    test "sets host to the given string" do
      opts = BootOptions.parse!(["--host", "0.0.0.0"])
      assert opts.host == "0.0.0.0"
    end
  end

  # -- Watch flags ---------------------------------------------------------------

  describe "--watch" do
    test "explicitly enables watch" do
      opts = BootOptions.parse!(["--watch"])
      assert opts.watch? == true
    end
  end

  describe "--no-watch" do
    test "disables watch" do
      opts = BootOptions.parse!(["--no-watch"])
      assert opts.watch? == false
    end
  end

  # -- Help flag -----------------------------------------------------------------

  describe "--help" do
    test "sets help to true" do
      opts = BootOptions.parse!(["--help"])
      assert opts.help? == true
    end
  end

  # -- Error cases ---------------------------------------------------------------

  describe "invalid input" do
    test "unknown flag raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown or invalid/, fn ->
        BootOptions.parse!(["--bogus"])
      end
    end

    test "unexpected positional argument raises ArgumentError" do
      assert_raise ArgumentError, ~r/unexpected positional/, fn ->
        BootOptions.parse!(["surprise"])
      end
    end

    test "multiple unexpected positional arguments are all listed" do
      assert_raise ArgumentError, ~r/unexpected positional/, fn ->
        BootOptions.parse!(["foo", "bar"])
      end
    end
  end

  # -- Combinations --------------------------------------------------------------

  describe "flag combinations" do
    test "multiple flags together" do
      opts =
        BootOptions.parse!(["--no-web", "--port", "4100", "--host", "0.0.0.0"])

      assert opts.cli? == true
      assert opts.web? == false
      assert opts.port == 4100
      assert opts.host == "0.0.0.0"
    end

    test "--web-only with --port and --host" do
      opts =
        BootOptions.parse!(["--web-only", "--port", "3000", "--host", "example.com"])

      assert opts.cli? == false
      assert opts.web? == true
      assert opts.port == 3000
      assert opts.host == "example.com"
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp restore_workspace_env(nil), do: System.delete_env("MUSE_WORKSPACE")
  defp restore_workspace_env(val), do: System.put_env("MUSE_WORKSPACE", val)
end
