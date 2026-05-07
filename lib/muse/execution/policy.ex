defmodule Muse.Execution.Policy do
  @moduledoc """
  Execution policy resolver for runner/target authorization.

  Determines which runners and targets are allowed for execution.
  Remote execution is denied by default. Context-aware routing
  (Phase C) allows fake remote runner routing only when:

    * The target is a registered Target in the TargetRegistry.
    * The target's protocol is `:fake`.
    * The context contains a valid approved `:remote_execution` approval.
    * The approval matches session_id + target_id + command_hash.
    * The approval is not expired.

  ## Policy decisions (arity-1, backward compatible)

    * `:local` target → allowed, uses `LocalRunner`
    * `:remote` target → denied
    * `:ssh` target → denied
    * Any string target → denied (unless context-aware routing resolves it)

  ## Policy decisions (arity-2, context-aware)

    * String target matching a registered Target with `:fake` protocol
      and valid approval → `FakeRemoteRunner`
    * String target matching a registered Target with `:ssh` protocol
      → denied (SSH runner not implemented)
    * All other cases → denied

  ## No String.to_atom/1

  This module never converts runner/target strings to atoms.
  All lookups use explicit maps with pre-defined keys.
  """

  alias Muse.Execution.{Command, Target}

  @allowed_targets MapSet.new([:local, nil])
  @denied_targets MapSet.new([:remote, :ssh])
  @reserved_target_strings ["local", "remote", "ssh"]

  # -- Arity-1: backward compatible (default deny for remote) --------------------

  @doc """
  Check if a target is allowed for execution (default context).

  Returns `{:ok, runner_module}` for allowed targets, `{:error, reason}` for denied.
  This is the backward-compatible entry point — remote targets are always denied
  without context.
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

  # -- Arity-2: context-aware routing -------------------------------------------

  @doc """
  Resolve a target with execution context.

  For local targets, behaves identically to `resolve_target/1`.

  For remote/string targets, context may contain:
    * `:approval` or `:remote_approval` — an `Approval.t()` or map with
      `kind: :remote_execution`, `status: :approved`, `target_id`, `command_hash`,
      `session_id`.
    * `:command` — the `%Command{}` being routed (used for command_hash matching).
    * `:target_id` — explicit target ID; must not contradict approval.target_id.
    * `:session_id` — context session ID; must match approval.session_id.

  A remote/string target routes to `FakeRemoteRunner` only when ALL of:
    1. Target (or approval target_id) resolves to a registered Target.
    2. The registered Target's protocol is `:fake`.
    3. The approval is `:remote_execution` kind, `:approved` status.
    4. The approval's `target_id` is present and matches the registered target's `id`;
       context.target_id must not contradict approval.target_id.
    5. The approval's `command_hash` is present and matches the command's hash.
    6. The approval's `session_id` is present and matches the context session_id.
    7. The approval is not expired.
  """
  @spec resolve_target(atom() | String.t() | nil, map()) ::
          {:ok, module()} | {:error, :remote_execution_denied | String.t()}
  def resolve_target(target, context) when is_map(context) do
    cond do
      local_target?(target) ->
        {:ok, Muse.Execution.LocalRunner}

      ssh_protocol_target?(target, context) ->
        {:error,
         "SSH runner not implemented; remote execution requires a runner for the :ssh protocol"}

      fake_protocol_target_with_approval?(target, context) ->
        {:ok, Muse.Execution.FakeRemoteRunner}

      true ->
        # Fall back to default deny
        resolve_target(target)
    end
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

  # -- Arity-1: backward compatible ---------------------------------------------

  @doc """
  Validate a command against the policy (default context).

  Returns `:ok` if the command can be executed, `{:error, reason}` otherwise.
  """
  @spec validate_command(Command.t()) :: :ok | {:error, String.t()}
  def validate_command(%Command{target: target} = _command) do
    case resolve_target(target) do
      {:ok, _runner} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Arity-2: context-aware ---------------------------------------------------

  @doc """
  Validate a command against the policy with execution context.

  Same as `validate_command/1` but uses context-aware routing for
  remote targets that may resolve to `FakeRemoteRunner`.
  """
  @spec validate_command(Command.t(), map()) :: :ok | {:error, String.t()}
  def validate_command(%Command{target: target} = command, context) when is_map(context) do
    context_with_command = Map.put(context, :command, command)

    case resolve_target(target, context_with_command) do
      {:ok, _runner} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Arity-1: backward compatible ---------------------------------------------

  @doc """
  Get the runner module for a command (default context).

  Returns `{:ok, module}` for allowed targets, `{:error, reason}` for denied.
  """
  @spec get_runner(Command.t()) :: {:ok, module()} | {:error, String.t()}
  def get_runner(%Command{target: target}) do
    resolve_target(target)
  end

  # -- Arity-2: context-aware ---------------------------------------------------

  @doc """
  Get the runner module for a command with execution context.

  Same as `get_runner/1` but uses context-aware routing.
  """
  @spec get_runner(Command.t(), map()) :: {:ok, module()} | {:error, String.t()}
  def get_runner(%Command{target: target} = command, context) when is_map(context) do
    context_with_command = Map.put(context, :command, command)
    resolve_target(target, context_with_command)
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

  Phase C: returns `true` (denied) unless the full context would route
  to the fake remote runner with a valid approved approval. This preserves
  the Phase B regression where arbitrary approved-looking maps still return
  `true`.

  A context is NOT denied only when ALL conditions hold:
    1. `approval` or `remote_approval` in context is `:remote_execution` kind, `:approved` status
    2. The approval's `target_id` is present and resolves to a registered Target
    3. Context `target_id` must not contradict the approval's `target_id`
    4. Command target (if a binary registered-target id) must match the approval's `target_id`
    5. The registered Target's protocol is `:fake`
    6. The approval's `command_hash` is present and matches the context command's hash
    7. The approval's `session_id` is present and matches the context `session_id`
    8. The approval is not expired
  """
  @spec remote_execution_denied?(map()) :: boolean()
  def remote_execution_denied?(context) when is_map(context) do
    approval = extract_approval(context)

    cond do
      # No approval at all — denied
      approval == nil ->
        true

      # Approval kind is not :remote_execution — denied
      not remote_execution_kind?(map_get(approval, :kind)) ->
        true

      # Approval is not :approved — denied
      not approved_status?(map_get(approval, :status)) ->
        true

      # Approval must have a target_id — denied if missing
      approval_target_id(approval) == nil ->
        true

      # Context target_id must not contradict approval target_id — denied if mismatch
      context_target_id_conflicts?(context, approval) ->
        true

      # Command target must not contradict approval target_id — denied if mismatch
      command_target_conflicts?(context, approval) ->
        true

      # Command target must be a valid remote routing form —
      # :local/nil/"local" are not remote; arbitrary atoms denied
      invalid_remote_command_target?(context, approval) ->
        true

      # Target not found in registry — denied
      not target_registered?(effective_target_id(context, approval)) ->
        true

      # Target protocol is not :fake — denied
      target_protocol(effective_target_id(context, approval)) != :fake ->
        true

      # Approval is expired — denied
      approval_expired?(approval) ->
        true

      # Command hash mismatch (missing or wrong) — denied
      command_hash_mismatch?(approval, context) ->
        true

      # Session ID must be present in both approval and context and match — denied if mismatch
      session_id_mismatch?(approval, context) ->
        true

      # All conditions met — not denied
      true ->
        false
    end
  end

  # Fallback for non-map input
  def remote_execution_denied?(_context), do: true

  @doc """
  Check if remote execution tool name is blocked.

  This is a helper for Tool.Registry integration. Always returns
  `true` for remote execution tool names regardless of context —
  `ApprovalGate.authorize_tool/2` is the enforcement point for tool-level
  blocking, and it must continue to block remote tools.
  """
  @spec remote_tool_blocked?(String.t()) :: boolean()
  def remote_tool_blocked?("remote_execution"), do: true
  def remote_tool_blocked?("ssh_exec"), do: true
  def remote_tool_blocked?("ssh_run"), do: true
  def remote_tool_blocked?("remote_run"), do: true
  def remote_tool_blocked?(_tool_name), do: false

  # -- Private helpers ---------------------------------------------------------

  defp local_target?(:local), do: true
  defp local_target?(nil), do: true
  defp local_target?("local"), do: true
  defp local_target?(_), do: false

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

  # -- Context-aware helpers ---------------------------------------------------

  defp extract_approval(context) do
    case Map.get(context, :approval) do
      nil -> Map.get(context, :remote_approval)
      value -> value
    end
  end

  # Approval's target_id is authoritative; context's target_id must not contradict it.
  defp approval_target_id(approval), do: map_get(approval, :target_id)

  defp context_target_id_conflicts?(context, approval) do
    approval_tid = approval_target_id(approval)
    context_tid = map_get(context, :target_id)

    cond do
      approval_tid == nil -> false
      context_tid == nil -> false
      approval_tid != context_tid -> true
      true -> false
    end
  end

  defp command_target_conflicts?(context, approval) do
    command = Map.get(context, :command)
    approval_tid = approval_target_id(approval)

    cond do
      # No command in context — checked elsewhere (command_hash_mismatch?)
      command == nil ->
        false

      # No approval target_id — checked elsewhere (approval_target_id check)
      approval_tid == nil ->
        false

      true ->
        cmd_target = command.target

        cond do
          # Atom targets (:local, :remote, :ssh, nil) are not registered-target ids
          is_atom(cmd_target) ->
            false

          # Reserved strings like "remote", "ssh", "local" — not registered ids
          is_binary(cmd_target) and
              String.downcase(String.trim(cmd_target)) in @reserved_target_strings ->
            false

          # Binary target that looks like a registered-target id must match approval
          is_binary(cmd_target) and cmd_target != approval_tid ->
            true

          true ->
            false
        end
    end
  end

  defp effective_target_id(context, approval) do
    # Approval target_id takes priority; fall back to context target_id
    approval_target_id(approval) || map_get(context, :target_id)
  end

  defp map_get(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_string(key))
      value -> value
    end
  end

  defp map_get(_, _), do: nil

  defp target_registered?(target_id) when is_binary(target_id) do
    case Muse.Execution.TargetRegistry.fetch(target_id) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  rescue
    # Registry not running
    _ -> false
  end

  defp target_registered?(_), do: false

  defp target_protocol(target_id) when is_binary(target_id) do
    case Muse.Execution.TargetRegistry.fetch(target_id) do
      {:ok, %Target{protocol: protocol}} -> protocol
      {:error, :not_found} -> nil
    end
  rescue
    _ -> nil
  end

  defp target_protocol(_), do: nil

  defp approval_expired?(approval) do
    case map_get(approval, :expires_at) do
      nil ->
        false

      value ->
        case parse_expires_at(value) do
          # Unparseable = fail closed = treat as expired
          nil -> true
          dt -> DateTime.compare(dt, DateTime.utc_now()) == :lt
        end
    end
  end

  defp parse_expires_at(%DateTime{} = dt), do: dt

  defp parse_expires_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_expires_at(_), do: nil

  defp command_hash_mismatch?(approval, context) do
    approval_hash = map_get(approval, :command_hash)
    command = Map.get(context, :command)

    cond do
      # No command in context — can't verify, treat as mismatch for safety
      command == nil ->
        true

      # No hash in approval — missing binding, denied (fail closed)
      approval_hash == nil ->
        true

      # Both present — must match
      true ->
        Command.command_hash(command) != approval_hash
    end
  end

  defp ssh_protocol_target?(target, context) do
    approval = extract_approval(context)
    target_id = effective_target_id(context, approval)

    cond do
      # Explicit :ssh atom target
      target == :ssh ->
        true

      # String target that normalizes to :ssh
      is_binary(target) and normalize_target_string(target) == :ssh ->
        true

      # Registered target with :ssh protocol
      is_binary(target_id) and target_protocol(target_id) == :ssh ->
        true

      # String target matching a registered SSH target
      is_binary(target) ->
        case Muse.Execution.TargetRegistry.fetch(target) do
          {:ok, %Target{protocol: :ssh}} -> true
          _ -> false
        end

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp fake_protocol_target_with_approval?(target, context) do
    approval = extract_approval(context)

    cond do
      # No approval — cannot route to fake runner
      approval == nil ->
        false

      # Approval kind must be :remote_execution
      not remote_execution_kind?(map_get(approval, :kind)) ->
        false

      # Approval must be :approved
      not approved_status?(map_get(approval, :status)) ->
        false

      # Approval must have a target_id
      approval_target_id(approval) == nil ->
        false

      # Context target_id must not contradict approval target_id
      context_target_id_conflicts?(context, approval) ->
        false

      # Command target must not contradict approval target_id.
      # If command.target is a binary registered-target id, it must match
      # the approval's target_id. Reserved strings ("remote", "ssh", "local")
      # and atoms (:remote, :ssh, :local) follow existing logic.
      command_target_conflicts?(context, approval) ->
        false

      # Target argument must be a valid remote routing form:
      #   - :remote atom
      #   - "remote" string
      #   - string exactly matching approval's target_id
      # Arbitrary atoms, local forms, SSH forms, and non-matching strings
      # are denied.
      not valid_remote_routing_target?(target, approval) ->
        false

      # Command target must be a valid remote routing form:
      #   - :remote atom
      #   - "remote" string
      #   - string exactly matching approval's target_id
      # Local/nil/"local" command targets are NOT valid remote contexts.
      # Arbitrary atom command targets are denied.
      invalid_remote_command_target?(context, approval) ->
        false

      # Session ID must match between approval and context
      session_id_mismatch?(approval, context) ->
        false

      # Must have a target_id that resolves to a registered :fake target
      true ->
        target_id = effective_target_id(context, approval)

        with {:ok, %Target{protocol: :fake}} <- fetch_registered_target(target_id),
             false <- approval_expired?(approval),
             false <- command_hash_mismatch?(approval, context) do
          true
        else
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  # -- Target argument and command target validation ---------------------------

  defp valid_remote_routing_target?(target, approval) do
    approval_tid = approval_target_id(approval)

    cond do
      # :remote atom — shorthand for "use approval's target_id"
      target == :remote -> true
      # "remote" string (case-insensitive, trimmed) — same as :remote
      is_binary(target) and normalize_target_string(target) == :remote -> true
      # String exactly matching the approval's target_id — direct reference
      is_binary(target) and target == approval_tid -> true
      # Everything else — not a valid remote routing form
      true -> false
    end
  end

  defp invalid_remote_command_target?(context, approval) do
    command = Map.get(context, :command)
    approval_tid = approval_target_id(approval)

    cond do
      # No command in context — can't verify, already handled by
      # command_hash_mismatch? but deny here for defense in depth
      command == nil ->
        true

      true ->
        cmd_target = command.target

        cond do
          # :remote atom — valid remote routing form
          cmd_target == :remote ->
            false

          # "remote" string — valid remote routing form
          is_binary(cmd_target) and normalize_target_string(cmd_target) == :remote ->
            false

          # String exactly matching approval's target_id — valid
          is_binary(cmd_target) and cmd_target == approval_tid ->
            false

          # All other forms are invalid for remote routing:
          # :local, nil, "local", :ssh, "ssh", arbitrary atoms,
          # strings not matching approval_tid — denied
          true ->
            true
        end
    end
  end

  # -- String/atom kind and status support -------------------------------------

  defp remote_execution_kind?(value) when is_atom(value), do: value == :remote_execution

  defp remote_execution_kind?(value) when is_binary(value) do
    String.downcase(String.trim(value)) == "remote_execution"
  end

  defp remote_execution_kind?(_), do: false

  defp approved_status?(value) when is_atom(value), do: value == :approved

  defp approved_status?(value) when is_binary(value) do
    String.downcase(String.trim(value)) == "approved"
  end

  defp approved_status?(_), do: false

  # -- Session ID matching ------------------------------------------------------

  defp session_id_mismatch?(approval, context) do
    approval_sid = map_get(approval, :session_id)
    context_sid = map_get(context, :session_id)

    cond do
      # No approval session_id — fail closed (denied)
      approval_sid == nil -> true
      # No context session_id — can't verify (denied)
      context_sid == nil -> true
      # Both present and must match
      approval_sid != context_sid -> true
      true -> false
    end
  end

  defp fetch_registered_target(nil), do: {:error, :no_target_id}

  defp fetch_registered_target(target_id) when is_binary(target_id) do
    Muse.Execution.TargetRegistry.fetch(target_id)
  rescue
    _ -> {:error, :not_found}
  end
end
