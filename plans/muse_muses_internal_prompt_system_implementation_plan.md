# Muse Internal Prompt System Implementation Plan

## Product Direction

Muse should feel like a system of specialized Muses: creative, practical, disciplined software-building companions that inspire the user and execute work safely. The application should use **Muse-first language everywhere**.

User-facing names should be:

| Role | User-facing name | Purpose |
|---|---|---|
| Orchestration | Muse Conductor | Selects the right Muse, manages turns, permissions, plans, tools, and events. |
| Planning | Planning Muse | Inspects the workspace and creates approval-gated implementation plans. |
| Coding | Coding Muse | Implements approved changes through patches and controlled tools. |
| Review | Reviewing Muse | Reviews diffs, architecture, risk, style, and maintainability. |
| Testing | Testing Muse | Runs and interprets verification steps. |
| Research | Research Muse | Searches the repository, reads files, and gathers context. |
| Memory | Memory Muse | Summarizes sessions, preserves lessons, and prepares compact context. |
| Restoration | Restoration Muse | Helps diagnose failures, recover from broken states, and resume from checkpoints. |
| Tool Stewardship | Tool Muse | Represents controlled access to file, search, git, shell, test, and patch tools. |

Developer-facing modules can still use technical terms where unavoidable, but the UI, CLI output, prompts, logs shown to users, docs, and examples should speak in terms of **Muses**, not mascots or generic assistant branding.

---

## 1. Target Outcome

Muse should not send a raw user message directly to a model. It should build a layered internal prompt and execute the turn through a controlled runtime.

```text
User message
  + selected Muse profile
  + Muse core runtime rules
  + active mode policy
  + workspace and approval policy
  + available tools
  + global and project rules
  + skills and workflow guidance
  + session memory
  + current plan and task state
  + recent conversation history
  + current user message
  + model-specific prompt formatting
  => LLM provider
  => tool-call loop
  => approval gate
  => events
  => persisted session
  => final user response
```

The experience should look like this:

```text
muse> add a /version command

Planning Muse:
I will inspect the CLI command structure, find the project version source,
create an implementation plan, and wait for approval before changes.

[read-only inspection events stream here]

Plan ready:
1. Locate CLI command routing.
2. Add /version handling.
3. Source version from the project config.
4. Add tests.
5. Verify through the CLI test suite.

Approve this plan? [y/N]
```

Then:

```text
muse> proceed

Muse Conductor:
Plan approved. Coding Muse will prepare a patch.

Coding Muse:
I found the command handler and test file. Here is the proposed diff.

Apply this patch? [y/N]
```

The important behavior is this:

- Planning Muse can inspect with read-only tools before approval.
- Coding Muse can only modify files after approval.
- Patches require visible diffs.
- Shell commands require approval unless explicitly marked safe.
- Every step emits events to the CLI and LiveView.
- Sessions, plans, tool calls, and checkpoints are persisted.

---

## 2. Product Naming Rules

### 2.1 User-facing language

Use these terms in CLI output, LiveView labels, help text, docs, and examples:

```text
Muse
Muses
Planning Muse
Coding Muse
Reviewing Muse
Testing Muse
Research Muse
Memory Muse
Restoration Muse
Muse Conductor
Muse Runtime
Muse Tools
Muse Session
Muse Plan
Muse Checkpoint
Muse Memory
```

Avoid user-facing labels like:

```text
Planning Agent
Coding Agent
Worker Agent
Bot
Mascot names
```

The internal technical architecture may still use an `Agent` concept only where it is idiomatic or already baked into dependencies, but all product-visible strings should use Muse naming.

### 2.2 Module naming recommendation

Prefer this structure:

```text
lib/muse/conductor.ex
lib/muse/muse_profile.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
lib/muse/muses/reviewing_muse.ex
lib/muse/muses/testing_muse.ex
lib/muse/muses/research_muse.ex
lib/muse/muses/memory_muse.ex
lib/muse/muses/restoration_muse.ex
```

Instead of:

```text
lib/muse/agents/planning_agent.ex
lib/muse/agents/coding_agent.ex
```

This keeps the codebase aligned with the product concept.

---

## 3. Core Lesson from the Reference System

The reference system’s internal prompt behavior is not a single prompt string. It is a runtime product assembled from many layers.

Muse should implement the same architectural idea using Muse naming:

1. **Dedicated Muse profiles**: Planning Muse, Coding Muse, Reviewing Muse, Testing Muse, and Restoration Muse each have separate roles, tool permissions, and output formats.
2. **Dynamic prompt assembly**: the final internal prompt is assembled from core rules, Muse profile, project rules, tools, memory, active plan, and current user message.
3. **Selective tool registration**: each Muse receives only the tools suitable for its role and current approval state.
4. **Read-only planning before approval**: Planning Muse may inspect files and search the repo, but cannot implement.
5. **Tool-first reasoning summaries**: Muses inspect real files and report findings instead of guessing.
6. **History compaction**: long conversations are summarized into durable memory while recent context remains available.
7. **Specialized Muses later**: do not build a swarm first; add specialist Muses after the single Planning Muse and Coding Muse loop is reliable.
8. **Model adapters**: different providers may need different message formatting and structured-output handling.
9. **Debuggability**: developers need redacted prompt previews, tool-call traces, and session replay.
10. **Runtime enforcement**: safety rules must be enforced in Elixir code, not only in prompt text.

---

## 4. Current Muse State

Muse already has a useful foundation:

```text
CLI REPL
Phoenix LiveView UI
Muse.submit/2 public entrypoint
Muse.State event log
Phoenix.PubSub broadcasting
Muse.Workspace path boundary
Muse.AgentRegistry placeholder
Muse.AgentRuntime placeholder
Diagnostics and self-healing queue placeholders
Log buffer
```

The main gap is the turn pipeline. Today, `Muse.submit/2` is mostly a placeholder response path.

The new path should be:

```text
Muse.submit/2
  ↓
Muse.SessionServer
  ↓
Muse.Conductor
  ↓
Muse.Prompt.Assembler
  ↓
Muse.LLM.Provider
  ↓
Muse.Tool.Runner
  ↓
Muse.ApprovalGate
  ↓
Muse.State / PubSub / CLI / LiveView
```

---

## 5. Non-Negotiable Design Principles

### 5.1 The internal prompt stays hidden, but the prompt stack is inspectable

Users should not normally see the full internal prompt. Developers should have a redacted debug view showing:

```text
Layer order
Layer IDs
Layer source
Layer token estimate
Whether the layer is core, project, memory, tool, or user context
Redacted content preview
Available tools
Blocked tools
Active Muse
Active session
Active plan state
```

Never show secrets, API keys, private keys, shell history, hidden tokens, or unredacted `.env` content in the prompt preview.

### 5.2 Prompt rules are not security boundaries

The internal prompt can tell a Muse not to write files before approval, but the actual protection must live in code:

```text
Muse.ApprovalGate.allowed?(session, tool_call)
Muse.Workspace.safe_path?(workspace, path)
Muse.Tool.Runner.execute(tool_call)
```

### 5.3 Muses should inspect before planning

For coding tasks, Planning Muse should use read-only tools before proposing a plan.

Allowed before plan approval:

```text
list_files
read_file
repo_search
git_status
git_diff read-only view
ask_user_question
list_muses
list_skills
```

Blocked before plan approval:

```text
write_file
patch_apply
replace_in_file
delete_file
shell_command
test_runner
package_install
network_call
remote_execution
implementation handoff
```

### 5.4 Approval must be stateful

Muse should not rely on one message containing “go ahead” without knowing what plan is being approved.

Approval should attach to a specific plan version:

```text
session_id
plan_id
plan_version
approved_by
approved_at
approval_scope
```

### 5.5 Patches need separate approval

Plan approval means “start executing the plan.” It should not automatically mean “apply every future diff.”

Recommended policy:

```text
Plan approval: allows Coding Muse to prepare implementation steps.
Patch approval: required before file modifications.
Shell approval: required before arbitrary commands.
Network approval: required before network activity.
Delete approval: required before deleting files.
```

### 5.6 Workspace safety must be symlink-aware

Before any file tool executes:

- normalize the path
- resolve symlinks when possible
- ensure the real target stays inside the workspace
- block reads of known secret paths unless explicitly allowed
- block writes through symlinks by default
- block all paths outside the workspace

---

## 6. Muse Runtime Architecture

### 6.1 High-level module map

```text
lib/muse.ex
  Public API. Delegates submit/resume/approve commands to SessionServer.

lib/muse/session.ex
  Session struct: id, workspace, status, messages, memory, plans, approvals, checkpoints.

lib/muse/session_server.ex
  GenServer for one active session. Owns session state and turn lifecycle.

lib/muse/session_supervisor.ex
  DynamicSupervisor for session processes.

lib/muse/session_store.ex
  Persists events, messages, plans, tool calls, checkpoints, and memory.

lib/muse/conductor.ex
  Selects the active Muse, builds prompts, runs model/tool loop, emits events.

lib/muse/muse_profile.ex
  Struct describing one Muse: id, display name, role, tools, prompt, permissions.

lib/muse/muses/planning_muse.ex
  Read-only planning profile and prompt.

lib/muse/muses/coding_muse.ex
  Implementation profile and prompt.

lib/muse/muses/reviewing_muse.ex
  Diff and architecture review profile.

lib/muse/muses/testing_muse.ex
  Verification profile.

lib/muse/muses/memory_muse.ex
  Compaction and memory profile.

lib/muse/muses/restoration_muse.ex
  Recovery and repair profile.

lib/muse/prompt/layer.ex
  One prompt layer with priority, source, content, visibility, token estimate.

lib/muse/prompt/bundle.ex
  Final prompt object passed to model provider.

lib/muse/prompt/assembler.ex
  Builds the prompt stack in deterministic order.

lib/muse/prompt/project_rules.ex
  Loads global and workspace project rules.

lib/muse/prompt/redactor.ex
  Redacts secrets and sensitive paths in debug previews.

lib/muse/prompt/model_preparer.ex
  Adapts prompt bundle to provider-specific message format.

lib/muse/prompt/debug_preview.ex
  Builds redacted prompt previews for CLI and LiveView.

lib/muse/llm/message.ex
lib/muse/llm/request.ex
lib/muse/llm/response.ex
lib/muse/llm/provider.ex
lib/muse/llm/providers/fake.ex
lib/muse/llm/providers/openai.ex
lib/muse/llm/providers/anthropic.ex
lib/muse/llm/providers/openrouter.ex
lib/muse/llm/providers/ollama.ex

lib/muse/tool/spec.ex
lib/muse/tool/call.ex
lib/muse/tool/result.ex
lib/muse/tool/registry.ex
lib/muse/tool/runner.ex

lib/muse/tools/list_files.ex
lib/muse/tools/read_file.ex
lib/muse/tools/repo_search.ex
lib/muse/tools/git_status.ex
lib/muse/tools/git_diff.ex
lib/muse/tools/patch_propose.ex
lib/muse/tools/patch_apply.ex
lib/muse/tools/shell_command.ex
lib/muse/tools/test_runner.ex

lib/muse/plan.ex
lib/muse/task.ex
lib/muse/approval_gate.ex
lib/muse/checkpoint.ex
lib/muse/memory/compactor.ex
```

### 6.2 Turn lifecycle

```text
1. User sends input through CLI or LiveView.
2. Muse.submit/2 forwards input to SessionServer.
3. SessionServer appends a user message event.
4. Muse Conductor classifies intent.
5. Muse Conductor selects Planning Muse, Coding Muse, or another Muse.
6. Prompt Assembler builds the internal prompt bundle.
7. Model Preparer formats the bundle for the selected provider.
8. Provider streams response and tool-call requests.
9. Tool Runner checks ApprovalGate before every tool execution.
10. Tool events stream to CLI and LiveView.
11. Muse Conductor stores messages, plan state, results, and memory updates.
12. Final response is appended and returned to caller.
```

---

## 7. Session Model

Add a durable session struct:

```elixir
defmodule Muse.Session do
  @enforce_keys [:id, :workspace, :status, :created_at, :updated_at]
  defstruct [
    :id,
    :workspace,
    :status,
    :active_muse,
    :active_plan_id,
    :active_task_id,
    :created_at,
    :updated_at,
    messages: [],
    memory: nil,
    plans: %{},
    approvals: [],
    checkpoints: [],
    tool_calls: [],
    artifacts: []
  ]
end
```

Recommended statuses:

```elixir
:idle
:planning
:awaiting_plan_approval
:executing
:awaiting_patch_approval
:awaiting_shell_approval
:verifying
:reviewing
:repairing
:done
:failed
:cancelled
```

Session persistence layout:

```text
.muse/
  sessions/
    <session_id>/
      session.json
      events.jsonl
      messages.jsonl
      plans.jsonl
      tool_calls.jsonl
      approvals.jsonl
      memory.md
      artifacts/
      checkpoints/
```

Keep an in-memory recent window for UI responsiveness, but persist every important event.

---

## 8. Muse Profiles

### 8.1 Profile struct

```elixir
defmodule Muse.MuseProfile do
  @enforce_keys [:id, :display_name, :role, :prompt, :tools]
  defstruct [
    :id,
    :display_name,
    :role,
    :prompt,
    :tools,
    :default_model,
    :output_schema,
    :permissions,
    :handoff_targets,
    :style
  ]
end
```

### 8.2 Planning Muse profile

```elixir
defmodule Muse.Muses.PlanningMuse do
  alias Muse.MuseProfile

  def profile do
    %MuseProfile{
      id: "planning_muse",
      display_name: "Planning Muse",
      role: :planning,
      tools: [
        "list_files",
        "read_file",
        "repo_search",
        "git_status",
        "git_diff_readonly",
        "ask_user_question",
        "list_muses",
        "list_skills"
      ],
      permissions: %{
        read: true,
        write: false,
        shell: false,
        network: false,
        can_create_plan: true,
        can_execute_plan: false
      },
      output_schema: Muse.Plan,
      prompt: prompt()
    }
  end
end
```

### 8.3 Coding Muse profile

```elixir
defmodule Muse.Muses.CodingMuse do
  alias Muse.MuseProfile

  def profile do
    %MuseProfile{
      id: "coding_muse",
      display_name: "Coding Muse",
      role: :coding,
      tools: [
        "list_files",
        "read_file",
        "repo_search",
        "git_status",
        "git_diff_readonly",
        "patch_propose",
        "patch_apply",
        "test_runner"
      ],
      permissions: %{
        read: true,
        write: :approval_required,
        shell: :approval_required,
        network: false,
        can_create_plan: false,
        can_execute_plan: true
      },
      prompt: prompt()
    }
  end
end
```

### 8.4 Reviewing Muse profile

```elixir
defmodule Muse.Muses.ReviewingMuse do
  def profile do
    %Muse.MuseProfile{
      id: "reviewing_muse",
      display_name: "Reviewing Muse",
      role: :review,
      tools: ["read_file", "repo_search", "git_status", "git_diff_readonly"],
      permissions: %{read: true, write: false, shell: false, network: false},
      prompt: prompt()
    }
  end
end
```

### 8.5 Testing Muse profile

```elixir
defmodule Muse.Muses.TestingMuse do
  def profile do
    %Muse.MuseProfile{
      id: "testing_muse",
      display_name: "Testing Muse",
      role: :testing,
      tools: ["read_file", "repo_search", "git_status", "test_runner"],
      permissions: %{read: true, write: false, shell: :approval_required, network: false},
      prompt: prompt()
    }
  end
end
```

### 8.6 Restoration Muse profile

```elixir
defmodule Muse.Muses.RestorationMuse do
  def profile do
    %Muse.MuseProfile{
      id: "restoration_muse",
      display_name: "Restoration Muse",
      role: :recovery,
      tools: ["git_status", "git_diff_readonly", "read_file", "checkpoint_restore"],
      permissions: %{read: true, write: :approval_required, shell: false, network: false},
      prompt: prompt()
    }
  end
end
```

---

## 9. Internal Prompt Stack

### 9.1 Prompt layer struct

```elixir
defmodule Muse.Prompt.Layer do
  @enforce_keys [:id, :priority, :source, :content]
  defstruct [
    :id,
    :priority,
    :source,
    :content,
    visibility: :internal,
    kind: :instruction,
    token_estimate: nil,
    redaction: :standard
  ]
end
```

### 9.2 Prompt bundle struct

```elixir
defmodule Muse.Prompt.Bundle do
  @enforce_keys [:session_id, :muse_id, :layers, :messages, :tools]
  defstruct [
    :session_id,
    :muse_id,
    :model,
    :layers,
    :messages,
    :tools,
    :metadata,
    :created_at
  ]
end
```

### 9.3 Prompt assembly order

The final prompt should be assembled in this order:

```text
1. Muse core invariants
2. Active mode policy
3. Selected Muse role prompt
4. Selected Muse identity and style
5. Workspace and path policy
6. Approval policy
7. Tool policy and available tool list
8. Model-specific response requirements
9. Global user rules
10. Project rules
11. Skills and workflow notes
12. Session memory summary
13. Active plan and active task state
14. Recent conversation history
15. Current user message
```

### 9.4 Important priority rule

Project rules are important, but they are not allowed to override:

```text
Muse core runtime rules
workspace safety rules
approval rules
secret-handling rules
provider safety rules
tool permission rules
```

Project rules should be wrapped as contextual preferences:

```text
<project_rules>
The following are project and user preferences. Follow them unless they conflict
with Muse core runtime, workspace, approval, secret-handling, or tool safety rules.

...
</project_rules>
```

---

## 10. Core Runtime Prompt

This is the foundation layer for every Muse.

```text
You are part of Muse, a coding system made of specialized Muses.

Muse helps users understand, plan, implement, review, test, and repair software projects.

You must follow the active Muse role, the active session state, the approval policy, and the available tools. You must not claim that you inspected files, ran commands, wrote code, applied patches, or verified behavior unless a tool result confirms it.

You must respect these invariants:

1. Workspace safety
- Never access paths outside the active workspace.
- Never write through symlinks unless the runtime explicitly allows it.
- Never read secret files unless the user explicitly asks and the runtime allows it.
- Never expose secrets in responses, logs, or prompt previews.

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
```

---

## 11. Planning Muse Prompt

```text
You are the Planning Muse, the strategic planning specialist inside Muse.

Your purpose is to understand the user's software goal, inspect the workspace with read-only tools, and create a clear approval-gated implementation plan.

You are not the implementation Muse. Before approval, you must not modify files, apply patches, run shell commands, install packages, delete files, perform network actions, or start implementation handoffs.

Allowed before plan approval:
- list_files
- read_file
- repo_search
- git_status
- git_diff_readonly
- ask_user_question
- list_muses
- list_skills

Blocked before plan approval:
- patch_apply
- write_file
- replace_in_file
- delete_file
- shell_command
- test_runner
- package_install
- network_call
- remote_execution
- implementation handoff

Planning workflow:

A. Classify the request
- If the user asks a simple question, answer after minimal inspection.
- If the user asks for code changes, inspect the project and create a plan.
- If the task is ambiguous and inspection cannot resolve it, ask one focused question.

B. Inspect the workspace
- Start with list_files at the workspace root.
- Read likely entry points such as README, project config, CLI files, routes, commands, tests, and relevant modules.
- Use repo_search for command names, function names, error messages, module names, and related tests.
- Do not read unrelated large files.
- Do not read secret files unless the user explicitly asks and the runtime allows it.

C. Build the plan
Every plan must include:
- objective
- discovered project facts
- files inspected
- likely files to change
- phases
- tasks
- recommended Muse for each task
- dependencies
- validation steps
- risks and mitigations
- approval requirement

D. Stop at approval
After producing the plan, ask the user to approve it. Do not start implementation.

Output format:

OBJECTIVE
One sentence.

PROJECT ANALYSIS
- Project type:
- Tech stack:
- Key files inspected:
- Relevant conventions:
- Current behavior:

EXECUTION PLAN
Phase 1: Preparation
- Task 1.1
  - Muse:
  - Files:
  - Tools:
  - Dependencies:
  - Validation:
  - Approval required:

Phase 2: Implementation
- Task 2.1 ...

Phase 3: Verification
- Task 3.1 ...

RISKS AND MITIGATIONS
- Risk:
  - Mitigation:

ALTERNATIVE APPROACHES
1. Approach:
   - Pros:
   - Cons:

NEXT STEP
Ask the user to approve, revise, or reject the plan.

Approval phrases include:
- approve
- approved
- proceed
- go ahead
- start
- begin
- execute plan
- looks good, proceed

Ambiguous enthusiasm is not approval. If approval is unclear, ask for confirmation.
```

---

## 12. Coding Muse Prompt

```text
You are the Coding Muse, the implementation specialist inside Muse.

You implement approved plans through small, reviewable, reversible changes.

You must only act within the approved plan and current task. If the requested change exceeds the approved scope, stop and ask the Muse Conductor to request approval for a plan update.

Implementation workflow:

1. Confirm active plan and task
- Read the approved plan.
- Identify the current task.
- Confirm affected files.

2. Inspect before editing
- Read relevant files.
- Search for existing patterns.
- Check git status.

3. Propose a patch
- Create the smallest useful diff.
- Explain what the diff changes.
- State risks and validation steps.
- Request patch approval.

4. Apply only after approval
- Apply the patch through the approved patch tool.
- Never write directly around the tool runner.
- Never edit files outside the workspace.

5. Validate
- Run approved verification tools.
- If tests fail, inspect failures and propose a repair plan.
- Do not enter an infinite repair loop.

6. Report
- Summarize changed files.
- Summarize validation results.
- Mention unresolved risks.
- Suggest the next step.

You must not:
- modify files before patch approval
- delete files without explicit delete approval
- run arbitrary shell commands without command approval
- install packages without approval
- access network resources without approval
- claim success without verification evidence
```

---

## 13. Reviewing Muse Prompt

```text
You are the Reviewing Muse, the quality and risk specialist inside Muse.

Your job is to review proposed or applied changes for correctness, maintainability, safety, style, and architectural fit.

You may inspect files, diffs, and project conventions. You must not modify files.

Review workflow:

1. Read the plan and current diff.
2. Inspect relevant files and tests.
3. Check whether the change matches project conventions.
4. Identify correctness risks.
5. Identify security, privacy, and workspace risks.
6. Identify missing tests or validation.
7. Recommend approve, revise, or reject.

Output format:

REVIEW SUMMARY
- Decision:
- Confidence:

FINDINGS
- Severity:
  - Issue:
  - Evidence:
  - Recommendation:

VALIDATION GAPS
- Gap:
  - Suggested validation:

FINAL RECOMMENDATION
Approve, revise, or reject with one-sentence reasoning.
```

---

## 14. Testing Muse Prompt

```text
You are the Testing Muse, the verification specialist inside Muse.

Your job is to choose, run, and interpret validation steps for approved changes.

You may run predefined safe test commands when the runtime allows them. Arbitrary shell commands require approval.

Testing workflow:

1. Read the active plan and changed files.
2. Identify the smallest relevant test command.
3. Request approval if the command is not pre-approved.
4. Run validation.
5. Summarize results.
6. If failures occur, identify likely causes and hand back to Planning Muse or Coding Muse.

Output format:

VALIDATION PLAN
- Command:
- Why this command:
- Approval needed:

RESULT
- Status:
- Key output:
- Failures:
- Next action:
```

---

## 15. Memory Muse Prompt

```text
You are the Memory Muse, the context preservation specialist inside Muse.

Your job is to summarize long sessions into compact, durable memory that helps future turns without exposing hidden reasoning or secrets.

Memory rules:
- Preserve user goals, decisions, constraints, approved plans, changed files, validation results, and unresolved issues.
- Do not preserve secrets.
- Do not store private keys, tokens, credentials, or sensitive file contents.
- Do not store hidden reasoning.
- Prefer concise factual summaries.

Output format:

SESSION MEMORY
- User goal:
- Project facts:
- Decisions made:
- Approved plans:
- Changes completed:
- Validation results:
- Open issues:
- Useful conventions:
```

---

## 16. Restoration Muse Prompt

```text
You are the Restoration Muse, the recovery specialist inside Muse.

Your job is to help when Muse fails, crashes, applies a bad patch, or reaches an inconsistent session state.

You may inspect session events, checkpoints, git status, and diffs. You must not restore or modify files without approval.

Recovery workflow:

1. Identify the failure mode.
2. Inspect the latest session events and checkpoints.
3. Inspect workspace status.
4. Explain recovery options.
5. Recommend the safest recovery path.
6. Request approval before restore or rollback.

Output format:

RECOVERY ANALYSIS
- Failure:
- Last known good state:
- Current workspace status:
- Available checkpoints:

RECOVERY OPTIONS
1. Option:
   - Pros:
   - Cons:
   - Risk:

RECOMMENDED ACTION
Ask for explicit approval before restoring.
```

---

## 17. Tool Registry

### 17.1 Tool spec

```elixir
defmodule Muse.Tool.Spec do
  @enforce_keys [:name, :description, :input_schema, :executor]
  defstruct [
    :name,
    :description,
    :input_schema,
    :executor,
    :risk,
    :permission,
    :allowed_roles,
    :requires_approval,
    :emits_events
  ]
end
```

### 17.2 Initial read-only tools

Implement these first:

```text
list_files
read_file
repo_search
git_status
git_diff_readonly
ask_user_question
list_muses
list_skills
```

### 17.3 Write and execution tools

Add after Planning Muse is working:

```text
patch_propose
patch_apply
write_file
replace_in_file
delete_file
test_runner
shell_command
checkpoint_create
checkpoint_restore
```

### 17.4 Tool permissions matrix

| Tool | Planning Muse before approval | Coding Muse after plan approval | Patch approval required | Notes |
|---|---:|---:|---:|---|
| list_files | allow | allow | no | Workspace only. |
| read_file | allow | allow | no | Secret policy enforced. |
| repo_search | allow | allow | no | Output limits required. |
| git_status | allow | allow | no | Read-only. |
| git_diff_readonly | allow | allow | no | Read-only. |
| patch_propose | block | allow | no | Generates diff only. |
| patch_apply | block | allow | yes | Checkpoint first. |
| write_file | block | allow | yes | Prefer patch workflow. |
| replace_in_file | block | allow | yes | Checkpoint first. |
| delete_file | block | allow | explicit delete approval | High risk. |
| test_runner | block | allow | maybe | Allow only configured safe tests. |
| shell_command | block | conditional | yes | Command allowlist recommended. |
| network_call | block | conditional | yes | Default block. |
| remote_execution | block | later only | yes | Implement late. |

---

## 18. Approval Gate

### 18.1 Approval struct

```elixir
defmodule Muse.Approval do
  @enforce_keys [:id, :session_id, :kind, :scope, :status, :created_at]
  defstruct [
    :id,
    :session_id,
    :plan_id,
    :task_id,
    :tool_call_id,
    :kind,
    :scope,
    :status,
    :requested_by,
    :approved_by,
    :created_at,
    :approved_at,
    :expires_at,
    :metadata
  ]
end
```

Approval kinds:

```elixir
:plan
:patch
:shell_command
:network
:delete
:restore
:remote_execution
```

### 18.2 Approval gate API

```elixir
defmodule Muse.ApprovalGate do
  def allowed?(session, tool_call) do
    # returns {:ok, :allowed} or {:blocked, reason}
  end

  def request_approval(session, approval_request) do
    # stores approval request and emits event
  end

  def approve(session, approval_id, approver) do
    # marks approval accepted and emits event
  end

  def reject(session, approval_id, approver) do
    # marks approval rejected and emits event
  end
end
```

### 18.3 Approval command handling

CLI examples:

```text
/approve plan
/reject plan
/approve patch
/reject patch
/approve command
/reject command
```

Natural language approval can be supported, but only when session state is unambiguous:

```text
User: proceed
Muse Conductor checks:
- exactly one pending plan approval exists
- no pending patch or command approval conflicts
- the plan version matches the displayed plan
```

---

## 19. Plan Model

```elixir
defmodule Muse.Plan do
  @enforce_keys [:id, :session_id, :objective, :status, :version, :tasks]
  defstruct [
    :id,
    :session_id,
    :objective,
    :summary,
    :status,
    :version,
    :created_by,
    :created_at,
    :approved_at,
    :completed_at,
    tasks: [],
    inspected_files: [],
    likely_changed_files: [],
    risks: [],
    alternatives: [],
    validation: []
  ]
end
```

```elixir
defmodule Muse.Task do
  @enforce_keys [:id, :title, :status]
  defstruct [
    :id,
    :title,
    :description,
    :status,
    :recommended_muse,
    :files,
    :tools,
    :dependencies,
    :validation,
    :risk_level,
    :approval_required
  ]
end
```

Plan statuses:

```elixir
:draft
:awaiting_approval
:approved
:in_progress
:completed
:rejected
:cancelled
:needs_revision
```

---

## 20. Prompt Assembler

### 20.1 API

```elixir
defmodule Muse.Prompt.Assembler do
  def build(session, muse_profile, user_message, opts \\ []) do
    layers = [
      core_invariants_layer(),
      active_mode_layer(session),
      muse_profile_layer(muse_profile),
      muse_identity_layer(muse_profile),
      workspace_policy_layer(session),
      approval_policy_layer(session),
      tool_policy_layer(session, muse_profile),
      model_requirements_layer(opts[:model]),
      global_rules_layer(session),
      project_rules_layer(session),
      skills_layer(session),
      memory_layer(session),
      active_plan_layer(session),
      recent_history_layer(session),
      current_user_message_layer(user_message)
    ]

    %Muse.Prompt.Bundle{
      session_id: session.id,
      muse_id: muse_profile.id,
      model: opts[:model],
      layers: Enum.reject(layers, &is_nil/1),
      messages: build_messages(layers),
      tools: Muse.Tool.Registry.tools_for(session, muse_profile),
      metadata: %{workspace: session.workspace},
      created_at: DateTime.utc_now()
    }
  end
end
```

### 20.2 Debug preview

```elixir
defmodule Muse.Prompt.DebugPreview do
  def render(bundle) do
    bundle.layers
    |> Enum.map(&redacted_layer_summary/1)
  end
end
```

Example developer preview:

```text
Prompt bundle for session s_123
Active Muse: Planning Muse
Model: fake
Tools: list_files, read_file, repo_search, git_status

Layers:
1. muse_core_invariants      internal    720 tokens
2. active_mode_policy        internal    180 tokens
3. planning_muse_profile     internal    950 tokens
4. workspace_policy          internal    310 tokens
5. approval_policy           internal    420 tokens
6. project_rules             context     260 tokens
7. memory_summary            context     140 tokens
8. active_plan_state         context     0 tokens
9. recent_history            context     220 tokens
10. current_user_message     user        18 tokens
```

---

## 21. Project Rules Loader

Search order:

```text
~/.muse/AGENTS.md
~/.muse/MUSE.md
workspace/.muse/AGENTS.md
workspace/.muse/MUSE.md
workspace/AGENTS.md
workspace/MUSE.md
workspace/agent.md
workspace/agents.md
```

Recommended Muse-native file:

```text
MUSE.md
```

But keep compatibility with common project-rule filenames.

Rules:

- Load only files inside trusted locations.
- Do not allow project rules to override core safety.
- Redact secrets in debug views.
- Include path and timestamp metadata.
- If the file is huge, summarize or cap it.

---

## 22. Model Provider Layer

### 22.1 Provider behavior

```elixir
defmodule Muse.LLM.Provider do
  @callback complete(Muse.LLM.Request.t()) ::
              {:ok, Muse.LLM.Response.t()} | {:error, term()}

  @callback stream(Muse.LLM.Request.t()) ::
              Enumerable.t()
end
```

### 22.2 Request struct

```elixir
defmodule Muse.LLM.Request do
  defstruct [
    :model,
    :messages,
    :tools,
    :temperature,
    :max_tokens,
    :response_format,
    :metadata
  ]
end
```

### 22.3 Fake provider first

Start with `Muse.LLM.Providers.Fake` so tests can drive the runtime without real API keys.

Fake provider test scenarios:

```text
Planning Muse creates a plan after tool inspection.
Planning Muse requests read_file.
Coding Muse proposes a patch.
Coding Muse requests patch_apply.
Testing Muse requests test_runner.
Provider returns malformed tool call.
Provider streams partial response.
Provider fails and runtime retries.
```

Add real providers only after the orchestration path works.

---

## 23. Muse Conductor

The Conductor is the runtime coordinator.

### 23.1 Responsibilities

```text
Select active Muse
Build prompt bundle
Call provider
Handle streaming events
Handle tool-call requests
Ask ApprovalGate before tools
Persist tool results
Update session state
Handoff between Muses
Return final response
```

### 23.2 Run-turn flow

```elixir
defmodule Muse.Conductor do
  def run_turn(session, user_message, opts \\ []) do
    with {:ok, selected_muse} <- select_muse(session, user_message),
         {:ok, bundle} <- build_prompt(session, selected_muse, user_message, opts),
         {:ok, response} <- run_model_loop(session, bundle, opts),
         {:ok, updated_session} <- apply_response(session, response) do
      {:ok, updated_session, response}
    else
      {:approval_required, request} ->
        {:ok, session, request}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 23.3 Muse selection

Initial routing rules:

| User intent | Selected Muse |
|---|---|
| asks for explanation | Research Muse or Planning Muse |
| asks for code change | Planning Muse |
| approves plan | Coding Muse |
| asks to review diff | Reviewing Muse |
| asks to run tests | Testing Muse |
| reports failed patch or broken state | Restoration Muse |
| asks to resume session | Muse Conductor, then appropriate Muse |

Do not overbuild routing at first. A simple rule-based router plus model fallback is enough.

---

## 24. Event Types

Add structured events so CLI and LiveView can show real progress.

```text
session_started
session_resumed
user_message_received
muse_selected
prompt_bundle_created
prompt_debug_preview_available
plan_created
plan_updated
plan_approval_requested
plan_approved
plan_rejected
task_started
task_completed
tool_call_requested
tool_call_allowed
tool_call_blocked
tool_call_started
tool_call_output
tool_call_finished
tool_call_failed
patch_proposed
patch_approval_requested
patch_approved
patch_rejected
checkpoint_created
checkpoint_restored
validation_started
validation_finished
memory_compacted
muse_handoff_requested
muse_handoff_completed
assistant_message_streamed
assistant_message_completed
session_failed
session_completed
```

Event struct should include:

```elixir
%Muse.Event{
  id: integer,
  seq: integer,
  session_id: binary,
  type: atom,
  source: binary,
  payload: map,
  created_at: DateTime.t()
}
```

Use session-local monotonic `seq` values for replay.

---

## 25. Workspace and Secret Safety

### 25.1 Path policy

For every file tool:

1. Accept a workspace-relative path.
2. Reject absolute paths unless explicitly allowed by a high-trust internal call.
3. Normalize the path.
4. Resolve symlinks where possible.
5. Confirm the real path remains inside the workspace.
6. Enforce read/write permission policy.
7. Enforce secret-file policy.
8. Emit a tool event.

### 25.2 Secret path patterns

Block by default:

```text
.env
.env.*
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519
.ssh/
.aws/
.gcp/
.azure/
.npmrc
.pypirc
.netrc
.git-credentials
credentials.json
secrets.*
```

If the user explicitly asks to inspect a secret-related file, Muse should ask for confirmation and explain the risk. Even then, redact obvious secrets in responses.

---

## 26. Checkpoints and Patch Workflow

### 26.1 Checkpoint before write

Before applying any patch:

```text
1. Capture git status.
2. Capture git diff.
3. Save the proposed patch.
4. Save backups of affected files.
5. Create checkpoint metadata.
6. Apply patch.
7. Capture post-apply diff.
8. Store result.
```

Checkpoint layout:

```text
.muse/sessions/<session_id>/checkpoints/<checkpoint_id>/
  metadata.json
  before.diff
  proposed.patch
  affected_files/
  after.diff
```

### 26.2 Patch proposal response

```text
PATCH PROPOSAL
- Plan:
- Task:
- Files changed:
- Summary:
- Risk:
- Validation:

DIFF
...

Apply this patch? [y/N]
```

### 26.3 Rollback response

```text
Restoration Muse:
A checkpoint exists from before the last patch.

Restore checkpoint chk_123?
This will revert:
- lib/muse/cli/repl.ex
- test/muse/cli/repl_test.ex

Approve restore? [y/N]
```

---

## 27. CLI Integration

### 27.1 Commands

Add or update CLI commands:

```text
/help
/status
/muses
/plan
/approve plan
/reject plan
/approve patch
/reject patch
/approve command
/reject command
/prompt preview
/tools
/memory
/checkpoints
/restore <checkpoint_id>
/resume <session_id>
/cancel
```

### 27.2 Example `/muses`

```text
Available Muses:
- Planning Muse: creates implementation plans after read-only inspection.
- Coding Muse: implements approved plans through patches.
- Reviewing Muse: reviews diffs and risks.
- Testing Muse: runs and interprets verification.
- Memory Muse: summarizes session context.
- Restoration Muse: recovers from failed or unsafe states.
```

### 27.3 Example `/status`

```text
Session: s_123
Workspace: /path/to/project
Status: awaiting_plan_approval
Active Muse: Planning Muse
Pending approval: plan p_456 v1
Last tool: repo_search completed
```

### 27.4 Example `/prompt preview`

```text
Prompt preview is redacted.
Active Muse: Planning Muse
Layers: 12
Tools: list_files, read_file, repo_search, git_status
Blocked tools: patch_apply, shell_command, delete_file, network_call
```

---

## 28. LiveView Integration

Add UI panels that reflect the Muse model:

```text
Active Muse panel
Plan panel
Tool activity stream
Approval panel
Patch diff panel
Validation panel
Memory panel
Checkpoints panel
Prompt preview panel for developer mode
```

Suggested labels:

```text
Active Muse
Muse Plan
Muse Tools
Muse Memory
Muse Checkpoints
Muse Review
Muse Validation
Muse Recovery
```

Do not expose the raw internal prompt in the normal UI. Use a redacted prompt preview only in developer/debug mode.

---

## 29. Implementation Roadmap

### PR 0 — Product naming cleanup

Goal: make the plan and app language Muse-first.

Tasks:

- Replace old mascot naming in docs, UI strings, examples, and planned module names.
- Use Planning Muse, Coding Muse, Reviewing Muse, Testing Muse, Memory Muse, Restoration Muse.
- Add a UI string test that checks key screens use Muse naming.
- Create a naming glossary in the docs.

Acceptance:

- `/muses` shows Muse names only.
- Example CLI output uses Muse names only.
- Prompt templates identify roles as Muses.

### PR 1 — Sessions

Goal: replace global-only state with session-aware state.

Tasks:

- Add `Muse.Session`.
- Add `Muse.SessionServer`.
- Add `Muse.SessionSupervisor`.
- Add `Muse.SessionStore` with JSONL persistence.
- Add session-local event sequence numbers.
- Update `Muse.submit/2` to route through default session.

Acceptance:

- A user message creates or resumes a session.
- Events include `session_id` and `seq`.
- Session can be resumed from disk.

### PR 2 — Muse profiles

Goal: introduce specialized Muses.

Tasks:

- Add `Muse.MuseProfile`.
- Add Planning Muse profile.
- Add Coding Muse profile.
- Add Reviewing Muse profile.
- Add Testing Muse profile.
- Add Memory Muse profile.
- Add Restoration Muse profile.
- Add `/muses` CLI command.

Acceptance:

- Tests can load every profile.
- Each profile has display name, role, prompt, tools, and permissions.
- CLI lists available Muses.

### PR 3 — Prompt layers and assembler

Goal: build internal prompt stacks deterministically.

Tasks:

- Add `Muse.Prompt.Layer`.
- Add `Muse.Prompt.Bundle`.
- Add `Muse.Prompt.Assembler`.
- Add core runtime prompt layer.
- Add role prompt layer.
- Add approval policy layer.
- Add workspace policy layer.
- Add recent history layer.
- Add current user message layer.

Acceptance:

- Assembler produces layers in the expected order.
- Prompt bundle includes selected Muse and tools.
- Debug preview is redacted.

### PR 4 — Project rules loader

Goal: support project-specific instructions safely.

Tasks:

- Add `Muse.Prompt.ProjectRules`.
- Load global and workspace rule files.
- Prefer `MUSE.md` but support common rule filenames.
- Cap large files.
- Wrap rules as lower-priority project context.
- Redact secrets in debug preview.

Acceptance:

- Project rules appear in prompt bundle.
- Rules cannot override approval policy.
- Missing rule files are handled gracefully.

### PR 5 — Read-only tools

Goal: let Planning Muse inspect the project.

Tasks:

- Add tool spec, registry, call, result, runner.
- Implement `list_files`.
- Implement `read_file`.
- Implement `repo_search`.
- Implement `git_status`.
- Implement `git_diff_readonly`.
- Add output limits.
- Add path safety checks.

Acceptance:

- Planning Muse can list, read, search, and inspect status.
- Read-only tools emit events.
- Secret and outside-workspace paths are blocked.

### PR 6 — Approval gate

Goal: enforce tool permissions in code.

Tasks:

- Add `Muse.Approval`.
- Add `Muse.ApprovalGate`.
- Add plan approval state.
- Add patch approval state.
- Add command approval state.
- Add CLI approve/reject commands.

Acceptance:

- Write tools are blocked before approval.
- Tool runner refuses blocked calls.
- Pending approval appears in `/status`.

### PR 7 — Fake model provider

Goal: test runtime without real API keys.

Tasks:

- Add LLM request/response/message structs.
- Add provider behavior.
- Add fake provider.
- Add scripted provider responses for tests.
- Add stream simulation.
- Add malformed tool-call tests.

Acceptance:

- Orchestrator tests can run deterministically.
- Tool-call loop can be tested offline.

### PR 8 — Muse Conductor first turn loop

Goal: make `Muse.submit/2` run a real read-only turn.

Tasks:

- Add `Muse.Conductor`.
- Add simple intent router.
- Select Planning Muse for code-change requests.
- Build prompt bundle.
- Call fake provider.
- Execute read-only tool calls.
- Store tool results.
- Return final response.

Acceptance:

- `muse> explain this project` uses read-only tools.
- `muse> add a /version command` creates a plan and waits for approval.

### PR 9 — Plan creation and approval

Goal: make Planning Muse produce durable plans.

Tasks:

- Add `Muse.Plan`.
- Add `Muse.Task`.
- Parse or validate structured plan output.
- Persist plans.
- Add `/plan` command.
- Add `/approve plan` and `/reject plan`.
- Bind approval to plan version.

Acceptance:

- Plans persist across restart.
- Approving a stale plan version is blocked.
- Approved plan transitions session to execution-ready state.

### PR 10 — Patch proposal

Goal: let Coding Muse prepare diffs without applying them.

Tasks:

- Add `patch_propose` tool.
- Add diff rendering.
- Add patch approval request event.
- Add LiveView patch panel.
- Add CLI patch display.

Acceptance:

- Coding Muse can propose a diff after plan approval.
- No file is modified before patch approval.

### PR 11 — Patch application and checkpoints

Goal: safely apply approved diffs.

Tasks:

- Add checkpoint creation.
- Add `patch_apply` tool.
- Save affected file backups.
- Save before and after diffs.
- Add checkpoint list command.
- Add restore approval flow.

Acceptance:

- Every patch application creates a checkpoint first.
- Restore requires approval.
- Applied patch is visible in git diff.

### PR 12 — Verification loop

Goal: validate changes.

Tasks:

- Add `test_runner` tool.
- Add safe command allowlist.
- Add test approval policy.
- Add Testing Muse handoff.
- Parse common test output minimally.
- Stop after bounded repair attempts.

Acceptance:

- Muse can run approved tests.
- Failures produce a repair plan, not uncontrolled edits.

### PR 13 — Reviewing Muse

Goal: add quality review before or after patch approval.

Tasks:

- Add Reviewing Muse turn path.
- Review proposed patches.
- Produce approve/revise/reject recommendation.
- Add optional auto-review before patch approval.

Acceptance:

- User can run `/review` on a proposed diff.
- Review output includes findings and validation gaps.

### PR 14 — Memory compaction

Goal: keep long sessions coherent.

Tasks:

- Add Memory Muse.
- Add compaction thresholds.
- Summarize old messages and tool results.
- Persist memory summary.
- Include memory layer in prompt bundle.

Acceptance:

- Long sessions compact without losing approved plan state.
- Memory excludes secrets and hidden reasoning.

### PR 15 — Real model providers

Goal: connect to real models.

Tasks:

- Add OpenAI adapter.
- Add Anthropic adapter.
- Add OpenRouter adapter.
- Add Ollama/local adapter.
- Add model routing config.
- Add provider error handling and retries.
- Add structured-output handling.

Acceptance:

- Provider can be selected from config.
- Fake provider remains default in tests.
- Tool-call loop works with at least one real provider.

### PR 16 — Specialist Muse handoffs

Goal: allow controlled collaboration between Muses.

Tasks:

- Add handoff events.
- Allow Planning Muse to recommend another Muse.
- Allow Conductor to execute handoff only when policy allows.
- Keep all tools gated by ApprovalGate.

Acceptance:

- Planning Muse can hand off to Coding Muse after plan approval.
- Coding Muse can request Testing Muse after patch application.
- Reviewing Muse can request Planning Muse revision.

### PR 17 — Remote execution later

Goal: add remote execution only after local runtime is safe.

Tasks:

- Add runner abstraction.
- Add local runner.
- Add remote SSH runner later.
- Add artifact sync.
- Add strict approvals.
- Add timeout and output limits.

Acceptance:

- Remote execution uses the same tool and approval policies.
- Local execution remains the default.

---

## 30. Testing Plan

### 30.1 Unit tests

```text
MuseProfile loads all Muses.
Prompt Assembler orders layers correctly.
Project rules load with correct priority.
Project rules cannot override core rules.
Debug preview redacts secrets.
ApprovalGate blocks writes before approval.
ApprovalGate binds approval to plan version.
Workspace path safety blocks traversal.
Workspace path safety blocks symlink escape.
Read file blocks secret paths.
Tool runner emits events.
Fake provider returns scripted tool calls.
Conductor handles tool-call loop.
Session store persists and resumes state.
```

### 30.2 Integration tests

```text
User asks for code change.
Planning Muse inspects files.
Planning Muse creates plan.
Session enters awaiting_plan_approval.
User approves plan.
Coding Muse proposes patch.
Patch is not applied before approval.
User approves patch.
Checkpoint is created.
Patch is applied.
Testing Muse runs validation.
Session completes.
```

### 30.3 Safety tests

```text
Blocked outside-workspace read.
Blocked outside-workspace write.
Blocked symlink write.
Blocked secret read.
Blocked shell command before approval.
Blocked delete before explicit delete approval.
Blocked stale plan approval.
Blocked patch approval for different patch hash.
Blocked tool not available to active Muse.
```

### 30.4 Product-language tests

Add tests or CI checks that the main user-facing UI and CLI use Muse naming:

```text
/muses lists Planning Muse, Coding Muse, Reviewing Muse, Testing Muse.
/status says Active Muse.
Plan output says recommended Muse.
Approval messages say Muse Plan and Patch Proposal.
```

---

## 31. Acceptance Criteria for the First Real Milestone

Milestone name:

```text
Read-only Planning Muse
```

User flow:

```text
muse> add a /version command
```

Expected behavior:

1. Muse creates or resumes a session.
2. Muse Conductor selects Planning Muse.
3. Prompt Assembler builds a prompt bundle.
4. Planning Muse lists the workspace.
5. Planning Muse reads relevant files.
6. Planning Muse searches for CLI command patterns.
7. Planning Muse creates a structured plan.
8. Plan is persisted.
9. Session status becomes `:awaiting_plan_approval`.
10. CLI and LiveView show the plan.
11. No files are modified.
12. No shell command runs.
13. No implementation Muse starts yet.

This milestone is enough to prove the internal prompt system works.

---

## 32. Acceptance Criteria for the Second Milestone

Milestone name:

```text
Approved Coding Muse Patch Flow
```

User flow:

```text
muse> add a /version command
Planning Muse creates plan.
muse> approve plan
Coding Muse proposes patch.
muse> approve patch
Patch is applied with checkpoint.
Testing Muse verifies.
```

Expected behavior:

1. Plan approval is bound to the exact plan version.
2. Coding Muse only acts within approved scope.
3. Patch proposal appears before file writes.
4. Patch approval is required.
5. Checkpoint is created before applying patch.
6. Patch is applied.
7. Validation runs only when allowed.
8. Final response summarizes changed files and validation results.

---

## 33. Recommended Immediate Work Order

Implement in this order:

```text
1. Product naming cleanup
2. Session model
3. Muse profiles
4. Prompt assembler
5. Project rules loader
6. Read-only tools
7. Approval gate
8. Fake provider
9. Muse Conductor
10. Read-only Planning Muse milestone
```

Do not start with:

```text
remote execution
multi-Muse handoffs
MCP integrations
large UI redesign
provider adapters
complex memory systems
```

Those become useful after the core turn loop works.

---

## 34. Handoff Instructions for Development

Give this instruction to the development system implementing Muse:

```text
Implement the Muse internal prompt runtime using Muse-first naming.

Do not add mascot branding. The product model is specialized Muses.

The first target is a read-only Planning Muse. It must inspect the workspace with safe tools, produce a structured plan, persist it, and wait for plan approval. It must not modify files, run shell commands, apply patches, delete files, install packages, use network access, or hand off to implementation before approval.

Implement the runtime in this order:
1. Session model and persistence.
2. MuseProfile and Planning Muse profile.
3. Prompt Layer, Prompt Bundle, and Prompt Assembler.
4. Project rules loader with safety priority.
5. Tool registry and read-only tools.
6. ApprovalGate.
7. Fake LLM provider.
8. Muse Conductor tool-call loop.
9. Planning Muse plan creation and approval state.

The internal prompt stack must be deterministic and inspectable through a redacted debug preview.

The app UI and CLI should show Planning Muse, Coding Muse, Reviewing Muse, Testing Muse, Memory Muse, Restoration Muse, and Muse Conductor.

Runtime enforcement is mandatory. Prompt text alone is not safety.
```

---

## 35. Final Target Architecture

```text
CLI / LiveView
   ↓
Muse.submit/2
   ↓
SessionServer
   ↓
Muse Conductor
   ↓
Muse selection
   ↓
Prompt Assembler
   ↓
Provider Adapter
   ↓
Tool-call loop
   ↓
ApprovalGate
   ↓
Tool Runner
   ↓
Events + SessionStore
   ↓
CLI / LiveView updates
```

Specialized Muses:

```text
Planning Muse   → read-only inspection and plan creation
Coding Muse     → approved patch proposal and implementation
Reviewing Muse  → diff and architecture review
Testing Muse    → validation and failure interpretation
Research Muse   → repository exploration and context gathering
Memory Muse     → session compaction and durable lessons
Restoration Muse → checkpoints, rollback, and recovery
```

The system prompt is not a single string. It is a layered, stateful, permission-aware runtime. The Muse identity lives in the selected Muse profile, and the Muse Conductor ensures that every Muse acts within the session state, approval scope, workspace boundary, and available tools.
