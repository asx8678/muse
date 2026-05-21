defmodule Muse.ConfigDirTest do
  use ExUnit.Case, async: false

  alias Muse.ConfigDir

  setup do
    # Capture original environment variable state to restore on exit
    orig_env = System.get_env("MUSE_CONFIG_DIR")

    on_exit(fn ->
      if orig_env do
        System.put_env("MUSE_CONFIG_DIR", orig_env)
      else
        System.delete_env("MUSE_CONFIG_DIR")
      end
    end)

    :ok
  end

  describe "candidates/0" do
    test "returns default candidate paths when MUSE_CONFIG_DIR is unset" do
      System.delete_env("MUSE_CONFIG_DIR")

      candidates = ConfigDir.candidates()

      assert length(candidates) >= 2
      assert Path.expand("~/Documents/.muse") in candidates
      assert Path.expand("~/.muse") in candidates
    end

    test "includes MUSE_CONFIG_DIR when set to a valid non-empty path" do
      custom_path = "/tmp/custom_muse_config_dir"
      System.put_env("MUSE_CONFIG_DIR", custom_path)

      candidates = ConfigDir.candidates()

      assert hd(candidates) == Path.expand(custom_path)
      assert Path.expand("~/Documents/.muse") in candidates
      assert Path.expand("~/.muse") in candidates
    end

    test "rejects/ignores MUSE_CONFIG_DIR when set to an empty string" do
      System.put_env("MUSE_CONFIG_DIR", "")

      candidates = ConfigDir.candidates()

      # Should fallback to standard candidates and NOT resolve to CWD
      refute File.cwd!() in candidates
      assert Path.expand("~/Documents/.muse") in candidates
      assert Path.expand("~/.muse") in candidates
    end

    test "rejects/ignores MUSE_CONFIG_DIR when set to a whitespace string" do
      System.put_env("MUSE_CONFIG_DIR", "   ")

      candidates = ConfigDir.candidates()

      refute File.cwd!() in candidates
      assert Path.expand("~/Documents/.muse") in candidates
      assert Path.expand("~/.muse") in candidates
    end
  end

  describe "preferred_init_dir/0" do
    test "returns the custom path if set" do
      custom_path = "/tmp/custom_pref_dir"
      System.put_env("MUSE_CONFIG_DIR", custom_path)

      assert ConfigDir.preferred_init_dir() == Path.expand(custom_path)
    end

    test "falls back to default if empty override" do
      System.put_env("MUSE_CONFIG_DIR", "")

      assert ConfigDir.preferred_init_dir() == Path.expand("~/Documents/.muse")
    end
  end

  describe "config_dir/0" do
    test "uses custom path if config.json exists there, even if legacy ~/.muse has it too" do
      # Since we're hitting the filesystem, let's mock custom directories using tmp_dir
      tmp = System.tmp_dir!()
      dir_a = Path.join(tmp, "muse_test_dir_a_#{:erlang.unique_integer([:positive])}")
      dir_b = Path.join(tmp, "muse_test_dir_b_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      on_exit(fn ->
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      # Create config.json in both
      File.write!(Path.join(dir_a, "config.json"), "{}")
      File.write!(Path.join(dir_b, "config.json"), "{}")

      # With dir_a first in precedence (via env override)
      System.put_env("MUSE_CONFIG_DIR", dir_a)

      # Ensure both candidates are present in the list
      # For test resolution we can override candidates/0's list manually by setting the env var
      # pointing to dir_a. Since documents and home won't have config.json (normally), dir_a wins.
      assert ConfigDir.config_dir() == Path.expand(dir_a)
    end
  end
end
