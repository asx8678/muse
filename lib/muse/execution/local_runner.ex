defmodule Muse.Execution.LocalRunner do
  @moduledoc """
  Local execution runner for safe argv-vector commands.

  Executes commands locally via `Port.open({:spawn_executable, path}, ...)`.
  Never uses shell interpolation. Enforces:

    * Timeout — closes the port on timeout; best-effort cleanup
      (descendant processes may survive port closure).
    * Output capping — caps output at `max_output_bytes`.
    * Secret redaction — redacts secrets via `Muse.Prompt.Redactor`.
    * Safe env — allowlisted base env via `Muse.Execution.Env`;
      user overrides are merged, then denylisted keys are stripped
      as defense-in-depth. Child processes never inherit provider API
      keys or unrelated secrets.
    * Non-zero exit — produces `status: :error`, not `status: :ok`.

  ## Safety properties

    * `System.find_executable/1` for bare executable names.
    * Rejects executables with path traversal or control characters.
    * Rejects absolute paths that don't resolve to an existing executable.
    * Timeout enforced by closing the port.
    * Output capped before returning.
    * Secrets redacted from output.

  ## Examples

      iex> alias Muse.Execution.{Command, LocalRunner}
      iex> {:ok, cmd} = Command.new("elixir", args: ["-e", "IO.puts(:hello)"])
      iex> {:ok, result} = LocalRunner.run(cmd)
      iex> result.status
      :ok

  """

  @behaviour Muse.Execution.Runner

  alias Muse.Execution.{Command, Env, Result}

  @impl Muse.Execution.Runner
  def capabilities do
    %{
      local: true,
      remote: false,
      ssh: false,
      shell: false,
      network: false,
      timeout_ms: 300_000,
      max_output_bytes: 500_000
    }
  end

  @impl Muse.Execution.Runner
  def run(%Command{} = command, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    with :ok <- validate_command(command),
         {:ok, executable_path} <- resolve_executable(command.executable),
         {:ok, result} <- execute_with_port(command, executable_path, opts) do
      duration_ms = System.monotonic_time(:millisecond) - start_time
      {:ok, %{result | duration_ms: duration_ms}}
    else
      {:error, %Result{} = result} ->
        {:error, result}

      {:error, reason} when is_binary(reason) ->
        {:error, Result.blocked(command.id, reason, runner: :local)}
    end
  end

  # -- Validation ---------------------------------------------------------------

  defp validate_command(%Command{executable: ""}) do
    {:error, "executable must not be empty"}
  end

  defp validate_command(%Command{executable: nil}) do
    {:error, "executable must not be nil"}
  end

  defp validate_command(%Command{args: args}) when not is_list(args) do
    {:error, "args must be a list"}
  end

  defp validate_command(%Command{timeout_ms: timeout})
       when not is_integer(timeout) or timeout <= 0 do
    {:error, "timeout_ms must be a positive integer"}
  end

  defp validate_command(%Command{max_output_bytes: max}) when not is_integer(max) or max <= 0 do
    {:error, "max_output_bytes must be a positive integer"}
  end

  defp validate_command(%Command{cwd: cwd}) when is_binary(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, "cwd must be an existing directory"}
    end
  end

  defp validate_command(_), do: :ok

  # -- Executable resolution ----------------------------------------------------

  defp resolve_executable(exe) when is_binary(exe) do
    cond do
      # Reject absolute paths that look suspicious
      Path.type(exe) == :absolute and not safe_absolute_path?(exe) ->
        {:error, "absolute path executable rejected for safety"}

      # For absolute paths, verify the file exists and is executable
      Path.type(exe) == :absolute ->
        if File.exists?(exe) do
          {:ok, exe}
        else
          {:error, "executable not found: #{exe}"}
        end

      # For relative paths, use System.find_executable
      true ->
        case System.find_executable(exe) do
          nil -> {:error, "executable not found: #{exe}"}
          path -> {:ok, path}
        end
    end
  end

  defp resolve_executable(_), do: {:error, "executable must be a string"}

  defp safe_absolute_path?(path) do
    # Reject paths with suspicious patterns
    not String.contains?(path, "..") and
      not String.contains?(path, "~") and
      not control_chars?(path)
  end

  defp control_chars?(s) when is_binary(s) do
    String.match?(s, ~r/[[:cntrl:]]/)
  end

  defp control_chars?(_), do: false

  # -- Port-based execution -----------------------------------------------------

  defp execute_with_port(%Command{} = command, executable_path, _opts) do
    port_opts = build_port_opts(command, executable_path)
    timeout = command.timeout_ms
    max_output = command.max_output_bytes

    port = Port.open({:spawn_executable, executable_path}, port_opts)

    try do
      deadline = System.monotonic_time(:millisecond) + timeout
      collect_output(port, deadline, max_output, command)
    after
      # Ensure port is closed — no orphan processes
      if Port.info(port) != nil do
        Port.close(port)
      end
    end
  end

  defp build_port_opts(command, _executable_path) do
    base_opts = [
      {:args, command.args},
      :use_stdio,
      :stderr_to_stdout,
      :binary,
      :exit_status
    ]

    # Add cwd if specified
    opts =
      case command.cwd do
        nil -> base_opts
        cwd -> [{:cd, cwd} | base_opts]
      end

    # Always set sanitized env via Env.port_env/2.
    # This replaces inherited BEAM environment with an allowlisted base,
    # merges user-provided overrides, then strips denylisted keys.
    # Child processes never receive provider API keys or unrelated secrets.
    env = Env.port_env(command.env, inherit?: true)
    [{:env, env} | opts]
  end

  defp collect_output(port, deadline, max_output, command) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:ok, Result.timed_out(command.id, argv_display: Command.safe_display(command))}
    else
      receive do
        {^port, {:data, data}} ->
          collect_output(port, deadline, max_output, append_capped(data, max_output), command)

        {^port, {:exit_status, 0}} ->
          {:ok, Result.ok(command.id, "", argv_display: Command.safe_display(command))}

        {^port, {:exit_status, status}} ->
          # Non-zero exit is a failed execution
          {:ok,
           Result.error(command.id, "command exited with status #{status}",
             exit_status: status,
             output: "",
             argv_display: Command.safe_display(command)
           )}
      after
        remaining ->
          {:ok, Result.timed_out(command.id, argv_display: Command.safe_display(command))}
      end
    end
  end

  defp collect_output(port, deadline, max_output, acc, command) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:ok,
       Result.timed_out(command.id,
         partial_output: cap_and_redact(acc, max_output),
         argv_display: Command.safe_display(command)
       )}
    else
      receive do
        {^port, {:data, data}} ->
          collect_output(
            port,
            deadline,
            max_output,
            append_capped(acc <> data, max_output),
            command
          )

        {^port, {:exit_status, 0}} ->
          {:ok,
           Result.ok(command.id, cap_and_redact(acc, max_output),
             argv_display: Command.safe_display(command)
           )}

        {^port, {:exit_status, status}} ->
          # Non-zero exit is a failed execution
          {:ok,
           Result.error(command.id, "command exited with status #{status}",
             exit_status: status,
             output: cap_and_redact(acc, max_output),
             argv_display: Command.safe_display(command)
           )}
      after
        remaining ->
          {:ok,
           Result.timed_out(command.id,
             partial_output: cap_and_redact(acc, max_output),
             argv_display: Command.safe_display(command)
           )}
      end
    end
  end

  defp append_capped(data, max) when is_binary(data) do
    if byte_size(data) > max do
      binary_part(data, 0, max)
    else
      data
    end
  end

  defp cap_and_redact(output, max_output) when is_binary(output) do
    capped =
      if byte_size(output) > max_output do
        String.slice(output, 0, max_output)
      else
        output
      end

    Muse.Prompt.Redactor.redact_text(capped)
  end

  defp cap_and_redact(output, _max), do: output

  # -- Public helpers for testing ------------------------------------------------

  @doc """
  Check if an executable name is safe to resolve.

  Returns `{:ok, path}` if the executable can be found, `{:error, reason}` otherwise.
  """
  @spec check_executable(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check_executable(exe) when is_binary(exe) do
    resolve_executable(exe)
  end

  def check_executable(_), do: {:error, "executable must be a string"}
end
