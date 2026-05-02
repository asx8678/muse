defmodule Muse.CLI.Repl do
  @moduledoc """
  Interactive `muse> ` REPL for the CLI interface.

  Spawns a linked process (NOT a GenServer — `IO.gets/1` is blocking) that
  reads lines from stdin, dispatches commands, and exits cleanly on EOF or
  `/quit`.

  Because `Muse.DevReloader` may not be compiled yet, every call to it
  is guarded with `Code.ensure_loaded?/1` + `function_exported?/3`.
  """

  @prompt "muse> "

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    pid = spawn_link(fn -> loop(opts) end)
    {:ok, pid}
  end

  @doc false
  # Supervised REPL: temporary restart (user quitting shouldn't respawn),
  # and we default halt? to true so System.halt(0) fires on /quit in real
  # runtime.  Tests can pass halt?: false to avoid killing the VM.
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :halt?, true)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec handle_input(String.t(), keyword()) :: :ok | :shutdown
  def handle_input(input, opts) do
    try do
      do_handle(input, opts)
    rescue
      e ->
        IO.puts("[error] #{inspect(e)}")
        maybe_rollback()
        :ok
    catch
      :exit, reason ->
        IO.puts("[error] #{inspect(reason)}")
        maybe_rollback()
        :ok
    end
  end

  # -- Loop --------------------------------------------------------------------

  defp loop(opts) do
    case IO.gets(@prompt) do
      :eof ->
        shutdown(opts)

      {:error, _} ->
        shutdown(opts)

      nil ->
        shutdown(opts)

      raw ->
        input = String.trim(raw)

        case handle_input(input, opts) do
          :shutdown -> :ok
          :ok -> loop(opts)
        end
    end
  end

  # -- Command dispatch ---------------------------------------------------------

  defp do_handle("", _opts), do: :ok

  defp do_handle("/help", _opts) do
    print_help()
    :ok
  end

  defp do_handle("/events", _opts) do
    print_events()
    :ok
  end

  defp do_handle("/workspace", _opts) do
    print_workspace()
    :ok
  end

  defp do_handle("/reload", _opts) do
    dev_call(Muse.DevReloader, :reload, [], "DevReloader not available")
    :ok
  end

  defp do_handle("/rollback", _opts) do
    dev_call(Muse.DevReloader, :rollback, [], "DevReloader not available")
    :ok
  end

  defp do_handle("/reload-status", _opts) do
    dev_call(Muse.DevReloader, :status, [], "DevReloader not available")
    :ok
  end

  defp do_handle("/quit", opts), do: shutdown(opts)
  defp do_handle(":quit", opts), do: shutdown(opts)

  defp do_handle(text, _opts) do
    Muse.submit(:cli, text)
    |> widen_result()
    |> print_submit_result()

    :ok
  end

  # Breaks type inference so the {:error, _} clause of print_submit_result/1
  # doesn't trigger an unreachable-code warning, even though Muse.submit/2
  # currently only returns {:ok, _}.
  @spec widen_result(term()) :: term()
  defp widen_result(result), do: result

  # -- Output helpers -----------------------------------------------------------

  defp print_submit_result({:ok, text}), do: IO.puts("assistant> #{text}")
  defp print_submit_result({:error, text}), do: IO.puts("[error] #{text}")
  defp print_submit_result(other), do: IO.puts("[error] #{inspect(other)}")

  defp print_help do
    IO.puts("""
    Commands:
      /help          Show this help
      /events        Print event log
      /workspace     Print current workspace
      /reload        Force dev reload
      /rollback      Roll back to last good generation
      /reload-status Show reload generation and last error
      /quit          Stop Muse
      :quit          Stop Muse
    """)
  end

  defp print_events do
    Muse.State.events()
    |> Enum.each(fn event ->
      IO.puts("[#{event.source}] #{inspect(event.data)}")
    end)
  end

  defp print_workspace do
    IO.puts("Workspace: #{Muse.Workspace.root()}")
  end

  # -- Optional DevReloader helpers ---------------------------------------------

  defp dev_call(module, function, args, fallback_msg) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) and
         process_alive?(module) do
      result = apply(module, function, args)
      print_dev_result(result)
    else
      IO.puts(fallback_msg)
    end
  end

  defp process_alive?(module) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp print_dev_result(:ok), do: IO.puts("ok")
  defp print_dev_result({:ok, _}), do: IO.puts("ok")
  defp print_dev_result({:error, reason}), do: IO.puts("[error] #{inspect(reason)}")

  defp print_dev_result(status) when is_map(status) do
    if generation = Map.get(status, :generation), do: IO.puts("Generation: #{generation}")

    if last_error = Map.get(status, :last_error) do
      IO.puts("Last error: #{inspect(last_error)}")
    end

    if last_reload_at = Map.get(status, :last_reload_at) do
      IO.puts("Last reload: #{last_reload_at}")
    end
  end

  defp print_dev_result(other), do: IO.puts(inspect(other))

  defp maybe_rollback do
    try do
      module = Muse.DevReloader

      if Code.ensure_loaded?(module) and function_exported?(module, :rollback, 0) and
           process_alive?(module) do
        apply(module, :rollback, [])
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # -- Shutdown -----------------------------------------------------------------

  @spec shutdown(keyword()) :: :shutdown
  defp shutdown(opts) do
    IO.puts("Goodbye!")

    if Keyword.get(opts, :halt?, true) do
      System.halt(0)
    end

    :shutdown
  end
end
