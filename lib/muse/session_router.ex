defmodule Muse.SessionRouter do
  @moduledoc """
  Routes `Muse.submit/2` calls to the correct `Muse.SessionServer` process.

  ## Session lifecycle

  Sessions are identified by `{active_store_base_dir, session_id}`. The
  public API still accepts a string `session_id`, and the router scopes it to
  the currently active workspace before lookup/start:

    1. Captures the active workspace store directory.
    2. Checks `Muse.SessionRegistry` for an existing session in that store.
    3. If found, returns the existing pid.
    4. If not found, starts a new `Muse.SessionServer` under
       `Muse.SessionSupervisor` using a `{:via, Registry, …}` name for
       atomic registration — concurrent callers for the same session id in the
       same workspace safely race, while the same id in different workspaces can
       coexist.
    5. The session pid is looked up via the Registry, not cached locally,
       so the registry stays as the single source of truth.

  ## Default session

  `Muse.submit/2` uses `"default"` as the session id for backward
  compatibility.  Lower-level APIs accept an explicit `:session_id` option.
  """

  @default_session_id "default"

  # -- Public API ---------------------------------------------------------------

  @doc """
  Submits user input to the session identified by `session_id`.

  Returns `{:ok, assistant_text}` — the same shape as `Muse.submit/3`.

  The `opts` keyword list is forwarded to `Muse.SessionServer.submit/4`
  and ultimately to `Muse.Conductor.run/3`. Supported keys include
  `:provider_env`, `:provider_config`, `:model_router_opts`,
  `:provider_module`, and `:workspace`.

  ## Calling conventions

      # 2-arg: default session, source and text (backward compatible)
      SessionRouter.submit(:web, "hello")  # session_id = "default"

      # 3-arg: explicit session_id, source and text (backward compatible)
      SessionRouter.submit("my-session", :web, "hello")

      # 4-arg: explicit session_id, source, text, and opts
      SessionRouter.submit("my-session", :web, "hello", provider_env: env)
  """

  # 2-arg: source, text — uses default session id
  @spec submit(atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(source, text) when is_atom(source) and is_binary(text) do
    submit(@default_session_id, source, text, [])
  end

  # 3-arg with string session_id: session_id, source, text (backward compatible)
  @spec submit(String.t(), atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(session_id, source, text)
      when is_binary(session_id) and is_atom(source) and is_binary(text) do
    submit(session_id, source, text, [])
  end

  # 3-arg with atom source: source, text, opts — uses default session id
  @spec submit(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def submit(source, text, opts) when is_atom(source) and is_binary(text) and is_list(opts) do
    submit(@default_session_id, source, text, opts)
  end

  # 4-arg: session_id, source, text, opts
  @spec submit(String.t(), atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def submit(session_id, source, text, opts)
      when is_binary(session_id) and is_atom(source) and is_binary(text) and is_list(opts) do
    with {:ok, pid} <- find_or_start_session(session_id) do
      Muse.SessionServer.submit(pid, source, text, opts)
    end
  end

  @doc """
  Returns the status map for the given session, or `{:error, :not_found}`.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(session_id \\ @default_session_id) do
    with {:ok, pid} <- lookup_session(session_id) do
      {:ok, Muse.SessionServer.status(pid)}
    end
  end

  @doc """
  Cancel the currently running turn for a session.

  Returns `:ok` if cancellation was signalled, `{:error, :not_found}` if the
  session doesn't exist, or `{:error, :no_active_turn}` if no turn is running.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found} | {:error, :no_active_turn}
  def cancel(session_id \\ @default_session_id) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.cancel(pid)
    end
  end

  @doc """
  Approves the active plan for an existing session.

  This does not start a missing session and does not execute the plan.
  """
  @spec approve_plan(String.t(), atom()) ::
          {:ok, Muse.Plan.t()}
          | {:error,
             :not_found
             | :turn_running
             | :no_active_plan
             | {:plan_not_awaiting_approval, Muse.Plan.status()}}
  def approve_plan(session_id \\ @default_session_id, source \\ :system) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.approve_plan(pid, source)
    end
  end

  @doc """
  Rejects the active plan for an existing session.

  This does not start a missing session and does not execute anything.
  """
  @spec reject_plan(String.t(), atom()) ::
          {:ok, Muse.Plan.t()}
          | {:error,
             :not_found
             | :turn_running
             | :no_active_plan
             | {:plan_not_awaiting_approval, Muse.Plan.status()}}
  def reject_plan(session_id \\ @default_session_id, source \\ :system) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.reject_plan(pid, source)
    end
  end

  @doc """
  Approves the active pending patch proposal for an existing session.

  PR18: approval records the decision; use /apply patch to apply with checkpoint protection.
  is created, and no patch is applied. Patch application will be handled in a
  future PR.
  """
  @spec approve_patch(String.t(), atom()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :turn_running
             | :no_pending_patch
             | {:patch_not_awaiting_approval, term()}}
  def approve_patch(session_id \\ @default_session_id, source \\ :system) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.approve_patch(pid, source)
    end
  end

  @doc """
  Rejects the active pending patch proposal for an existing session.

  PR17: rejection records the decision only; no files are modified.
  """
  @spec reject_patch(String.t(), atom()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :turn_running
             | :no_pending_patch
             | {:patch_not_awaiting_approval, term()}}
  def reject_patch(session_id \\ @default_session_id, source \\ :system) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.reject_patch(pid, source)
    end
  end

  @doc """
  Applies the latest approved patch for an existing session.

  PR18: creates a checkpoint, applies the approved patch diff via git apply,
  and returns bounded post-apply diff output. If a specific patch_id is
  given, applies that patch; otherwise applies the most recently approved.
  """
  @spec apply_patch(String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :turn_running
             | :no_approved_patch
             | :no_active_plan
             | :apply_failed
             | term()}
  def apply_patch(session_id \\ @default_session_id, patch_id \\ nil) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.apply_patch(pid, patch_id)
    end
  end

  @doc """
  Rolls back a checkpoint for an existing session.

  PR18: restores the workspace to the state captured in the checkpoint.
  Only checkpoints belonging to the current session and active plan
  may be rolled back.
  """
  @spec rollback_checkpoint(String.t(), String.t()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :turn_running
             | term()}
  def rollback_checkpoint(session_id \\ @default_session_id, checkpoint_id) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.rollback_checkpoint(pid, checkpoint_id)
    end
  end

  @doc """
  Returns a list of all active session ids and their pids.

  If the same session id is active in multiple workspace profiles, the id will
  appear more than once with different pids. Registry keys remain
  workspace-scoped internally.
  """
  @spec active_sessions() :: [{String.t(), pid()}]
  def active_sessions do
    Muse.SessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn
      {{_store_base_dir, session_id}, pid} -> {session_id, pid}
      {session_id, pid} -> {session_id, pid}
    end)
  end

  # -- Memory API ----------------------------------------------------------------

  @doc """
  Returns the memory artifact for the given session, or `nil`.
  """
  @spec get_memory(String.t()) :: {:ok, term() | nil} | {:error, :not_found}
  def get_memory(session_id \\ @default_session_id) do
    with {:ok, pid} <- lookup_session(session_id) do
      {:ok, Muse.SessionServer.get_memory(pid)}
    end
  end

  @doc """
  Sets the memory artifact for the given session.
  """
  @spec set_memory(String.t(), term()) :: :ok | {:error, :not_found}
  def set_memory(session_id \\ @default_session_id, memory) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.set_memory(pid, memory)
    end
  end

  @doc """
  Clears the memory artifact for the given session.
  """
  @spec clear_memory(String.t()) :: :ok | {:error, :not_found}
  def clear_memory(session_id \\ @default_session_id) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.clear_memory(pid)
    end
  end

  @doc """
  Sets the active Muse for the given session, affecting turn routing.
  """
  @spec set_active_muse(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_active_muse(session_id \\ @default_session_id, muse_id) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.set_active_muse(pid, muse_id)
    end
  end

  @doc """
  Requests a pending remote execution approval for the given session.

  The session transitions to `:awaiting_remote_execution_approval`.
  No remote execution is actually granted — this is auditable metadata only.
  """
  @spec request_remote_execution_approval(String.t(), keyword()) ::
          {:ok, Muse.Approval.t()}
          | {:error, :not_found | :turn_running | :pending_remote_approval_exists | term()}
  def request_remote_execution_approval(session_id \\ @default_session_id, opts \\ []) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.request_remote_execution_approval(pid, opts)
    end
  end

  @doc """
  Approves the pending remote execution approval for the given session.

  The session transitions back to `:idle`. Approval is audit metadata only —
  no runner/tool execution is granted.
  """
  @spec approve_remote(String.t(), atom()) ::
          {:ok, Muse.Approval.t()}
          | {:error, :not_found | :turn_running | :no_pending_remote_approval | term()}
  def approve_remote(session_id \\ @default_session_id, source \\ :system) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.approve_remote(pid, source)
    end
  end

  @doc """
  Rejects the pending remote execution approval for the given session.

  The session transitions back to `:idle`. Rejection is recorded for audit.
  """
  @spec reject_remote(String.t(), atom()) ::
          {:ok, Muse.Approval.t()}
          | {:error, :not_found | :turn_running | :no_pending_remote_approval | term()}
  def reject_remote(session_id \\ @default_session_id, source \\ :system) do
    with {:ok, pid} <- lookup_session(session_id) do
      Muse.SessionServer.reject_remote(pid, source)
    end
  end

  # -- Session lifecycle --------------------------------------------------------

  @doc false
  @spec find_or_start_session(String.t()) :: {:ok, pid()} | {:error, term()}
  def find_or_start_session(session_id) do
    session_id = to_string(session_id)
    context = active_session_context(session_id)

    case Registry.lookup(Muse.SessionRegistry, context.registry_key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        start_session(context)
    end
  end

  # -- Private helpers ----------------------------------------------------------

  defp lookup_session(session_id) do
    session_id = to_string(session_id)
    %{registry_key: registry_key} = active_session_context(session_id)

    case Registry.lookup(Muse.SessionRegistry, registry_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp active_session_context(session_id) do
    %{store_base_dir: store_base_dir, workspace: workspace} =
      Muse.SessionServer.current_runtime_context()

    %{
      session_id: session_id,
      store_base_dir: store_base_dir,
      workspace: workspace,
      registry_key: Muse.SessionServer.registry_key(session_id, store_base_dir)
    }
  end

  defp start_session(context) do
    # Use the module shorthand for child_spec; DynamicSupervisor.start_child
    # passes the arg to SessionServer.child_spec/1. The :via-registered name
    # guarantees that concurrent callers for the same session_id in the same
    # workspace get the same pid. We still defensively resolve already-started
    # responses through the registry because OTP can surface race results in
    # more than one shape.
    case DynamicSupervisor.start_child(
           Muse.SessionSupervisor,
           {Muse.SessionServer,
            session_id: context.session_id,
            store_base_dir: context.store_base_dir,
            workspace: context.workspace}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:ok, pid}

      {:error, :already_started} ->
        lookup_started_session(context.registry_key, :already_started)

      {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}}
      when is_pid(pid) ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_started_session(registry_key, fallback_reason) do
    case Registry.lookup(Muse.SessionRegistry, registry_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, fallback_reason}
    end
  end
end
