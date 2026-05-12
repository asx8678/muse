defmodule Muse.Tools.EvalElixir do
  @moduledoc """
  Execute Elixir code in the project's runtime context.

  Evaluates a string of Elixir code in an isolated process with:
  - `IEx.Helpers` imported for `h/1`, `exports/1`, etc.
  - IO capture via `StringIO` so printed output is returned separately
  - Timeout protection (default 30s, configurable)
  - Exception catching — never crashes the caller

  ## Arguments

    * `code` — (required) Elixir code string to evaluate
    * `arguments` — (optional) list of values available as `args` binding
    * `timeout` — (optional) max execution time in ms (default: 30_000)

  ## Output

      %{
        result: String.t(),   # inspected result of evaluation
        io: String.t(),        # captured IO output
        success: boolean()     # true if evaluation succeeded
      }
  """

  alias Muse.Tool.Result

  @default_timeout_ms 30_000
  # Safety cap — never allow more than 5 minutes
  @max_timeout_ms 300_000
  @default_output_limit 50_000

  @doc """
  Execute Elixir code in an isolated process.

  Returns a `%Result{}` with `result`, `io`, and `success` fields.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    code = Map.get(args, "code") || Map.get(args, :code)
    arguments = Map.get(args, "arguments") || Map.get(args, :arguments) || []
    timeout_ms = parse_timeout(args)
    output_limit = Map.get(context, :output_limit, @default_output_limit)

    cond do
      is_nil(code) or code == "" ->
        Result.error("eval_elixir", "code is required")

      not is_binary(code) ->
        Result.error("eval_elixir", "code must be a string")

      not is_list(arguments) ->
        Result.error("eval_elixir", "arguments must be a list")

      true ->
        run_eval(code, arguments, timeout_ms, output_limit)
    end
  end

  # -- Private: evaluation ----------------------------------------------------

  defp run_eval(code, arguments, timeout_ms, output_limit) do
    caller = self()
    ref = make_ref()

    eval_pid =
      spawn(fn ->
        result = do_eval(code, arguments, output_limit)
        send(caller, {:eval_result, ref, result})
      end)

    monitor_ref = Process.monitor(eval_pid)

    receive do
      {:eval_result, ^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        build_result(result, output_limit)

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        handle_down(reason, output_limit)
    after
      timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(eval_pid, :kill)

        Result.ok("eval_elixir", %{
          result: "Evaluation timed out after #{timeout_ms}ms",
          io: "",
          success: false
        })
    end
  end

  defp do_eval(code, arguments, output_limit) do
    {:ok, io_pid} = StringIO.open("")
    original_group_leader = Process.group_leader()
    Process.group_leader(self(), io_pid)

    try do
      binding = [args: arguments]
      # Prepend IEx.Helpers import so h/1, exports/1, etc. are available
      code_with_import = "import IEx.Helpers; " <> code

      {result, _binding} =
        try do
          Code.eval_string(code_with_import, binding)
        rescue
          # If IEx.Helpers import fails (e.g. no IEx at runtime), eval without it
          CompileError ->
            Code.eval_string(code, binding)
        end

      {_, io_input} = StringIO.contents(io_pid)

      %{
        result: inspect(result, limit: 50, printable_limit: output_limit),
        io: cap_string(io_input, output_limit),
        success: true
      }
    rescue
      e ->
        {_, io_input} = StringIO.contents(io_pid)

        %{
          result: format_exception(e),
          io: cap_string(io_input, output_limit),
          success: false
        }
    catch
      kind, reason ->
        {_, io_input} = StringIO.contents(io_pid)

        %{
          result: format_catch(kind, reason),
          io: cap_string(io_input, output_limit),
          success: false
        }
    after
      Process.group_leader(self(), original_group_leader)
      StringIO.close(io_pid)
    end
  end

  # -- Private: result construction -------------------------------------------

  defp build_result(%{result: result, io: io, success: success}, _output_limit) do
    Result.ok("eval_elixir", %{
      result: result,
      io: io,
      success: success
    })
  end

  defp handle_down(reason, _output_limit) do
    Result.ok("eval_elixir", %{
      result: "Process exited: #{format_down_reason(reason)}",
      io: "",
      success: false
    })
  end

  # -- Private: error formatting -----------------------------------------------

  defp format_exception(%CompileError{description: description}) do
    "CompileError: #{description}"
  end

  defp format_exception(%{__struct__: struct} = e) do
    "#{inspect(struct)}: #{Exception.message(e)}"
  end

  defp format_exception(e) do
    "Error: #{inspect(e)}"
  end

  defp format_catch(:exit, reason) do
    "Exit: #{inspect(reason)}"
  end

  defp format_catch(:throw, value) do
    "Throw: #{inspect(value)}"
  end

  defp format_catch(kind, reason) do
    "#{inspect(kind)}: #{inspect(reason)}"
  end

  defp format_down_reason(:killed), do: "killed (timeout or :kill)"
  defp format_down_reason(:normal), do: "normal exit"
  defp format_down_reason(reason), do: inspect(reason)

  # -- Private: parsing & safety -----------------------------------------------

  defp parse_timeout(args) do
    raw = Map.get(args, "timeout") || Map.get(args, :timeout)

    case raw do
      nil ->
        @default_timeout_ms

      n when is_integer(n) and n > 0 ->
        min(n, @max_timeout_ms)

      n when is_binary(n) ->
        case Integer.parse(n) do
          {val, _} when val > 0 -> min(val, @max_timeout_ms)
          _ -> @default_timeout_ms
        end

      _ ->
        @default_timeout_ms
    end
  end

  defp cap_string(str, limit) when byte_size(str) > limit do
    String.slice(str, 0, limit) <> "… [truncated]"
  end

  defp cap_string(str, _limit), do: str
end
