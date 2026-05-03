defmodule Muse.CLI.NifAvailability do
  @moduledoc """
  Runtime check for ExRatatui NIF availability.

  When Muse runs as an escript, the native NIF shared library cannot be
  loaded because `Application.app_dir(:ex_ratatui, ...)` resolves to a
  path inside the escript archive (a zip file), and `dlopen` cannot open
  shared libraries from within an archive.

  This module provides `check!/0` which raises a clear, actionable error
  in that case, and `available?/0` which returns a boolean.

  ## Detection strategy

  * **`available?/0`** — resolves `Application.app_dir(:ex_ratatui, "priv/native")`,
    lists files, and returns `true` when a native file (`.so`, `.dylib`, `.dll`)
    exists and is a regular file on disk.
  * **`escript_mode?/0`** — uses `:init.get_argument(:escript)` which is
    `:error` outside escript mode and `{:ok, [...]}` inside. Falls back to
    a heuristic when the argument is unavailable.
  """

  @nif_extensions ~w(.so .dylib .dll)

  # -- Public API ----------------------------------------------------------------

  @doc """
  Returns `true` if the ExRatatui NIF appears loadable, `false` otherwise.

  Resolves the native directory, lists its files, and checks that at least
  one native library file (`.so`, `.dylib`, or `.dll`) exists and is a
  regular file on disk. Works correctly regardless of whether the path
  contains `_build`, `releases`, or an arbitrary install prefix.
  """
  @spec available?() :: boolean()
  def available? do
    case resolve_native_dir() do
      {:ok, native_dir} ->
        case File.ls(native_dir) do
          {:ok, files} ->
            case Enum.find(files, &nif_file?/1) do
              nil -> false
              f -> File.regular?(Path.join(native_dir, f))
            end

          {:error, _} ->
            false
        end

      {:error, _} ->
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

  Uses `:init.get_argument(:escript)` which returns `:error` when not
  running inside an escript. When running as an escript, it returns
  `{:ok, [...]}`. Falls back to a heuristic (not in release, not in
  source mode, no loadable NIF) if the argument is unavailable.
  """
  @spec escript_mode?() :: boolean()
  def escript_mode? do
    case :init.get_argument(:escript) do
      :error -> escript_fallback?()
      {:ok, _} -> true
    end
  end

  @doc """
  Whether the current runtime is a Mix release.
  """
  @spec release_mode?() :: boolean()
  def release_mode? do
    System.get_env("RELEASE_NAME") != nil
  end

  # -- Internal (exposed for testability) ---------------------------------------

  @doc false
  @spec resolve_native_dir() :: {:ok, String.t()} | {:error, atom()}
  def resolve_native_dir do
    try do
      case Application.app_dir(:ex_ratatui, "priv") do
        nil ->
          {:error, :no_app_dir}

        priv_dir ->
          {:ok, Path.join(priv_dir, "native")}
      end
    rescue
      _ -> {:error, :app_dir_error}
    catch
      :exit, _ -> {:error, :app_dir_exit}
    end
  end

  @doc false
  @spec nif_file?(String.t()) :: boolean()
  def nif_file?(name) do
    Enum.any?(@nif_extensions, &String.ends_with?(name, &1))
  end

  @doc false
  @spec nif_extensions() :: [String.t()]
  def nif_extensions, do: @nif_extensions

  # -- Private -------------------------------------------------------------------

  defp escript_fallback? do
    # If :init.get_argument(:escript) returned :error but we're not in
    # release mode and not in source mode and the NIF isn't available,
    # it's likely an escript or broken install. Distinguish by checking
    # source_mode? — if true, we're in `iex -S mix` or `mix test`, not escript.
    cond do
      source_mode?() -> false
      release_mode?() -> false
      not available?() -> true
      true -> false
    end
  end

  defp source_mode? do
    Application.get_env(:muse, :source_mode?) == true
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
