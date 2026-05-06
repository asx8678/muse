defmodule Muse.Execution.Runner do
  @moduledoc """
  Behaviour for execution runners.

  Runners execute `Muse.Execution.Command` structs and return
  `Muse.Execution.Result` structs. All runners must:

    * Execute via argv vector — no shell interpolation.
    * Enforce timeout; close port on expiry (descendant processes may survive).
    * Cap and redact output.
    * Return safe results suitable for events/logs.

  ## Built-in runners

    * `Muse.Execution.LocalRunner` — local execution via Port.open
    * `Muse.Execution.RemoteDeniedRunner` — always denies remote execution

  ## Future runners (not in PR24)

    * SSH/remote runners will require explicit approval and strict
      authorization. Remote execution is denied by default.
  """

  alias Muse.Execution.Command
  alias Muse.Execution.Result

  @type run_result :: {:ok, Result.t()} | {:error, Result.t() | term()}

  @doc """
  Execute a command and return a result.

  Implementations must:
    * Validate the command is safe for this runner.
    * Execute the command via argv vector (no shell).
    * Enforce timeout.
    * Cap output at `command.max_output_bytes`.
    * Redact secrets in output.
    * Return a `%Result{}`.

  The returned result must always have:
    * `command_id` matching the input command.
    * `runner` matching this runner's identifier.
    * `status` indicating success/failure/denied/blocked.
  """
  @callback run(Command.t(), keyword()) :: run_result()

  @doc """
  Return the runner's capabilities.

  Optional callback. Default implementation returns local-only capabilities.
  """
  @callback capabilities() :: map()

  @optional_callbacks capabilities: 0

  @doc """
  Return the default capabilities for a runner.
  """
  @spec default_capabilities() :: map()
  def default_capabilities do
    %{
      local: true,
      remote: false,
      ssh: false,
      shell: false,
      network: false,
      timeout_ms: 60_000,
      max_output_bytes: 50_000
    }
  end

  @doc """
  Check if a runner supports local execution.
  """
  @spec supports_local?(module()) :: boolean()
  def supports_local?(runner) when is_atom(runner) do
    capabilities = get_capabilities(runner)
    Map.get(capabilities, :local, false)
  end

  @doc """
  Check if a runner supports remote execution.
  """
  @spec supports_remote?(module()) :: boolean()
  def supports_remote?(runner) when is_atom(runner) do
    capabilities = get_capabilities(runner)
    Map.get(capabilities, :remote, false)
  end

  @doc """
  Get capabilities from a runner module.
  """
  @spec get_capabilities(module()) :: map()
  def get_capabilities(runner) when is_atom(runner) do
    if function_exported?(runner, :capabilities, 0) do
      runner.capabilities()
    else
      default_capabilities()
    end
  end

  @doc """
  Execute a command using the appropriate runner based on target.

  Routes to LocalRunner for local targets, RemoteDeniedRunner for remote.
  """
  @spec run(Command.t(), keyword()) :: run_result()
  def run(%Command{target: :local} = command, opts) do
    Muse.Execution.LocalRunner.run(command, opts)
  end

  def run(%Command{target: nil} = command, opts) do
    Muse.Execution.LocalRunner.run(command, opts)
  end

  def run(%Command{target: :remote} = command, _opts) do
    Muse.Execution.RemoteDeniedRunner.run(command, [])
  end

  def run(%Command{target: :ssh} = command, _opts) do
    Muse.Execution.RemoteDeniedRunner.run(command, [])
  end

  def run(%Command{target: target} = command, _opts) when is_binary(target) do
    Muse.Execution.RemoteDeniedRunner.run(command, [])
  end

  def run(%Command{} = command, opts) do
    # Default to local runner
    Muse.Execution.LocalRunner.run(command, opts)
  end
end
