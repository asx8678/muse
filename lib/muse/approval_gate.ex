defmodule Muse.ApprovalGate do
  @moduledoc """
  Pure, deterministic approval helpers for Muse plan approvals.

  This module is intentionally side-effect free: it only inspects and returns
  structs/maps and never executes tools, writes files, or performs shell/network
  operations.

  The implementation is map-compatible so it works with `%Muse.Session{}` /
  `%Muse.Plan{}` structs and plain maps.
  """

  @type approval :: map()

  @type reason ::
          :invalid_session_or_plan
          | :missing_session_id
          | :missing_plan_id
          | :missing_plan_version
          | :missing_plan_approval
          | :approval_not_pending
          | :approval_not_approved
          | :approval_expired
          | :approval_rejected
          | :session_mismatch
          | :active_plan_mismatch
          | :plan_id_mismatch
          | :plan_version_mismatch
          | :plan_hash_mismatch
          | :workspace_mismatch
          | :no_active_plan
          | {:scope_denied, atom()}

  @denied_scopes MapSet.new([
                   :patch,
                   :write,
                   :shell,
                   :network,
                   :delete,
                   :restore,
                   :restore_checkpoint,
                   :remote_execution,
                   :unknown
                 ])

  @doc """
  Requests a plan approval and appends it to the session/context approvals list.

  Returns `{:ok, approval, updated_session}` when binding validation succeeds.
  """
  @spec request_plan_approval(map(), map(), keyword()) ::
          {:ok, approval(), map()} | {:error, reason()}
  def request_plan_approval(session, plan, opts \\ [])

  def request_plan_approval(session, plan, opts) when is_map(session) and is_map(plan) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())
    expires_at = resolve_expires_at(opts, now)

    with {:ok, binding} <- build_binding(session, plan, opts) do
      approval =
        %{
          id: Keyword.get(opts, :id, approval_id(binding, now)),
          type: :approval,
          kind: :plan,
          scope: :plan,
          status: :pending,
          session_id: binding.session_id,
          plan_id: binding.plan_id,
          plan_version: binding.plan_version,
          plan_hash: binding.plan_hash,
          workspace: binding.workspace,
          requested_by: Keyword.get(opts, :requested_by),
          approved_by: nil,
          rejected_by: nil,
          created_at: now,
          approved_at: nil,
          rejected_at: nil,
          reason: nil,
          expires_at: expires_at,
          metadata: normalize_metadata(Keyword.get(opts, :metadata, %{}))
        }

      {:ok, approval, append_approval(session, approval)}
    end
  end

  def request_plan_approval(_session, _plan, _opts), do: {:error, :invalid_session_or_plan}

  @doc """
  Marks a pending plan approval as approved.

  By default this looks up the latest plan approval from `session.approvals`.
  Pass `approval: map` in `opts` to approve a specific approval record.
  """
  @spec approve_plan(map(), map(), term(), keyword()) :: {:ok, approval()} | {:error, reason()}
  def approve_plan(session, plan, approver, opts \\ [])

  def approve_plan(session, plan, approver, opts) when is_map(session) and is_map(plan) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    with {:ok, approval} <- resolve_approval(session, plan, opts),
         :ok <- ensure_pending(approval),
         :ok <- validate_plan_approval_binding(session, plan, approval, now) do
      {:ok,
       approval
       |> Map.put(:status, :approved)
       |> Map.put(:approved_by, approver)
       |> Map.put(:approved_at, now)
       |> Map.put(:rejected_by, nil)
       |> Map.put(:rejected_at, nil)
       |> Map.put(:reason, nil)}
    end
  end

  def approve_plan(_session, _plan, _approver, _opts), do: {:error, :invalid_session_or_plan}

  @doc """
  Marks a pending plan approval as rejected.

  By default this looks up the latest plan approval from `session.approvals`.
  Pass `approval: map` in `opts` to reject a specific approval record.
  """
  @spec reject_plan(map(), map(), term(), keyword()) :: {:ok, approval()} | {:error, reason()}
  def reject_plan(session, plan, rejector, opts \\ [])

  def reject_plan(session, plan, rejector, opts) when is_map(session) and is_map(plan) do
    now = keyword_datetime(opts, :now, DateTime.utc_now())

    with {:ok, approval} <- resolve_approval(session, plan, opts),
         :ok <- ensure_pending(approval),
         :ok <- validate_plan_approval_binding(session, plan, approval, now) do
      {:ok,
       approval
       |> Map.put(:status, :rejected)
       |> Map.put(:rejected_by, rejector)
       |> Map.put(:rejected_at, now)
       |> Map.put(:reason, Keyword.get(opts, :reason))}
    end
  end

  def reject_plan(_session, _plan, _rejector, _opts), do: {:error, :invalid_session_or_plan}

  @doc """
  Returns `:ok` when the requested plan scope is currently allowed.

  Scope behavior in PR09:

    * `:plan` uses plan approval binding validation.
    * Patch/write/shell/network and other future scopes are denied by default.
  """
  @spec allowed?(map(), map() | atom() | String.t()) :: :ok | {:error, reason()}
  def allowed?(session_or_context, approval)
      when is_map(session_or_context) and is_map(approval) do
    case normalize_scope(approval_scope(approval)) do
      :plan -> allowed_with_explicit_approval(session_or_context, approval)
      scope -> {:error, {:scope_denied, scope}}
    end
  end

  def allowed?(session_or_context, scope) when is_map(session_or_context) do
    case normalize_scope(scope) do
      :plan -> allowed_for_plan_scope(session_or_context)
      denied_scope -> {:error, {:scope_denied, denied_scope}}
    end
  end

  def allowed?(_session_or_context, _approval_or_scope), do: {:error, :invalid_session_or_plan}

  @doc """
  Returns true when a plan approval has gone stale for the supplied plan/session.
  """
  @spec stale_plan_approval?(map(), map()) :: boolean()
  def stale_plan_approval?(approval, plan_or_session)
      when is_map(approval) and is_map(plan_or_session) do
    now = DateTime.utc_now()

    case normalize_scope(approval_scope(approval)) do
      :plan -> stale_for_plan_scope?(approval, plan_or_session, now)
      _other -> true
    end
  end

  def stale_plan_approval?(_approval, _plan_or_session), do: true

  defp stale_for_plan_scope?(approval, plan_or_session, now) do
    cond do
      rejected?(approval) ->
        true

      expired?(approval, now) ->
        true

      session_like?(plan_or_session) ->
        case active_plan(plan_or_session) do
          nil ->
            true

          plan ->
            match?(
              {:error, _},
              validate_plan_approval_binding(plan_or_session, plan, approval, now)
            )
        end

      true ->
        pseudo_session = %{
          id: plan_session_id(plan_or_session),
          active_plan_id: plan_id(plan_or_session),
          workspace: plan_workspace(plan_or_session)
        }

        match?(
          {:error, _},
          validate_plan_approval_binding(pseudo_session, plan_or_session, approval, now)
        )
    end
  end

  defp allowed_with_explicit_approval(session_or_context, approval) do
    case active_plan(session_or_context) do
      nil ->
        {:error, :no_active_plan}

      plan ->
        now = DateTime.utc_now()

        with :ok <- ensure_approved(approval),
             :ok <- validate_plan_approval_binding(session_or_context, plan, approval, now) do
          :ok
        end
    end
  end

  defp allowed_for_plan_scope(session_or_context) do
    case active_plan(session_or_context) do
      nil ->
        {:error, :no_active_plan}

      plan ->
        case latest_plan_approval(session_or_context, plan, [:approved]) do
          nil ->
            {:error, :missing_plan_approval}

          approval ->
            now = DateTime.utc_now()

            with :ok <- ensure_approved(approval),
                 :ok <- validate_plan_approval_binding(session_or_context, plan, approval, now) do
              :ok
            end
        end
    end
  end

  defp build_binding(session, plan, opts) do
    with {:ok, session_id} <- resolve_session_id(session, plan),
         {:ok, plan_id} <- resolve_plan_id(session, plan),
         {:ok, plan_version} <- resolve_plan_version(plan),
         {:ok, plan_hash} <- resolve_plan_hash(plan, opts) do
      {:ok,
       %{
         session_id: session_id,
         plan_id: plan_id,
         plan_version: plan_version,
         plan_hash: plan_hash,
         workspace: resolve_workspace(session, plan)
       }}
    end
  end

  defp resolve_session_id(session, plan) do
    current_session_id = session_id(session)
    plan_session = plan_session_id(plan)

    cond do
      current_session_id == nil and plan_session == nil ->
        {:error, :missing_session_id}

      current_session_id != nil and plan_session != nil and current_session_id != plan_session ->
        {:error, :session_mismatch}

      true ->
        {:ok, current_session_id || plan_session}
    end
  end

  defp resolve_plan_id(session, plan) do
    current_active_plan_id = active_plan_id(session)
    current_plan_id = plan_id(plan)

    cond do
      current_active_plan_id == nil and current_plan_id == nil ->
        {:error, :missing_plan_id}

      current_active_plan_id != nil and current_plan_id != nil and
          current_active_plan_id != current_plan_id ->
        {:error, :active_plan_mismatch}

      true ->
        {:ok, current_plan_id || current_active_plan_id}
    end
  end

  defp resolve_plan_version(plan) do
    case plan_version(plan) do
      version when is_integer(version) and version >= 0 -> {:ok, version}
      _other -> {:error, :missing_plan_version}
    end
  end

  defp resolve_plan_hash(plan, opts) do
    case Keyword.get(opts, :plan_hash) || plan_hash(plan) do
      hash when is_binary(hash) and hash != "" -> {:ok, hash}
      hash when is_atom(hash) -> {:ok, Atom.to_string(hash)}
      _other -> {:error, :plan_hash_mismatch}
    end
  end

  defp validate_plan_approval_binding(session, plan, approval, now) do
    with :ok <- ensure_plan_scope(approval),
         :ok <- ensure_not_rejected(approval),
         :ok <- ensure_not_expired(approval, now),
         :ok <- validate_session_binding(session, plan, approval),
         :ok <- validate_plan_id_binding(session, plan, approval),
         :ok <- validate_plan_version_binding(plan, approval),
         :ok <- validate_plan_hash_binding(plan, approval),
         :ok <- validate_workspace_binding(session, plan, approval) do
      :ok
    end
  end

  defp ensure_plan_scope(approval) do
    scope = normalize_scope(approval_scope(approval))

    if scope == :plan do
      :ok
    else
      {:error, {:scope_denied, scope}}
    end
  end

  defp ensure_not_expired(approval, now) do
    if expired?(approval, now), do: {:error, :approval_expired}, else: :ok
  end

  defp ensure_not_rejected(approval) do
    if rejected?(approval), do: {:error, :approval_rejected}, else: :ok
  end

  defp validate_session_binding(session, plan, approval) do
    resolved_session_id = session_id(session) || plan_session_id(plan)
    approval_bound_session_id = approval_session_id(approval)

    cond do
      resolved_session_id == nil ->
        {:error, :missing_session_id}

      approval_bound_session_id == nil ->
        {:error, :session_mismatch}

      approval_bound_session_id != resolved_session_id ->
        {:error, :session_mismatch}

      true ->
        :ok
    end
  end

  defp validate_plan_id_binding(session, plan, approval) do
    resolved_plan_id = plan_id(plan) || active_plan_id(session)
    approval_bound_plan_id = approval_plan_id(approval)
    current_active_plan_id = active_plan_id(session)

    cond do
      resolved_plan_id == nil ->
        {:error, :missing_plan_id}

      current_active_plan_id != nil and resolved_plan_id != current_active_plan_id ->
        {:error, :active_plan_mismatch}

      approval_bound_plan_id == nil ->
        {:error, :plan_id_mismatch}

      approval_bound_plan_id != resolved_plan_id ->
        {:error, :plan_id_mismatch}

      true ->
        :ok
    end
  end

  defp validate_plan_version_binding(plan, approval) do
    current_version = plan_version(plan)
    approval_version = approval_plan_version(approval)

    cond do
      not (is_integer(current_version) and current_version >= 0) ->
        {:error, :plan_version_mismatch}

      not (is_integer(approval_version) and approval_version >= 0) ->
        {:error, :plan_version_mismatch}

      approval_version != current_version ->
        {:error, :plan_version_mismatch}

      true ->
        :ok
    end
  end

  defp validate_plan_hash_binding(plan, approval) do
    current_plan_hash = plan_hash(plan)
    approval_bound_hash = approval_plan_hash(approval)

    cond do
      is_nil(current_plan_hash) or current_plan_hash == "" ->
        {:error, :plan_hash_mismatch}

      is_nil(approval_bound_hash) or approval_bound_hash == "" ->
        {:error, :plan_hash_mismatch}

      approval_bound_hash != current_plan_hash ->
        {:error, :plan_hash_mismatch}

      true ->
        :ok
    end
  end

  defp validate_workspace_binding(session, plan, approval) do
    approval_bound_workspace = approval_workspace(approval)

    if is_nil(approval_bound_workspace) do
      :ok
    else
      current_workspace = resolve_workspace(session, plan)

      cond do
        current_workspace == nil -> {:error, :workspace_mismatch}
        approval_bound_workspace != current_workspace -> {:error, :workspace_mismatch}
        true -> :ok
      end
    end
  end

  defp resolve_workspace(session, plan), do: plan_workspace(plan) || session_workspace(session)

  defp resolve_approval(session, plan, opts) do
    case Keyword.get(opts, :approval) do
      nil ->
        case latest_plan_approval(session, plan, [:pending, :approved, :rejected]) do
          nil -> {:error, :missing_plan_approval}
          approval -> {:ok, approval}
        end

      approval when is_map(approval) ->
        {:ok, approval}

      _other ->
        {:error, :missing_plan_approval}
    end
  end

  defp latest_plan_approval(session, plan, statuses) do
    expected_plan_id = plan_id(plan) || active_plan_id(session)

    session_approvals(session)
    |> Enum.reverse()
    |> Enum.find(fn approval ->
      normalize_scope(approval_scope(approval)) == :plan and
        approval_plan_id(approval) == expected_plan_id and
        approval_status(approval) in statuses
    end)
  end

  defp ensure_pending(approval) do
    case normalize_status(approval_status(approval)) do
      :pending -> :ok
      :rejected -> {:error, :approval_rejected}
      _other -> {:error, :approval_not_pending}
    end
  end

  defp ensure_approved(approval) do
    case normalize_status(approval_status(approval)) do
      :approved -> :ok
      :rejected -> {:error, :approval_rejected}
      _other -> {:error, :approval_not_approved}
    end
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "pending" -> :pending
      "approved" -> :approved
      "rejected" -> :rejected
      _other -> :unknown
    end
  end

  defp normalize_status(_status), do: :unknown

  defp append_approval(session, approval) do
    approvals = session_approvals(session) ++ [approval]

    cond do
      Map.has_key?(session, :approvals) -> Map.put(session, :approvals, approvals)
      Map.has_key?(session, "approvals") -> Map.put(session, "approvals", approvals)
      true -> Map.put(session, :approvals, approvals)
    end
  end

  defp session_approvals(session) when is_map(session) do
    case map_get_any(session, [:approvals, "approvals"]) do
      approvals when is_list(approvals) -> approvals
      _other -> []
    end
  end

  defp active_plan(session_or_context) when is_map(session_or_context) do
    direct = map_get_any(session_or_context, [:plan, "plan", :active_plan, "active_plan"])

    cond do
      is_map(direct) ->
        direct

      true ->
        plans = map_get_any(session_or_context, [:plans, "plans"])
        current_active_plan_id = active_plan_id(session_or_context)
        fetch_plan(plans, current_active_plan_id)
    end
  end

  defp fetch_plan(plans, plan_id) when is_map(plans) and not is_nil(plan_id) do
    Map.get(plans, plan_id) || Map.get(plans, to_string(plan_id))
  end

  defp fetch_plan(_plans, _plan_id), do: nil

  defp session_like?(map) when is_map(map) do
    map_get_any(map, [:plans, "plans", :active_plan_id, "active_plan_id"]) != nil
  end

  defp approval_id(binding, now) do
    digest =
      hash_term(%{
        session_id: binding.session_id,
        plan_id: binding.plan_id,
        plan_version: binding.plan_version,
        plan_hash: binding.plan_hash,
        created_at: DateTime.to_iso8601(now)
      })

    "approval_" <> String.slice(digest, 0, 12)
  end

  defp plan_hash(plan) do
    map_get_any(plan, [:plan_hash, "plan_hash", :content_hash, "content_hash", :hash, "hash"]) ||
      compute_plan_hash(plan)
  end

  defp compute_plan_hash(plan) do
    payload = %{
      id: plan_id(plan),
      session_id: plan_session_id(plan),
      version: plan_version(plan),
      schema_version: map_get_any(plan, [:schema_version, "schema_version"]),
      title: map_get_any(plan, [:title, "title"]),
      objective: map_get_any(plan, [:objective, "objective"]),
      summary: map_get_any(plan, [:summary, "summary"]),
      tasks: map_get_any(plan, [:tasks, "tasks"], []),
      assumptions: map_get_any(plan, [:assumptions, "assumptions"], []),
      required_permissions:
        map_get_any(plan, [:required_permissions, "required_permissions"], []),
      agent_assignments: map_get_any(plan, [:agent_assignments, "agent_assignments"], []),
      phases: map_get_any(plan, [:phases, "phases"], []),
      steps: map_get_any(plan, [:steps, "steps"], []),
      inspected_files: map_get_any(plan, [:inspected_files, "inspected_files"], []),
      likely_changed_files:
        map_get_any(plan, [:likely_changed_files, "likely_changed_files"], []),
      files_expected: map_get_any(plan, [:files_expected, "files_expected"], []),
      commands_expected: map_get_any(plan, [:commands_expected, "commands_expected"], []),
      risks: map_get_any(plan, [:risks, "risks"], []),
      alternatives: map_get_any(plan, [:alternatives, "alternatives"], []),
      validation: map_get_any(plan, [:validation, "validation"], []),
      metadata: map_get_any(plan, [:metadata, "metadata"], %{})
    }

    hash_term(payload)
  end

  defp hash_term(term) do
    term
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp canonical_term(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> canonical_term()
  end

  defp canonical_term(term) when is_map(term) do
    term
    |> Enum.map(fn {key, value} -> {canonical_key(key), canonical_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(term) when is_list(term), do: Enum.map(term, &canonical_term/1)
  defp canonical_term(term) when is_atom(term) and term in [true, false, nil], do: term
  defp canonical_term(term) when is_atom(term), do: Atom.to_string(term)
  defp canonical_term(term), do: term

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: inspect(key)

  defp approval_scope(approval) do
    map_get_any(approval, [:scope, "scope", :kind, "kind", :type, "type"])
  end

  defp approval_status(approval), do: map_get_any(approval, [:status, "status"])
  defp approval_session_id(approval), do: map_get_any(approval, [:session_id, "session_id"])
  defp approval_plan_id(approval), do: map_get_any(approval, [:plan_id, "plan_id"])
  defp approval_plan_hash(approval), do: map_get_any(approval, [:plan_hash, "plan_hash"])
  defp approval_workspace(approval), do: map_get_any(approval, [:workspace, "workspace"])

  defp approval_plan_version(approval) do
    approval
    |> map_get_any([:plan_version, "plan_version"])
    |> normalize_integer()
  end

  defp rejected?(approval), do: normalize_status(approval_status(approval)) == :rejected

  defp expired?(approval, now) do
    case map_get_any(approval, [:expires_at, "expires_at"]) do
      %DateTime{} = expires_at -> DateTime.compare(expires_at, now) == :lt
      _other -> false
    end
  end

  defp session_id(session_or_context) do
    map_get_any(session_or_context, [:id, "id", :session_id, "session_id"])
  end

  defp active_plan_id(session_or_context) do
    map_get_any(session_or_context, [:active_plan_id, "active_plan_id"])
  end

  defp session_workspace(session_or_context) do
    map_get_any(session_or_context, [:workspace, "workspace"])
  end

  defp plan_id(plan), do: map_get_any(plan, [:id, "id"])
  defp plan_session_id(plan), do: map_get_any(plan, [:session_id, "session_id"])

  defp plan_workspace(plan) do
    map_get_any(plan, [:workspace, "workspace"]) ||
      map_get_any(map_get_any(plan, [:metadata, "metadata"], %{}), [:workspace, "workspace"])
  end

  defp plan_version(plan) do
    plan
    |> map_get_any([:version, "version"])
    |> normalize_integer()
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp resolve_expires_at(opts, now) do
    cond do
      match?(%DateTime{}, Keyword.get(opts, :expires_at)) ->
        Keyword.get(opts, :expires_at)

      is_integer(Keyword.get(opts, :ttl_seconds)) ->
        ttl_seconds = Keyword.get(opts, :ttl_seconds)
        if ttl_seconds > 0, do: DateTime.add(now, ttl_seconds, :second), else: now

      true ->
        nil
    end
  end

  defp keyword_datetime(opts, key, default) do
    case Keyword.get(opts, key) do
      %DateTime{} = datetime -> datetime
      _other -> default
    end
  end

  defp normalize_scope(scope) when is_atom(scope) do
    if MapSet.member?(@denied_scopes, scope) or scope == :plan, do: scope, else: :unknown
  end

  defp normalize_scope(scope) when is_binary(scope) do
    case String.downcase(scope) do
      "plan" -> :plan
      "patch" -> :patch
      "patch_apply" -> :patch
      "write" -> :write
      "shell" -> :shell
      "shell_command" -> :shell
      "network" -> :network
      "network_call" -> :network
      "delete" -> :delete
      "restore" -> :restore
      "restore_checkpoint" -> :restore_checkpoint
      "remote_execution" -> :remote_execution
      _other -> :unknown
    end
  end

  defp normalize_scope(_scope), do: :unknown

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp map_get_any(map, keys, default \\ nil)

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default
end
