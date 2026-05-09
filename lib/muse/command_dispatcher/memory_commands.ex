defmodule Muse.CommandDispatcher.MemoryCommands do
  @moduledoc """
  Memory management command dispatchers.

  Handles `/memory`, `/memory compact`, and `/memory clear` commands.
  Memory commands interact with `SessionRouter` for persistence and
  `Memory.compact_safe/1` for compaction with secret detection.

  ## Lifecycle

  Called from `Muse.CommandDispatcher.dispatch/3` when the action
  is a memory-related command. Returns the standard
  `{:ok, output, effects}` or `{:error, output, effects}` tuple.
  """

  alias Muse.{Memory, SessionRouter}
  alias Muse.Diagnostics.SilentRescue

  @spec dispatch(atom(), String.t() | nil, map()) ::
          {:ok, String.t(), [tuple()]} | {:error, String.t(), [tuple()]} | :unknown
  def dispatch(:memory, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /memory", []}
    else
      session_id = context_session_id(context)

      case SessionRouter.get_memory(session_id) do
        {:ok, nil} ->
          {:ok, "No session memory. Use /memory compact to create one.", []}

        {:ok, memory} when is_map(memory) ->
          output = format_memory(memory)
          {:ok, output, []}

        {:ok, other_memory} ->
          output = format_memory_safely(other_memory)
          {:ok, output, []}

        {:error, :not_found} ->
          {:ok, "No active Muse session.", []}

        {:error, {:invalid_session_id, id}} ->
          {:error, invalid_session_id_error(id), []}
      end
    end
  end

  def dispatch(:memory_compact, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /memory compact", []}
    else
      session_id = context_session_id(context)

      case SessionRouter.status(session_id) do
        {:ok, session_status} when is_map(session_status) ->
          session = build_session_from_status(session_status)

          case Memory.compact_safe(session) do
            {:ok, memory} ->
              case SessionRouter.set_memory(session_id, memory) do
                :ok ->
                  output = "Memory compacted successfully.\n\n" <> Memory.render(memory)
                  {:ok, output, [{:refresh, :session}]}

                {:error, {:unsafe_memory, reasons}} ->
                  {:error,
                   "Memory compaction blocked: secrets detected in persistence. #{inspect(reasons)}",
                   []}

                {:error, {:invalid_session_id, id}} ->
                  {:error, invalid_session_id_error(id), []}

                {:error, reason} ->
                  {:error, "Memory compaction failed: persistence error. #{inspect(reason)}", []}
              end

            {:error, :secrets_detected, reasons} ->
              {:error, "Memory compaction blocked: secrets detected. #{inspect(reasons)}", []}
          end

        {:error, :not_found} ->
          {:ok, "No active Muse session to compact.", []}

        {:error, {:invalid_session_id, id}} ->
          {:error, invalid_session_id_error(id), []}
      end
    end
  end

  def dispatch(:memory_clear, args, context) do
    if present_args?(args) do
      {:error, "Error: usage: /memory clear", []}
    else
      session_id = context_session_id(context)

      case SessionRouter.clear_memory(session_id) do
        :ok ->
          {:ok, "Session memory cleared. Future turns will not have memory context.",
           [{:refresh, :session}]}

        {:error, :not_found} ->
          {:ok, "No active Muse session.", []}

        {:error, {:invalid_session_id, id}} ->
          {:error, invalid_session_id_error(id), []}
      end
    end
  end

  def dispatch(_action, _args, _context), do: :unknown

  # -- Private helpers ----------------------------------------------------------

  defp present_args?(nil), do: false
  defp present_args?(""), do: false
  defp present_args?(args) when is_binary(args), do: String.trim(args) != ""
  defp present_args?(_), do: true

  defp context_session_id(%{session_id: id}), do: id
  defp context_session_id(%{"session_id" => id}), do: id
  defp context_session_id(_), do: nil

  defp invalid_session_id_error(id), do: "Invalid session ID: #{inspect(id)}"

  defp build_session_from_status(status) when is_map(status) do
    %{
      id: status[:id] || status["id"],
      status: status[:status] || status["status"],
      workspace: status[:workspace] || status["workspace"]
    }
  end

  defp build_session_from_status(_), do: %{}

  defp format_memory(memory) when is_map(memory) do
    Memory.render(memory)
  rescue
    e ->
      SilentRescue.log_rescued(__MODULE__, :format_memory, e)

      "Memory display unavailable (render error). " <>
        "Stored memory may contain unsafe data and has been withheld."
  end

  defp format_memory(_), do: "No memory available."

  defp format_memory_safely(memory) when is_binary(memory) do
    # Redact binary memory through full pipeline before display.
    memory
    |> Muse.EventPayloadRedactor.redact_string()
    |> Muse.Prompt.Redactor.redact_text()
  rescue
    e ->
      SilentRescue.log_rescued(__MODULE__, :format_memory_safely_binary, e)
      "Memory display unavailable (redaction error). Content withheld."
  end

  defp format_memory_safely(memory) do
    # Non-map, non-binary memory (lists, tuples, etc.) — apply structural
    # redaction first to catch sensitive-key values in nested terms, then
    # convert to string and apply string-level pattern redaction.
    memory
    |> Muse.EventPayloadRedactor.redact()
    |> Muse.Prompt.Redactor.redact_term()
    |> inspect(limit: 20, printable_limit: 500)
    |> Muse.EventPayloadRedactor.redact_string()
    |> Muse.Prompt.Redactor.redact_text()
  rescue
    e ->
      SilentRescue.log_rescued(__MODULE__, :format_memory_safely_struct, e)
      "Memory display unavailable (render error). Content withheld."
  end
end
