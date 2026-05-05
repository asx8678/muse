defmodule Muse.EventDisplay do
  @moduledoc """
  Display-safe event helpers shared by CLI, TUI, and LiveView surfaces.

  The event log is a UI-facing structure, so display helpers must avoid two
  common foot-guns:

    * leaking secrets embedded in ad-hoc event payloads; and
    * rendering raw structured plan JSON instead of the safe rendered plan view.

  These helpers intentionally return concise summaries. Detailed plan rendering
  belongs to `/plan` and `/plan show <id>`, not generic event rows. Approval
  lifecycle summaries also make it explicit that plan approval records a plan
  decision only; it does not start implementation by itself.
  """

  alias Muse.{Event, Plan}
  alias Muse.Prompt.Redactor

  @max_summary_chars 240
  @raw_plan_json_placeholder "[structured plan JSON omitted; use /plan or /plan show <id> for the rendered plan]"
  @plan_lifecycle_types [
    :plan_created,
    :plan_approved,
    :plan_rejected,
    :approval_requested,
    :approval_approved,
    :approval_rejected,
    :patch_proposal
  ]

  @doc "Return a concise, redacted summary for an event."
  @spec summary(Event.t() | term()) :: String.t()
  def summary(%Event{type: :patch_proposal, data: data}) do
    data
    |> safe_data()
    |> patch_proposal_summary()
  end

  def summary(%Event{type: type, data: data}) when type in @plan_lifecycle_types do
    data
    |> safe_data()
    |> plan_lifecycle_summary(type)
  end

  def summary(%Event{data: data}), do: data |> safe_data() |> data_summary()
  def summary(data), do: data |> safe_data() |> data_summary()

  @doc "Redact secrets and replace raw plan payloads with safe summaries."
  @spec safe_data(term()) :: term()
  def safe_data(term) do
    term
    |> Redactor.redact_term()
    |> omit_raw_plan_payloads()
  end

  @doc "Redact text and suppress raw structured plan JSON strings."
  @spec safe_text(String.t()) :: String.t()
  def safe_text(text) when is_binary(text) do
    text
    |> Redactor.redact_text()
    |> maybe_omit_raw_plan_json()
  end

  # -- Plan lifecycle summaries ------------------------------------------------

  defp plan_lifecycle_summary(data, :plan_created) do
    [
      "Plan created: #{plan_identity(data)}",
      "Status: #{format_status(map_get_any(data, [:status, "status"]) || :awaiting_approval)}",
      objective_sentence(data),
      task_count_sentence(data)
    ]
    |> compact_sentences()
  end

  defp plan_lifecycle_summary(data, :plan_approved) do
    [
      "Plan approved: #{plan_identity(data)}",
      "Status: #{format_status(map_get_any(data, [:status, "status"]) || :approved)}",
      task_count_sentence(data),
      "Approval records the plan decision only; implementation still requires a later explicit gate"
    ]
    |> compact_sentences()
  end

  defp plan_lifecycle_summary(data, :plan_rejected) do
    [
      "Plan rejected: #{plan_identity(data)}",
      "Status: #{format_status(map_get_any(data, [:status, "status"]) || :rejected)}",
      task_count_sentence(data),
      "Ask Planning Muse for a revised plan before approving anything"
    ]
    |> compact_sentences()
  end

  defp plan_lifecycle_summary(data, :approval_requested) do
    [
      "Approval requested: #{plan_identity(data)}",
      approval_identity(data),
      hash_sentence(data),
      "Approve with /approve plan or reject with /reject plan"
    ]
    |> compact_sentences()
  end

  defp plan_lifecycle_summary(data, :approval_approved) do
    [
      "Approval recorded: #{plan_identity(data)}",
      approval_identity(data),
      hash_sentence(data),
      "No implementation started"
    ]
    |> compact_sentences()
  end

  defp plan_lifecycle_summary(data, :approval_rejected) do
    [
      "Approval rejected: #{plan_identity(data)}",
      approval_identity(data),
      hash_sentence(data),
      "No implementation started"
    ]
    |> compact_sentences()
  end

  # -- Patch proposal summaries ----------------------------------------------

  @max_diff_summary_chars 120

  defp patch_proposal_summary(data) when is_map(data) do
    hash =
      map_get_any(data, [:patch_hash, "patch_hash", :content_hash, "content_hash"])
      |> present_string()

    files =
      map_get_any(data, [:files, "files"])
      |> files_summary()

    diff_preview =
      map_get_any(data, [:diff, "diff"])
      |> diff_summary()

    [
      if(hash, do: "Patch hash: #{String.slice(hash, 0, 12)}", else: nil),
      files,
      diff_preview,
      "PR17 lifecycle only: no apply, no checkpoints, no file modifications"
    ]
    |> compact_sentences()
  end

  defp patch_proposal_summary(data), do: data_summary(data)

  defp files_summary(nil), do: nil

  defp files_summary(files) when is_list(files) do
    case length(files) do
      0 -> nil
      n -> "#{n} file(s) affected"
    end
  end

  defp files_summary(_), do: nil

  defp diff_summary(nil), do: nil

  defp diff_summary(diff) when is_binary(diff) do
    preview = String.slice(diff, 0, @max_diff_summary_chars)
    if String.length(diff) > @max_diff_summary_chars, do: "#{preview}…", else: preview
  end

  defp diff_summary(_), do: nil

  # -- Generic summaries --------------------------------------------------------

  defp data_summary(%{text: text}) when is_binary(text), do: summarize_text(text)
  defp data_summary(%{"text" => text}) when is_binary(text), do: summarize_text(text)

  defp data_summary(%{file: file}) when is_binary(file), do: summarize_text(file)
  defp data_summary(%{"file" => file}) when is_binary(file), do: summarize_text(file)

  defp data_summary(%{files: files}) when is_list(files), do: join_files(files)
  defp data_summary(%{"files" => files}) when is_list(files), do: join_files(files)

  defp data_summary(%{issues: issues}) when is_list(issues),
    do: "#{length(issues)} issue(s) attached"

  defp data_summary(%{"issues" => issues}) when is_list(issues),
    do: "#{length(issues)} issue(s) attached"

  defp data_summary(data) when is_map(data) do
    data
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{format_key(key)}=#{format_value(value)}" end)
    |> blank_to_inspect(data)
  end

  defp data_summary(text) when is_binary(text), do: summarize_text(text)
  defp data_summary(nil), do: "nil"
  defp data_summary(other), do: safe_inspect(other)

  defp join_files(files) do
    files
    |> Enum.map(&format_value/1)
    |> Enum.join(", ")
  end

  # -- Raw plan suppression -----------------------------------------------------

  defp omit_raw_plan_payloads(%Plan{} = plan), do: plan_to_summary_map(plan)

  defp omit_raw_plan_payloads(map) when is_map(map) and not is_struct(map) do
    if plan_map?(map) do
      plan_map_to_summary(map)
    else
      Map.new(map, fn {key, value} -> {key, omit_raw_plan_payloads(value)} end)
    end
  end

  defp omit_raw_plan_payloads(list) when is_list(list),
    do: Enum.map(list, &omit_raw_plan_payloads/1)

  defp omit_raw_plan_payloads(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&omit_raw_plan_payloads/1)
    |> List.to_tuple()
  end

  defp omit_raw_plan_payloads(text) when is_binary(text), do: maybe_omit_raw_plan_json(text)
  defp omit_raw_plan_payloads(other), do: other

  defp maybe_omit_raw_plan_json(text) do
    if raw_plan_json?(text), do: @raw_plan_json_placeholder, else: text
  end

  defp raw_plan_json?(text) do
    trimmed = String.trim(text)

    jsonish? =
      String.starts_with?(trimmed, ["{", "```", "["]) or
        (String.contains?(trimmed, "{") and String.contains?(trimmed, "}"))

    objective? = contains_any?(trimmed, ["\"objective\"", "'objective'"])
    tasks? = contains_any?(trimmed, ["\"tasks\"", "'tasks'"])

    jsonish? and objective? and tasks?
  end

  defp plan_map?(map) do
    has_any_key?(map, [:objective, "objective"]) and
      is_list(map_get_any(map, [:tasks, "tasks"]))
  end

  defp plan_to_summary_map(%Plan{} = plan) do
    %{
      plan_id: plan.id,
      version: plan.version,
      status: plan.status,
      objective: safe_optional_text(plan.objective),
      task_count: length(plan.tasks || [])
    }
    |> drop_nil_values()
  end

  defp plan_map_to_summary(map) do
    %{
      plan_id: map_get_any(map, [:plan_id, "plan_id", :id, "id"]),
      version: map_get_any(map, [:version, "version"]),
      status: map_get_any(map, [:status, "status"]),
      objective: map_get_any(map, [:objective, "objective"]) |> safe_optional_text(),
      task_count: task_count(map)
    }
    |> drop_nil_values()
  end

  # -- Plan summary fragments ---------------------------------------------------

  defp plan_identity(data) when is_map(data) do
    id = map_get_any(data, [:plan_id, "plan_id", :id, "id"]) |> present_string()
    version = map_get_any(data, [:version, "version"]) |> present_string()

    base = id || "(no id)"
    if version, do: "#{base} (version #{version})", else: base
  end

  defp plan_identity(_data), do: "(no id)"

  defp objective_sentence(data) when is_map(data) do
    case map_get_any(data, [:objective, "objective"]) do
      objective when is_binary(objective) and objective != "" ->
        "Objective: #{truncate(objective, 160)}"

      _ ->
        nil
    end
  end

  defp objective_sentence(_), do: nil

  defp task_count_sentence(data) when is_map(data) do
    case task_count(data) do
      nil -> nil
      count -> "#{count} task(s)"
    end
  end

  defp task_count_sentence(_), do: nil

  defp approval_identity(data) when is_map(data) do
    case map_get_any(data, [:approval_id, "approval_id", :id, "id"]) |> present_string() do
      nil -> nil
      approval_id -> "Approval id: #{approval_id}"
    end
  end

  defp approval_identity(_), do: nil

  defp hash_sentence(data) when is_map(data) do
    hash =
      map_get_any(data, [
        :content_hash_short,
        "content_hash_short",
        :content_hash,
        "content_hash",
        :plan_hash,
        "plan_hash",
        :hash,
        "hash"
      ])
      |> present_string()

    if hash, do: "Hash: #{String.slice(hash, 0, 12)}", else: nil
  end

  defp hash_sentence(_), do: nil

  defp task_count(map) when is_map(map) do
    case map_get_any(map, [:task_count, "task_count"]) do
      count when is_integer(count) -> count
      count when is_binary(count) -> count
      _ -> task_count_from_tasks(map_get_any(map, [:tasks, "tasks"]))
    end
  end

  defp task_count_from_tasks(tasks) when is_list(tasks), do: length(tasks)
  defp task_count_from_tasks(_), do: nil

  # -- Formatting primitives ----------------------------------------------------

  defp safe_optional_text(nil), do: nil
  defp safe_optional_text(text) when is_binary(text), do: safe_text(text)
  defp safe_optional_text(other), do: other |> safe_inspect() |> safe_text()

  defp summarize_text(text), do: text |> safe_text() |> truncate(@max_summary_chars)

  defp format_value(value) when is_binary(value), do: summarize_text(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: "nil"
  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(%Date{} = value), do: Date.to_iso8601(value)
  defp format_value(%Time{} = value), do: Time.to_iso8601(value)
  defp format_value(value), do: safe_inspect(value)

  defp format_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_key(key) when is_binary(key), do: key
  defp format_key(key), do: safe_inspect(key)

  defp format_status(status) when is_atom(status), do: Atom.to_string(status)
  defp format_status(status) when is_binary(status), do: status
  defp format_status(status), do: format_value(status)

  defp safe_inspect(value) do
    value
    |> inspect(limit: 10, printable_limit: @max_summary_chars)
    |> truncate(@max_summary_chars)
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max - 1) <> "…"
    else
      text
    end
  end

  defp compact_sentences(parts) do
    parts
    |> Enum.reject(&blank?/1)
    |> Enum.join(". ")
    |> Kernel.<>(".")
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  defp blank_to_inspect("", data), do: safe_inspect(data)
  defp blank_to_inspect(text, _data), do: text

  defp present_string(nil), do: nil

  defp present_string(value) do
    value = to_string(value)
    if String.trim(value) == "", do: nil, else: value
  end

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp map_get_any(_map, _keys), do: nil

  defp has_any_key?(map, keys), do: Enum.any?(keys, &Map.has_key?(map, &1))

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
