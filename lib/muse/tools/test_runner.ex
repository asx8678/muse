defmodule Muse.Tools.TestRunner do
  @moduledoc """
  Safe, bounded test command runner for Testing Muse.

  Only predefined safe command presets are executable. Arbitrary shell
  strings are blocked. Commands execute via the Execution.LocalRunner
  abstraction (PR24) which enforces argv-vector-only execution.

  ## Safe presets

    * `mix_format_check` — `mix format --check-formatted`
    * `mix_compile` — `mix compile --warnings-as-errors`
    * `mix_test` — `mix test`
    * `mix_test_file` — `mix test <workspace-relative test path>`
      (strictly validated: must be an existing regular `_test.exs` file under
       `test/`, with no absolute path, traversal, symlink, ignored, hidden, or
       secret-path access)

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

  alias Muse.Execution.{Command, LocalRunner}
  alias Muse.Execution.Result, as: ExecutionResult
  alias Muse.Prompt.Redactor
  alias Muse.Workspace
  alias Muse.Tool.Result

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

  # -- Bounded command execution via LocalRunner (PR24) ------------------------

  defp run_bounded_command(command, executable, argv, workspace, env, timeout) do
    start_time = System.monotonic_time(:millisecond)

    # Build Command struct for the LocalRunner
    case Command.new(executable,
           args: argv,
           cwd: workspace,
           env: env_to_map(env),
           timeout_ms: timeout,
           max_output_bytes: @max_output_bytes
         ) do
      {:ok, cmd} ->
        result =
          case LocalRunner.run(cmd) do
            {:ok, %ExecutionResult{} = res} -> res
            {:error, %ExecutionResult{} = res} -> res
            {:error, reason} -> Result.error("test_runner", inspect(reason))
          end

        duration_ms = System.monotonic_time(:millisecond) - start_time
        build_result(command, executable, argv, result, duration_ms)

      {:error, reason} ->
        Result.error("test_runner", "command validation failed: #{reason}")
    end
  end

  defp env_to_map(env) when is_list(env) do
    # Handle both charlist and binary key/value pairs from Port-style env
    Map.new(env, fn
      {k, v} when is_list(k) and is_list(v) ->
        # Convert charlist pairs to strings
        {List.to_string(k), List.to_string(v)}

      {k, v} when is_binary(k) and is_binary(v) ->
        {k, v}

      {k, v} ->
        {to_string(k), to_string(v)}
    end)
  end

  defp env_to_map(env) when is_map(env), do: env
  defp env_to_map(_), do: %{}

  # -- Result construction -------------------------------------------------------

  defp build_result(command, executable, argv, %ExecutionResult{} = exec_result, duration_ms) do
    argv_display = redact_argv_display(executable, argv)

    case exec_result.status do
      :ok ->
        # LocalRunner returns :ok only for exit_status 0
        exit_status = exec_result.exit_status || 0
        status = if exit_status == 0, do: :passed, else: :failed

        Result.ok("test_runner", %{
          command: command,
          argv_display: argv_display,
          exit_status: exit_status,
          duration_ms: duration_ms,
          timed_out: false,
          status: status,
          output_preview: cap_and_redact(exec_result.output || ""),
          next_action: next_action(status)
        })

      :error ->
        exit_status = exec_result.exit_status

        if is_integer(exit_status) and exit_status != 0 do
          # Command completed with non-zero exit — test/tool failure, not infra failure.
          # Test failures are reported as verification failures so callers can
          # distinguish them from tool execution errors.
          Result.ok("test_runner", %{
            command: command,
            argv_display: argv_display,
            exit_status: exit_status,
            duration_ms: duration_ms,
            timed_out: false,
            status: :failed,
            output_preview: cap_and_redact(exec_result.output || ""),
            next_action: next_action(:failed)
          })
        else
          # Infra error (no exit status — command blocked, validation failed, etc.)
          Result.error("test_runner", exec_result.error || "execution failed")
        end

      :timed_out ->
        Result.ok("test_runner", %{
          command: command,
          argv_display: argv_display,
          exit_status: nil,
          duration_ms: duration_ms,
          timed_out: true,
          status: :timed_out,
          output_preview: cap_and_redact(exec_result.output || ""),
          next_action: "increase_timeout_or_simplify_command"
        })

      status when status in [:blocked, :denied] ->
        Result.error("test_runner", exec_result.error || "execution failed")
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

  defp validate_test_file_path(path, workspace) do
    cond do
      # Must end in _test.exs
      not String.ends_with?(path, "_test.exs") ->
        {:error, "file_path must end with _test.exs"}

      # No absolute paths (check before test/ check to give clear error)
      Path.type(path) == :absolute ->
        {:error, "file_path must be workspace-relative, not absolute"}

      # Must be lexically under the test/ directory (workspace-relative)
      not String.starts_with?(path, "test/") ->
        {:error, "file_path must be under the test/ directory"}

      # No path traversal, even when it would resolve back under test/
      path_contains_traversal?(path) ->
        {:error, "file_path contains path traversal sequences"}

      # No NUL/control characters in the argv value
      path_contains_control_chars?(path) ->
        {:error, "file_path contains control characters"}

      true ->
        resolve_and_validate_test_file(path, workspace)
    end
  end

  defp path_contains_traversal?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp path_contains_control_chars?(path) do
    String.match?(path, ~r/[[:cntrl:]]/)
  end

  defp resolve_and_validate_test_file(path, workspace) do
    with {:ok, resolved} <- safe_resolve(path, workspace),
         :ok <- ensure_under_test_dir(resolved, workspace),
         :ok <- ensure_regular_non_symlink_file(resolved) do
      {:ok, Path.relative_to(resolved, Path.expand(workspace))}
    end
  end

  defp safe_resolve(path, workspace) do
    {:ok, Workspace.safe_resolve!(path, workspace)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp ensure_under_test_dir(resolved, workspace) do
    test_dir = Path.expand("test", workspace)

    if resolved != test_dir and String.starts_with?(resolved, test_dir <> "/") do
      :ok
    else
      {:error, "file_path must resolve under the test/ directory"}
    end
  end

  defp ensure_regular_non_symlink_file(resolved) do
    case File.lstat(resolved) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "file_path must be a regular test file, not a symlink"}

      {:ok, _stat} ->
        {:error, "file_path must be a regular test file"}

      {:error, :enoent} ->
        {:error, "file_path must be an existing test file"}

      {:error, reason} ->
        {:error, "file_path could not be inspected: #{reason}"}
    end
  end

  # -- Safety helpers -----------------------------------------------------------

  defp valid_workspace?(workspace) when is_binary(workspace) do
    File.dir?(workspace)
  end

  defp valid_workspace?(_), do: false

  defp safe_env do
    # Force MIX_ENV=test, strip any network-leaking env vars. Port.open/2 expects
    # env entries as charlist pairs, unlike System.cmd/3's binary env values.
    System.get_env()
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Map.put("MIX_ENV", "test")
    |> Map.drop(network_env_keys())
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp network_env_keys do
    # Strip keys that might provide network escape hatches
    ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
       NO_PROXY no_proxy FTP_PROXY ftp_proxy SOCKS_PROXY SOCKS_SERVER)
  end

  defp cap_and_redact(output) when is_binary(output) do
    redacted = Redactor.redact_text(output)

    if byte_size(redacted) > @max_output_bytes do
      String.slice(redacted, 0, @max_output_bytes) <> "... [output truncated]"
    else
      redacted
    end
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
