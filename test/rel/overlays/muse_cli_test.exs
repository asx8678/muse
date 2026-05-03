defmodule Muse.Rel.Overlays.MuseCliTest do
  use ExUnit.Case, async: true
  import Bitwise

  @muse_cli Path.join(File.cwd!(), "rel/overlays/bin/muse_cli")

  describe "rel/overlays/bin/muse_cli" do
    test "exists" do
      assert File.exists?(@muse_cli)
    end

    test "is executable" do
      case File.stat(@muse_cli) do
        {:ok, %{mode: mode}} -> assert (mode &&& 0o111) != 0
        _ -> flunk("cannot stat #{@muse_cli}")
      end
    end

    test "uses /usr/bin/env sh shebang" do
      content = File.read!(@muse_cli)
      assert String.starts_with?(content, "#!/usr/bin/env sh")
    end

    test "uses set -eu" do
      content = File.read!(@muse_cli)
      assert content =~ ~r/^set -eu$/m
    end

    test "resolves SCRIPT_DIR relative to own location" do
      content = File.read!(@muse_cli)
      assert content =~ ~r{SCRIPT_DIR=}
      assert content =~ ~r{dirname -- "\$0"}
    end

    test "invokes muse eval with ReleaseCommand.main(System.argv())" do
      content = File.read!(@muse_cli)

      assert content =~
               ~r{exec "\$SCRIPT_DIR/muse" eval "Muse\.CLI\.ReleaseCommand\.main\(System\.argv\(\)\)" -- "\$@"}
    end

    test "forwards arguments with quoted $@" do
      content = File.read!(@muse_cli)
      assert content =~ ~S("$@")
    end

    test "uses exec to replace the shell process" do
      content = File.read!(@muse_cli)
      assert String.contains?(content, "exec ")
    end

    test "is a valid POSIX sh script (syntax check)" do
      case System.shell("sh -n #{@muse_cli}") do
        {_output, 0} -> :ok
        {output, _exit_code} -> flunk("sh syntax check failed: #{output}")
      end
    end
  end

  describe "runtime behavior with fake release" do
    test "invokes bin/muse with eval and forwards arguments" do
      tmp_dir = tmp_dir!()
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      # Copy the wrapper into the fake release's bin/ so SCRIPT_DIR picks it up
      wrapper_target = Path.join(bin_dir, "muse_cli")
      File.cp!(@muse_cli, wrapper_target)
      File.chmod!(wrapper_target, 0o755)

      # Create a fake bin/muse that captures what it was called with
      probe = Path.join(tmp_dir, "probe.txt")
      fake_muse = Path.join(bin_dir, "muse")

      File.write!(fake_muse, """
      #!/usr/bin/env sh
      echo "called_with=$@" > #{probe}
      """)

      File.chmod!(fake_muse, 0o755)

      # Run the wrapper with sample args
      System.shell("cd #{tmp_dir} && #{wrapper_target} --tui --no-web --workspace '/some/path'")

      probe_content = File.read!(probe)

      assert probe_content =~
               ~r{called_with=eval Muse\.CLI\.ReleaseCommand\.main\(System\.argv\(\)\) -- --tui --no-web --workspace /some/path}

      cleanup(tmp_dir)
    end

    test "preserves quoted arguments with spaces" do
      tmp_dir = tmp_dir!()
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      wrapper_target = Path.join(bin_dir, "muse_cli")
      File.cp!(@muse_cli, wrapper_target)
      File.chmod!(wrapper_target, 0o755)

      probe = Path.join(tmp_dir, "probe.txt")
      fake_muse = Path.join(bin_dir, "muse")

      File.write!(fake_muse, """
      #!/usr/bin/env sh
      printf '%s\\n' "$@" > #{probe}
      """)

      File.chmod!(fake_muse, 0o755)

      # Run with an arg that contains spaces
      System.shell(~s[cd #{tmp_dir} && #{wrapper_target} --workspace "/my project/files"])

      probe_content = File.read!(probe)
      assert probe_content =~ ~r{eval}
      assert probe_content =~ ~r{--}
      assert probe_content =~ ~r{--workspace}
      assert probe_content =~ ~r{/my project/files}

      cleanup(tmp_dir)
    end

    test "exits with non-zero when bin/muse is missing" do
      tmp_dir = tmp_dir!()
      bin_dir = Path.join(tmp_dir, "bin")
      File.mkdir_p!(bin_dir)

      wrapper_target = Path.join(bin_dir, "muse_cli")
      File.cp!(@muse_cli, wrapper_target)
      File.chmod!(wrapper_target, 0o755)

      # No bin/muse present — should fail
      {_output, exit_code} = System.shell("#{wrapper_target} --help")
      assert exit_code != 0

      cleanup(tmp_dir)
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "muse-cli-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end
end
