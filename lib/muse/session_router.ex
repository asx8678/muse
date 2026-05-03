defmodule Muse.SessionRouter do
  @moduledoc """
  Routes `Muse.submit/2` calls to the correct `Muse.SessionServer` process.

  ## Session lifecycle

  Sessions are identified by a string `session_id`.  The router:

    1. Checks `Muse.SessionRegistry` for an existing session.
    2. If found, returns the existing pid.
    3. If not found, starts a new `Muse.SessionServer` under
       `Muse.SessionSupervisor` using a `{:via, Registry, …}` name for
       atomic registration — concurrent callers for the same id safely
       race, and losing callers resolve the already-started process through
       the registry.
    4. The session pid is looked up via the Registry, not cached locally,
       so the registry stays as the single source of truth.

  ## Default session

  `Muse.submit/2` uses `"default"` as the session id for backward
  compatibility.  Lower-level APIs accept an explicit `:session_id` option.
  """

  @default_session_id "default"

  # -- Public API ---------------------------------------------------------------

  @doc """
  Submits user input to the session identified by `session_id`.

  Returns `{:ok, assistant_text}` — the same shape as `Muse.submit/2`.
  """
  @spec submit(String.t(), atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(session_id \\ @default_session_id, source, text) do
    with {:ok, pid} <- find_or_start_session(session_id) do
      Muse.SessionServer.submit(pid, source, text)
    end
  end

  @doc """
  Returns the status map for the given session, or `{:error, :not_found}`.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(session_id \\ @default_session_id) do
    case Registry.lookup(Muse.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, Muse.SessionServer.status(pid)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all active session ids and their pids.
  """
  @spec active_sessions() :: [{String.t(), pid()}]
  def active_sessions do
    Registry.select(Muse.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  end

  # -- Session lifecycle --------------------------------------------------------

  @doc false
  @spec find_or_start_session(String.t()) :: {:ok, pid()} | {:error, term()}
  def find_or_start_session(session_id) do
    session_id = to_string(session_id)

    case Registry.lookup(Muse.SessionRegistry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        start_session(session_id)
    end
  end

  # -- Private helpers ----------------------------------------------------------

  defp start_session(session_id) do
    # Use the module shorthand for child_spec; DynamicSupervisor.start_child
    # passes the arg to SessionServer.child_spec/1. The :via-registered name
    # guarantees that concurrent callers for the same session_id get the same
    # pid. We still defensively resolve already-started responses through the
    # registry because OTP can surface race results in more than one shape.
    case DynamicSupervisor.start_child(
           Muse.SessionSupervisor,
           {Muse.SessionServer, session_id: session_id}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:ok, pid}

      {:error, :already_started} ->
        lookup_started_session(session_id, :already_started)

      {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}}
      when is_pid(pid) ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_started_session(session_id, fallback_reason) do
    case Registry.lookup(Muse.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, fallback_reason}
    end
  end
end
