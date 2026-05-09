defmodule Muse.Diagnostics.SilentRescue do
  @moduledoc """
  Structured logging for previously-silent rescue blocks.

  Provides bounded, redacted diagnostic logging for catch-all rescue/catch
  blocks that previously swallowed exceptions silently.  Preserves the
  original error-handling contract (return value unchanged) while adding
  observability.

  ## Design

  - Exception messages are truncated to 200 characters maximum.
  - Exit/throw reasons are truncated to 80 characters maximum.
  - No full payloads, raw paths, or secrets are logged.
  - Metadata is bounded via `Muse.MetadataSanitizer.sanitize/1`.
  - Designed to be called from rescue/catch clauses before returning
    the original fallback value.

  ## Usage

      # Before (silent swallow):
      rescue
        _ -> :ok

      # After (structured diagnostic):
      rescue
        e ->
          Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :my_operation, e)
          :ok

      # For catch blocks:
      catch
        :exit, reason ->
          Muse.Diagnostics.SilentRescue.log_rescued_catch(__MODULE__, :my_operation, :exit, reason)
          :ok
  """

  require Logger

  @max_exception_len 200
  @max_catch_reason_len 80

  @doc """
  Emits a structured warning for a rescued exception.

  Returns `:ok` so it can be used inline before the original fallback value.
  """
  @spec log_rescued(module(), atom(), Exception.t()) :: :ok
  def log_rescued(module, operation, exception) do
    reason = bounded_exception_reason(exception)

    Logger.warning("Silent rescue in #{inspect(module)}:#{operation}",
      module: module,
      operation: operation,
      reason: reason,
      exception_kind: :rescue
    )

    :ok
  end

  @doc """
  Emits a structured warning for a caught throw/exit.

  Returns `:ok` so it can be used inline before the original fallback value.
  """
  @spec log_rescued_catch(module(), atom(), :throw | :exit | :error, term()) :: :ok
  def log_rescued_catch(module, operation, kind, reason) do
    safe_reason = bounded_catch_reason(kind, reason)

    Logger.warning("Silent catch in #{inspect(module)}:#{operation}",
      module: module,
      operation: operation,
      reason: safe_reason,
      exception_kind: kind
    )

    :ok
  end

  # -- Private: bounded reason helpers -----------------------------------------

  defp bounded_exception_reason(exception) do
    message =
      try do
        Exception.message(exception)
      rescue
        _ -> "(exception message unavailable)"
      end

    String.slice(message, 0, @max_exception_len)
  end

  defp bounded_catch_reason(:exit, reason) when is_atom(reason) do
    "exit:#{reason}"
  end

  defp bounded_catch_reason(:exit, reason) when is_tuple(reason) and tuple_size(reason) <= 2 do
    reason
    |> inspect(limit: 2, printable_limit: @max_catch_reason_len)
    |> String.slice(0, @max_catch_reason_len)
  end

  defp bounded_catch_reason(:exit, reason) do
    reason
    |> inspect(limit: 3, printable_limit: @max_catch_reason_len)
    |> String.slice(0, @max_catch_reason_len)
  end

  defp bounded_catch_reason(:throw, reason) do
    reason
    |> inspect(limit: 3, printable_limit: @max_catch_reason_len)
    |> String.slice(0, @max_catch_reason_len)
  end

  defp bounded_catch_reason(kind, reason) do
    "#{kind}:#{inspect(reason, limit: 3, printable_limit: @max_catch_reason_len)}"
    |> String.slice(0, @max_catch_reason_len)
  end
end
