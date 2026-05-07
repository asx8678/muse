defmodule Muse.Execution.FakeRemoteRunner do
  @moduledoc """
  Fake remote runner for deterministic testing — no network, no shell, no SSH.

  Implements both `Muse.Execution.Runner` and `Muse.Execution.RemoteRunner`
  behaviours. Returns configurable outcomes for tests without any real
  remote execution.

  ## Safety invariants

    * **No network** — `ssh: false`, `network: false` in capabilities.
    * **No shell** — `shell: false` in capabilities.
    * **No SSH** — never opens an SSH connection.
    * Output is capped and redacted using existing redaction patterns.
    * Connect returns an opaque fake connection ref (tuple containing
      module marker, ref, and target_id). No external storage is used;
      no `persistent_term` entries are created.

    * Disconnect is best-effort `:ok` (no external storage to clean up).

  ## Configurable outcomes

  The fake outcome is determined by:

    1. `command.metadata[:fake_outcome]` — `:ok | :error | :timed_out | :denied`
    2. Runner opts `:fake_outcome` — same values
    3. Default — `:ok`

  Output is configurable via `command.metadata[:fake_output]` or
  runner opts `:fake_output`. Default output is `"fake remote output"`.

  ## Redaction

  All output passes through `Muse.Prompt.Redactor.redact_text/1`
  before returning, ensuring fake runner output never leaks secrets.
  """

  @behaviour Muse.Execution.Runner
  @behaviour Muse.Execution.RemoteRunner

  alias Muse.Execution.{Command, Result}

  @default_output "fake remote output"
  @default_outcome :ok

  # -- Runner behaviour ---------------------------------------------------------

  @impl Muse.Execution.Runner
  def capabilities do
    %{
      local: false,
      remote: true,
      ssh: false,
      shell: false,
      network: false,
      timeout_ms: 60_000,
      max_output_bytes: 50_000,
      protocols: [:fake],
      fake: true
    }
  end

  @impl Muse.Execution.Runner
  def run(%Command{} = command, opts) do
    outcome = resolve_outcome(command, opts)
    output = resolve_output(command, opts)
    redacted_output = cap_and_redact(output, command.max_output_bytes)
    argv_display = Command.safe_display(command)

    result = build_result(command, outcome, redacted_output, argv_display)
    {:ok, result}
  end

  # -- RemoteRunner behaviour ---------------------------------------------------

  @impl Muse.Execution.RemoteRunner
  def connect(_target, opts \\ []) do
    ref = make_ref()
    target_id = Keyword.get(opts, :target_id, "fake_target")
    # Opaque fake connection ref — no external storage needed.
    # The tuple embeds module marker + ref + target_id for validation.
    {:ok, {__MODULE__, ref, target_id}}
  end

  @impl Muse.Execution.RemoteRunner
  def disconnect(_connection_ref) do
    # No external storage to clean up — best-effort :ok
    :ok
  end

  @impl Muse.Execution.RemoteRunner
  def remote_run({__MODULE__, _ref, _target_id} = _connection_ref, %Command{} = command, opts) do
    # Valid fake connection ref — proceed with execution
    {:ok, result} = run(command, opts)
    result
  end

  def remote_run(_invalid_ref, %Command{} = command, _opts) do
    # Invalid or disconnected connection ref — denied
    Result.denied(command.id, "invalid or disconnected connection ref",
      target: command.target,
      runner: :fake_remote
    )
  end

  # -- Private helpers -----------------------------------------------------------

  defp resolve_outcome(command, opts) do
    case {Map.get(command.metadata, :fake_outcome), Keyword.get(opts, :fake_outcome)} do
      {outcome, _} when outcome in [:ok, :error, :timed_out, :denied] -> outcome
      {_, outcome} when outcome in [:ok, :error, :timed_out, :denied] -> outcome
      _ -> @default_outcome
    end
  end

  defp resolve_output(command, opts) do
    case {Map.get(command.metadata, :fake_output), Keyword.get(opts, :fake_output)} do
      {output, _} when is_binary(output) -> output
      {_, output} when is_binary(output) -> output
      _ -> @default_output
    end
  end

  defp cap_and_redact(output, max_bytes) when is_binary(output) do
    capped =
      if byte_size(output) > max_bytes do
        String.slice(output, 0, max_bytes)
      else
        output
      end

    Muse.Prompt.Redactor.redact_text(capped)
  end

  defp cap_and_redact(output, _max), do: output

  defp build_result(command, :ok, output, argv_display) do
    Result.ok(command.id, output,
      runner: :fake_remote,
      target: command.target,
      argv_display: argv_display,
      exit_status: 0,
      duration_ms: 0
    )
  end

  defp build_result(command, :error, output, argv_display) do
    Result.error(command.id, "fake remote execution failed",
      runner: :fake_remote,
      target: command.target,
      argv_display: argv_display,
      exit_status: 1,
      output: output
    )
  end

  defp build_result(command, :timed_out, output, argv_display) do
    Result.timed_out(command.id,
      runner: :fake_remote,
      target: command.target,
      argv_display: argv_display,
      partial_output: output,
      duration_ms: command.timeout_ms
    )
  end

  defp build_result(command, :denied, _output, argv_display) do
    Result.denied(command.id, "fake remote execution denied by policy",
      runner: :fake_remote,
      target: command.target,
      argv_display: argv_display
    )
  end
end
