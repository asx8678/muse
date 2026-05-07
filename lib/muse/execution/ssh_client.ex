defmodule Muse.Execution.SSHClient do
  @moduledoc """
  Behaviour for SSH client adapters.

  Defines a contract for SSH connection, command execution, and
  disconnection. The default implementation (`ErlangSSHClient`)
  wraps the Erlang `:ssh` application. Tests use `FakeSSHClient`
  for deterministic, offline behavior.

  ## Safety invariants

    * No adapter implementation stores credentials.
    * Connection refs are opaque — no credential data in refs.
    * Errors are redacted — never leak host, user, or key paths.
    * Host key verification is mandatory; no-verification modes
      must be rejected by all conforming adapters.

  ## Adapter contract

  All adapters must:

    1. `connect/2` — validate target, resolve credentials via
       `SSHCredentialResolver`, verify host key, return `{:ok, conn_ref}`.
    2. `exec/3` — execute a POSIX shell command string on an open
       connection, collect stdout/stderr/exit_status within timeout,
       return `{:ok, exec_result}`.
    3. `disconnect/1` — best-effort close; never raises.
  """

  @type connection_ref :: term()
  @type exec_result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_status: non_neg_integer() | nil,
          timed_out: boolean()
        }

  @doc """
  Connect to an SSH target.

  Returns `{:ok, connection_ref}` on success, `{:error, reason}` on failure.
  The reason string must be redacted — no host, user, key path, or credential
  data in the error message.

  ## Options

    * `:host` — hostname or IP (required, non-empty)
    * `:port` — port number (default: 22)
    * `:user` — SSH user (required)
    * `:credential_ref` — opaque credential reference for `SSHCredentialResolver`
    * `:connection_opts` — validated/allowlisted connection options
    * `:timeout_ms` — connection timeout (default: 30_000)
  """
  @callback connect(target :: map(), opts :: keyword()) ::
              {:ok, connection_ref()} | {:error, String.t()}

  @doc """
  Execute a command string on an open SSH connection.

  Returns `{:ok, exec_result}` with stdout, stderr, exit_status, and timed_out.
  The command string should be a safe POSIX shell command produced by
  quoting each argv element.

  ## Options

    * `:timeout_ms` — execution timeout (default: 60_000)
  """
  @callback exec(connection_ref(), command_string :: String.t(), opts :: keyword()) ::
              {:ok, exec_result()} | {:error, String.t()}

  @doc """
  Disconnect from an SSH target.

  Best-effort — must return `:ok` even if the connection is already closed
  or the ref is invalid. Must never raise.
  """
  @callback disconnect(connection_ref()) :: :ok
end
