defmodule Muse.ApprovalGate do
  @moduledoc """
  Minimal approval facade for tool execution decisions.

  The facade is intentionally side-effect free: it only inspects tool specs and
  returns an authorization decision. It never executes tools, writes files, runs
  shell commands, performs network calls, or reads provider-supplied arguments.

  PR09 keeps tool execution deny-by-default. Plan approval is a plan lifecycle
  state only; it does **not** grant write, shell, network, patch, delete, or
  other future tool permissions. Future approval scopes should be added here
  only when exact, auditable approval records can be matched against a tool spec.
  """

  alias Muse.Tool.Spec

  @type decision :: :ok | {:blocked, String.t()}

  @safe_permissions MapSet.new([:read, :interactive])

  @approval_scoped_permissions MapSet.new([
                                 :write,
                                 :shell,
                                 :network,
                                 :patch,
                                 :delete,
                                 :restore,
                                 :restore_checkpoint,
                                 :remote_execution
                               ])

  @doc """
  Authorizes a tool spec for execution.

  In PR09, only specs that do **not** require approval and use a safe permission
  category (`:read` or `:interactive`) are allowed. The context is accepted as
  part of the facade contract for future scoped approvals, but plan approval or
  any other current context field is deliberately not treated as a tool grant.
  """
  @spec authorize_tool(Spec.t(), map()) :: decision()
  def authorize_tool(%Spec{} = spec, context) when is_map(context) do
    cond do
      safe_without_approval?(spec) ->
        :ok

      spec.requires_approval ->
        {:blocked, requires_approval_reason(spec)}

      approval_scoped_permission?(spec) ->
        {:blocked, approval_scoped_permission_reason(spec)}

      true ->
        {:blocked, unmatched_policy_reason(spec)}
    end
  end

  def authorize_tool(%Spec{} = spec, _context), do: authorize_tool(spec, %{})
  def authorize_tool(_spec, _context), do: {:blocked, "invalid tool approval request"}

  defp safe_without_approval?(%Spec{requires_approval: false} = spec) do
    MapSet.member?(@safe_permissions, tool_scope(spec))
  end

  defp safe_without_approval?(%Spec{}), do: false

  defp approval_scoped_permission?(%Spec{} = spec) do
    MapSet.member?(@approval_scoped_permissions, tool_scope(spec))
  end

  defp tool_scope(%Spec{permission: permission, kind: kind}) do
    permission_scope = normalize_scope(permission)

    if permission_scope == :unknown do
      normalize_scope(kind)
    else
      permission_scope
    end
  end

  defp requires_approval_reason(%Spec{} = spec) do
    "#{spec.name} requires explicit #{format_scope(tool_scope(spec))} approval which has not been granted; plan approval does not authorize tool execution"
  end

  defp approval_scoped_permission_reason(%Spec{} = spec) do
    "#{spec.name} uses #{format_scope(tool_scope(spec))} permission and is denied by default; plan approval does not authorize tool execution"
  end

  defp unmatched_policy_reason(%Spec{} = spec) do
    "#{spec.name} is denied by default because no approval policy matches #{format_scope(tool_scope(spec))} permission"
  end

  defp normalize_scope(scope) when is_atom(scope), do: scope

  defp normalize_scope(scope) when is_binary(scope) do
    case String.downcase(scope) do
      "read" -> :read
      "interactive" -> :interactive
      "plan" -> :plan
      "write" -> :write
      "shell" -> :shell
      "shell_command" -> :shell
      "network" -> :network
      "network_call" -> :network
      "patch" -> :patch
      "patch_apply" -> :patch
      "patch_propose" -> :patch
      "delete" -> :delete
      "delete_file" -> :delete
      "remote_execution" -> :remote_execution
      "restore" -> :restore
      "restore_checkpoint" -> :restore_checkpoint
      _other -> :unknown
    end
  end

  defp normalize_scope(_scope), do: :unknown

  defp format_scope(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp format_scope(scope) when is_binary(scope), do: scope
  defp format_scope(_scope), do: "unknown"
end
