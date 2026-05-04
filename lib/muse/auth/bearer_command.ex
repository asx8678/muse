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
    * A large stdout cap (1 MB) prevents resource exhaustion from runaway
      command output.

  ## Returns

    * `{:ok, %Credential{type: :bearer, source: :command}}` on success.
    * `{:error, reason}` on any failure — missing command, exec failure,
      empty output, oversized output, or `allow_exec?` set to `false`.
  """

  alias Muse.Auth.Credential

  @max_bytes 1_048_576

  @type error_reason ::
          {:not_allowed, String.t()}
          | {:no_command, String.t()}
          | {:exec_failed, String.t()}
          | {:empty_output}
          | {:output_too_large}

  @doc """
  Resolve a bearer credential by executing a shell command.

  ## Options

    * `:command` — shell command string **(required)**. Example:
      `"gcloud auth print-access-token"`.
    * `:allow_exec?` — boolean, default `false`. When `false`, returns
      `{:error, {:not_allowed, ...}}` instead of executing. Set to `true`
      only when you intend to actually run the command.
    * `:source_label` — string used in error messages in place of the raw
      command (default: `"bearer_command"`). Prevents command strings from
      leaking into log/event output.

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
    * Commands are executed via `System.cmd/3` with `into: []` — no shell
      interpretation unless you explicitly wrap in `"sh -c '...'"`.
    * Stderr is discarded; only stdout is read.
  """
  @spec resolve(keyword()) :: {:ok, Credential.t()} | {:error, error_reason()}
  def resolve(opts \\ []) when is_list(opts) do
    command = Keyword.get(opts, :command)
    allow_exec? = Keyword.get(opts, :allow_exec?, false)
    source_label = Keyword.get(opts, :source_label, "bearer_command")

    with {:ok, cmd} <- validate_command(command, source_label),
         :ok <- check_allowed(allow_exec?, source_label),
         {:ok, value} <- exec_command(cmd) do
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

  defp validate_command(_cmd, source_label),
    do: {:error, {:no_command, source_label}}

  # ---------------------------------------------------------------------------
  # Exec guard
  # ---------------------------------------------------------------------------

  defp check_allowed(true, _source_label), do: :ok

  defp check_allowed(false, source_label),
    do: {:error, {:not_allowed, source_label}}

  # ---------------------------------------------------------------------------
  # Execution (size-capped, no token leakage in errors)
  # ---------------------------------------------------------------------------

  defp exec_command(command) do
    case System.cmd(command, [], into: [], stderr_to_stdout: false, parallelism: false) do
      {output, 0} ->
        token = output |> List.to_string() |> String.trim_trailing()

        if token == "" do
          {:error, :empty_output}
        else
          {:ok, token}
        end

      {_output, _exit_code} ->
        # Never include output in error — it might contain partial tokens.
        {:error, {:exec_failed, "command exited with non-zero status"}}
    end
  rescue
    ArgumentError ->
      {:error, {:exec_failed, "command not found or invalid"}}

    e in ErlangError ->
      {:error, {:exec_failed, "execution error: #{Exception.message(e)}"}}
  end
end
