defmodule Muse.Reports.VerificationReport do
  @moduledoc """
  Structured verification report for Testing Muse output.

  Testing Muse produces verification results from test runner outputs.
  This struct normalizes the output into a deterministic, capped, and
  redacted report that can be safely stored, emitted in events, and
  displayed to users.

  ## Fields

    * `:command`       — the safe preset name (e.g. `mix_test`)
    * `:status`        — `:passed`, `:failed`, `:timed_out`, or `:blocked`
    * `:exit_status`   — process exit code (nil if timed_out or blocked)
    * `:duration_ms`   — wall-clock execution time
    * `:timed_out`     — whether the command exceeded timeout
    * `:key_output`    — capped/redacted summary of command output
    * `:failures`      — list of failure descriptions (capped)
    * `:next_action`   — suggested next step

  ## Capping

  All string fields are capped at reasonable limits. Raw command output
  is never stored verbatim — only a preview is retained.
  """

  @max_key_output 5_000
  @max_failure_len 500
  @max_failures 10

  @enforce_keys [:command, :status]

  defstruct [
    :command,
    :status,
    exit_status: nil,
    duration_ms: nil,
    timed_out: false,
    key_output: nil,
    failures: [],
    next_action: nil
  ]

  @type status :: :passed | :failed | :timed_out | :blocked

  @type t :: %__MODULE__{
          command: String.t(),
          status: status(),
          exit_status: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          timed_out: boolean(),
          key_output: String.t() | nil,
          failures: [String.t()],
          next_action: String.t() | nil
        }

  @doc """
  Build a verification report from a test_runner tool result output map.

  The `output_map` is the `:output` field from a `%Muse.Tool.Result{}` when
  the test_runner executed successfully. When the result was blocked or
  errored, use `from_blocked/2` or `from_error/2` instead.
  """
  @spec from_output(map()) :: t()
  def from_output(%{} = output_map) do
    %__MODULE__{
      command: cap_string(output_map[:command] || output_map["command"], 100),
      status: parse_status(output_map[:status] || output_map["status"]),
      exit_status: output_map[:exit_status] || output_map["exit_status"],
      duration_ms: output_map[:duration_ms] || output_map["duration_ms"],
      timed_out: output_map[:timed_out] || output_map["timed_out"] || false,
      key_output:
        cap_string(output_map[:output_preview] || output_map["output_preview"], @max_key_output),
      failures: extract_failures(output_map[:output_preview] || output_map["output_preview"]),
      next_action: cap_string(output_map[:next_action] || output_map["next_action"], 200)
    }
  end

  @doc """
  Build a verification report for a blocked test command.
  """
  @spec from_blocked(String.t(), String.t()) :: t()
  def from_blocked(command, reason) do
    %__MODULE__{
      command: cap_string(command, 100),
      status: :blocked,
      key_output: cap_string(reason, @max_key_output),
      next_action: "request_approval_for_command"
    }
  end

  @doc """
  Build a verification report for an execution error.
  """
  @spec from_error(String.t(), String.t()) :: t()
  def from_error(command, error_message) do
    %__MODULE__{
      command: cap_string(command, 100),
      status: :failed,
      key_output: cap_string(error_message, @max_key_output),
      next_action: "inspect_error_and_retry"
    }
  end

  @doc """
  Render the report as a human-readable string.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = report) do
    lines = [
      "VALIDATION RESULT",
      "- Command: #{report.command}",
      "- Status: #{report.status}",
      "- Duration: #{format_duration(report.duration_ms)}"
    ]

    lines =
      if report.timed_out do
        lines ++ ["- Timed out: true"]
      else
        lines
      end

    lines =
      if report.exit_status != nil do
        lines ++ ["- Exit status: #{report.exit_status}"]
      else
        lines
      end

    lines =
      case report.failures do
        [] ->
          lines

        failures ->
          lines ++ ["- Failures:"] ++ Enum.map(Enum.take(failures, @max_failures), &"  - #{&1}")
      end

    lines =
      if report.key_output do
        lines ++ ["- Key output:", "  #{String.slice(report.key_output, 0, 500)}"]
      else
        lines
      end

    lines =
      if report.next_action do
        lines ++ ["- Next action: #{report.next_action}"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Convert to a safe summary map for event emission.
  """
  @spec to_summary(t()) :: map()
  def to_summary(%__MODULE__{} = report) do
    %{
      command: report.command,
      status: report.status,
      duration_ms: report.duration_ms,
      failure_count: length(report.failures),
      next_action: report.next_action
    }
  end

  # -- Private ------------------------------------------------------------------

  defp parse_status(:passed), do: :passed
  defp parse_status(:failed), do: :failed
  defp parse_status(:timed_out), do: :timed_out
  defp parse_status(:blocked), do: :blocked
  defp parse_status("passed"), do: :passed
  defp parse_status("failed"), do: :failed
  defp parse_status("timed_out"), do: :timed_out
  defp parse_status("blocked"), do: :blocked
  defp parse_status(_), do: :failed

  defp extract_failures(nil), do: []

  defp extract_failures(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&failure_line?/1)
    |> Enum.take(@max_failures)
    |> Enum.map(&cap_string(&1, @max_failure_len))
  end

  defp extract_failures(_), do: []

  defp failure_line?(line) do
    stripped = String.trim(line)

    String.starts_with?(stripped, "1)") or
      String.starts_with?(stripped, "Failure") or
      String.starts_with?(stripped, "error") or
      String.starts_with?(stripped, "** ") or
      String.contains?(stripped, "AssertionError") or
      (String.contains?(stripped, "ExUnit") and String.contains?(stripped, "failure"))
  end

  defp cap_string(nil, _max), do: nil

  defp cap_string(s, max) when is_binary(s) and byte_size(s) > max do
    String.slice(s, 0, max) <> "..."
  end

  defp cap_string(s, _max) when is_binary(s), do: s
  defp cap_string(s, max), do: s |> inspect(limit: 10, printable_limit: max)

  defp format_duration(nil), do: "unknown"
  defp format_duration(ms), do: "#{ms}ms"
end
