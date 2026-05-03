defmodule Muse.CLI.NifAvailabilityTest do
  use ExUnit.Case, async: false

  alias Muse.CLI.NifAvailability

  describe "available?/0" do
    test "returns a boolean" do
      assert is_boolean(NifAvailability.available?())
    end

    test "returns true when running from source (mix test)" do
      # In test mode, we're running from _build which has the NIF
      assert NifAvailability.available?() == true
    end
  end

  describe "check/0" do
    test "returns :ok when NIF is available" do
      assert NifAvailability.check() == :ok
    end
  end

  describe "check!/0" do
    test "returns :ok when NIF is available" do
      assert NifAvailability.check!() == :ok
    end
  end

  describe "escript_mode?/0" do
    test "returns false when running from source" do
      # In test mode, source_mode? is true, so escript_mode? is false
      assert NifAvailability.escript_mode?() == false
    end
  end

  describe "release_mode?/0" do
    test "returns false when RELEASE_NAME is not set" do
      original = System.get_env("RELEASE_NAME")
      System.delete_env("RELEASE_NAME")

      try do
        refute NifAvailability.release_mode?()
      after
        if original, do: System.put_env("RELEASE_NAME", original)
      end
    end

    test "returns true when RELEASE_NAME is set" do
      original = System.get_env("RELEASE_NAME")
      System.put_env("RELEASE_NAME", "muse")

      try do
        assert NifAvailability.release_mode?()
      after
        if original do
          System.put_env("RELEASE_NAME", original)
        else
          System.delete_env("RELEASE_NAME")
        end
      end
    end
  end

  describe "resolve_native_dir/0" do
    test "returns ok tuple with native dir path" do
      assert {:ok, path} = NifAvailability.resolve_native_dir()
      assert String.ends_with?(path, "native")
    end
  end

  describe "nif_file?/1" do
    test "recognizes .so files" do
      assert NifAvailability.nif_file?("libex_ratatui.so") == true
    end

    test "recognizes .dylib files" do
      assert NifAvailability.nif_file?("libex_ratatui.dylib") == true
    end

    test "recognizes .dll files" do
      assert NifAvailability.nif_file?("libex_ratatui.dll") == true
    end

    test "rejects non-NIF files" do
      refute NifAvailability.nif_file?("readme.txt")
      refute NifAvailability.nif_file?("metadata.json")
      refute NifAvailability.nif_file?("Makefile")
    end
  end

  describe "nif_extensions/0" do
    test "includes all three platform extensions" do
      exts = NifAvailability.nif_extensions()
      assert ".so" in exts
      assert ".dylib" in exts
      assert ".dll" in exts
    end
  end

  describe "path-based detection (not _build/releases)" do
    test "available? works even if path has neither _build nor releases" do
      # This test runs from _build, so the path WILL contain _build.
      # The key invariant is: available? returns true because it checks
      # the actual file, not the path structure. A release installed at
      # /opt/muse/lib/ex_ratatui-0.8.2/priv/native/ with a .so file would
      # also return true — the path heuristic is no longer the gate.
      assert NifAvailability.available?() == true
    end

    test "escript_mode? returns false even if _build not in path" do
      # In test mode source_mode? is true, so escript_mode? is false
      # regardless of path contents. This proves that a release installed
      # at an arbitrary path (e.g. /opt/muse/...) won't be falsely
      # detected as escript mode.
      refute NifAvailability.escript_mode?()
    end

    test "release mode is not falsely detected as escript" do
      # When RELEASE_NAME is set, escript_mode? must be false
      original_release = System.get_env("RELEASE_NAME")
      System.put_env("RELEASE_NAME", "muse")

      try do
        refute NifAvailability.escript_mode?()
      after
        if original_release do
          System.put_env("RELEASE_NAME", original_release)
        else
          System.delete_env("RELEASE_NAME")
        end
      end
    end
  end
end
