defmodule Muse.Health do
  @moduledoc """
  Smoke checks for the Dev Reloader.

  `check!/0` returns `:ok` when every check passes and raises with a
  descriptive message when any check fails.  Each check is written to be
  robust — no `Process.alive?(nil)` crashes, no exit propagation.
  """

  @spec check!() :: :ok | no_return()
  def check! do
    check_workspace!()
    check_state_alive!()
    check_state_events!()
    check_boot_options!()
    check_submit_exists!()
    :ok
  end

  # -- Individual checks --------------------------------------------------------

  defp check_workspace! do
    pid = Process.whereis(Muse.Workspace)

    if is_nil(pid) do
      raise "Health check failed: Muse.Workspace process not running"
    end

    unless Process.alive?(pid) do
      raise "Health check failed: Muse.Workspace process is dead"
    end

    root = Muse.Workspace.root()

    unless File.dir?(root) do
      raise "Health check failed: workspace root #{inspect(root)} is not a directory"
    end
  end

  defp check_state_alive! do
    pid = Process.whereis(Muse.State)

    if is_nil(pid) do
      raise "Health check failed: Muse.State process not running"
    end

    unless Process.alive?(pid) do
      raise "Health check failed: Muse.State process is dead"
    end
  end

  defp check_state_events! do
    result =
      try do
        Muse.State.events()
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, inspect(reason)}
      end

    unless is_list(result) do
      raise "Health check failed: Muse.State.events() did not return a list, got: #{inspect(result)}"
    end
  end

  defp check_boot_options! do
    try do
      Muse.BootOptions.parse!([])
    rescue
      e ->
        raise "Health check failed: Muse.BootOptions.parse!([]) raised: #{Exception.message(e)}"
    end
  end

  defp check_submit_exists! do
    case Code.ensure_loaded(Muse) do
      {:module, _} ->
        unless function_exported?(Muse, :submit, 2) do
          raise "Health check failed: Muse.submit/2 is not exported"
        end

      {:error, reason} ->
        raise "Health check failed: Muse module not loaded (#{inspect(reason)})"
    end
  end
end
