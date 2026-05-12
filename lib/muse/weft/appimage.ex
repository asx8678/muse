defmodule Muse.Weft.AppImage do
  @moduledoc """
  AppImage environment cleanup for tool execution.

  When Muse itself runs inside an AppImage, the AppImage runtime injects
  environment variables (APPDIR, LD_LIBRARY_PATH, GTK_*, QT_PLUGIN_PATH,
  etc.) that bundle library paths, plugin paths, and overrides. These
  MUST be stripped before executing child tools, because:

    * Bundled libraries may conflict with system libraries
    * GTK/Qt plugins from the AppImage may not work outside
    * PATH entries pointing into the AppImage mount resolve binaries
      that depend on the AppImage's bundled runtime
    * Cert paths (SSL_CERT_FILE) redirect to AppImage's bundled certs

  This module detects when Muse is running inside an AppImage and
  provides functions to clean the environment for child processes.

  ## How it works

  1. `detect?/0` checks for the APPIMAGE env var
  2. `injected_env_vars/0` lists vars injected by the AppImage runtime
  3. `filter_path/1` removes AppImage mount path entries from PATH or
     XDG_DATA_DIRS
  4. `clean_env/1` processes a list of `{charlist, charlist | false}`
     pairs (the format returned by `Muse.Execution.Env.port_env/2`),
     removing AppImage-injected vars and filtering PATH/XDG_DATA_DIRS

  All functions are safe with nil/missing input — no crashes.
  """

  # -- AppImage-injected env vars (authoritative list) ---------------------------

  @injected_env_vars [
    # Core AppImage runtime
    "APPDIR",
    "APPIMAGE",
    "ARGV0",
    "OWD",
    "APPIMAGE_UUID",

    # Loader pollution
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LD_AUDIT",

    # GTK theming
    "GTK_MODULES",
    "GTK_PATH",
    "GTK_IM_MODULE",
    "GTK_IM_MODULE_FILE",
    "GTK3_MODULES",

    # Qt plugins
    "QT_PLUGIN_PATH",
    "QT_QPA_PLATFORM_PLUGIN_PATH",
    "QT_XKB_CONFIG_ROOT",
    "QML2_IMPORT_PATH",

    # GStreamer
    "GST_PLUGIN_PATH",
    "GST_PLUGIN_SYSTEM_PATH",
    "GST_REGISTRY",
    "GST_REGISTRY_UPDATE",

    # XDG dirs (filtered, not stripped raw)
    "XDG_DATA_DIRS",
    "XDG_CONFIG_DIRS",
    "XDG_CACHE_HOME",

    # Fontconfig
    "FONTCONFIG_PATH",
    "FONTCONFIG_FILE",

    # Language runtimes
    "PYTHONHOME",
    "PYTHONPATH",
    "PERLLIB",
    "PERL5LIB",
    "RUBYLIB",
    "RUBYOPT",
    "GEM_PATH",
    "GEM_HOME",
    "BUNDLE_GEMFILE",
    "TCL_LIBRARY",
    "TK_LIBRARY",

    # Cert paths
    "SSL_CERT_FILE",
    "CURL_CA_BUNDLE",

    # i18n
    "GCONV_PATH",
    "LOCALE_ARCHIVE",
    "NLSPATH",

    # Cursor/display
    "XCURSOR_PATH",
    "SDL_VIDEODRIVER",

    # FUSE/AppImage internals
    "FUSE_LIBRARY_PATH",
    "OWL_DL_PATH",

    # Themes
    "GTK_THEME",
    "ICON_THEME_NAME",

    # DBus
    "DBUS_SESSION_BUS_ADDRESS"
  ]

  # Prefix patterns for catch-all stripping: any key starting with
  # these prefixes is also removed, even if not in @injected_env_vars.
  @prefix_patterns [
    "GTK_",
    "QT_",
    "GST_"
  ]

  # Vars whose values should be filtered (not stripped) — we remove
  # AppImage mount path entries from their colon-separated values.
  @filterable_path_vars ["PATH", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS"]

  # -- Public API ---------------------------------------------------------------

  @doc """
  Check whether Muse is running inside an AppImage.

  Returns `true` when the `APPIMAGE` environment variable is set to a
  non-empty value, `false` otherwise.
  """
  @spec detect?() :: boolean()
  def detect? do
    case System.get_env("APPIMAGE") do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  @doc """
  Return the list of environment variable names injected by the
  AppImage runtime that should be stripped before child execution.
  """
  @spec injected_env_vars() :: [String.t()]
  def injected_env_vars, do: @injected_env_vars

  @doc """
  Remove AppImage mount path entries from a colon-separated path string.

  Reads `APPDIR` from the system environment to determine the AppImage
  mount path, then removes any entries containing that path.

  Returns the input unchanged when:
  * `APPDIR` is not set (not running in an AppImage)
  * the input is `nil`

  ## Examples

      # Inside AppImage with APPDIR="/tmp/.mount_abc123"
      iex> Muse.Weft.AppImage.filter_path("/usr/bin:/tmp/.mount_abc123/usr/bin:/bin")
      "/usr/bin:/bin"

      # Outside AppImage — no change
      iex> Muse.Weft.AppImage.filter_path("/usr/bin:/bin")
      "/usr/bin:/bin"

      # nil input
      iex> Muse.Weft.AppImage.filter_path(nil)
      nil
  """
  @spec filter_path(String.t() | nil) :: String.t() | nil
  def filter_path(nil), do: nil

  def filter_path(path) when is_binary(path) do
    case System.get_env("APPDIR") do
      appdir when is_binary(appdir) and appdir != "" ->
        path
        |> String.split(":")
        |> Enum.reject(&String.contains?(&1, appdir))
        |> Enum.join(":")

      _ ->
        path
    end
  end

  @doc """
  Clean a Port env list of AppImage-injected variables.

  Takes a list of `{charlist(), charlist() | false}` pairs (the format
  returned by `Muse.Execution.Env.port_env/2`) and returns the same
  format with AppImage-injected vars removed and PATH/XDG entries
  filtered.

  ## Logic

    1. Vars whose key is in `injected_env_vars/0` are removed.
    2. Vars whose key starts with `GTK_`, `QT_`, or `GST_` are removed
       (catch-all prefix patterns).
    3. `PATH`, `XDG_DATA_DIRS`, and `XDG_CONFIG_DIRS` values are
       filtered via `filter_path/1` to remove AppImage mount entries.
    4. `{key, false}` (unset markers) are preserved for all
       non-AppImage vars.
  """
  @spec clean_env([{charlist(), charlist() | false}]) :: [{charlist(), charlist() | false}]
  def clean_env(env) when is_list(env) do
    injected_set = MapSet.new(@injected_env_vars)

    env
    |> Enum.reject(fn {key, _value} ->
      key_str = to_string(key)
      MapSet.member?(injected_set, key_str) or prefix_match?(key_str)
    end)
    |> Enum.map(fn {key, value} ->
      key_str = to_string(key)

      cond do
        value == false ->
          {key, value}

        key_str in @filterable_path_vars ->
          filtered = filter_path(to_string(value))
          {key, if(filtered, do: String.to_charlist(filtered), else: value)}

        true ->
          {key, value}
      end
    end)
  end

  # -- Private ------------------------------------------------------------------

  defp prefix_match?(key_str) when is_binary(key_str) do
    Enum.any?(@prefix_patterns, &String.starts_with?(key_str, &1))
  end
end
