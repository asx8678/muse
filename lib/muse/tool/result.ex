defmodule Muse.Tool.Result do
  @moduledoc """
  Struct representing the outcome of a tool invocation.

  The runner always returns a `%Result{}` — either success or error.
  Handlers also return `%Result{}` structs for consistency.

  ## Fields

    * `:success`     — `true` if the tool executed without error
    * `:output`      — the tool output (map, string, or nil)
    * `:error`       — redacted error message string or nil
    * `:tool_name`   — the tool name that produced this result
    * `:metadata`    — additional metadata (elapsed_ms, backend used, etc.)

  ## API contract

  `Muse.Tool.Runner.run/3` always returns a `%Result{}`:

      - On success: `%Result{success: true, output: ..., error: nil, ...}`
      - On blocked: `%Result{success: false, error: "blocked: ...", ...}`
      - On failure: `%Result{success: false, error: "...", ...}`

  This is the ergonomic choice: callers can pattern-match on `success` without
  unpacking tuples.
  """

  alias Muse.Prompt.Redactor

  @enforce_keys [:success, :tool_name]

  defstruct [
    :success,
    :output,
    :error,
    :tool_name,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          success: boolean(),
          output: term() | nil,
          error: String.t() | nil,
          tool_name: String.t(),
          metadata: map()
        }

  @doc """
  Create a successful result.

  ## Examples

      iex> result = Muse.Tool.Result.ok("read_file", %{content: "hello"})
      iex> result.success
      true
      iex> result.output
      %{content: "hello"}

  """
  @spec ok(term(), term(), map()) :: t()
  def ok(tool_name, output \\ nil, metadata \\ %{}) do
    %__MODULE__{
      success: true,
      output: output,
      error: nil,
      tool_name: safe_tool_name(tool_name),
      metadata: metadata
    }
  end

  @doc """
  Create an error/blocked result.

  ## Examples

      iex> result = Muse.Tool.Result.error("shell_command", "blocked: write tools not allowed")
      iex> result.success
      false
      iex> result.error
      "blocked: write tools not allowed"

  """
  @spec error(term(), String.t(), map()) :: t()
  def error(tool_name, error_message, metadata \\ %{}) do
    %__MODULE__{
      success: false,
      output: nil,
      error: safe_error_message(error_message),
      tool_name: safe_tool_name(tool_name),
      metadata: metadata
    }
  end

  @doc """
  Create a blocked result (a specific kind of error for permission denials).

  ## Examples

      iex> result = Muse.Tool.Result.blocked("write_file", "write tools not allowed for planning muse")
      iex> result.success
      false
      iex> result.error
      "blocked: write tools not allowed for planning muse"

  """
  @spec blocked(term(), String.t(), map()) :: t()
  def blocked(tool_name, reason, metadata \\ %{}) do
    error(tool_name, "blocked: #{reason}", metadata)
  end

  @doc """
  Return a safe summary map for event emission.

  Never includes raw file contents or secrets — only tool name, success,
  error (if any), and capped/truncated output summary.
  """
  @spec safe_summary(t(), pos_integer()) :: map()
  def safe_summary(%__MODULE__{} = result, max_len \\ 200) do
    %{
      tool_name: safe_tool_name(result.tool_name),
      success: result.success,
      error: safe_error_message(result.error),
      output_summary: result.output |> summarize_output(max_len) |> redact_summary()
    }
  end

  defp summarize_output(nil, _max_len), do: nil

  defp summarize_output(output, max_len) when is_binary(output) do
    if byte_size(output) > max_len do
      String.slice(output, 0, max_len) <> "…"
    else
      output
    end
  end

  defp summarize_output(output, max_len) do
    inspect(output, limit: 5, printable_limit: max_len)
  end

  defp safe_tool_name(name) when is_binary(name) do
    name
    |> cap_text(200)
    |> Redactor.redact_text()
  end

  defp safe_tool_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> safe_tool_name()

  defp safe_tool_name(name) do
    name
    |> inspect(limit: 10, printable_limit: 200)
    |> cap_text(200)
    |> Redactor.redact_text()
  end

  defp safe_error_message(nil), do: nil

  defp safe_error_message(message) when is_binary(message) do
    message
    |> cap_text(1_000)
    |> Redactor.redact_text()
  end

  defp safe_error_message(message) do
    message
    |> inspect(limit: 10, printable_limit: 500)
    |> cap_text(1_000)
    |> Redactor.redact_text()
  end

  defp cap_text(text, max_bytes) when byte_size(text) > max_bytes do
    String.slice(text, 0, max_bytes) <> "…"
  end

  defp cap_text(text, _max_bytes), do: text

  defp redact_summary(nil), do: nil
  defp redact_summary(summary) when is_binary(summary), do: Redactor.redact_text(summary)
  defp redact_summary(summary), do: Redactor.redact_term(summary)
end
