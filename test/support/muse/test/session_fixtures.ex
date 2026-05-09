defmodule Muse.Test.SessionFixtures do
  @moduledoc """
  Reusable helpers for building session, turn, and tool-call test data.

  These helpers produce deterministic structs and maps suitable for
  testing `SessionServer`, `SessionStore`, `Conductor`, and related
  modules without starting real processes or writing to disk.

  ## Usage

      alias Muse.Test.SessionFixtures, as: SF

      session = SF.build_session(id: "sess_1")
      turn = SF.build_turn(session_id: "sess_1", id: "turn_1")
  """

  alias Muse.{Session, Turn}

  @doc "Build a `%Session{}` with sensible defaults."
  @spec build_session(keyword()) :: Session.t()
  def build_session(opts \\ []) do
    Session.new(
      workspace: Keyword.get(opts, :workspace, "/tmp/muse_test_workspace"),
      id: Keyword.get(opts, :id),
      status: Keyword.get(opts, :status, :idle),
      active_muse: Keyword.get(opts, :active_muse, "planning"),
      created_at: Keyword.get(opts, :created_at, ~U[2025-01-15 12:00:00Z]),
      updated_at: Keyword.get(opts, :updated_at, ~U[2025-01-15 12:00:00Z])
    )
  end

  @doc "Build a `%Turn{}` with sensible defaults."
  @spec build_turn(keyword()) :: Turn.t()
  def build_turn(opts \\ []) do
    Turn.new(
      session_id: Keyword.get(opts, :session_id, "sess_1"),
      id: Keyword.get(opts, :id, "turn_test"),
      source: Keyword.get(opts, :source, :user),
      user_text: Keyword.get(opts, :user_text, "test input"),
      selected_muse: Keyword.get(opts, :selected_muse, "planning"),
      started_at: Keyword.get(opts, :started_at, ~U[2025-01-15 12:00:00Z])
    )
  end

  @doc "Transition a turn to `:running` status."
  @spec turn_running(Turn.t()) :: Turn.t()
  def turn_running(%Turn{} = turn) do
    {:ok, t} = Turn.transition(turn, :running)
    t
  end

  @doc "Transition a turn to `:completed` status."
  @spec turn_completed(Turn.t()) :: Turn.t()
  def turn_completed(%Turn{} = turn) do
    {:ok, t} = Turn.transition(turn, :completed)
    t
  end

  @doc "Transition a turn to `:failed` status."
  @spec turn_failed(Turn.t()) :: Turn.t()
  def turn_failed(%Turn{} = turn) do
    {:ok, t} = Turn.transition(turn, :failed)
    t
  end

  @doc "Transition a turn to `:cancelled` status."
  @spec turn_cancelled(Turn.t()) :: Turn.t()
  def turn_cancelled(%Turn{} = turn) do
    {:ok, t} = Turn.transition(turn, :cancelled)
    t
  end

  @doc """
  Build a tool call map (as would appear in LLM response tool_calls).

  Returns a map with `:name`, `:arguments`, and `:id` keys, matching
  the shape expected by `Muse.LLM.ToolCall.new/3`.
  """
  @spec tool_call_map(String.t(), map(), String.t()) :: map()
  def tool_call_map(name, args \\ %{}, id \\ "tc_test_1") do
    %{name: name, arguments: args, id: id}
  end

  @doc "Build a minimal tool-runner context map."
  @spec tool_context(keyword()) :: map()
  def tool_context(opts \\ []) do
    %{
      workspace: Keyword.get(opts, :workspace, "/tmp/muse_test_workspace"),
      muse_id: Keyword.get(opts, :muse_id, :planning),
      session_id: Keyword.get(opts, :session_id, "sess_1"),
      turn_id: Keyword.get(opts, :turn_id, "turn_1"),
      emit_events?: Keyword.get(opts, :emit_events?, false)
    }
  end

  @doc """
  Build a minimal SessionServer initial state map.

  This mirrors the state that `SessionServer.init/1` produces,
  useful for unit-testing `handle_call` / `handle_info` clauses
  without starting the GenServer.
  """
  @spec server_state(keyword()) :: map()
  def server_state(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "sess_test")
    store_base_dir = Keyword.get(opts, :store_base_dir, "/tmp/muse_test_sessions")

    %{
      session_id: session_id,
      status: Keyword.get(opts, :status, :idle),
      active_muse: Keyword.get(opts, :active_muse, "planning"),
      store_base_dir: store_base_dir,
      workspace: Keyword.get(opts, :workspace, "/tmp/muse_test_workspace"),
      seq: Keyword.get(opts, :seq, 0),
      events: Keyword.get(opts, :events, []),
      active_turn_id: Keyword.get(opts, :active_turn_id),
      runner_pid: Keyword.get(opts, :runner_pid),
      runner_task: Keyword.get(opts, :runner_task),
      from: Keyword.get(opts, :from),
      cancellation_requested: Keyword.get(opts, :cancellation_requested, false),
      plan: Keyword.get(opts, :plan),
      plans: Keyword.get(opts, :plans, %{}),
      approvals: Keyword.get(opts, :approvals, []),
      approval_binding: Keyword.get(opts, :approval_binding, %{}),
      active_approval: Keyword.get(opts, :active_approval),
      active_plan_id: Keyword.get(opts, :active_plan_id),
      pending_patch: Keyword.get(opts, :pending_patch),
      pending_remote_approval: Keyword.get(opts, :pending_remote_approval),
      memory: Keyword.get(opts, :memory),
      checkpoints: Keyword.get(opts, :checkpoints, []),
      artifacts: Keyword.get(opts, :artifacts, []),
      session_events_before_turn: Keyword.get(opts, :session_events_before_turn, []),
      turn_start_time: Keyword.get(opts, :turn_start_time)
    }
  end
end
