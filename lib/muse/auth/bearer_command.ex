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
    * The caller controls whether command execution is allowed (via
      `allow_exec?: true`, default `false`) — preventing accidental shell-outs
      in test or inspection-only contexts.
    * Command execution is bounded: stdout is capped at `max_stdout_bytes`
      (default 4 096). Output exceeding this limit fails with
      `{:error, {:output_too_large, source_label}}` before the raw data can
      exhaust memory.
    * A finite timeout (`timeout_ms`, default 5 000) terminates the command
      process group on expiry — no orphaned child processes.
    * Child processes receive only allowlisted environment variables via
      `Muse.Execution.Env`; secrets (API keys, tokens) are never inherited.

  ## Returns

    * `{:ok, %Credential{type: :bearer, source: :command}}` on success.
    * `{:error, reason}` on any failure — missing command, exec failure,
      empty output, oversized output, timeout, or `allow_exec?` set to `false`.
  """

  alias Muse.Auth.Credential
  alias Muse.Execution.{Env, ProcessGroup}

  import Bitwise

  @default_max_stdout_bytes 4_096
  @default_timeout_ms 5_000
  @force_kill_after_ms 100

  @type error_reason ::
          {:not_allowed, String.t()}
          | {:no_command, String.t()}
          | {:exec_failed, String.t()}
          | {:empty_output}
          | {:output_too_large, String.t()}
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
      command process group is killed if it does not complete within this
      duration. If the timeout fires, `{:error, {:timeout, source_label}}`
      is returned.
    * `:max_stdout_bytes` — positive integer, default `4_096`. Maximum stdout
      bytes accepted from the command. If the command produces more output,
      the process group is terminated and
      `{:error, {:output_too_large, source_label}}` is returned. This prevents
      memory exhaustion from misconfigured or compromised credential helpers.
    * `:runner` — function injected for test isolation. When provided,
      `System.cmd/3` is never called. A one-arity runner receives the command
      (binary or argv list); a two-arity runner receives the command and a
      keyword opts list. It must return `{output, 0}`, `{:ok, output}`, or
      `{:error, reason}`. The `:allow_exec?` guard is still enforced. Runner
      output is also validated against `:max_stdout_bytes`.
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
    * Argv-list commands are passed directly without splitting — safer and
      faster for fixed-argument commands.
    * Stderr is captured into the same stream as stdout (`:stderr_to_stdout`)
      to prevent credential helpers from leaking tokens to the BEAM console.
      Both streams count toward `max_stdout_bytes`. Output parsing takes the
      last non-empty line, which correctly extracts the token when stderr
      diagnostics precede the token on stdout.
    * The `:runner` / `:cmd_fn` option bypasses real execution entirely and is
      intended for test injection. The runner API accepts the full command
      (binary or list) and returns success/failure tuples.
  """
  @spec resolve(keyword()) :: {:ok, Credential.t()} | {:error, error_reason()}
  def resolve(opts \\ []) when is_list(opts) do
    command = Keyword.get(opts, :command)
    allow_exec? = Keyword.get(opts, :allow_exec?, false)
    source_label = Keyword.get(opts, :source_label, "bearer_command")
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms))

    max_stdout =
      normalize_max_stdout(Keyword.get(opts, :max_stdout_bytes, @default_max_stdout_bytes))

    runner = Keyword.get(opts, :runner) || Keyword.get(opts, :cmd_fn)

    with {:ok, cmd} <- validate_command(command, source_label),
         :ok <- check_allowed(allow_exec?, source_label),
         {:ok, value} <- exec_command(cmd, timeout_ms, max_stdout, runner, source_label) do
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
  # Execution dispatch — port-based for real commands, spawn-based for runners
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

  # Port-based bounded execution for real commands.
  # Uses Port.open with sanitized env, byte-capped output collection,
  # and process-group cleanup on timeout/oversized output.
  defp exec_command(command, timeout_ms, max_stdout, nil, source_label) do
    exec_with_port(command, timeout_ms, max_stdout, source_label)
  end

  # Spawn-based execution for test runner injection.
  # Bounded by timeout and max_stdout_bytes validation.
  defp exec_command(command, timeout_ms, max_stdout, runner, source_label)
       when is_function(runner, 1) or is_function(runner, 2) do
    exec_with_runner(command, timeout_ms, max_stdout, runner, source_label)
  end

  defp exec_command(_command, _timeout_ms, _max_stdout, _runner, _source_label) do
    {:error, {:exec_failed, "runner must be a one- or two-arity function"}}
  end

  # -- Port-based bounded execution (real commands) ----------------------------

  defp exec_with_port(command, timeout_ms, max_stdout, source_label) do
    {prog, args} = normalize_command(command)

    with {:ok, exe_path} <- resolve_executable(prog),
         :ok <- validate_argv(args) do
      env = Env.port_env(%{}, inherit?: true)

      # Use stderr_to_stdout to capture and bound stderr output alongside
      # stdout. This prevents credential helpers from leaking tokens to
      # the BEAM's stderr log surface. Both streams count toward
      # max_stdout_bytes, keeping the bound enforced.
      port_opts = [
        {:args, args},
        :use_stdio,
        :stderr_to_stdout,
        :binary,
        :exit_status,
        {:env, env}
      ]

      try do
        port = Port.open({:spawn_executable, exe_path}, port_opts)

        try do
          deadline = System.monotonic_time(:millisecond) + timeout_ms
          collect_port_output(port, deadline, max_stdout, 0, "", source_label)
        after
          if Port.info(port) != nil, do: Port.close(port)
        end
      catch
        :error, reason ->
          {:error, {:exec_failed, "port open failed: #{safe_exit_reason(reason)}"}}
      end
    else
      {:error, reason} -> {:error, {:exec_failed, reason}}
    end
  end

  defp validate_argv(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, "all command arguments must be strings"}
    end
  end

  defp validate_argv(_), do: {:error, "command arguments must be a list of strings"}

  defp resolve_executable(prog) do
    cond do
      prog in [nil, ""] ->
        {:error, "command not found"}

      Path.type(prog) == :absolute ->
        cond do
          not safe_absolute_path?(prog) ->
            {:error, "executable path rejected for safety"}

          not File.exists?(prog) ->
            {:error, "executable not found"}

          not is_executable?(prog) ->
            {:error, "executable not accessible"}

          true ->
            {:ok, prog}
        end

      true ->
        case System.find_executable(prog) do
          nil -> {:error, "command not found"}
          path -> {:ok, path}
        end
    end
  end

  # Best-effort executability check. Returns true if the file appears
  # executable (has execute permission for the current user).
  defp is_executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        # Check if any execute bit is set (owner, group, or other)
        band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp safe_absolute_path?(path) do
    not String.contains?(path, "..") and
      not String.contains?(path, "~") and
      not control_chars?(path)
  end

  defp control_chars?(s) when is_binary(s) do
    String.match?(s, ~r/[[:cntrl:]]/)
  end

  defp control_chars?(_), do: false

  # Collect output from a port with byte-level capping and deadline.
  # Stops collecting and terminates the process group when:
  #   - Output exceeds max_stdout_bytes → {:error, {:output_too_large, ...}}
  #   - Deadline passes → {:error, {:timeout, ...}}
  #   - Process exits 0 → parse_output and validate token
  #   - Process exits non-zero → {:error, {:exec_failed, ...}}
  #
  # The raw stdout is NEVER logged. Only reason/metadata appear in errors.
  defp collect_port_output(port, deadline, max_stdout, byte_count, acc, source_label) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      cleanup = ProcessGroup.terminate_group(port, force_after_ms: @force_kill_after_ms)
      _ = cleanup
      {:error, {:timeout, source_label}}
    else
      receive do
        {^port, {:data, data}} ->
          new_count = byte_count + byte_size(data)

          if new_count > max_stdout do
            # Output exceeded the safe limit — kill the process group and fail.
            # The raw output is intentionally NOT included in the error.
            cleanup = ProcessGroup.terminate_group(port, force_after_ms: @force_kill_after_ms)
            _ = cleanup
            {:error, {:output_too_large, source_label}}
          else
            collect_port_output(port, deadline, max_stdout, new_count, acc <> data, source_label)
          end

        {^port, {:exit_status, 0}} ->
          parse_output(acc)

        {^port, {:exit_status, status}} ->
          {:error, {:exec_failed, "command exited with non-zero status (#{status})"}}
      after
        remaining ->
          cleanup = ProcessGroup.terminate_group(port, force_after_ms: @force_kill_after_ms)
          _ = cleanup
          {:error, {:timeout, source_label}}
      end
    end
  end

  # -- Spawn-based execution (test runner injection) ---------------------------

  defp exec_with_runner(command, timeout_ms, max_stdout, runner, source_label) do
    caller = self()
    ref = make_ref()

    spawn_pid =
      spawn(fn ->
        result = do_exec_with_runner(command, max_stdout, runner, source_label)
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

  defp do_exec_with_runner(command, max_stdout, runner, source_label) do
    runner_result =
      cond do
        is_function(runner, 1) ->
          safe_runner_call(fn -> runner.(command) end)

        is_function(runner, 2) ->
          safe_runner_call(fn -> runner.(command, source_label: source_label) end)
      end

    case runner_result do
      {:ok, {output, 0}} -> validate_runner_output(output, max_stdout, source_label)
      {:ok, {:ok, output}} -> validate_runner_output(output, max_stdout, source_label)
      _other -> {:error, {:exec_failed, "runner failed"}}
    end
  end

  defp validate_runner_output(output, max_stdout, source_label) when is_binary(output) do
    if byte_size(output) > max_stdout do
      {:error, {:output_too_large, source_label}}
    else
      parse_output(output)
    end
  end

  defp validate_runner_output(_output, _max_stdout, _source_label) do
    {:error, {:exec_failed, "runner output must be a string"}}
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
  # Output parsing — trim, take last non-empty line, validate token shape
  #
  # With :stderr_to_stdout, stderr diagnostics may precede the actual token
  # on stdout. Bearer tokens are typically the last line of output, so we
  # take the last non-empty line rather than the first. This is correct for
  # single-line output (first == last) and robust for merged stderr.
  # ---------------------------------------------------------------------------

  defp parse_output(output) when is_binary(output) do
    if String.valid?(output) do
      output
      |> String.trim()
      |> parse_trimmed_output()
    else
      {:error, {:exec_failed, "output is not valid UTF-8"}}
    end
  end

  defp parse_output(_output), do: {:error, {:exec_failed, "output must be a string"}}

  defp parse_trimmed_output(""), do: {:error, :empty_output}

  defp parse_trimmed_output(trimmed) do
    trimmed
    |> String.split(["\r\n", "\n"])
    |> Enum.reverse()
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil ->
        {:error, :empty_output}

      line ->
        line
        |> String.trim()
        |> validate_token()
    end
  end

  defp validate_token(token) do
    cond do
      not String.printable?(token) ->
        {:error, {:exec_failed, "output contains non-printable characters"}}

      String.match?(token, ~r/\s/u) ->
        {:error, {:exec_failed, "output contains whitespace"}}

      true ->
        {:ok, token}
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout / max_stdout normalization — positive integer only, else default
  # ---------------------------------------------------------------------------
  defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp normalize_timeout(_ms), do: @default_timeout_ms

  defp normalize_max_stdout(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_stdout(_bytes), do: @default_max_stdout_bytes

  defp safe_exit_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_exit_reason(_reason), do: "unknown"

  # Map process DOWN reasons to safe error messages.
  defp exec_down_reason(:enoent, _source_label), do: "command not found"
  defp exec_down_reason(:normal, _source_label), do: "process exited normally without result"

  defp exec_down_reason(reason, _source_label) when is_atom(reason),
    do: "process crashed: #{safe_exit_reason(reason)}"

  defp exec_down_reason(_reason, _source_label), do: "process crashed"

  # -- Public configuration accessors -------------------------------------------

  @doc """
  Return the default maximum stdout bytes for bearer command execution.
  """
  @spec default_max_stdout_bytes() :: pos_integer()
  def default_max_stdout_bytes, do: @default_max_stdout_bytes

  @doc """
  Return the default timeout in milliseconds for bearer command execution.
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms
end
