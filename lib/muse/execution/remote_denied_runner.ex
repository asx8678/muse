defmodule Muse.Execution.RemoteDeniedRunner do
  @moduledoc """
  Runner that always denies remote execution.

  This runner exists to provide a clear, auditable rejection path for
  any attempt to execute commands remotely. Remote execution is not
  implemented in PR24 and must remain denied by default until explicitly
  approved in a future milestone.

  ## Denial policy

  All requests with `target` not equal to `:local` or `nil` are denied:

    * `:remote` — denied
    * `:ssh` — denied
    * Any string target (hostname, IP, etc.) — denied

  The denial is logged and returned as a `:denied` status result.
  """

  @behaviour Muse.Execution.Runner

  alias Muse.Execution.{Command, Result}

  @impl Muse.Execution.Runner
  def capabilities do
    %{
      local: false,
      remote: false,
      ssh: false,
      shell: false,
      network: false,
      denial_reason: "remote execution is not enabled"
    }
  end

  @impl Muse.Execution.Runner
  def run(%Command{} = command, opts) do
    reason = Keyword.get(opts, :denial_reason) || denial_reason(command)
    {:error, Result.denied(command.id, reason, target: command.target, runner: :remote_denied)}
  end

  # -- Private helpers ---------------------------------------------------------

  defp denial_reason(%Command{target: :ssh}) do
    "SSH execution is not implemented; remote execution requires explicit approval"
  end

  defp denial_reason(%Command{target: :remote}) do
    "Remote execution is not enabled; requires explicit approval and future milestone"
  end

  defp denial_reason(%Command{target: target}) when is_binary(target) do
    "Execution on target '#{redact_target(target)}' is not enabled; remote execution requires explicit approval"
  end

  defp denial_reason(_command) do
    "Remote execution is not enabled; requires explicit approval"
  end

  defp redact_target(target) when is_binary(target) do
    # Redact any credential-like patterns in target
    target
    |> Muse.Prompt.Redactor.redact_text()
    |> String.slice(0, 50)
  end

  defp redact_target(target), do: inspect(target)
end
