defmodule Muse.Execution.Policy do
  @moduledoc """
  Execution policy resolver for runner/target authorization.

  Determines which runners and targets are allowed for execution.
  In PR24, only `:local` execution is allowed. Remote execution
  (SSH, network, etc.) is denied by default.

  ## Policy decisions

    * `:local` target → allowed, uses `Muse.Execution.LocalRunner`
    * `:remote` target → denied
    * `:ssh` target → denied
    * Any string target → denied

  ## No String.to_atom/1

  This module never converts runner/target strings to atoms.
  All lookups use explicit maps with pre-defined keys.
  """

  alias Muse.Execution.Command

  @allowed_targets MapSet.new([:local, nil])
  @denied_targets MapSet.new([:remote, :ssh])

  # Map of target atoms to runner modules
  # (not used at runtime but documents the routing logic)

  @doc """
  Check if a target is allowed for execution.

  Returns `{:ok, runner_module}` for allowed targets, `{:error, reason}` for denied.
  """
  @spec resolve_target(atom() | String.t() | nil) ::
          {:ok, module()} | {:error, :remote_execution_denied | String.t()}
  def resolve_target(:local), do: {:ok, Muse.Execution.LocalRunner}
  def resolve_target(nil), do: {:ok, Muse.Execution.LocalRunner}

  def resolve_target(:remote) do
    {:error, "remote execution is denied by default"}
  end

  def resolve_target(:ssh) do
    {:error, "SSH execution is denied by default"}
  end

  def resolve_target(target) when is_binary(target) do
    # Handle string versions of known targets
    case normalize_target_string(target) do
      :local -> {:ok, Muse.Execution.LocalRunner}
      :remote -> {:error, "remote execution is denied by default"}
      :ssh -> {:error, "SSH execution is denied by default"}
      :unknown -> {:error, "execution target '#{redact_target(target)}' is not recognized"}
    end
  end

  def resolve_target(target) do
    {:error, "execution target '#{inspect(target)}' is not recognized"}
  end

  @doc """
  Check if a target is allowed (boolean).
  """
  @spec target_allowed?(atom() | String.t() | nil) :: boolean()
  def target_allowed?(:local), do: true
  def target_allowed?(nil), do: true
  def target_allowed?(_), do: false

  @doc """
  Check if a target is explicitly denied (boolean).
  """
  @spec target_denied?(atom() | String.t() | nil) :: boolean()
  def target_denied?(:remote), do: true
  def target_denied?(:ssh), do: true
  def target_denied?(target) when is_binary(target), do: true
  def target_denied?(_), do: false

  @doc """
  Validate a command against the policy.

  Returns `:ok` if the command can be executed, `{:error, reason}` otherwise.
  """
  @spec validate_command(Command.t()) :: :ok | {:error, String.t()}
  def validate_command(%Command{target: target} = _command) do
    case resolve_target(target) do
      {:ok, _runner} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the runner module for a command.

  Returns `{:ok, module}` for allowed targets, `{:error, reason}` for denied.
  """
  @spec get_runner(Command.t()) :: {:ok, module()} | {:error, String.t()}
  def get_runner(%Command{target: target}) do
    resolve_target(target)
  end

  @doc """
  Return the list of allowed targets (for documentation/testing).
  """
  @spec allowed_targets() :: [atom()]
  def allowed_targets do
    MapSet.to_list(@allowed_targets)
  end

  @doc """
  Return the list of denied targets (for documentation/testing).
  """
  @spec denied_targets() :: [atom()]
  def denied_targets do
    MapSet.to_list(@denied_targets)
  end

  @doc """
  Check if remote execution is denied for the given context.

  This is used by ApprovalGate to deny remote execution tools
  even if approval-looking data is present.
  """
  @spec remote_execution_denied?(map()) :: boolean()
  def remote_execution_denied?(_context) do
    # Remote execution is ALWAYS denied in PR24
    # No context can override this
    true
  end

  @doc """
  Check if remote execution tool name is blocked.

  This is a helper for Tool.Registry integration.
  """
  @spec remote_tool_blocked?(String.t()) :: boolean()
  def remote_tool_blocked?("remote_execution"), do: true
  def remote_tool_blocked?("ssh_exec"), do: true
  def remote_tool_blocked?("ssh_run"), do: true
  def remote_tool_blocked?("remote_run"), do: true
  def remote_tool_blocked?(_tool_name), do: false

  # -- Private helpers ---------------------------------------------------------

  defp normalize_target_string(target) when is_binary(target) do
    target
    |> String.downcase()
    |> String.trim()
    |> case do
      "local" -> :local
      "remote" -> :remote
      "ssh" -> :ssh
      _ -> :unknown
    end
  end

  defp redact_target(target) when is_binary(target) do
    target
    |> String.slice(0, 50)
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp redact_target(target), do: inspect(target)
end
