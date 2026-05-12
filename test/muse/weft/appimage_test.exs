defmodule Muse.Weft.AppImageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Muse.Weft.AppImage

  # -- detect?/0 ----------------------------------------------------------------

  describe "detect?/0" do
    test "returns true when APPIMAGE env var is set" do
      original = System.get_env("APPIMAGE")
      System.put_env("APPIMAGE", "/path/to/AppImage")

      on_exit(fn ->
        restore_env("APPIMAGE", original)
      end)

      assert AppImage.detect?() == true
    end

    test "returns false when APPIMAGE env var is not set" do
      original = System.get_env("APPIMAGE")
      System.delete_env("APPIMAGE")

      on_exit(fn ->
        restore_env("APPIMAGE", original)
      end)

      assert AppImage.detect?() == false
    end

    test "returns false when APPIMAGE env var is empty string" do
      original = System.get_env("APPIMAGE")
      System.put_env("APPIMAGE", "")

      on_exit(fn ->
        restore_env("APPIMAGE", original)
      end)

      assert AppImage.detect?() == false
    end
  end

  # -- injected_env_vars/0 ------------------------------------------------------

  describe "injected_env_vars/0" do
    test "returns a non-empty list" do
      vars = AppImage.injected_env_vars()
      assert is_list(vars)
      assert length(vars) > 0
    end

    test "includes core AppImage vars" do
      vars = AppImage.injected_env_vars()
      assert "APPIMAGE" in vars
      assert "APPDIR" in vars
      assert "ARGV0" in vars
    end

    test "includes loader vars" do
      vars = AppImage.injected_env_vars()
      assert "LD_LIBRARY_PATH" in vars
    end

    test "includes GTK vars" do
      vars = AppImage.injected_env_vars()
      assert "GTK_MODULES" in vars
      assert "GTK_PATH" in vars
    end

    test "includes Qt vars" do
      vars = AppImage.injected_env_vars()
      assert "QT_PLUGIN_PATH" in vars
    end

    test "includes GStreamer vars" do
      vars = AppImage.injected_env_vars()
      assert "GST_PLUGIN_PATH" in vars
    end

    test "includes language runtime vars" do
      vars = AppImage.injected_env_vars()
      assert "PYTHONPATH" in vars
      assert "PERL5LIB" in vars
    end

    test "includes cert path vars" do
      vars = AppImage.injected_env_vars()
      assert "SSL_CERT_FILE" in vars
    end
  end

  # -- filter_path/1 ------------------------------------------------------------

  describe "filter_path/1" do
    test "removes entries containing APPDIR mount path" do
      original = System.get_env("APPDIR")
      System.put_env("APPDIR", "/tmp/.mount_abc123")

      on_exit(fn ->
        restore_env("APPDIR", original)
      end)

      input = "/usr/bin:/tmp/.mount_abc123/usr/bin:/bin"
      assert AppImage.filter_path(input) == "/usr/bin:/bin"
    end

    test "returns input unchanged when APPDIR is not set" do
      original = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original)
      end)

      input = "/usr/bin:/bin"
      assert AppImage.filter_path(input) == "/usr/bin:/bin"
    end

    test "returns nil for nil input" do
      assert AppImage.filter_path(nil) == nil
    end

    test "returns input unchanged when no entries match APPDIR" do
      original = System.get_env("APPDIR")
      System.put_env("APPDIR", "/tmp/.mount_xyz")

      on_exit(fn ->
        restore_env("APPDIR", original)
      end)

      input = "/usr/bin:/bin:/usr/local/bin"
      assert AppImage.filter_path(input) == "/usr/bin:/bin:/usr/local/bin"
    end

    test "handles multiple AppImage entries" do
      original = System.get_env("APPDIR")
      System.put_env("APPDIR", "/tmp/.mount_abc")

      on_exit(fn ->
        restore_env("APPDIR", original)
      end)

      input = "/tmp/.mount_abc/bin:/usr/bin:/tmp/.mount_abc/sbin:/bin"
      assert AppImage.filter_path(input) == "/usr/bin:/bin"
    end
  end

  # -- clean_env/1 --------------------------------------------------------------

  describe "clean_env/1" do
    test "removes injected vars from Port env list" do
      original_appdir = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"APPIMAGE", ~c"/some/AppImage"},
        {~c"APPDIR", ~c"/tmp/.mount_abc"},
        {~c"PATH", ~c"/usr/bin:/bin"}
      ]

      result = AppImage.clean_env(env)

      keys = Enum.map(result, fn {k, _v} -> to_string(k) end)
      refute "APPIMAGE" in keys
      refute "APPDIR" in keys
    end

    test "filters PATH value via filter_path" do
      original_appdir = System.get_env("APPDIR")
      System.put_env("APPDIR", "/tmp/.mount_abc")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"PATH", ~c"/tmp/.mount_abc/bin:/usr/bin"}
      ]

      result = AppImage.clean_env(env)

      assert List.keyfind(result, ~c"PATH", 0) == {~c"PATH", ~c"/usr/bin"}
    end

    test "preserves non-AppImage vars" do
      original_appdir = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"LANG", ~c"C.UTF-8"}
      ]

      result = AppImage.clean_env(env)

      assert List.keyfind(result, ~c"LANG", 0) == {~c"LANG", ~c"C.UTF-8"}
    end

    test "preserves unset markers" do
      original_appdir = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"SOME_VAR", false}
      ]

      result = AppImage.clean_env(env)

      assert List.keyfind(result, ~c"SOME_VAR", 0) == {~c"SOME_VAR", false}
    end

    test "strips GTK_ prefixed vars" do
      original_appdir = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"GTK_CUSTOM_VAR", ~c"some_value"}
      ]

      result = AppImage.clean_env(env)

      keys = Enum.map(result, fn {k, _v} -> to_string(k) end)
      refute "GTK_CUSTOM_VAR" in keys
    end

    test "strips QT_ prefixed vars" do
      original_appdir = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"QT_CUSTOM_VAR", ~c"some_value"}
      ]

      result = AppImage.clean_env(env)

      keys = Enum.map(result, fn {k, _v} -> to_string(k) end)
      refute "QT_CUSTOM_VAR" in keys
    end

    test "strips GST_ prefixed vars" do
      original_appdir = System.get_env("APPDIR")
      System.delete_env("APPDIR")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"GST_CUSTOM_VAR", ~c"some_value"}
      ]

      result = AppImage.clean_env(env)

      keys = Enum.map(result, fn {k, _v} -> to_string(k) end)
      refute "GST_CUSTOM_VAR" in keys
    end

    test "returns empty list for empty input" do
      assert AppImage.clean_env([]) == []
    end

    test "handles mixed env with injected, safe, and filtered vars" do
      original_appdir = System.get_env("APPDIR")
      System.put_env("APPDIR", "/tmp/.mount_xyz")

      on_exit(fn ->
        restore_env("APPDIR", original_appdir)
      end)

      env = [
        {~c"APPIMAGE", ~c"/some/AppImage"},
        {~c"LD_LIBRARY_PATH", ~c"/tmp/.mount_xyz/lib"},
        {~c"GTK_MODULES", ~c"unity-gtk-module"},
        {~c"PATH", ~c"/tmp/.mount_xyz/bin:/usr/bin:/bin"},
        {~c"LANG", ~c"C.UTF-8"},
        {~c"HOME", ~c"/home/user"},
        {~c"SOME_VAR", false},
        {~c"QT_CUSTOM_THING", ~c"bad"}
      ]

      result = AppImage.clean_env(env)

      result_keys = Enum.map(result, fn {k, _v} -> to_string(k) end)

      # Injected vars removed
      refute "APPIMAGE" in result_keys
      refute "LD_LIBRARY_PATH" in result_keys
      refute "GTK_MODULES" in result_keys

      # Prefix-matched vars removed
      refute "QT_CUSTOM_THING" in result_keys

      # Safe vars preserved
      assert "LANG" in result_keys
      assert "HOME" in result_keys

      # Unset markers preserved
      assert "SOME_VAR" in result_keys
      assert List.keyfind(result, ~c"SOME_VAR", 0) == {~c"SOME_VAR", false}

      # PATH filtered — AppImage mount entries removed
      assert List.keyfind(result, ~c"PATH", 0) == {~c"PATH", ~c"/usr/bin:/bin"}
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
