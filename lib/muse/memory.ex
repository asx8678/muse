defmodule Muse.Memory do
  @moduledoc """
  Memory compaction and session context preservation for Muse.

  Memory Muse uses this module to safely compact session context into
  a durable summary that helps future turns without exposing secrets.

  ## Safety

  - Secrets are never persisted in memory artifacts
  - All content is redacted through MetadataSanitizer
  - Memory artifacts are bounded in size
  - Raw diffs, credentials, and sensitive metadata are excluded

  ## Memory Artifact Structure

  A memory artifact contains:
  - `:user_goal` — the primary user objective
  - `:project_facts` — relevant project information
  - `:decisions_made` — key decisions recorded
  - `:approved_plans` — summary of approved plans
  - `:changes_completed` — files changed and status
  - `:validation_results` — test/verification outcomes
  - `:open_issues` — unresolved items
  - `:useful_conventions` — discovered patterns

  """

  alias Muse.{MetadataSanitizer, Session}

  @max_memory_bytes 20_000
  @max_list_length 10
  @max_string_len 1_000

  @type memory_artifact :: %{
          user_goal: String.t() | nil,
          project_facts: [String.t()],
          decisions_made: [String.t()],
          approved_plans: [String.t()],
          changes_completed: [String.t()],
          validation_results: [String.t()],
          open_issues: [String.t()],
          useful_conventions: [String.t()],
          compacted_at: DateTime.t(),
          source_session_id: String.t()
        }

  @doc """
  Create a new empty memory artifact.
  """
  @spec new(keyword()) :: memory_artifact()
  def new(opts \\ []) do
    %{
      user_goal: Keyword.get(opts, :user_goal),
      project_facts: Keyword.get(opts, :project_facts, []),
      decisions_made: Keyword.get(opts, :decisions_made, []),
      approved_plans: Keyword.get(opts, :approved_plans, []),
      changes_completed: Keyword.get(opts, :changes_completed, []),
      validation_results: Keyword.get(opts, :validation_results, []),
      open_issues: Keyword.get(opts, :open_issues, []),
      useful_conventions: Keyword.get(opts, :useful_conventions, []),
      compacted_at: Keyword.get(opts, :compacted_at, DateTime.utc_now()),
      source_session_id: Keyword.get(opts, :source_session_id)
    }
  end

  @doc """
  Compact a session into a memory artifact.

  This extracts key information from the session while ensuring
  no secrets are included. All content is sanitized.

  ## Options

    * `:include_events` — include recent events in compaction (default: false)
    * `:max_events` — maximum events to consider (default: 20)

  """
  @spec compact(Session.t(), keyword()) :: memory_artifact()
  def compact(%Session{} = session, opts \\ []) do
    include_events = Keyword.get(opts, :include_events, false)
    max_events = Keyword.get(opts, :max_events, 20)

    # Extract approved plans safely
    approved_plans =
      session.plans
      |> Map.values()
      |> Enum.filter(&(&1.status == :approved))
      |> Enum.map(&summarize_plan/1)
      |> Enum.map(&sanitize_string/1)
      |> Enum.take(@max_list_length)

    # Extract artifacts safely (e.g., patches applied)
    changes_completed =
      session.artifacts
      |> Enum.map(&summarize_artifact/1)
      |> Enum.map(&sanitize_string/1)
      |> Enum.take(@max_list_length)

    # Extract checkpoints info
    checkpoint_summaries =
      session.checkpoints
      |> Enum.map(&summarize_checkpoint/1)
      |> Enum.map(&sanitize_string/1)
      |> Enum.take(@max_list_length)

    # Combine changes and checkpoints
    changes_completed = changes_completed ++ checkpoint_summaries

    # Extract recent events if requested
    open_issues =
      if include_events do
        extract_open_issues(session, max_events)
      else
        []
      end

    new(
      user_goal: extract_user_goal(session),
      project_facts: extract_project_facts(session),
      decisions_made: extract_decisions(session),
      approved_plans: approved_plans,
      changes_completed: changes_completed,
      validation_results: extract_validation_results(session),
      open_issues: open_issues,
      useful_conventions: extract_conventions(session),
      source_session_id: session.id
    )
    |> bound_size()
  end

  @doc """
  Render a memory artifact as a human-readable string.

  Used by the Prompt Assembler's memory_layer.
  """
  @spec render(memory_artifact()) :: String.t()
  def render(%{user_goal: nil} = memory) do
    render_without_goal(memory)
  end

  def render(memory) do
    sections = [
      goal_section(memory),
      facts_section(memory),
      decisions_section(memory),
      plans_section(memory),
      changes_section(memory),
      validation_section(memory),
      issues_section(memory),
      conventions_section(memory)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Validate that a memory artifact contains no secrets.

  Returns `:ok` if safe, `{:error, reasons}` if secrets detected.
  """
  @spec validate_no_secrets(memory_artifact()) :: :ok | {:error, [String.t()]}
  def validate_no_secrets(memory) do
    memory
    |> Map.drop([:compacted_at, :source_session_id])
    |> Enum.flat_map(fn {key, value} ->
      check_for_secrets(key, value)
    end)
    |> case do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  @doc """
  Merge two memory artifacts, preferring newer data.
  """
  @spec merge(memory_artifact(), memory_artifact()) :: memory_artifact()
  def merge(memory1, memory2) do
    # Prefer newer compacted_at
    if DateTime.compare(memory1.compacted_at, memory2.compacted_at) in [:gt, :eq] do
      do_merge(memory1, memory2)
    else
      do_merge(memory2, memory1)
    end
  end

  defp do_merge(newer, older) do
    %{
      user_goal: newer.user_goal || older.user_goal,
      project_facts: merge_list(newer.project_facts, older.project_facts),
      decisions_made: merge_list(newer.decisions_made, older.decisions_made),
      approved_plans: merge_list(newer.approved_plans, older.approved_plans),
      changes_completed: merge_list(newer.changes_completed, older.changes_completed),
      validation_results: merge_list(newer.validation_results, older.validation_results),
      open_issues: merge_list(newer.open_issues, older.open_issues),
      useful_conventions: merge_list(newer.useful_conventions, older.useful_conventions),
      compacted_at: newer.compacted_at,
      source_session_id: newer.source_session_id || older.source_session_id
    }
  end

  defp merge_list(newer, older) do
    (newer ++ older)
    |> Enum.uniq()
    |> Enum.take(@max_list_length)
  end

  # -- Private: Extraction helpers -----------------------------------------------

  defp extract_user_goal(%Session{plans: plans} = _session) when map_size(plans) > 0 do
    # Try to extract from the most recent plan
    plans
    |> Map.values()
    |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      plan -> plan.objective
    end
    |> sanitize_string()
  end

  defp extract_user_goal(_session), do: nil

  defp extract_project_facts(%Session{workspace: workspace}) do
    [
      "Workspace: #{workspace}"
    ]
    |> Enum.map(&sanitize_string/1)
  end

  defp extract_decisions(%Session{approvals: approvals}) when is_list(approvals) do
    approvals
    |> Enum.filter(&(&1.status == :approved))
    |> Enum.map(fn approval ->
      "#{approval.kind || "decision"} approved at #{format_datetime(approval.approved_at)}"
    end)
    |> Enum.map(&sanitize_string/1)
    |> Enum.take(@max_list_length)
  end

  defp extract_decisions(_), do: []

  defp extract_validation_results(%Session{artifacts: artifacts}) when is_list(artifacts) do
    artifacts
    |> Enum.filter(&(&1.type == :verification or &1.type == :test_result))
    |> Enum.map(fn artifact ->
      "Validation: #{artifact.status || "completed"}"
    end)
    |> Enum.map(&sanitize_string/1)
    |> Enum.take(@max_list_length)
  end

  defp extract_validation_results(_), do: []

  defp extract_open_issues(_session, _max_events) do
    # In a full implementation, this would scan recent events for
    # errors, failures, or pending items
    []
  end

  defp extract_conventions(_session) do
    # In a full implementation, this would extract discovered patterns
    []
  end

  # -- Private: Summary helpers --------------------------------------------------

  defp summarize_plan(plan) do
    "#{plan.objective || "Plan"}: #{length(plan.tasks || [])} tasks"
  end

  defp summarize_artifact(artifact) when is_map(artifact) do
    artifact[:description] || artifact[:type] || "artifact"
  end

  defp summarize_artifact(_), do: "artifact"

  defp summarize_checkpoint(checkpoint) when is_map(checkpoint) do
    checkpoint[:status] || checkpoint[:id] || "checkpoint"
  end

  defp summarize_checkpoint(_), do: "checkpoint"

  # -- Private: Sanitization -----------------------------------------------------

  defp sanitize_string(nil), do: nil

  defp sanitize_string(str) when is_binary(str) do
    str
    |> MetadataSanitizer.sanitize(max_string_len: @max_string_len)
    |> to_string()
    |> String.slice(0, @max_string_len)
  end

  defp sanitize_string(other), do: sanitize_string(inspect(other))

  # Secret pattern matchers - defined as module attributes for clarity
  @sk_pattern ~r|sk-[a-zA-Z0-9]+|
  @bearer_pattern ~r|Bearer\s+[a-zA-Z0-9\-._~+/]+=*|
  @api_key_pattern ~r|api[_-]?key\s*[=:]\s*\S+|i
  @password_pattern ~r|password\s*[=:]\s*\S+|i
  @token_pattern ~r|token\s*[=:]\s*\S+|i
  @secret_pattern ~r|secret\s*[=:]\s*\S+|i
  @private_key_pattern ~r|-----BEGIN.*PRIVATE KEY-----|
  @auth_header_pattern ~r|Authorization:\s*Bearer|i

  defp check_for_secrets(key, value) when is_binary(value) do
    patterns = [
      @sk_pattern,
      @bearer_pattern,
      @api_key_pattern,
      @password_pattern,
      @token_pattern,
      @secret_pattern,
      @private_key_pattern,
      @auth_header_pattern
    ]

    matches = Enum.filter(patterns, fn pattern -> Regex.match?(pattern, value) end)

    if matches != [] do
      ["Secret pattern found in #{key}"]
    else
      []
    end
  end

  defp check_for_secrets(key, value) when is_list(value) do
    Enum.flat_map(value, &check_for_secrets(key, &1))
  end

  defp check_for_secrets(key, value) when is_map(value) do
    Enum.flat_map(value, fn {k, v} ->
      check_for_secrets("#{key}.#{k}", v)
    end)
  end

  defp check_for_secrets(_key, _value), do: []

  # -- Private: Size bounding -----------------------------------------------------

  defp bound_size(memory) do
    json =
      memory
      |> Map.drop([:compacted_at, :source_session_id])
      |> Jason.encode!()

    if byte_size(json) > @max_memory_bytes do
      # Truncate lists progressively
      memory
      |> truncate_lists()
      |> bound_size()
    else
      memory
    end
  end

  defp truncate_lists(memory) do
    memory
    |> Map.update!(:project_facts, &Enum.take(&1, max(length(&1) - 1, 0)))
    |> Map.update!(:decisions_made, &Enum.take(&1, max(length(&1) - 1, 0)))
    |> Map.update!(:approved_plans, &Enum.take(&1, max(length(&1) - 1, 0)))
    |> Map.update!(:changes_completed, &Enum.take(&1, max(length(&1) - 1, 0)))
    |> Map.update!(:validation_results, &Enum.take(&1, max(length(&1) - 1, 0)))
    |> Map.update!(:open_issues, &Enum.take(&1, max(length(&1) - 1, 0)))
    |> Map.update!(:useful_conventions, &Enum.take(&1, max(length(&1) - 1, 0)))
  end

  # -- Private: Rendering ---------------------------------------------------------

  defp goal_section(%{user_goal: nil}), do: nil

  defp goal_section(%{user_goal: goal}) do
    "User goal: #{goal}"
  end

  defp render_without_goal(memory) do
    sections = [
      facts_section(memory),
      decisions_section(memory),
      plans_section(memory),
      changes_section(memory),
      validation_section(memory),
      issues_section(memory),
      conventions_section(memory)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp facts_section(%{project_facts: []}), do: nil

  defp facts_section(%{project_facts: facts}) do
    "Project facts:\n" <> Enum.map_join(facts, "\n", &("- " <> &1))
  end

  defp decisions_section(%{decisions_made: []}), do: nil

  defp decisions_section(%{decisions_made: decisions}) do
    "Decisions made:\n" <> Enum.map_join(decisions, "\n", &("- " <> &1))
  end

  defp plans_section(%{approved_plans: []}), do: nil

  defp plans_section(%{approved_plans: plans}) do
    "Approved plans:\n" <> Enum.map_join(plans, "\n", &("- " <> &1))
  end

  defp changes_section(%{changes_completed: []}), do: nil

  defp changes_section(%{changes_completed: changes}) do
    "Changes completed:\n" <> Enum.map_join(changes, "\n", &("- " <> &1))
  end

  defp validation_section(%{validation_results: []}), do: nil

  defp validation_section(%{validation_results: results}) do
    "Validation results:\n" <> Enum.map_join(results, "\n", &("- " <> &1))
  end

  defp issues_section(%{open_issues: []}), do: nil

  defp issues_section(%{open_issues: issues}) do
    "Open issues:\n" <> Enum.map_join(issues, "\n", &("- " <> &1))
  end

  defp conventions_section(%{useful_conventions: []}), do: nil

  defp conventions_section(%{useful_conventions: conventions}) do
    "Useful conventions:\n" <> Enum.map_join(conventions, "\n", &("- " <> &1))
  end

  defp format_datetime(nil), do: "unknown time"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)
end
