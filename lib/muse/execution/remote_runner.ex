defmodule Muse.Execution.RemoteRunner do
  @moduledoc """
  Extension behaviour for remote execution runners.

  Remote runners implement the standard `Muse.Execution.Runner` behaviour
  plus additional callbacks for:

    * Connection lifecycle (connect, disconnect)
    * Remote command execution
    * Output capping and redaction (inherited from Runner)

  All remote runners must:

    * Enforce connection timeout.
    * Validate host identity before executing commands.
    * Never emit credentials in events, logs, or debug output.
    * Cap and redact output (inherits from Runner).
    * Emit structured audit events for connect/disconnect/execution.

  ## Safety invariants

    * Remote execution is deny-by-default and requires an approved
      `:remote_execution` approval matching session_id + target_id +
      command_hash.
    * `FakeRemoteRunner` remains deterministic/offline for tests.
    * `SSHRunner` is the real SSH implementation and must fail closed unless
      routed through context-aware policy with a valid approval.

  ## Separate from Runner behaviour

  Not all runners are remote — keeping `RemoteRunner` separate avoids
  forcing local runners to implement callbacks they don't need. A module
  that `@behaviour Muse.Execution.RemoteRunner` explicitly declares
  remote capability.
  """

  alias Muse.Execution.{Command, Result}

  @doc """
  Connect to a remote target.

  Returns `{:ok, connection_ref}` on success, `{:error, reason}` on failure.
  Connection refs are opaque tokens used for subsequent execution.

  Implementations must:

    * Validate the target descriptor before connecting.
    * Enforce connection timeout.
    * Never store credentials in the connection ref.
    * Never emit credentials in logs or events.
  """
  @callback connect(target :: map(), opts :: keyword()) ::
              {:ok, connection_ref :: term()} | {:error, String.t()}

  @doc """
  Disconnect from a remote target.

  Called at session end or on error cleanup. Best-effort — must
  return `:ok` even if the connection is already closed or invalid.

  Implementations must:

    * Never raise on invalid/closed connection refs.
    * Clean up any associated resources.
    * Never emit credentials during disconnect.
  """
  @callback disconnect(connection_ref :: term()) :: :ok

  @doc """
  Execute a command on the connected remote target.

  Same contract as `Runner.run/2` but operates on a connection ref
  returned by `connect/2`.

  Implementations must:

    * Validate the command is safe for remote execution.
    * Enforce command timeout.
    * Cap output at `command.max_output_bytes`.
    * Redact secrets in output via `Muse.Prompt.Redactor`.
    * Return a `%Result{}` with `status: :denied` if the approval
      context is missing or invalid.
    * Never emit credentials in the result, events, or logs.
  """
  @callback remote_run(connection_ref :: term(), Command.t(), keyword()) :: Result.t()
end
