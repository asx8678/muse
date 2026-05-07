defmodule Muse.Execution.SSHRunner do
  @moduledoc """
  SSH remote execution runner — approval-bound, deny-by-default.

  Implements both `Muse.Execution.Runner` and `Muse.Execution.RemoteRunner`
  behaviours. Executes commands via SSH using a pluggable SSH client adapter.

  ## Safety invariants

    * **Deny-by-default**: `run/2` without a valid `execution_context` in opts
      is always denied. No SSH connection is attempted.
    * **Approval-bound**: The execution context must contain a valid
      `:remote_execution` approval that routes to this runner via
      `Policy.resolve_target/2`.
    * **No shell interpolation**: Commands are passed as argv vectors; each
      argument is individually shell-quoted to produce a safe POSIX command
      string. No `sh -c` with raw interpolation.
    * **No env forwarding**: `command.env` must be empty for SSH initially.
    * **No cwd**: `command.cwd` must be nil for SSH initially.
    * **Host key verification**: Required; no silent host acceptance.
    * **Credential safety**: Credentials are resolved via
      `SSHCredentialResolver` and never stored, logged, or emitted.
    * **Output capping and redaction**: Identical to LocalRunner.
    * **Best-effort disconnect**: Never raises on disconnect.

  ## Adapter

  Uses `Muse.Execution.ErlangSSHClient` by default for real SSH connections.
  Tests inject `Muse.Execution.FakeSSHClient` via opts for deterministic,
  offline behavior. Default `mix test` must never require a live SSH server.

  ## Capabilities

      %{
        local: false,
        remote: true,
        ssh: true,
        shell: false,
        network: true,
        protocols: [:ssh],
        timeout_ms: 60_000,
        max_output_bytes: 50_000
      }

  ## Credential model

  Only `identity_file` credential references are supported initially:
  `%{type: "identity_file", path: "/path/to/key"}`. See
  `Muse.Execution.SSHCredentialResolver` for details.
  """

  @behaviour Muse.Execution.Runner
  @behaviour Muse.Execution.RemoteRunner

  alias Muse.Execution.{Command, Result, Target, TargetRegistry}

  @default_ssh_client Muse.Execution.ErlangSSHClient
  @default_timeout_ms 60_000
  @default_max_output_bytes 50_000

  # -- Runner behaviour ---------------------------------------------------------

  @impl Muse.Execution.Runner
  def capabilities do
    %{
      local: false,
      remote: true,
      ssh: true,
      shell: false,
      network: true,
      protocols: [:ssh],
      timeout_ms: @default_timeout_ms,
      max_output_bytes: @default_max_output_bytes
    }
  end

  @impl Muse.Execution.Runner
  def run(%Command{} = command, opts) do
    # REQUIRE valid execution context — deny-by-default
    execution_context = Keyword.get(opts, :execution_context)

    if valid_execution_context?(execution_context, command) do
      execute_with_context(command, opts, execution_context)
    else
      {:error,
       Result.denied(command.id, "SSH execution requires valid approval-bound execution context",
         target: command.target,
         runner: :ssh
       )}
    end
  end

  # -- RemoteRunner behaviour ---------------------------------------------------

  @impl Muse.Execution.RemoteRunner
  def connect(target, opts \\ []) do
    ssh_client = ssh_client_module(opts)
    target_map = target_to_connect_map(target, opts)
    ssh_client.connect(target_map, opts)
  end

  @impl Muse.Execution.RemoteRunner
  def disconnect(connection_ref) do
    # Best-effort — never raises
    ssh_client = @default_ssh_client
    ssh_client.disconnect(connection_ref)
  rescue
    _ -> :ok
  end

  @impl Muse.Execution.RemoteRunner
  def remote_run(connection_ref, %Command{} = command, opts) do
    execution_context = Keyword.get(opts, :execution_context)

    with true <- valid_execution_context?(execution_context, command),
         :ok <- validate_ssh_command(command) do
      do_remote_run(connection_ref, command, opts)
    else
      _ ->
        Result.denied(
          command.id,
          "SSH remote_run requires valid approval-bound execution context",
          target: command.target,
          runner: :ssh
        )
    end
  end

  defp do_remote_run(connection_ref, %Command{} = command, opts) do
    ssh_client = ssh_client_module(opts)

    command_string = build_safe_command_string(command)

    start_time = System.monotonic_time(:millisecond)

    exec_opts = [{:timeout_ms, command.timeout_ms}]

    fake_keys = [:fake_outcome, :fake_stdout, :fake_stderr, :fake_exit_status]

    exec_opts =
      Enum.reduce(fake_keys, exec_opts, fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, val} -> Keyword.put(acc, key, val)
          :error -> acc
        end
      end)

    case ssh_client.exec(connection_ref, command_string, exec_opts) do
      {:ok, exec_result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        build_result_from_exec(command, exec_result, duration_ms)

      {:error, reason} ->
        Result.error(command.id, reason,
          runner: :ssh,
          target: command.target,
          argv_display: Command.safe_display(command)
        )
    end
  end

  # -- Private: execution context validation ------------------------------------

  defp valid_execution_context?(context, command) when is_map(context) do
    # Bind policy validation to the actual command passed to SSHRunner.run/2.
    # Do not trust a caller-supplied context[:command], which could be stale or
    # intentionally different from the command being executed.
    context_with_actual_command = Map.put(context, :command, command)

    case Muse.Execution.Policy.resolve_target(command.target, context_with_actual_command) do
      {:ok, runner_module} when runner_module == __MODULE__ -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_execution_context?(_context, _command), do: false

  # -- Private: execution with context -------------------------------------------

  defp execute_with_context(command, opts, context) do
    # Pre-flight validation for SSH-specific constraints
    with :ok <- validate_ssh_command(command),
         {:ok, target} <- resolve_target_from_context(context, command) do
      result = execute_on_target(command, opts, target)
      wrap_result(result)
    else
      {:error, reason} ->
        {:error,
         Result.denied(command.id, reason,
           target: command.target,
           runner: :ssh
         )}
    end
  end

  # -- Private: SSH command validation ------------------------------------------

  defp validate_ssh_command(%Command{env: env}) when env != %{} do
    {:error, "SSH execution does not support environment variables initially"}
  end

  defp validate_ssh_command(%Command{cwd: cwd}) when cwd != nil do
    {:error, "SSH execution does not support remote cwd initially"}
  end

  defp validate_ssh_command(_command), do: :ok

  # -- Private: target resolution from context ----------------------------------

  defp resolve_target_from_context(context, _command) do
    approval = extract_approval(context)
    target_id = effective_target_id(context, approval)

    case TargetRegistry.fetch(target_id) do
      {:ok, %Target{protocol: :ssh} = target} ->
        {:ok, target}

      {:ok, %Target{protocol: other}} ->
        {:error, "SSH runner received target with protocol :#{other}; only :ssh is supported"}

      {:error, :not_found} ->
        {:error, "SSH target not found in registry"}
    end
  rescue
    _ -> {:error, "SSH target lookup failed"}
  end

  defp extract_approval(context) do
    case Map.get(context, :approval) do
      nil -> Map.get(context, :remote_approval)
      value -> value
    end
  end

  defp effective_target_id(context, approval) do
    (approval && map_get(approval, :target_id)) || map_get(context, :target_id)
  end

  defp map_get(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_string(key))
      value -> value
    end
  end

  defp map_get(_, _), do: nil

  # -- Private: execution on target ----------------------------------------------

  defp execute_on_target(command, opts, target) do
    ssh_client = ssh_client_module(opts)
    target_map = target_to_connect_map(target, opts)

    case ssh_client.connect(target_map, opts) do
      {:ok, conn_ref} ->
        try do
          remote_run(conn_ref, command, opts)
        after
          # Best-effort disconnect
          try do
            ssh_client.disconnect(conn_ref)
          rescue
            _ -> :ok
          end
        end

      {:error, reason} ->
        Result.error(command.id, reason,
          runner: :ssh,
          target: command.target,
          argv_display: Command.safe_display(command)
        )
    end
  end

  # -- Private: target to connect map -------------------------------------------

  defp target_to_connect_map(%Target{} = target, _opts) do
    %{
      host: target.host,
      port: target.port || 22,
      user: target.user,
      credential_ref: target.credential_ref,
      connection_opts: target.connection_opts || []
    }
  end

  defp target_to_connect_map(target, _opts) when is_map(target), do: target

  # -- Private: SSH client module resolution -------------------------------------

  defp ssh_client_module(opts) do
    Keyword.get(opts, :ssh_client, @default_ssh_client)
  end

  # -- Private: command string building (POSIX shell quoting) --------------------

  @doc """
  Build a safe POSIX shell command string from a Command's argv vector.

  Each argument is individually shell-quoted to prevent injection.
  The executable and each argument are quoted using single-quote escaping:
  - Wrap in single quotes
  - Escape embedded single quotes as `'\''`

  This ensures that arguments containing spaces, `$()`, `;`, backticks,
  `|`, `>`, `<`, newlines, and other shell metacharacters are safely
  passed as literal strings with no shell interpretation.

  ## Examples

      iex> Muse.Execution.SSHRunner.build_safe_command_string(%Muse.Execution.Command{executable: "echo", args: ["hello world"]})
      "'echo' 'hello world'"

      iex> Muse.Execution.SSHRunner.build_safe_command_string(%Muse.Execution.Command{executable: "echo", args: ["it's", "a test"]})
      "'echo' 'it'\\''s' 'a test'"
  """
  @spec build_safe_command_string(Command.t()) :: String.t()
  def build_safe_command_string(%Command{} = command) do
    [command.executable | command.args]
    |> Enum.map(&shell_quote/1)
    |> Enum.join(" ")
  end

  @doc """
  Shell-quote a single argument using POSIX single-quote escaping.

  Wraps the argument in single quotes and escapes any embedded single
  quotes by ending the current single-quoted segment, inserting an
  escaped single quote, and starting a new single-quoted segment.

  This is the standard POSIX shell quoting technique that is safe
  against all shell metacharacter injection.
  """
  @spec shell_quote(String.t()) :: String.t()
  def shell_quote(arg) when is_binary(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  # -- Private: result building from exec result ---------------------------------

  defp build_result_from_exec(command, exec_result, duration_ms) do
    stdout = cap_and_redact(exec_result[:stdout] || "", command.max_output_bytes)
    stderr_output = exec_result[:stderr] || ""

    combined_output =
      case {stdout, stderr_output} do
        {"", ""} ->
          ""

        {"", s} when is_binary(s) and s != "" ->
          "STDERR: " <> cap_and_redact(s, command.max_output_bytes)

        {o, ""} ->
          o

        {o, s} when is_binary(s) and s != "" ->
          o <> "\nSTDERR: " <> cap_and_redact(s, command.max_output_bytes)

        _ ->
          stdout
      end

    argv_display = Command.safe_display(command)

    cond do
      exec_result.timed_out ->
        Result.timed_out(command.id,
          runner: :ssh,
          target: command.target,
          argv_display: argv_display,
          partial_output: combined_output,
          duration_ms: duration_ms
        )

      exec_result.exit_status == 0 ->
        Result.ok(command.id, combined_output,
          runner: :ssh,
          target: command.target,
          argv_display: argv_display,
          exit_status: 0,
          duration_ms: duration_ms
        )

      exec_result.exit_status != nil ->
        Result.error(command.id, "SSH command exited with status #{exec_result.exit_status}",
          runner: :ssh,
          target: command.target,
          argv_display: argv_display,
          exit_status: exec_result.exit_status,
          output: combined_output,
          duration_ms: duration_ms
        )

      true ->
        Result.error(command.id, "SSH command failed with unknown status",
          runner: :ssh,
          target: command.target,
          argv_display: argv_display,
          output: combined_output,
          duration_ms: duration_ms
        )
    end
  end

  # -- Private: output capping and redaction ------------------------------------

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

  # Wrap a Result.t() in {:ok, result} or {:error, result} per Runner behaviour
  # Only :denied and :blocked statuses are wrapped as {:error, result};
  # all others (including :error with non-zero exit) are {:ok, result}.
  defp wrap_result(%Result{status: status} = result) when status in [:denied, :blocked],
    do: {:error, result}

  defp wrap_result(%Result{} = result), do: {:ok, result}
end
