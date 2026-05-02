defmodule Muse.Script.InstallDevTest do
  use ExUnit.Case, async: false
  import Bitwise

  @muse_src File.cwd!()
  @install_dev Path.join(@muse_src, "script/install-dev")
  @bin_muse Path.join(@muse_src, "bin/muse")

  describe "script/install-dev" do
    test "creates executable wrapper at target path" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      assert {output, 0} = System.shell("sh #{@install_dev} #{target}")

      assert File.exists?(target)
      assert is_executable?(target)
      assert output =~ "Installed muse dev wrapper"
      assert output =~ target

      cleanup(tmp_dir)
    end

    test "generated wrapper embeds absolute muse source path" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      System.shell("sh #{@install_dev} #{target}")

      content = File.read!(target)
      assert content =~ ~r/cd "#{Regex.escape(@muse_src)}"/

      cleanup(tmp_dir)
    end

    test "generated wrapper preserves MUSE_WORKSPACE at runtime" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      System.shell("sh #{@install_dev} #{target}")

      content = File.read!(target)
      # $(pwd) must appear as literal text — it expands at wrapper runtime,
      # not at install time.
      assert content =~ ~S|export MUSE_WORKSPACE="${MUSE_WORKSPACE:-$(pwd)}"|

      cleanup(tmp_dir)
    end

    test "generated wrapper passes arguments with quoted $@" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      System.shell("sh #{@install_dev} #{target}")

      content = File.read!(target)
      # "$@" ensures args with spaces are preserved.
      assert content =~ ~S(exec mix muse "$@")

      cleanup(tmp_dir)
    end

    test "generated wrapper uses set -eu" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      System.shell("sh #{@install_dev} #{target}")

      content = File.read!(target)
      assert content =~ "set -eu"

      cleanup(tmp_dir)
    end

    test "install-dev creates parent directory if missing" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "nested/deep/muse")

      assert {_output, 0} = System.shell("sh #{@install_dev} #{target}")
      assert File.exists?(target)

      cleanup(tmp_dir)
    end
  end

  describe "bin/muse template" do
    test "exists and is executable" do
      assert File.exists?(@bin_muse)
      assert is_executable?(@bin_muse)
    end

    test "resolves MUSE_SRC relative to script location" do
      content = File.read!(@bin_muse)
      # Should use dirname to find repo root (go up from bin/)
      assert content =~ ~S|MUSE_SRC="$(cd "$(dirname "$0")/.." && pwd)"|
    end

    test "preserves caller cwd as MUSE_WORKSPACE" do
      content = File.read!(@bin_muse)
      assert content =~ ~S|export MUSE_WORKSPACE="${MUSE_WORKSPACE:-$(pwd)}"|
    end

    test "passes arguments with quoted $@" do
      content = File.read!(@bin_muse)
      assert content =~ ~S(exec mix muse "$@")
    end

    test "uses set -eu" do
      content = File.read!(@bin_muse)
      assert content =~ "set -eu"
    end
  end

  describe "generated wrapper runtime behavior" do
    test "sets MUSE_WORKSPACE to caller cwd when invoked from different directory" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      System.shell("sh #{@install_dev} #{target}")

      # Create a fake `mix` that captures MUSE_WORKSPACE and args
      fake_bin = Path.join(tmp_dir, "bin")
      File.mkdir_p!(fake_bin)

      fake_mix = Path.join(fake_bin, "mix")

      probe = Path.join(tmp_dir, "probe.txt")

      File.write!(fake_mix, """
      #!/usr/bin/env sh
      echo "MUSE_WORKSPACE=$MUSE_WORKSPACE" > #{probe}
      echo "ARGS=$*" >> #{probe}
      """)

      File.chmod!(fake_mix, 0o755)

      # Run the generated wrapper from a different cwd with a fake mix in PATH
      caller_dir = Path.join(tmp_dir, "my_project")
      File.mkdir_p!(caller_dir)

      System.shell(
        "cd #{caller_dir} && PATH=#{fake_bin}:$PATH sh #{target} --port 4100 --workspace /foo",
        env: %{"MUSE_WORKSPACE" => nil}
      )

      probe_content = File.read!(probe)
      assert probe_content =~ "MUSE_WORKSPACE=#{caller_dir}"
      assert probe_content =~ "ARGS=muse --port 4100 --workspace /foo"

      cleanup(tmp_dir)
    end

    test "respects pre-set MUSE_WORKSPACE env var" do
      tmp_dir = tmp_dir()
      target = Path.join(tmp_dir, "muse")

      System.shell("sh #{@install_dev} #{target}")

      fake_bin = Path.join(tmp_dir, "bin")
      File.mkdir_p!(fake_bin)

      fake_mix = Path.join(fake_bin, "mix")
      probe = Path.join(tmp_dir, "probe.txt")

      File.write!(fake_mix, """
      #!/usr/bin/env sh
      echo "MUSE_WORKSPACE=$MUSE_WORKSPACE" > #{probe}
      echo "ARGS=$*" >> #{probe}
      """)

      File.chmod!(fake_mix, 0o755)

      caller_dir = Path.join(tmp_dir, "my_project")
      File.mkdir_p!(caller_dir)

      custom_workspace = Path.join(tmp_dir, "custom_workspace")
      File.mkdir_p!(custom_workspace)

      # MUSE_WORKSPACE is pre-set; the wrapper should preserve it
      System.shell(
        "cd #{caller_dir} && MUSE_WORKSPACE=#{custom_workspace} PATH=#{fake_bin}:$PATH sh #{target} --no-web"
      )

      probe_content = File.read!(probe)
      assert probe_content =~ "MUSE_WORKSPACE=#{custom_workspace}"
      assert probe_content =~ "ARGS=muse --no-web"

      cleanup(tmp_dir)
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "muse-install-dev-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end

  defp is_executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end
end
