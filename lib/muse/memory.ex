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

  alias Muse.{EventPayloadRedactor, MetadataSanitizer, Prompt.Redactor, Session, SessionStore}

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
  Returns true if the given map has the shape of a memory artifact.

  Used by the prompt assembler to decide whether to render through
  `render/1` (canonical artifact) or a generic redacted inspect
  (arbitrary map).
  """
  @spec memory_artifact?(map()) :: boolean()
  def memory_artifact?(map) when is_map(map) do
    Map.has_key?(map, :user_goal) and
      Map.has_key?(map, :compacted_at) and
      Map.has_key?(map, :source_session_id)
  end

  @doc """
  Compact a session into a memory artifact.

  This extracts key information from the session while ensuring
  no secrets are included. All content is sanitized.

  For a fail-closed variant that returns an error tuple when secrets
  are detected, see `compact_safe/2`.

  ## Options

    * `:include_events` — include recent events in compaction (default: false)
    * `:max_events` — maximum events to consider (default: 20)

  """
  @type compact_result ::
          {:ok, memory_artifact()}
          | {:error, :secrets_detected, reasons :: [String.t()]}

  @spec compact(Session.t(), keyword()) :: memory_artifact()
  def compact(%Session{} = session, opts \\ []) do
    do_compact(session, opts)
  end

  @doc """
  Compact a session into a memory artifact with fail-closed validation.

  Returns `{:ok, memory}` on success or `{:error, :secrets_detected, reasons}`
  if secrets are detected after compaction. This is the safe variant that
  callers should prefer when they need to handle the error case.
  """
  @spec compact_safe(Session.t(), keyword()) :: compact_result()
  def compact_safe(%Session{} = session, opts \\ []) do
    memory = do_compact(session, opts)

    case validate_no_secrets(memory) do
      :ok -> {:ok, memory}
      {:error, reasons} -> {:error, :secrets_detected, reasons}
    end
  end

  defp do_compact(session, opts) do
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

  All output is redacted through the event-payload and prompt redactors
  before rendering, ensuring that any secrets that may have been stored
  are never displayed raw.

  Used by the Prompt Assembler's memory_layer and the `/memory` command.
  """
  @spec render(memory_artifact()) :: String.t()
  def render(%{user_goal: nil} = memory) do
    memory
    |> redact_memory()
    |> render_without_goal()
  end

  def render(memory) do
    redacted = redact_memory(memory)

    sections = [
      goal_section(redacted),
      facts_section(redacted),
      decisions_section(redacted),
      plans_section(redacted),
      changes_section(redacted),
      validation_section(redacted),
      issues_section(redacted),
      conventions_section(redacted)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Validate that a memory artifact contains no secrets.

  Checks for two classes of secrets:

    1. **Sensitive keys** — any key (atom or string) matching
       `Muse.MetadataSanitizer.sensitive_key?/1` is flagged regardless of
       the value content. A key like `:password` or `"api_key"` is unsafe
       even if the value doesn't match a token regex.

    2. **Secret patterns** — binary values containing known credential
       patterns (API keys, Bearer tokens, private keys, etc.).

  Recursively walks maps, lists, tuples, keywords, and charlists.
  Non-binary values (tuples, charlists, iodata, etc.) are stringified
  via `inspect/1` and checked for secret patterns.

  Returns `:ok` if safe, `{:error, reasons}` if secrets detected.
  """
  @spec validate_no_secrets(term()) :: :ok | {:error, reasons :: [String.t()]}
  def validate_no_secrets(memory) when is_map(memory) do
    memory
    |> Map.drop([:compacted_at, :source_session_id, "compacted_at", "source_session_id"])
    |> Enum.flat_map(fn {key, value} ->
      check_for_secrets(key, value, [])
    end)
    |> case do
      [] -> :ok
      reasons -> {:error, Enum.uniq(reasons)}
    end
  end

  def validate_no_secrets(memory) do
    {:error, ["memory must be a map, got: #{type_label(memory)}"]}
  end

  @doc """
  Validate memory for secrets and persist it to disk.

  This is the central persistence boundary for memory artifacts. It
  validates the memory with `validate_no_secrets/1` before calling
  `SessionStore.save_memory/3`. If validation fails, the memory is
  **not** written and an error is returned. If the disk write fails,
  the error is propagated to the caller rather than swallowed.

  Returns:
    - `:ok` on successful validation and persistence
    - `{:error, {:unsafe_memory, reasons}}` if secrets are detected
    - `{:error, reason}` if the disk write fails
  """
  @spec validate_and_persist(String.t(), String.t(), term()) ::
          :ok | {:error, {:unsafe_memory, reasons :: [String.t()]} | tuple()}
  def validate_and_persist(store_base_dir, session_id, memory) do
    case validate_no_secrets(memory) do
      :ok ->
        case SessionStore.save_memory(store_base_dir, session_id, memory) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reasons} ->
        {:error, {:unsafe_memory, reasons}}
    end
  end

  @doc """
  Validate memory loaded from disk before trusting it.

  Memory restored from `memory.json` may contain secrets from legacy
  sessions or corrupted files. This function validates the loaded map
  and returns either the safe memory or `nil` (fail-closed).

  Returns:
    - `{:ok, memory}` if the loaded memory is safe
    - `{:error, {:unsafe_memory, reasons}}` if secrets are detected
  """
  @spec validate_loaded_memory(term()) ::
          {:ok, map()} | {:error, {:unsafe_memory, reasons :: [String.t()]}}
  def validate_loaded_memory(memory) when is_map(memory) do
    case validate_no_secrets(memory) do
      :ok -> {:ok, memory}
      {:error, reasons} -> {:error, {:unsafe_memory, reasons}}
    end
  end

  def validate_loaded_memory(memory) do
    {:error, {:unsafe_memory, ["memory must be a map, got: #{type_label(memory)}"]}}
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

  # -- Private: Secret validation (recursive, key-aware) -------------------------

  defp check_for_secrets(key, value, path) when is_binary(value) do
    full_path = path ++ [key]

    # Sensitive-key detection: if the key is sensitive, flag regardless of value.
    # Pattern detection: check binary value against known secret patterns.
    sensitive_key_reasons(full_path) ++
      if secret_pattern_match?(value) do
        ["Secret pattern found in #{format_path(full_path)}"]
      else
        []
      end
  end

  # Keyword lists: check both the key and the value of each pair.
  defp check_for_secrets(key, [{k, _v} | _] = kw, path) when is_atom(k) do
    full_path = path ++ [key]

    # Walk keyword pairs — each pair's key is checked for sensitivity.
    kw_reasons =
      Enum.flat_map(kw, fn {k, v} ->
        pair_key_reasons =
          if sensitive_key?(k) do
            ["Sensitive key #{format_path(full_path ++ [k])} with value present"]
          else
            []
          end

        pair_value_reasons = check_for_secrets(k, v, full_path)
        pair_key_reasons ++ pair_value_reasons
      end)

    sensitive_key_reasons(full_path) ++ kw_reasons
  end

  # 2-tuples: treat as key-value pair if first element is an atom or binary.
  # This catches {:password, "hunter2"} and {"api_key", "plain"} where the
  # first element is a sensitive key.
  defp check_for_secrets(key, {k, v}, path) when is_atom(k) do
    full_path = path ++ [key]

    key_reasons =
      if sensitive_key?(k) do
        ["Sensitive key #{format_path(full_path ++ [k])} with value present"]
      else
        []
      end

    value_reasons = check_for_secrets(k, v, full_path)
    sensitive_key_reasons(full_path) ++ key_reasons ++ value_reasons
  end

  defp check_for_secrets(key, {k, v}, path) when is_binary(k) do
    full_path = path ++ [key]

    key_reasons =
      if sensitive_key?(k) do
        ["Sensitive key #{format_path(full_path ++ [k])} with value present"]
      else
        []
      end

    value_reasons = check_for_secrets(k, v, full_path)
    sensitive_key_reasons(full_path) ++ key_reasons ++ value_reasons
  end

  # Tuples (3+ elements): convert to list and recurse.
  defp check_for_secrets(key, value, path) when is_tuple(value) do
    full_path = path ++ [key]

    tuple_reasons =
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {elem, idx} ->
        check_for_secrets("[#{idx}]", elem, full_path)
      end)

    sensitive_key_reasons(full_path) ++ tuple_reasons
  end

  # Maps: recurse into each key/value pair.
  defp check_for_secrets(key, value, path) when is_map(value) do
    full_path = path ++ [key]

    map_reasons =
      Enum.flat_map(value, fn {k, v} ->
        check_for_secrets(k, v, full_path)
      end)

    sensitive_key_reasons(full_path) ++ map_reasons
  end

  # Lists: check if this is a charlist first, then recurse into each element.
  # Charlists (lists of integers) are stringified and checked for secret
  # patterns in addition to the per-element recursion.
  defp check_for_secrets(key, value, path) when is_list(value) do
    full_path = path ++ [key]

    # Check for charlist: a list of integers that can be converted to a string.
    charlist_reasons =
      if charlist?(value) do
        try do
          stringified = List.to_string(value)

          pattern_reasons =
            if secret_pattern_match?(stringified) do
              ["Secret pattern found in #{format_path(full_path)} (charlist)"]
            else
              []
            end

          pattern_reasons
        rescue
          ArgumentError -> []
        end
      else
        []
      end

    list_reasons =
      Enum.with_index(value)
      |> Enum.flat_map(fn {elem, idx} ->
        check_for_secrets("[#{idx}]", elem, full_path)
      end)

    sensitive_key_reasons(full_path) ++ charlist_reasons ++ list_reasons
  end

  # Catch-all: inspect non-standard types (pids, refs, functions, iodata, etc.)
  # and check the stringified form for secrets.
  defp check_for_secrets(key, value, path) do
    full_path = path ++ [key]

    stringified = inspect(value, limit: 10, printable_limit: 200)

    value_reasons =
      if secret_pattern_match?(stringified) do
        ["Secret pattern found in #{format_path(full_path)} (non-binary value)"]
      else
        []
      end

    sensitive_key_reasons(full_path) ++ value_reasons
  end

  # Helper: produce key-related rejection reasons for a given path if the last
  # element is sensitive or itself looks like a secret. Used by composite-type
  # clauses above. Path formatting is redacted so malicious key names cannot
  # leak raw secret values through error reasons.
  defp sensitive_key_reasons(full_path) do
    case List.last(full_path) do
      nil ->
        []

      key ->
        sensitive_reason =
          if sensitive_key?(key),
            do: ["Sensitive key #{format_path(full_path)} with value present"],
            else: []

        key_secret_reason =
          if secret_pattern_match?(key_to_binary(key)),
            do: ["Secret pattern found in key #{format_path(full_path)}"],
            else: []

        sensitive_reason ++ key_secret_reason
    end
  end

  # Check if a key (atom or string) is sensitive using MetadataSanitizer.
  defp sensitive_key?(key), do: MetadataSanitizer.sensitive_key?(key)

  # Check if a list is a charlist (all elements are integers in Unicode range).
  defp charlist?([]), do: false

  defp charlist?([h | _] = list) when is_integer(h) do
    Enum.all?(list, fn
      i when is_integer(i) and i >= 0 and i <= 0x10FFFF -> true
      _ -> false
    end)
  end

  defp charlist?(_), do: false

  # Check a binary string against known secret patterns.
  @sk_pattern ~r|sk-[a-zA-Z0-9]+|
  @bearer_pattern ~r|Bearer\s+[a-zA-Z0-9\-._~+/]+=*|
  @api_key_pattern ~r|api[_-]?key\s*[=:]\s*\S+|i
  @password_pattern ~r|password\s*[=:]\s*\S+|i
  @token_pattern ~r|token\s*[=:]\s*\S+|i
  @secret_pattern ~r|secret\s*[=:]\s*\S+|i
  @private_key_pattern ~r|-----BEGIN.*PRIVATE KEY-----|
  @auth_header_pattern ~r|Authorization:\s*Bearer|i

  defp secret_pattern_match?(binary) when is_binary(binary) do
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

    Enum.any?(patterns, &Regex.match?(&1, binary)) or redaction_would_change?(binary)
  end

  defp secret_pattern_match?(_), do: false

  # Format a path list as a dot-separated string for error messages.
  # Segments are sanitized so error reasons never echo raw secret-like keys.
  defp format_path([]), do: "root"
  defp format_path(path), do: Enum.map_join(path, ".", &safe_path_segment/1)

  defp safe_path_segment(segment) when is_binary(segment) do
    segment
    |> EventPayloadRedactor.redact_string()
    |> Redactor.redact_text()
  end

  defp safe_path_segment(segment) when is_atom(segment),
    do: segment |> Atom.to_string() |> safe_path_segment()

  defp safe_path_segment(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp safe_path_segment(segment) when is_float(segment), do: Float.to_string(segment)
  defp safe_path_segment(segment) when is_list(segment), do: "<list>"
  defp safe_path_segment(segment) when is_tuple(segment), do: "<tuple>"
  defp safe_path_segment(segment) when is_map(segment), do: "<map>"
  defp safe_path_segment(_segment), do: "<term>"

  defp key_to_binary(key) when is_binary(key), do: key
  defp key_to_binary(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_binary(_key), do: ""

  defp redaction_would_change?(binary) do
    redacted =
      binary
      |> EventPayloadRedactor.redact_string()
      |> Redactor.redact_text()
      |> redact_private_key_header()

    redacted != binary
  end

  defp type_label(value) when is_map(value), do: "map"
  defp type_label(value) when is_binary(value), do: "binary"

  defp type_label(value) when is_list(value),
    do: if(charlist?(value), do: "charlist", else: "list")

  defp type_label(value) when is_tuple(value), do: "tuple"
  defp type_label(value) when is_atom(value), do: "atom"
  defp type_label(value) when is_integer(value), do: "integer"
  defp type_label(value) when is_float(value), do: "float"
  defp type_label(value) when is_pid(value), do: "pid"
  defp type_label(value) when is_reference(value), do: "reference"
  defp type_label(value) when is_function(value), do: "function"
  defp type_label(_value), do: "term"

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

  # -- Private: Memory redaction --------------------------------------------------

  # Redact all values in the memory artifact through the full redaction
  # pipeline before rendering. Applies key-aware structural redaction
  # (EventPayloadRedactor + Prompt.Redactor) to ALL artifact fields — not
  # just :open_issues — then converts to strings and applies string-level
  # pattern redaction as a final pass. This ensures that even malformed
  # nested terms (maps, tuples with sensitive keys, etc.) cannot leak
  # secret values through rendering.
  #
  # muse-zgm: Normalize each expected list field before Enum.map/2 to handle
  # malformed canonical memory where a list field is replaced by a tuple,
  # scalar, or other non-list term. This prevents crashes and ensures
  # secrets are still redacted even when the memory structure is unexpected.
  defp redact_memory(memory) do
    list_keys =
      [
        :project_facts,
        :decisions_made,
        :approved_plans,
        :changes_completed,
        :validation_results,
        :open_issues,
        :useful_conventions
      ]

    memory
    |> safe_update(:user_goal, &redact_optional_string/1)
    |> then(fn mem ->
      Enum.reduce(list_keys, mem, fn key, acc ->
        safe_update(acc, key, fn list_field ->
          redact_list_field(list_field)
        end)
      end)
    end)
  end

  # Normalize and redact an expected list field value.
  #
  # Handles malformed canonical memory safely:
  #   - Proper list: map entries through structural + string redaction
  #   - Nil: treat as empty list (omit section)
  #   - Printable charlist: treat as single string value, redact safely
  #   - Non-list (tuple, map, scalar, etc.): treat as single item, redact
  #
  # This ensures that secrets in malformed fields are still redacted and
  # rendering does not crash.
  defp redact_list_field(nil), do: []

  defp redact_list_field(list) when is_list(list) do
    # Check if this is a charlist (list of integers representing a string)
    if charlist?(list) do
      # Charlist: treat as single string value, not as list of codepoints
      [redact_charlist(list)]
    else
      # Normal list: redact each entry
      Enum.map(list, &redact_term_value/1)
    end
  end

  # Non-list values: treat as single malformed item and redact
  # This catches tuples like {:password, "sentinel"} that replace whole fields
  defp redact_list_field(non_list) do
    [redact_term_value(non_list)]
  end

  # Redact a charlist as a single string value.
  # Converts to string first, then applies full redaction pipeline.
  defp redact_charlist(charlist) do
    try do
      charlist
      |> List.to_string()
      |> redact_string_value()
    rescue
      ArgumentError ->
        # Invalid charlist: inspect and redact the inspected form
        charlist
        |> inspect(limit: 10, printable_limit: 200)
        |> redact_string_value()
    end
  end

  # Safe version of Map.update!/3 that handles missing keys gracefully.
  # For canonical memory artifacts (which always have these keys), behaves
  # identically. For arbitrary maps, applies the function if the key exists,
  # or skips otherwise.
  defp safe_update(map, key, fun) when is_map(map) do
    if Map.has_key?(map, key) do
      Map.update!(map, key, fun)
    else
      # For unknown keys in arbitrary maps, redact the value if present
      map
    end
  end

  defp redact_optional_string(nil), do: nil
  defp redact_optional_string(str) when is_binary(str), do: redact_string_value(str)

  # Non-string user_goal: apply key-aware structural redaction before
  # converting to string, so sensitive-key values in nested terms are
  # never leaked via raw inspect.
  defp redact_optional_string(other), do: redact_term_value(other)

  # Redact private key headers that don't have the full BEGIN...END block.
  # Prompt.Redactor.redact_text only matches the full block pattern, so
  # partial headers need separate handling.
  @private_key_header_pattern ~r/-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----/

  defp redact_string_value(str) when is_binary(str) do
    str
    |> EventPayloadRedactor.redact_string()
    |> Redactor.redact_text()
    |> redact_private_key_header()
  end

  defp redact_private_key_header(str) when is_binary(str) do
    Regex.replace(@private_key_header_pattern, str, "[REDACTED]")
  end

  # Redact any term value for safe rendering. Always returns a string
  # so that section rendering functions (which use string concatenation)
  # cannot crash on non-string elements.
  #
  # For complex terms (maps, tuples, lists), applies key-aware structural
  # redaction first (EventPayloadRedactor + Prompt.Redactor), then converts
  # to a bounded inspect string, then applies string-level pattern redaction
  # as a final pass. This two-phase approach catches both:
  #   - sensitive-key values (e.g. {:password, "hunter2"}) via structural redaction
  #   - secret patterns in values (e.g. "sk-abc123") via string redaction
  defp redact_term_value(term) when is_binary(term), do: redact_string_value(term)

  defp redact_term_value(term) do
    term
    |> EventPayloadRedactor.redact()
    |> Redactor.redact_term()
    |> inspect(limit: 10, printable_limit: 200)
    |> redact_string_value()
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
