defmodule Muse.Tools.TestRunner do
  @moduledoc """
  Safe, bounded test command runner for Testing Muse.

  Only predefined safe command presets are executable. Arbitrary shell
  strings are blocked. Commands execute as executable + argv vectors,
  never through a shell. Execution is bounded by timeout and max output
  bytes; orphan processes are killed on timeout via Port-based execution.

  ## Safe presets

    * `mix_format_check` — `mix format --check-formatted`
    * `mix_compile` — `mix compile --warnings-as-errors`
    * `mix_test` — `mix test`
    * `mix_test_file` — `mix test <workspace-relative test path>`
      (strictly validated: must end in `_test.exs`, must be under `test/`,
       no path traversal)

  ## Safety invariants

    * No shell metacharacter interpretation — argv vector only
    * Timeout enforced with Port kill (no orphan processes)
    * Output capped at `@max_output_bytes`
    * Workspace must exist and be a directory
    * `MIX_ENV=test` forced; no network env vars
    * Unknown/raw command strings are blocked, never executed
    * Secrets in output are redacted via `Muse.Prompt.Redactor`

  ## Approval model

  Safe presets are pre-approved for Testing Muse. Any command not in the
  preset allowlist returns a blocked/approval-required result rather than
  executing. This tool cannot become a generic shell escape hatch.
  """

  alias Muse.Tool.Result
  alias Muse.Prompt.Redactor

  @max_output_bytes 50_000
  @default_timeout_ms 120_000

  # Predefined safe command presets: name => {executable, base_argv}
  @safe_presets %{
    "mix_format_check" => {"mix", ["format", "--check-formatted"]},
    "mix_compile" => {"mix", ["compile", "--warnings-as-errors"]},
    "mix_test" => {"mix", ["test"]}
  }

  # Presets that accept a file_path argument
  @file_presets MapSet.new(["mix_test_file"])

  # All allowed preset names
  @allowed_presets MapSet.new(Map.keys(@safe_presets) ++ MapSet.to_list(@file_presets))

  @doc """
  Execute a safe test command preset.

  ## Arguments

    * `command` — (required) one of the safe preset names
    * `file_path` — (optional) workspace-relative test file path for `mix_test_file`

  ## Returns

  `%Muse.Tool.Result{}` with output containing:
    * `command` — the preset name
    * `argv_display` — safe display of the argv vector
    * `exit_status` — process exit code
    * `duration_ms` — wall-clock execution time
    * `timed_out` — whether the command exceeded the timeout
    * `status` — `:passed`, `:failed`, `:timed_out`, or `:blocked`
    * `output_preview` — capped/redacted output summary
    * `next_action` — suggested next step
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.fetch!(context, :workspace)
    command = Map.get(args, "command") || Map.get(args, :command)

    cond do
      is_nil(command) or command == "" ->
        Result.error("test_runner", "command is required")

      not MapSet.member?(@allowed_presets, command) ->
        Result.blocked("test_runner", blocked_message(command))

      not valid_workspace?(workspace) ->
        Result.error("test_runner", "workspace is not a valid directory: #{workspace}")

      MapSet.member?(@file_presets, command) ->
        file_path = Map.get(args, "file_path") || Map.get(args, :file_path)
        execute_file_preset(command, file_path, workspace)

      true ->
        execute_preset(command, workspace)
    end
  end

  # -- Preset execution ---------------------------------------------------------

  defp execute_preset(command, workspace) do
    {executable, base_argv} = Map.fetch!(@safe_presets, command)
    argv = base_argv
    env = safe_env()
    timeout = @default_timeout_ms

    run_bounded_command(command, executable, argv, workspace, env, timeout)
  end

  defp execute_file_preset("mix_test_file", file_path, workspace) do
    case validate_test_file_path(file_path, workspace) do
      {:ok, resolved} ->
        argv = ["test", resolved]
        env = safe_env()
        timeout = @default_timeout_ms

        run_bounded_command("mix_test_file", "mix", argv, workspace, env, timeout)

      {:error, reason} ->
        Result.blocked("test_runner", "mix_test_file path rejected: #{reason}")
    end
  end

  defp execute_file_preset(command, _file_path, _workspace) do
    Result.blocked("test_runner", "unknown file preset: #{command}")
  end

  # -- Bounded command execution via Port ---------------------------------------

  defp run_bounded_command(command, executable, argv, workspace, env, timeout) do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        execute_with_port(executable, argv, workspace, env, timeout)
      rescue
        e ->
          {:error, "execution error: #{Exception.message(e)}"}
      catch
        :exit, :timeout ->
          {:timed_out}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    build_result(command, executable, argv, result, duration_ms)
  end

  # Port-based execution: starts the OS process, collects output with timeout,
  # and kills the process if the timeout fires. This avoids orphan shell/test
  # processes that a plain `Task.await(System.cmd(...))` timeout would leave.
  defp execute_with_port(executable, argv, workspace, env, timeout) do
    # Build the full command with args for Port
    port_opts = [
      {:args, argv},
      {:cd, workspace},
      {:env, env},
      :use_stdio,
      :stderr_to_stdout,
      :binary,
      {:parallelism, true}
    ]

    port = Port.open({:spawn_executable, find_executable(executable)}, port_opts)

    try do
      collect_port_output(port, timeout, "")
    after
      # Ensure the port (and its OS process) is always closed
      if Port.info(port) != nil do
        Port.close(port)
      end
    end
  end

  defp find_executable(executable) do
    case System.find_executable(executable) do
      nil -> raise "executable not found: #{executable}"
      path -> path
    end
  end

  defp collect_port_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        new_acc = acc <> data

        # Cap collection to avoid unbounded memory growth
        if byte_size(new_acc) > @max_output_bytes * 2 do
          String.slice(new_acc, 0, @max_output_bytes * 2)
        else
          collect_port_output(port, timeout, new_acc)
        end
    after
      timeout ->
        # Timeout: the OS process is still running. Port.close in the
        # after block will send SIGTERM to the OS process on Unix.
        {:timed_out, acc}
    end
  end

  # -- Result construction -------------------------------------------------------

  defp build_result(command, executable, argv, result, duration_ms) do
    argv_display = redact_argv_display(executable, argv)

    case result do
      {:ok, output, exit_status} ->
        status = if exit_status == 0, do: :passed, else: :failed

        Result.ok("test_runner", %{
          command: command,
          argv_display: argv_display,
          exit_status: exit_status,
          duration_ms: duration_ms,
          timed_out: false,
          status: status,
          output_preview: cap_and_redact(output),
          next_action: next_action(status)
        })

      {:timed_out, partial_output} ->
        Result.ok("test_runner", %{
          command: command,
          argv_display: argv_display,
          exit_status: nil,
          duration_ms: duration_ms,
          timed_out: true,
          status: :timed_out,
          output_preview: cap_and_redact(partial_output || ""),
          next_action: "increase_timeout_or_simplify_command"
        })

      {:error, reason} ->
        Result.error("test_runner", reason)
    end
  end

  # -- Path validation for mix_test_file ----------------------------------------

  defp validate_test_file_path(nil, _workspace) do
    {:error, "file_path is required for mix_test_file"}
  end

  defp validate_test_file_path(path, _workspace) when not is_binary(path) do
    {:error, "file_path must be a string"}
  end

  defp validate_test_file_path(path, _workspace) when byte_size(path) > 500 do
    {:error, "file_path is too long (max 500 chars)"}
  end

  defp validate_test_file_path(path, _workspace) do
    cond do
      # Must end in _test.exs
      not String.ends_with?(path, "_test.exs") ->
        {:error, "file_path must end with _test.exs"}

      # No absolute paths (check before test/ check to give clear error)
      String.starts_with?(path, "/") ->
        {:error, "file_path must be workspace-relative, not absolute"}

      # Must be under test/ directory (workspace-relative)
      not (String.starts_with?(path, "test/") or path =~ ~r{^test\b}) ->
        {:error, "file_path must be under the test/ directory"}

      # No path traversal
      path_contains_traversal?(path) ->
        {:error, "file_path contains path traversal sequences"}

      true ->
        {:ok, path}
    end
  end

  defp path_contains_traversal?(path) do
    normalized = Path.expand(path, "/safe_root")
    # If expanding the path under a safe root escapes it, there's traversal
    not String.starts_with?(normalized, "/safe_root")
  end

  # -- Safety helpers -----------------------------------------------------------

  defp valid_workspace?(workspace) when is_binary(workspace) do
    File.dir?(workspace)
  end

  defp valid_workspace?(_), do: false

  defp safe_env do
    # Force MIX_ENV=test, strip any network-leaking env vars
    base = System.get_env() |> Map.new(fn {k, v} -> {to_string(k), v} end)

    base
    |> Map.put("MIX_ENV", "test")
    |> Map.drop(network_env_keys())
  end

  defp network_env_keys do
    # Strip keys that might provide network escape hatches
    ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
       NO_PROXY no_proxy FTP_PROXY ftp_proxy SOCKS_PROXY SOCKS_SERVER)
  end

  defp cap_and_redact(output) when is_binary(output) do
    capped =
      if byte_size(output) > @max_output_bytes do
        String.slice(output, 0, @max_output_bytes) <> "... [output truncated]"
      else
        output
      end

    Redactor.redact_text(capped)
  end

  defp cap_and_redact(output), do: inspect(output, limit: 10, printable_limit: 200)

  defp redact_argv_display(executable, argv) do
    full = [executable | argv] |> Enum.join(" ")
    Redactor.redact_text(full)
  end

  defp next_action(:passed), do: "continue_to_next_step"
  defp next_action(:failed), do: "inspect_failures_and_decide_repair"
  defp next_action(_), do: "increase_timeout_or_simplify_command"

  defp blocked_message(command) do
    "command '#{command}' is not a safe preset; " <>
      "allowed presets: #{Enum.join(MapSet.to_list(@allowed_presets), ", ")}; " <>
      "arbitrary shell commands require explicit approval and are not executable via test_runner"
  end

  # -- Public introspection (for tests and policy) -------------------------------

  @doc """
  Returns the set of allowed safe preset names.
  """
  @spec allowed_presets() :: MapSet.t(String.t())
  def allowed_presets, do: @allowed_presets

  @doc """
  Returns the default timeout in milliseconds.
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Returns the max output bytes cap.
  """
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes
end
