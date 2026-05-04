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

  defp do_handle("/quit", opts), do: shutdown(opts)
  defp do_handle(":quit", opts), do: shutdown(opts)

  defp do_handle("/" <> _ = text, opts) do
    case Muse.Commands.parse(text) do
      {:command, action} ->
        dispatch_and_print(action, nil, opts)

      {:command, action, args} ->
        dispatch_and_print(action, args, opts)

      {:unknown, cmd} ->
        IO.puts("Unknown command: #{cmd}")
        :ok

      :empty ->
        :ok

      {:message, msg} ->
        # Not a slash command — shouldn't reach here, but handle gracefully
        submit_message(msg)
    end
  end

  defp do_handle(text, _opts) do
    submit_message(text)
  end

  defp submit_message(text) do
    Muse.CLI.StreamPrinter.stream_submit(:cli, text)

    :ok
  end

  defp dispatch_and_print(action, args, _opts) do
    context = build_repl_context()
    {_status, output, _effects} = Muse.CommandDispatcher.dispatch(action, args, context)
    IO.puts(output)
    :ok
  end

  defp build_repl_context do
    %{
      events: safe_state_events(),
      logs: safe_log_buffer_list(),
      diagnostics: Muse.Backend.safe_diagnostics(),
      agent_snapshot: Muse.Backend.safe_agent_snapshot(),
      workspace: Muse.Backend.safe_workspace_root(),
      reload_status: Muse.Backend.safe_reload_status(),
      agent_runtime: Muse.Backend.safe_agent_runtime_snapshot(),
      beam_stats: Muse.BeamStats.snapshot(),
      event_filter: "all",
      event_search: "",
      log_filter: "all",
      log_search: ""
    }
  end

  defp safe_state_events do
    try do
      Muse.State.events()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp safe_log_buffer_list do
    try do
      Muse.LogBuffer.list()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  # -- DevReloader rollback (used in error recovery) ----------------------------

  defp maybe_rollback do
    case Process.whereis(Muse.DevReloader) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          try do
            Muse.DevReloader.rollback()
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end
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
