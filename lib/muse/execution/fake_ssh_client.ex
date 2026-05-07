defmodule Muse.Execution.FakeSSHClient do
  @moduledoc """
  Fake SSH client adapter for deterministic testing — no network, no SSH.

  Implements `Muse.Execution.SSHClient` behaviour. Returns configurable
  outcomes for tests without any real SSH connection.

  ## Safety invariants

    * **No network** — never opens an SSH connection
    * **No shell** — never executes real commands
    * Output is configurable via target metadata or opts
    * Connection refs are opaque fake tuples

  ## Configurable outcomes

  The fake outcome is determined by:

    1. `opts[:fake_outcome]` — `:ok | :error | :timed_out | :denied`
    2. Default — `:ok`

  Output is configurable via `opts[:fake_stdout]` (default: `"fake ssh stdout"`)
  and `opts[:fake_stderr]` (default: `""`).

  Exit status is configurable via `opts[:fake_exit_status]` (default: `0`).
  """

  @behaviour Muse.Execution.SSHClient

  @default_stdout "fake ssh stdout"
  @default_stderr ""
  @default_exit_status 0
  @default_outcome :ok

  @impl Muse.Execution.SSHClient
  def connect(_target, opts \\ []) do
    ref = make_ref()
    target_id = Keyword.get(opts, :target_id, "fake_ssh_target")
    {:ok, {__MODULE__, ref, target_id}}
  end

  @impl Muse.Execution.SSHClient
  def exec(connection_ref, command_string, opts \\ [])

  def exec({__MODULE__, _ref, _target_id}, _command_string, opts) do
    outcome = Keyword.get(opts, :fake_outcome, @default_outcome)

    case outcome do
      :ok ->
        {:ok,
         %{
           stdout: Keyword.get(opts, :fake_stdout, @default_stdout),
           stderr: Keyword.get(opts, :fake_stderr, @default_stderr),
           exit_status: Keyword.get(opts, :fake_exit_status, @default_exit_status),
           timed_out: false
         }}

      :error ->
        {:ok,
         %{
           stdout: Keyword.get(opts, :fake_stdout, ""),
           stderr: Keyword.get(opts, :fake_stderr, "command failed"),
           exit_status: Keyword.get(opts, :fake_exit_status, 1),
           timed_out: false
         }}

      :timed_out ->
        {:ok,
         %{
           stdout: Keyword.get(opts, :fake_stdout, ""),
           stderr: "",
           exit_status: nil,
           timed_out: true
         }}

      :denied ->
        {:error, "SSH execution denied by policy"}
    end
  end

  def exec(_invalid_ref, _command_string, _opts) do
    {:error, "invalid or disconnected SSH connection"}
  end

  @impl Muse.Execution.SSHClient
  def disconnect(_connection_ref) do
    :ok
  end
end
