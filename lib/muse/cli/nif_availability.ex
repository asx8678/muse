defmodule Muse.CLI.NifAvailability do
  @moduledoc """
  Runtime check for ExRatatui NIF availability.

  When Muse runs as an escript, the native NIF shared library cannot be
  loaded because `Application.app_dir(:ex_ratatui, ...)` resolves to a
  path inside the escript archive (a zip file), and `dlopen` cannot open
  shared libraries from within an archive.

  This module provides `check!/0` which raises a clear, actionable error
  in that case, and `available?/0` which returns a boolean.
  """

  @doc """
  Returns `true` if the ExRatatui NIF appears loadable, `false` otherwise.

  Performs a lightweight probe: checks that the NIF shared library exists
  at the expected path AND that the path is a real file on disk
  (not inside an escript archive extraction).
  """
  @spec available?() :: boolean()
  def available? do
    case resolve_nif_path() do
      {:ok, path} ->
        File.exists?(path) and File.regular?(path)

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Returns `:ok` if the NIF is available, or `{:error, reason}` with a
  human-readable explanation if not.
  """
  @spec check() :: :ok | {:error, String.t()}
  def check do
    if available?() do
      :ok
    else
      {:error, error_message()}
    end
  end

  @doc """
  Same as `check/0` but raises on failure.
  """
  @spec check!() :: :ok | no_return()
  def check! do
    case check() do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  @doc """
  Whether the current runtime appears to be an escript.

  Heuristic: `source_mode?` is `false` AND no `RELEASE_NAME` env var
  (which Mix releases set automatically).
  """
  @spec escript_mode?() :: boolean()
  def escript_mode? do
    not Application.get_env(:muse, :source_mode?, true) and
      System.get_env("RELEASE_NAME") == nil
  end

  @doc """
  Whether the current runtime is a Mix release.
  """
  @spec release_mode?() :: boolean()
  def release_mode? do
    System.get_env("RELEASE_NAME") != nil
  end

  # -- Private ------------------------------------------------------------------

  defp resolve_nif_path do
    try do
      case Application.app_dir(:ex_ratatui, "priv") do
        nil ->
          {:error, :no_app_dir}

        priv_dir ->
          # Escript extracts to a temp dir that does NOT contain "_build"
          # or "releases".  In source mode and release mode, the path
          # always contains "_build" or "releases" respectively.
          # If neither is present, we're in escript archive land.
          if String.contains?(priv_dir, "_build") or String.contains?(priv_dir, "releases") do
            native_dir = Path.join(priv_dir, "native")

            case File.ls(native_dir) do
              {:ok, files} ->
                case Enum.find(files, &nif_file?/1) do
                  nil -> {:error, :no_nif_file}
                  f -> {:ok, Path.join(native_dir, f)}
                end

              {:error, _} ->
                {:error, :no_native_dir}
            end
          else
            # Path doesn't look like _build or releases — escript archive
            {:error, :escript_archive}
          end
      end
    rescue
      _ -> {:error, :app_dir_error}
    catch
      :exit, _ -> {:error, :app_dir_exit}
    end
  end

  defp nif_file?(name) do
    String.ends_with?(name, ".so") or String.ends_with?(name, ".dylib")
  end

  defp error_message do
    if escript_mode?() do
      """
      TUI mode requires the ExRatatui native NIF, which cannot be loaded
      from a plain escript archive. Use one of these alternatives:

        1. Run from source:   mix muse --tui
        2. Build a release:  MIX_ENV=prod mix release
           Then run:         _build/prod/rel/muse/bin/muse_cli --tui

      The Mix release includes the native library and supports --tui.
      See README "Distribution" for details.
      """
      |> String.trim_trailing()
    else
      """
      TUI mode requires the ExRatatui native NIF, but the shared library
      was not found. Ensure ex_ratatui is compiled for this platform:

        mix deps.compile ex_ratatui

      If running from a release, rebuild it:

        MIX_ENV=prod mix release
      """
      |> String.trim_trailing()
    end
  end
end
