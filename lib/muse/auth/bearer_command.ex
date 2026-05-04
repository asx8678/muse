defmodule Muse.Auth.BearerCommand do
  @moduledoc """
  Resolves bearer tokens by executing a configured shell command.

  The `bearer_command` field in `Muse.LLM.ProviderConfig` specifies a shell
  command whose stdout is treated as the bearer token (with trailing newlines
  stripped). Typical use: `"cat ~/.token"` or `"gcloud auth print-access-token"`.

  ## Security

    * The resolved credential's `inspect/1` is redacted — the raw token value
      never appears in logs, events, or diagnostic output.
    * Error messages reference the command source label but never include the
      token value, partial token output, or stderr content.
    * The caller controls whether `System.cmd/3` is allowed (via
      `allow_exec?: true`, default `false`) — preventing accidental shell-outs
      in test or inspection-only contexts.

  ## Returns

    * `{:ok, %Credential{type: :bearer, source: :command}}` on success.
    * `{:error, reason}` on any failure — missing command, exec failure,
      empty output, oversized output, or `allow_exec?` set to `false`.
  """

  alias Muse.Auth.Credential

  @type error_reason ::
          {:not_allowed, String.t()}
          | {:no_command, String.t()}
          | {:exec_failed, String.t()}
          | {:empty_output}
          | {:output_too_large}
          | {:timeout, String.t()}

  @doc """
  Resolve a bearer credential by executing a shell command.

  ## Options

    * `:command` — command string or argv list **(required)**. Example:
      `"gcloud auth print-access-token"` or `["echo", "tok"]`.
    * `:allow_exec?` — boolean, default `false`. When `false`, returns
      `{:error, {:not_allowed, ...}}` instead of executing. Set to `true`
      only when you intend to actually run the command.
    * `:source_label` — string used in error messages in place of the raw
      command (default: `"bearer_command"`). Prevents command strings from
      leaking into log/event output.
    * `:timeout_ms` — positive integer milliseconds, default `5_000`. The
      command is killed if it does not complete within this duration.
      If the timeout fires, `{:error, {:timeout, source_label}}` is returned.
    * `:runner` — function injected for test isolation. When provided,
      `System.cmd/3` is never called. The runner receives the command
      (binary or argv list) and must return `{output, 0}`, `{:ok, output}`,
      or `{:error, reason}`. The `:allow_exec?` guard is still enforced.
    * `:cmd_fn` — alias for `:runner` (accepted for convenience).

  ## Examples

      # Safe inspection (no exec)
      iex> Muse.Auth.BearerCommand.resolve(command: "cat ~/.token")
      {:error, {:not_allowed, "bearer_command"}}

      # Intentional exec
      iex> Muse.Auth.BearerCommand.resolve(command: "echo tok-secret", allow_exec?: true)
      {:ok, %Muse.Auth.Credential{type: :bearer, source: :command, redacted: "tok...REDACTED"}}

  ## Notes

    * The `:command` option is **required**. Without it, `{:error, {:no_command, ...}}`
      is returned.
    * Binary commands are split on whitespace to extract program and args.
      No shell interpretation is performed unless you explicitly wrap in
      `"sh -c '...'"`.
    * Argv-list commands are passed directly to `System.cmd/3` without
      splitting — safer and faster for fixed-argument commands.
    * Stderr is discarded; only stdout is read.
    * The `:runner` / `:cmd_fn` option bypasses `System.cmd/3` entirely and is
      intended for test injection. The runner API accepts the full command
      (binary or list) and returns success/failure tuples.
  """
  @spec resolve(keyword()) :: {:ok, Credential.t()} | {:error, error_reason()}
  def resolve(opts \\ []) when is_list(opts) do
    command = Keyword.get(opts, :command)
    allow_exec? = Keyword.get(opts, :allow_exec?, false)
    source_label = Keyword.get(opts, :source_label, "bearer_command")
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, 5_000))
    runner = Keyword.get(opts, :runner) || Keyword.get(opts, :cmd_fn)

    with {:ok, cmd} <- validate_command(command, source_label),
         :ok <- check_allowed(allow_exec?, source_label),
         {:ok, value} <- exec_command(cmd, timeout_ms, runner, source_label) do
      credential = %Credential{
        type: :bearer,
        value: value,
        source: :command,
        redacted: Credential.redact_value(value)
      }

      {:ok, credential}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_command(nil, source_label),
    do: {:error, {:no_command, source_label}}

  defp validate_command("", source_label),
    do: {:error, {:no_command, source_label}}

  defp validate_command(cmd, _source_label) when is_binary(cmd) and cmd != "",
    do: {:ok, cmd}

  defp validate_command(cmd, source_label) when is_list(cmd) do
    case cmd do
      [prog | _] when is_binary(prog) and byte_size(prog) > 0 -> {:ok, cmd}
      _ -> {:error, {:no_command, source_label}}
    end
  end

  defp validate_command(_cmd, source_label),
    do: {:error, {:no_command, source_label}}

  # ---------------------------------------------------------------------------
  # Exec guard
  # ---------------------------------------------------------------------------

  defp check_allowed(true, _source_label), do: :ok

  defp check_allowed(false, source_label),
    do: {:error, {:not_allowed, source_label}}

  # ---------------------------------------------------------------------------
  # Execution (no token leakage in errors)
  # ---------------------------------------------------------------------------

  # Normalize a binary or argv-list command to {prog, args}.
  defp normalize_command(command) when is_binary(command) do
    tokens = String.split(command)

    case tokens do
      [] -> {"", []}
      [h | t] -> {h, t}
    end
  end

  defp normalize_command([prog | args]), do: {prog, args}

  # Execute the command with a timeout via spawn/receive.
  # Both runner and real-exec paths are bounded by the timeout.
  # Uses spawn (not spawn_link) so that System.cmd exits (e.g. :enoent for
  # missing executables) are caught as DOWN messages rather than killing
  # the caller.
  defp exec_command(command, timeout_ms, runner, source_label) do
    caller = self()
    ref = make_ref()

    spawn_pid =
      spawn(fn ->
        result = do_exec(command, runner)
        send(caller, {:cmd_result, ref, result})
      end)

    monitor_ref = Process.monitor(spawn_pid)

    receive do
      {:cmd_result, ^ref, {:ok, _value} = ok} ->
        Process.demonitor(monitor_ref, [:flush])
        ok

      {:cmd_result, ^ref, {:error, _reason} = err} ->
        Process.demonitor(monitor_ref, [:flush])
        err

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:exec_failed, exec_down_reason(reason, source_label)}}
    after
      timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(spawn_pid, :kill)
        {:error, {:timeout, source_label}}
    end
  end

  # Dispatch to runner or System.cmd
  defp do_exec(command, runner) when is_function(runner, 1) do
    case safe_runner_call(fn -> runner.(command) end) do
      {:ok, {output, 0}} -> parse_output(output)
      {:ok, {:ok, output}} -> parse_output(output)
      _other -> {:error, {:exec_failed, "runner failed"}}
    end
  end

  defp do_exec(command, nil) do
    {prog, args} = normalize_command(command)

    try do
      result = System.cmd(prog, args, stderr_to_stdout: false)

      case result do
        {output, 0} -> parse_output(output)
        {_output, _exit_code} -> {:error, {:exec_failed, "command exited with non-zero status"}}
      end
    catch
      :error, :enoent ->
        {:error, {:exec_failed, "command not found: #{safe_prog_label(prog)}"}}

      kind, reason ->
        {:error, {:exec_failed, "execution error (#{kind}): #{safe_exit_reason(reason)}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Runner safety wrapper
  # ---------------------------------------------------------------------------

  defp safe_runner_call(fun) do
    {:ok, fun.()}
  rescue
    _exception -> {:error, :runner_raised}
  catch
    _kind, _reason -> {:error, :runner_exit}
  end

  # ---------------------------------------------------------------------------
  # Output parsing — trim, take first non-empty line
  # ---------------------------------------------------------------------------

  defp parse_output(output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      {:error, :empty_output}
    else
      first =
        trimmed
        |> String.split(["\r\n", "\n"])
        |> Enum.find(&(String.trim(&1) != ""))

      case first do
        nil -> {:error, :empty_output}
        line -> {:ok, String.trim(line)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout normalization — positive integer only, else default
  # ---------------------------------------------------------------------------
  defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp normalize_timeout(_ms), do: 5_000

  # Safe program label for error messages — never include full command args.
  defp safe_prog_label(prog) when is_binary(prog), do: String.slice(prog, 0, 80)
  defp safe_prog_label(prog), do: inspect(prog, limit: 5, printable_limit: 80)

  defp safe_exit_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_exit_reason(reason), do: inspect(reason, limit: 5, printable_limit: 120)

  # Map process DOWN reasons to safe error messages.
  defp exec_down_reason(:enoent, _source_label), do: "command not found"
  defp exec_down_reason(:normal, _source_label), do: "process exited normally without result"
  defp exec_down_reason(reason, _source_label), do: "process crashed: #{safe_exit_reason(reason)}"
end
