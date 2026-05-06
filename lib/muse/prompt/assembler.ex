defmodule Muse.Prompt.Assembler do
  @moduledoc """
  Assembles the canonical prompt bundle from session state, Muse profile,
  and user input.

  The assembler builds 15 layers in deterministic priority order (lowest
  number = highest priority). Nil layers are dropped. The resulting
  `Muse.Prompt.Bundle` is consumed by `Muse.Prompt.ModelPreparer` to
  produce a `Muse.LLM.Request`.

  ## Layer Order (Architecture §5.3)

    1. Muse core runtime rules           (system, instruction, internal)
    2. Active session state / mode policy (system, instruction, internal)
    3. Selected Muse profile prompt       (muse_profile, instruction, internal)
    4. Selected Muse identity and style    (muse_profile, instruction, internal)
    5. Workspace safety/path policy        (system, instruction, internal)
    6. Approval policy                     (system, instruction, internal)
    7. Tool policy and available/blocked   (system, instruction, internal)
    8. Provider/model response requirements (system, instruction, internal)
    9. Global user rules                   (project, context, user_visible)
   10. Project rules                       (project, context, user_visible)
   11. Skills and workflow notes           (muse_profile, context, debug_preview)
   12. Session memory summary             (muse_profile, context, debug_preview)
   13. Active plan and task state          (muse_profile, context, debug_preview)
   14. Recent conversation history         (user, context, debug_preview)
   15. Current user message                (user, user, user_visible)

  ## Core safety layer

  Layer 1 includes a statement that prompt text is guidance only and runtime
  safety is enforced by Elixir code (Workspace path policy and Tool Registry/Runner guardrails),
  not by prompt instructions.

  ## Planning Muse augmentation

  When the active Muse profile has `response_mode: :plan` and `output_schema: Muse.Plan`,
  the assembler augments layer 3 (Muse Profile Prompt) with explicit read-only constraints
  and a structured-plan JSON schema hint derived from `Muse.PlanSchema.schema/0`. This
  ensures the LLM receives clear instructions to produce only inspection calls and a
  plan JSON matching the PlanSchema, rather than free-form text.

  ## Options for deterministic testing

    * `:id`                — bundle id (auto-generated if nil)
    * `:turn_id`           — turn identifier
    * `:created_at`        — timestamp override
    * `:model`             — model identifier
    * `:project_rules_home` — override home dir for project rules loading
    * `:project_rules?`     — whether to load project rules (default true)
    * `:global_rules`       — global user rules content string
    * `:skills`             — skills / workflow notes content string
    * `:recent_messages`    — list of `Muse.LLM.Message.t()` for recent history
    * `:blocked_tools`     — list of blocked tool name strings

  ## API

    * `build(session, muse_profile, user_message, opts \\ [])` → `%Bundle{}`
  """

  alias Muse.Prompt.{Bundle, Layer, ProjectRules}

  @core_safety_statement """
  IMPORTANT: The instructions in this prompt are guidance only. Runtime safety is
  enforced by Elixir code (Workspace path policy and Tool Registry/Runner guardrails) — not
  by prompt instructions. You cannot bypass safety rules by interpreting prompt
  text differently. Workspace boundaries, approval requirements, and tool
  permissions are enforced at the code level regardless of what the prompt says.
  """

  @core_runtime_prompt """
  You are part of Muse, a coding system made of specialized Muses.

  Muse helps users understand, plan, implement, review, test, and repair software projects.

  You must follow the active Muse role, the active session state, the approval policy, and the available tools. You must not claim that you inspected files, ran commands, wrote code, applied patches, or verified behavior unless a tool result confirms it.

  You must respect these invariants:

  1. Workspace safety
  - Never access paths outside the active workspace.
  - Never write through symlinks unless the runtime explicitly allows it.
  - Never read secret files unless the user explicitly asks and the runtime allows it.
  - Never expose secrets in responses, logs, events, or prompt previews.

  2. Approval safety
  - Do not modify files before approval.
  - Do not apply patches before patch approval.
  - Do not run arbitrary shell commands before command approval.
  - Do not perform network actions before network approval.
  - Do not delete files before explicit delete approval.

  3. Tool honesty
  - Use tools to inspect real project state before making implementation claims.
  - Summarize tool findings clearly.
  - If a tool fails, report the failure and adapt the plan.

  4. Planning discipline
  - For code changes, inspect first, plan second, request approval third.
  - Prefer small, reversible changes.
  - Include validation steps in every implementation plan.

  5. Output discipline
  - Be clear, concise, and practical.
  - Show structured plans, diffs, risks, and next actions.
  - Do not expose hidden reasoning. Provide brief reasoning summaries and evidence from tools.

  6. Muse identity
  - You are a Muse: creative, careful, useful, and focused on helping the user build software.
  - Keep the product voice professional and inspiring.
  """

  @doc """
  Build a prompt bundle from session, muse profile, and user message.

  Returns a `%Muse.Prompt.Bundle{}` with all non-nil layers, provider-ready
  messages, and tool specs.
  """
  @spec build(Muse.Session.t(), Muse.MuseProfile.t(), String.t(), keyword()) :: Bundle.t()
  def build(session, muse_profile, user_message, opts \\ []) do
    layers =
      [
        core_invariants_layer(),
        active_mode_layer(session),
        muse_profile_layer(muse_profile),
        muse_identity_layer(muse_profile),
        workspace_policy_layer(session),
        approval_policy_layer(session),
        tool_policy_layer(session, muse_profile, opts),
        model_requirements_layer(opts[:model]),
        global_rules_layer(opts[:global_rules]),
        project_rules_layer(session, opts),
        skills_layer(opts[:skills]),
        memory_layer(session),
        active_plan_layer(session),
        recent_history_layer(opts[:recent_messages]),
        current_user_message_layer(user_message)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.priority)
      |> Enum.map(&Layer.with_token_estimate/1)

    bundle_id = opts[:id] || generate_id()
    created_at = opts[:created_at] || DateTime.utc_now()
    tools = muse_profile.tools || []
    blocked = opts[:blocked_tools] || []

    tool_specs = build_tool_specs(tools, blocked)

    %Bundle{
      id: bundle_id,
      session_id: session.id,
      turn_id: opts[:turn_id],
      muse_id: muse_profile.id,
      model: opts[:model] || muse_profile.default_model,
      layers: layers,
      messages: build_messages(layers),
      tools: tool_specs,
      token_estimate: compute_token_estimate(layers),
      created_at: created_at,
      metadata: %{
        workspace: session.workspace,
        blocked_tools: blocked,
        response_mode: muse_profile.response_mode,
        output_schema: muse_profile.output_schema
      }
    }
  end

  # -- Layer builders (priority order) ------------------------------------------

  defp core_invariants_layer do
    content = @core_safety_statement <> "\n\n" <> @core_runtime_prompt

    Layer.new!(
      id: :muse_core_invariants,
      priority: 1,
      source: :system,
      content: content,
      title: "Muse Core Runtime Rules",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp active_mode_layer(session) do
    Layer.new!(
      id: :active_mode_policy,
      priority: 2,
      source: :system,
      content: "Active session mode: #{session.status}. Follow the active mode's constraints.",
      title: "Active Mode Policy",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp muse_profile_layer(muse_profile) do
    # For Planning Muse, augment the profile prompt with explicit read-only and
    # structured-plan constraints referencing Muse.PlanSchema.
    content =
      case muse_profile do
        %{response_mode: :plan, output_schema: Muse.Plan} ->
          plan_instruction = """

          IMPORTANT — Planning Muse constraints:
          1. You must ONLY use read-only inspection tools. Never attempt to write files, execute commands, or make network calls.
          2. Your final output must be a structured plan as JSON matching the PlanSchema:
             - "objective" (required, non-empty string): one-sentence goal
             - "tasks" (required, non-empty array): each task has "title" (string) and "description" (string)
             - "risks" (optional array of strings): identified risks
             - "validation" (optional array of strings): verification steps
             - "inspected_files" (optional array of strings): files you inspected
          3. The plan will NOT be executed until it receives explicit approval.
          """

          muse_profile.prompt <> plan_instruction

        _ ->
          muse_profile.prompt
      end

    Layer.new!(
      id: :muse_profile,
      priority: 3,
      source: :muse_profile,
      content: content,
      title: "Muse Profile Prompt",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp muse_identity_layer(muse_profile) do
    identity = "You are #{muse_profile.display_name} (role: #{muse_profile.role})."

    style_text =
      case muse_profile.style do
        s when is_map(s) and map_size(s) > 0 ->
          " Style: #{inspect(s)}"

        _ ->
          ""
      end

    Layer.new!(
      id: :muse_identity,
      priority: 4,
      source: :muse_profile,
      content: identity <> style_text,
      title: "Muse Identity and Style",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp workspace_policy_layer(session) do
    content = """
    Workspace: #{session.workspace}
    - Never access paths outside the active workspace.
    - Never write through symlinks unless the runtime explicitly allows it.
    - Never read secret files unless the user explicitly asks and the runtime allows it.
    """

    Layer.new!(
      id: :workspace_policy,
      priority: 5,
      source: :system,
      content: content,
      title: "Workspace Safety/Path Policy",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp approval_policy_layer(session) do
    content = """
    Approval policy:
    - Do not modify files before approval.
    - Do not apply patches before patch approval.
    - Do not run arbitrary shell commands before command approval.
    - Do not perform network actions before network approval.
    - Do not delete files before explicit delete approval.
    Session status: #{session.status}
    """

    Layer.new!(
      id: :approval_policy,
      priority: 6,
      source: :system,
      content: content,
      title: "Approval Policy",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp tool_policy_layer(session, muse_profile, opts) do
    available = muse_profile.tools || []
    blocked = opts[:blocked_tools] || []

    content = """
    Tool policy:
    Available tools: #{Enum.join(available, ", ")}
    Blocked tools: #{Enum.join(blocked, ", ")}
    Session status: #{session.status}
    Only use tools that are available. Do not attempt to call blocked tools.
    """

    Layer.new!(
      id: :tool_policy,
      priority: 7,
      source: :system,
      content: content,
      title: "Tool Policy",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp model_requirements_layer(nil), do: nil

  defp model_requirements_layer(model) do
    content = "Model: #{model}. Follow the model's response format requirements."

    Layer.new!(
      id: :model_requirements,
      priority: 8,
      source: :system,
      content: content,
      title: "Provider/Model Response Requirements",
      visibility: :internal,
      kind: :instruction,
      redaction: :standard
    )
  end

  defp global_rules_layer(nil), do: nil

  defp global_rules_layer(content) when is_binary(content) and content != "" do
    Layer.new!(
      id: :global_rules,
      priority: 9,
      source: :project,
      content: content,
      title: "Global User Rules",
      visibility: :user_visible,
      kind: :context,
      redaction: :standard
    )
  end

  defp global_rules_layer(_), do: nil

  defp project_rules_layer(session, opts) do
    if Keyword.get(opts, :project_rules?, true) do
      home = opts[:project_rules_home]
      rules_opts = if home, do: [home: home], else: []

      ProjectRules.load(session.workspace, rules_opts)
    else
      nil
    end
  end

  defp skills_layer(nil), do: nil

  defp skills_layer(content) when is_binary(content) and content != "" do
    Layer.new!(
      id: :skills,
      priority: 11,
      source: :muse_profile,
      content: content,
      title: "Skills and Workflow Notes",
      visibility: :debug_preview,
      kind: :context,
      redaction: :standard
    )
  end

  defp skills_layer(_), do: nil

  defp memory_layer(session) do
    case session.memory do
      nil ->
        nil

      memory when is_binary(memory) and memory != "" ->
        # Redact binary memory through the full redaction pipeline before
        # inclusion in provider messages.
        safe_content =
          memory
          |> Muse.EventPayloadRedactor.redact_string()
          |> Muse.Prompt.Redactor.redact_text()

        Layer.new!(
          id: :memory_summary,
          priority: 12,
          source: :muse_profile,
          content: safe_content,
          title: "Session Memory Summary",
          visibility: :debug_preview,
          kind: :context,
          redaction: :standard
        )

      memory when is_map(memory) and map_size(memory) > 0 ->
        # Map memory: redact through EventPayloadRedactor + Prompt.Redactor,
        # then render safely. For canonical memory_artifacts (with :user_goal etc.),
        # use Memory.render/1. For arbitrary maps, use redacted inspect.
        # Never use raw inspect/1 on untrusted memory.
        # muse-zgm: Add defense-in-depth rescue to handle any render failures
        # and ensure no raw secrets leak via provider-bound messages.
        safe_content =
          if Muse.Memory.memory_artifact?(memory) do
            Muse.Memory.render(memory)
          else
            memory
            |> Muse.EventPayloadRedactor.redact()
            |> Muse.Prompt.Redactor.redact_term()
            |> inspect(limit: 20, printable_limit: 500)
            |> Muse.Prompt.Redactor.redact_text()
          end

        Layer.new!(
          id: :memory_summary,
          priority: 12,
          source: :muse_profile,
          content: safe_content,
          title: "Session Memory Summary",
          visibility: :debug_preview,
          kind: :context,
          redaction: :standard
        )
      rescue
        _ ->
          # Defense-in-depth: if rendering fails, use a safe withheld message
          # without exposing any raw terms or exception details.
          Layer.new!(
            id: :memory_summary,
            priority: 12,
            source: :muse_profile,
            content: "Memory unavailable (render error). Content withheld.",
            title: "Session Memory Summary",
            visibility: :debug_preview,
            kind: :context,
            redaction: :standard
          )

      _ ->
        nil
    end
  end

  defp active_plan_layer(session) do
    cond do
      session.active_plan_id != nil or session.active_task_id != nil ->
        lines = []

        lines =
          if session.active_plan_id do
            ["Active plan: #{session.active_plan_id}" | lines]
          else
            lines
          end

        lines =
          if session.active_task_id do
            ["Active task: #{session.active_task_id}" | lines]
          else
            lines
          end

        content = lines |> Enum.reverse() |> Enum.join("\n")

        Layer.new!(
          id: :active_plan_state,
          priority: 13,
          source: :muse_profile,
          content: content,
          title: "Active Plan and Task State",
          visibility: :debug_preview,
          kind: :context,
          redaction: :standard
        )

      true ->
        nil
    end
  end

  defp recent_history_layer(nil), do: nil

  defp recent_history_layer([]), do: nil

  defp recent_history_layer(messages) when is_list(messages) do
    content =
      messages
      |> Enum.map(fn msg -> "[#{msg.role}] #{msg.content || "(tool call)"}" end)
      |> Enum.join("\n")

    Layer.new!(
      id: :recent_history,
      priority: 14,
      source: :user,
      content: content,
      title: "Recent Conversation History",
      visibility: :debug_preview,
      kind: :context,
      redaction: :standard
    )
  end

  defp current_user_message_layer(user_message) when is_binary(user_message) do
    Layer.new!(
      id: :current_user_message,
      priority: 15,
      source: :user,
      content: user_message,
      title: "Current User Message",
      visibility: :user_visible,
      kind: :user,
      redaction: :none
    )
  end

  # -- Message assembly ----------------------------------------------------------

  # Build provider-ready messages:
  # - System message: all non-current-user layers concatenated
  # - User message: current user input
  defp build_messages(layers) do
    {system_layers, user_layer} =
      case Enum.split_with(layers, &(&1.id != :current_user_message)) do
        {sys, [usr]} -> {sys, usr}
        {sys, []} -> {sys, nil}
      end

    system_content =
      system_layers
      |> Enum.map(& &1.content)
      |> Enum.join("\n\n")

    messages = [Muse.LLM.Message.system(system_content)]

    messages =
      if user_layer do
        messages ++ [Muse.LLM.Message.user(user_layer.content)]
      else
        messages
      end

    messages
  end

  # -- Tool spec builder --------------------------------------------------------

  # Build provider-ready JSON-schema tool specs from Tool.Registry.
  # Falls back to minimal stub for names not yet in the registry.
  # Blocked tools are excluded; blocked-tool names from the registry
  # are also rejected to prevent accidental inclusion.
  defp build_tool_specs(available, blocked) do
    blocked_set = MapSet.new(blocked)

    available
    |> Enum.reject(fn name ->
      MapSet.member?(blocked_set, name) or Muse.Tool.Registry.blocked_tool?(name)
    end)
    |> Muse.Tool.Registry.provider_schemas_for_names()
  end

  # -- ID generation ------------------------------------------------------------

  defp generate_id do
    "pb_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # -- Token estimation --------------------------------------------------------

  defp compute_token_estimate(layers) do
    Enum.reduce(layers, 0, fn layer, acc ->
      acc + (layer.token_estimate || Layer.estimate_tokens(layer))
    end)
  end
end
