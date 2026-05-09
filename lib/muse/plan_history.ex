defmodule Muse.PlanHistory do
  @moduledoc """
  Read-only query and rendering helpers for Muse Plan history commands.

  This module is intentionally non-mutating: it only normalizes plan data that
  is already present in command context or returned by `Muse.SessionRouter.status/1`.
  It must not start sessions, submit turns, approve/reject plans, execute tools,
  run shell commands, or write workspace files.
  """

  alias Muse.Plan

  @type query :: %{
          plans: [Plan.t()],
          active_plan: Plan.t() | nil,
          active_plan_id: String.t() | nil,
          session_status: term()
        }

  @doc """
  Builds a normalized, read-only view of the current session's Muse Plans.

  Context values are preferred. If no plan data is present, the helper falls
  back to `Muse.SessionRouter.status/1` for the context session id (or
  `"default"`) without starting a missing session.
  """
  @spec query(map() | term()) :: query()
  def query(context) when is_map(context) do
    context_query = query_from_map(context)

    if query_has_plans?(context_query) do
      context_query
    else
      case router_query(context_session_id(context)) do
        nil -> context_query
        router_query -> router_query
      end
    end
  end

  def query(_context) do
    case router_query("default") do
      nil -> empty_query()
      router_query -> router_query
    end
  end

  @doc """
  Renders a non-empty Muse Plan history list.
  """
  @spec render_history([Plan.t()], term()) :: String.t()
  def render_history(plans, active_plan_id) when is_list(plans) do
    count = length(plans)
    label = if count == 1, do: "Muse Plan", else: "Muse Plans"

    lines = Enum.map(plans, &render_plan_history_line(&1, active_plan_id))

    "Muse Plan history: #{count} #{label}\n" <> Enum.join(lines, "\n")
  end

  @doc """
  Renders concise lifecycle status for the active Muse Plan.
  """
  @spec render_active_status(Plan.t(), query()) :: String.t()
  def render_active_status(%Plan{} = plan, query) do
    [
      "Active Muse Plan status:",
      "- Active plan id: #{display_plan_id(plan)}",
      "- Version: #{plan.version}",
      "- Plan status: #{format_status(plan.status)}",
      Muse.ApprovalAudit.status_lines(plan),
      maybe_line(
        "- Session status: #{format_status(query.session_status)}",
        query.session_status
      ),
      "- Summary: #{plan_summary(plan)}",
      "- Task count: #{task_count(plan)}",
      timestamp_line("Created at", plan.created_at),
      timestamp_line("Updated at", plan.updated_at),
      timestamp_line("Approved at", plan.approved_at),
      timestamp_line("Rejected at", plan.rejected_at)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Finds a Muse Plan by id in a normalized plan list.
  """
  @spec find_plan_by_id([Plan.t()], term()) :: Plan.t() | nil
  def find_plan_by_id(plans, id) when is_list(plans) do
    normalized_id = normalize_plan_id(id)
    Enum.find(plans, &(plan_id(&1) == normalized_id))
  end

  def find_plan_by_id(_plans, _id), do: nil

  @doc """
  Returns a display-safe Muse Plan id.
  """
  @spec display_plan_id(Plan.t()) :: String.t()
  def display_plan_id(%Plan{} = plan), do: plan_id(plan) || "(no id)"

  # -- Querying ----------------------------------------------------------------

  defp router_query(session_id) do
    case Muse.SessionRouter.status(session_id) do
      {:ok, status} when is_map(status) -> query_from_map(status)
      _ -> nil
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :router_query, e)
      nil
  catch
    :exit, reason ->
      Muse.Diagnostics.SilentRescue.log_rescued_catch(__MODULE__, :router_query, :exit, reason)
      nil
  end

  defp query_from_map(source) when is_map(source) do
    session =
      case map_get_any(source, [:session, "session"]) do
        session when is_map(session) -> session
        _ -> %{}
      end

    active_plan_id =
      map_get_any(source, [:active_plan_id, "active_plan_id"]) ||
        map_get_any(session, [:active_plan_id, "active_plan_id"])

    active_plan =
      [
        map_get_any(source, [:plan, "plan"]),
        map_get_any(source, [:active_plan, "active_plan"]),
        map_get_any(session, [:plan, "plan"]),
        map_get_any(session, [:active_plan, "active_plan"])
      ]
      |> Enum.find_value(&normalize_plan_value/1)
      |> ensure_plan_id(active_plan_id)

    plans_data =
      map_get_any(source, [:plans, "plans"]) || map_get_any(session, [:plans, "plans"])

    plans =
      plans_data
      |> normalize_plan_collection()
      |> put_plan_if_missing(active_plan)

    active_plan = active_plan || find_plan_by_id(Map.values(plans), active_plan_id)
    active_plan_id = normalize_plan_id(active_plan_id) || plan_id(active_plan)

    %{
      plans: sort_plans(Map.values(plans)),
      active_plan: active_plan,
      active_plan_id: active_plan_id,
      session_status:
        map_get_any(source, [:session_status, "session_status", :status, "status"]) ||
          map_get_any(session, [:status, "status"])
    }
  end

  defp query_from_map(_source), do: empty_query()

  defp empty_query do
    %{plans: [], active_plan: nil, active_plan_id: nil, session_status: nil}
  end

  defp query_has_plans?(%{plans: plans, active_plan: active_plan}) do
    plans != [] or not is_nil(active_plan)
  end

  defp context_session_id(context) do
    case map_get_any(context, [:session_id, "session_id"]) do
      nil -> "default"
      session_id -> to_string(session_id)
    end
  end

  # -- Normalization -----------------------------------------------------------

  defp normalize_plan_collection(plans) when is_map(plans) do
    Enum.reduce(plans, %{}, fn {key, value}, acc ->
      key_id = normalize_plan_id(key)

      case value |> normalize_plan_value() |> ensure_plan_id(key_id) do
        %Plan{} = plan -> put_plan(acc, plan)
        nil -> acc
      end
    end)
  end

  defp normalize_plan_collection(plans) when is_list(plans) do
    Enum.reduce(plans, %{}, fn value, acc ->
      case normalize_plan_value(value) do
        %Plan{} = plan -> put_plan(acc, plan)
        _ -> acc
      end
    end)
  end

  defp normalize_plan_collection(_plans), do: %{}

  defp normalize_plan_value(%Plan{} = plan), do: plan

  defp normalize_plan_value(plan_map) when is_map(plan_map) do
    Plan.from_map(plan_map)
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :normalize_plan_value, e)
      nil
  end

  defp normalize_plan_value(_), do: nil

  defp ensure_plan_id(nil, _id), do: nil
  defp ensure_plan_id(%Plan{id: id} = plan, _id) when not is_nil(id), do: plan
  defp ensure_plan_id(%Plan{} = plan, id), do: %{plan | id: normalize_plan_id(id)}

  defp put_plan(plans, %Plan{} = plan) do
    case plan_id(plan) do
      nil -> plans
      id -> Map.put(plans, id, plan)
    end
  end

  defp put_plan_if_missing(plans, nil), do: plans

  defp put_plan_if_missing(plans, %Plan{} = plan) do
    case plan_id(plan) do
      nil -> plans
      id -> Map.put_new(plans, id, plan)
    end
  end

  # -- Rendering ---------------------------------------------------------------

  defp render_plan_history_line(%Plan{} = plan, active_plan_id) do
    active_marker =
      if plan_id(plan) == normalize_plan_id(active_plan_id), do: " [active]", else: ""

    "- #{display_plan_id(plan)}#{active_marker} — #{format_status(plan.status)} — #{plan_summary(plan)} — #{task_count(plan)} task(s)"
  end

  defp plan_summary(%Plan{} = plan) do
    [plan.title, plan.objective, plan.summary]
    |> Enum.find_value(fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
    |> case do
      nil -> "(no objective)"
      summary -> truncate(summary, 96)
    end
  end

  defp task_count(%Plan{tasks: tasks}) when is_list(tasks), do: length(tasks)
  defp task_count(_), do: 0

  defp format_status(nil), do: "unknown"
  defp format_status(status) when is_atom(status), do: Atom.to_string(status)
  defp format_status(status) when is_binary(status), do: status
  defp format_status(status), do: safe_to_string(status)

  defp timestamp_line(_label, nil), do: nil
  defp timestamp_line(label, timestamp), do: "- #{label}: #{format_timestamp(timestamp)}"

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp format_timestamp(timestamp), do: safe_to_string(timestamp)

  defp maybe_line(_line, nil), do: nil
  defp maybe_line(line, _value), do: line

  defp truncate(value, max_length) when byte_size(value) <= max_length, do: value

  defp truncate(value, max_length) do
    value
    |> String.slice(0, max_length - 1)
    |> Kernel.<>("…")
  end

  # -- Sorting -----------------------------------------------------------------

  defp sort_plans(plans) do
    Enum.sort(plans, fn left, right ->
      case compare_plan_timestamps(left, right) do
        :gt ->
          true

        :lt ->
          false

        :eq ->
          {plan_id(left) || "", String.downcase(plan_summary(left))} <=
            {plan_id(right) || "", String.downcase(plan_summary(right))}
      end
    end)
  end

  defp compare_plan_timestamps(left, right) do
    case {plan_timestamp_sort_value(left), plan_timestamp_sort_value(right)} do
      {nil, nil} -> :eq
      {_left, nil} -> :gt
      {nil, _right} -> :lt
      {same, same} -> :eq
      {left_ts, right_ts} when left_ts > right_ts -> :gt
      {_left_ts, _right_ts} -> :lt
    end
  end

  defp plan_timestamp_sort_value(%Plan{} = plan) do
    timestamp_sort_value(plan.updated_at) || timestamp_sort_value(plan.created_at)
  end

  defp timestamp_sort_value(%DateTime{} = timestamp),
    do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.to_unix(timestamp, :microsecond)
      _ -> nil
    end
  end

  defp timestamp_sort_value(_), do: nil

  # -- Shared helpers ----------------------------------------------------------

  defp plan_id(%Plan{id: id}), do: normalize_plan_id(id)
  defp plan_id(_), do: nil

  defp normalize_plan_id(nil), do: nil
  defp normalize_plan_id(id) when is_binary(id), do: id
  defp normalize_plan_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_plan_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_plan_id(id), do: safe_to_string(id)

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp map_get_any(_map, _keys), do: nil

  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value), do: inspect(value)
end
