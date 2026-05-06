defmodule Muse.Execution.Result do
  @moduledoc """
  Execution result struct for Muse runner abstraction.

  Represents the outcome of a command execution. Always returned as a
  struct with safe, redacted output suitable for events, logs, and display.

  ## Safety properties

    * Output is capped at `max_output_bytes` from the command.
    * Secrets are redacted via `Muse.Prompt.Redactor`.
    * Error messages are sanitized to never leak secrets.
    * Safe summaries are available for event emission.

  ## Status values

    * `:ok` — command completed successfully (exit_status 0)
    * `:error` — command failed with non-zero exit status
    * `:timed_out` — command exceeded timeout
    * `:denied` — execution denied by policy (remote execution)
    * `:blocked` — executable/args blocked by safety rules
  """

  @enforce_keys [:command_id, :runner, :status]
  defstruct [
    :command_id,
    :runner,
    :target,
    :argv_display,
    :exit_status,
    :output,
    :duration_ms,
    :timed_out,
    :status,
    :error,
    :metadata
  ]

  @type status :: :ok | :error | :timed_out | :denied | :blocked

  @type t :: %__MODULE__{
          command_id: String.t(),
          runner: :local | atom(),
          target: :local | String.t() | nil,
          argv_display: String.t() | nil,
          exit_status: non_neg_integer() | nil,
          output: String.t() | map() | nil,
          duration_ms: non_neg_integer() | nil,
          timed_out: boolean() | nil,
          status: status(),
          error: String.t() | nil,
          metadata: map()
        }

  @doc """
  Create a successful result.
  """
  @spec ok(String.t(), String.t() | map(), keyword()) :: t()
  def ok(command_id, output, opts \\ []) do
    %__MODULE__{
      command_id: command_id,
      runner: Keyword.get(opts, :runner, :local),
      target: Keyword.get(opts, :target, :local),
      argv_display: Keyword.get(opts, :argv_display),
      exit_status: Keyword.get(opts, :exit_status, 0),
      output: output,
      duration_ms: Keyword.get(opts, :duration_ms),
      timed_out: false,
      status: :ok,
      error: nil,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Create an error result (non-zero exit status).
  """
  @spec error(String.t(), String.t(), keyword()) :: t()
  def error(command_id, reason, opts \\ []) do
    %__MODULE__{
      command_id: command_id,
      runner: Keyword.get(opts, :runner, :local),
      target: Keyword.get(opts, :target, :local),
      argv_display: Keyword.get(opts, :argv_display),
      exit_status: Keyword.get(opts, :exit_status),
      output: Keyword.get(opts, :output),
      duration_ms: Keyword.get(opts, :duration_ms),
      timed_out: false,
      status: :error,
      error: redact_error(reason),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Create a timed-out result.
  """
  @spec timed_out(String.t(), keyword()) :: t()
  def timed_out(command_id, opts \\ []) do
    %__MODULE__{
      command_id: command_id,
      runner: Keyword.get(opts, :runner, :local),
      target: Keyword.get(opts, :target, :local),
      argv_display: Keyword.get(opts, :argv_display),
      exit_status: nil,
      output: Keyword.get(opts, :partial_output),
      duration_ms: Keyword.get(opts, :duration_ms),
      timed_out: true,
      status: :timed_out,
      error: "command timed out",
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Create a denied result (policy blocked remote execution).
  """
  @spec denied(String.t(), String.t(), keyword()) :: t()
  def denied(command_id, reason, opts \\ []) do
    %__MODULE__{
      command_id: command_id,
      runner: Keyword.get(opts, :runner, :remote),
      target: Keyword.get(opts, :target, :remote),
      argv_display: Keyword.get(opts, :argv_display),
      exit_status: nil,
      output: nil,
      duration_ms: nil,
      timed_out: false,
      status: :denied,
      error: redact_error(reason),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Create a blocked result (safety rules).
  """
  @spec blocked(String.t(), String.t(), keyword()) :: t()
  def blocked(command_id, reason, opts \\ []) do
    %__MODULE__{
      command_id: command_id,
      runner: Keyword.get(opts, :runner, :local),
      target: Keyword.get(opts, :target, :local),
      argv_display: nil,
      exit_status: nil,
      output: nil,
      duration_ms: nil,
      timed_out: false,
      status: :blocked,
      error: redact_error(reason),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Return true if the result indicates success.
  """
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{status: :ok}), do: true
  def ok?(_), do: false

  @doc """
  Return true if the result indicates any kind of failure.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{status: status}), do: status != :ok

  @doc """
  Return true if the result indicates timeout.
  """
  @spec timed_out?(t()) :: boolean()
  def timed_out?(%__MODULE__{timed_out: true}), do: true
  def timed_out?(_), do: false

  @doc """
  Return true if the result indicates denied execution.
  """
  @spec denied?(t()) :: boolean()
  def denied?(%__MODULE__{status: :denied}), do: true
  def denied?(_), do: false

  @doc """
  Return a safe summary for events/logs.

  Never includes raw output or secrets.
  """
  @spec safe_summary(t()) :: map()
  def safe_summary(%__MODULE__{} = result) do
    base = %{
      command_id: result.command_id,
      runner: result.runner,
      target: result.target,
      status: result.status,
      duration_ms: result.duration_ms,
      timed_out: result.timed_out
    }

    base =
      if result.argv_display do
        Map.put(base, :argv_display, redact_string(result.argv_display))
      else
        base
      end

    base =
      if result.exit_status != nil do
        Map.put(base, :exit_status, result.exit_status)
      else
        base
      end

    base =
      if result.error do
        Map.put(base, :error, redact_string(result.error))
      else
        base
      end

    base =
      if result.output do
        Map.put(base, :output_preview, output_preview(result.output))
      else
        base
      end

    base
  end

  @doc """
  Convert result to a map suitable for tool output.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    result
    |> Map.from_struct()
    |> Map.update!(:output, &redact_output/1)
    |> Map.update!(:error, &redact_error/1)
    |> Map.update!(:argv_display, &redact_string/1)
    |> drop_nil_values()
  end

  # -- Private helpers ---------------------------------------------------------

  defp output_preview(output) when is_binary(output) do
    output
    |> redact_string()
    |> String.slice(0, 200)
  end

  defp output_preview(output) when is_map(output) do
    output
    |> inspect(limit: 3, printable_limit: 100)
    |> redact_string()
  end

  defp output_preview(output) when is_list(output) do
    output
    |> inspect(limit: 3, printable_limit: 100)
    |> redact_string()
  end

  defp output_preview(_), do: "[output omitted]"

  defp redact_output(nil), do: nil

  defp redact_output(output) when is_binary(output) do
    Muse.Prompt.Redactor.redact_text(output)
  end

  defp redact_output(output) when is_map(output) do
    Muse.Prompt.Redactor.redact_term(output)
  end

  defp redact_output(output) when is_list(output) do
    Enum.map(output, &redact_output/1)
  end

  defp redact_output(other), do: inspect(other, limit: 5, printable_limit: 100)

  defp redact_error(nil), do: nil
  defp redact_error(error) when is_binary(error), do: redact_string(error)
  defp redact_error(error), do: redact_string(inspect(error, limit: 10, printable_limit: 200))

  defp redact_string(nil), do: nil

  defp redact_string(s) when is_binary(s) do
    Muse.Prompt.Redactor.redact_text(s)
  end

  defp redact_string(other), do: inspect(other)

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
