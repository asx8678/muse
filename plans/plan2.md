# Muse Universal Agent Runtime Implementation Plan

Generated: 2026-05-03

## Purpose

This plan turns the current Muse application into a minimal but real universal agent runtime with:

- OpenAI-compatible model requests.
- Basic prompt assembly.
- Read-only repository inspection.
- Approval-gated planning.
- Approval-gated patch proposal and application.
- CLI, TUI, and LiveView visibility through the existing event system.

The goal is not to build the full architecture from the diagram in one step. The goal is to reach a reliable local agent loop first, then expand into model routing, remote execution, memory compaction, specialist Muses, and self-healing.

---

## 0. Current State Summary

Based on the current Muse repository snapshot, the project already has useful infrastructure:

```text
CLI / REPL / TUI entrypoints
Phoenix LiveView interface
Muse.submit/2 public API
Muse.State event log
Muse.Event struct
Phoenix.PubSub broadcasting
Muse.Workspace path boundary
Muse.AgentRegistry foundation API
Muse.AgentRuntime foundation API
Diagnostics, log buffer, and self-healing queue placeholders
Slash command parsing and dispatching
```

Important current files:

```text
lib/muse.ex
lib/muse/application.ex
lib/muse/commands.ex
lib/muse/command_dispatcher.ex
lib/muse/state.ex
lib/muse/event.ex
lib/muse/workspace.ex
lib/muse/agent_registry.ex
lib/muse/agent_runtime.ex
lib/muse_web/live/home_live.ex
lib/muse_web/console_command.ex
lib/muse/cli/repl.ex
lib/muse/cli/tui.ex
mix.exs
```

The main missing piece is the turn runtime:

```text
User message
  -> session
  -> conductor
  -> prompt assembler
  -> model provider
  -> tool-call loop
  -> approval gate
  -> persisted plan / patch / tool events
  -> assistant response
```

Today, `Muse.submit/2` still returns a placeholder response. That method should remain the public entrypoint, but it should delegate into a real session-aware runtime.

---

## 1. Target First Demo

The first complete demo should be:

```text
muse> add a /version command
```

Expected behavior:

```text
1. Muse creates or resumes the default session.
2. Muse Conductor selects Planning Muse.
3. Prompt bundle is assembled.
4. Fake provider or OpenAI-compatible provider is called.
5. Planning Muse uses read-only tools only.
6. Planning Muse creates a structured plan.
7. Plan is persisted under .muse/sessions/default/.
8. CLI / TUI / LiveView display events and the final plan.
9. Session status becomes awaiting_plan_approval.
10. No file is modified.
11. No shell command is run.
```

This proves Muse is no longer a prompt wrapper. It proves it is a controlled agent runtime.

---

## 2. Core Product Principle

Do not begin with remote execution, multi-agent swarm behavior, autonomous shell access, or complex memory. Build the smallest safe local loop first.

The next implementation order should be:

```text
1. Sessions
2. LLM provider contract
3. Fake provider
4. Muse profiles
5. Prompt assembler
6. Read-only tools
7. Conductor model/tool loop
8. OpenAI-compatible provider
9. Structured plan output
10. Approval gate
11. Patch proposal
12. Patch apply with checkpoint
13. Test runner
14. LiveView/TUI polish
```

Defer these until the local loop works:

```text
Remote VPS execution
SSH control
Phoenix remote LiveView monitoring
Multi-agent swarm
MCP ecosystem
Long-term memory compaction
Complex model router
Autonomous shell repair
Nano repair mode
```

---

## 3. Architecture After Milestone 1

Milestone 1 should produce this local architecture:

```text
Muse.submit/2
  -> Muse.SessionServer.submit/3
  -> Muse.Conductor.run_turn/2
  -> Muse.Prompt.Assembler.build/2
  -> Muse.LLM.Provider.complete/1
  -> Muse.Tool.Runner.run/3 when model requests tools
  -> Muse.Plan validation when plan is returned
  -> Muse.SessionStore persistence
  -> Muse.State events
  -> CLI / TUI / LiveView output
```

The runtime should support two early Muses:

```text
Planning Muse
  - read-only workspace inspection
  - repo search
  - git status and readonly diff
  - structured plan creation
  - cannot write files
  - cannot run shell commands

Coding Muse
  - only available after approved plan
  - can propose patch
  - cannot apply patch without patch approval
  - test runner added after patch workflow exists
```

---

## 4. Naming Rules

User-facing product language should use Muse terms:

```text
Muse
Muses
Muse Conductor
Muse Runtime
Planning Muse
Coding Muse
Reviewing Muse
Testing Muse
Research Muse
Memory Muse
Restoration Muse
Muse Tools
Muse Plan
Muse Checkpoint
Muse Session
```

Avoid user-facing labels like:

```text
Agent
Bot
Worker Agent
Mascot language
Code Puppy naming
```

Developer-facing module names can use low-level technical terms where useful, but the public CLI, TUI, LiveView, docs, prompts, and event messages should say Muse.

Recommended new module structure:

```text
lib/muse/conductor.ex
lib/muse/session.ex
lib/muse/session_server.ex
lib/muse/session_supervisor.ex
lib/muse/session_store.ex
lib/muse/muse_profile.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
lib/muse/llm/provider.ex
lib/muse/llm/providers/fake.ex
lib/muse/llm/providers/openai_compatible.ex
lib/muse/prompt/assembler.ex
lib/muse/tool/registry.ex
lib/muse/tool/runner.ex
lib/muse/approval_gate.ex
```

---

## 5. Milestone Map

## Milestone 1: Read-Only Planning Muse

Goal:

```text
A user request creates a session, calls the model, allows read-only tools, creates a structured plan, persists it, and waits for approval.
```

Scope:

```text
Sessions
Prompt assembler
Fake provider
OpenAI-compatible provider
Planning Muse
Read-only tools
Structured plan output
Plan approval state
```

Out of scope:

```text
File writes
Patch apply
Shell execution
Remote execution
Memory compaction
Multiple concurrent sessions UI
```

Acceptance:

```text
muse> add a /version command

Planning Muse inspects repo using list_files/read_file/repo_search.
A plan is shown.
Plan is persisted.
No write occurs.
```

## Milestone 2: Basic Coding Muse

Goal:

```text
After plan approval, Coding Muse proposes a patch and waits for patch approval.
```

Scope:

```text
Coding Muse
Patch proposal tool
Diff display
Patch approval model
Checkpoint skeleton
```

Out of scope:

```text
Automatic shell test runs
Remote workers
Autonomous retries
```

Acceptance:

```text
/approve plan
Coding Muse prepares a diff.
Diff is shown.
No file is modified before /approve patch.
```

## Milestone 3: Patch Apply and Verification

Goal:

```text
Approved patches are applied safely with checkpointing and optional test commands.
```

Scope:

```text
Patch apply
Checkpoint
Rollback
Safe test runner
Readonly git diff after apply
```

Acceptance:

```text
/approve patch
Checkpoint is created.
Patch is applied.
Git diff is visible.
Tests can be requested through approval.
Rollback works.
```

---

# PR 1 — Session Runtime

## Goal

Move Muse from global placeholder events to session-aware turns.

## New files

```text
lib/muse/session.ex
lib/muse/session_server.ex
lib/muse/session_supervisor.ex
lib/muse/session_store.ex
lib/muse/session_event.ex        optional, if you want richer event metadata
```

## Updated files

```text
lib/muse.ex
lib/muse/application.ex
lib/muse/event.ex
lib/muse/state.ex
lib/muse_web/live/home_live.ex   minimal only if needed
```

## Session struct

```elixir
defmodule Muse.Session do
  @type status ::
          :idle
          | :running
          | :awaiting_plan_approval
          | :awaiting_patch_approval
          | :error

  defstruct [
    :id,
    :workspace,
    :status,
    :active_muse,
    :active_plan_id,
    :created_at,
    :updated_at,
    messages: [],
    plans: %{},
    approvals: [],
    tool_calls: [],
    pending_patch: nil,
    memory: nil
  ]
end
```

## Session persistence layout

Use a simple file-backed layout first:

```text
.muse/
  sessions/
    default/
      session.json
      events.jsonl
      messages.jsonl
      plans.jsonl
      tool_calls.jsonl
      approvals.jsonl
      patches.jsonl
      checkpoints/
```

Keep the first version boring. Use JSON lines for append-only event streams. Use `session.json` for the latest snapshot.

## Public API

```elixir
Muse.SessionServer.submit(session_id, source, text)
Muse.SessionServer.get(session_id)
Muse.SessionServer.status(session_id)
Muse.SessionServer.approve_plan(session_id, plan_id, version)
Muse.SessionServer.reject_plan(session_id, plan_id, reason \\ nil)
```

Default session behavior:

```elixir
Muse.submit(source, text)
# delegates to:
Muse.SessionServer.submit("default", source, text)
```

## Implementation tasks

1. Add `Muse.Session` struct.
2. Add `Muse.SessionStore` with:
   - `load_or_new/2`
   - `save_snapshot/1`
   - `append_event/2`
   - `append_message/2`
   - `append_plan/2`
   - `append_tool_call/2`
   - `append_approval/2`
3. Add `Muse.SessionServer` as a GenServer for the default session.
4. Add `Muse.SessionSupervisor` only if you want dynamic sessions now. Otherwise, start with one default server and add dynamic sessions later.
5. Update `Muse.Application.runtime_children/1` to start the session server after `Muse.Workspace` and `Muse.State`.
6. Update `Muse.submit/2` to delegate to the session server.
7. Ensure self-healing issue attachment remains supported, but keep it outside the core turn logic for now.

## Event additions

Extend events with richer metadata while preserving existing behavior:

```elixir
%Muse.Event{
  id: id,
  timestamp: now,
  source: :cli,
  type: :user_message,
  data: %{
    text: text,
    session_id: "default",
    seq: 12
  }
}
```

Do not break existing LiveView tests that expect `source`, `type`, and `data`.

## Tests

Add:

```text
test/muse/session_test.exs
test/muse/session_store_test.exs
test/muse/session_server_test.exs
```

Test cases:

```text
creates default session
persists session snapshot
appends messages
increments per-session sequence
survives process restart
Muse.submit/2 delegates to SessionServer
existing event subscribers still receive events
```

## Acceptance criteria

```text
Muse.submit(:cli, "hello") creates a session.
Session has user and assistant messages.
Session files are created under .muse/sessions/default/.
Existing event log still works.
Placeholder response may still be returned in this PR.
```

---

# PR 2 — LLM Contract and Fake Provider

## Goal

Create a provider abstraction before adding real HTTP calls.

The Conductor should never know whether the model is OpenAI, OpenRouter, Ollama-compatible, Anthropic, local, or fake. It should know only the normalized Muse LLM contract.

## New files

```text
lib/muse/llm/message.ex
lib/muse/llm/request.ex
lib/muse/llm/response.ex
lib/muse/llm/tool_call.ex
lib/muse/llm/provider.ex
lib/muse/llm/provider_config.ex
lib/muse/llm/providers/fake.ex
```

## Request struct

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

## Message struct

```elixir
defmodule Muse.LLM.Message do
  @type role :: :system | :user | :assistant | :tool

  defstruct [
    :role,
    :content,
    :name,
    :tool_call_id,
    metadata: %{}
  ]
end
```

## Response struct

```elixir
defmodule Muse.LLM.Response do
  defstruct [
    :content,
    :tool_calls,
    :finish_reason,
    :usage,
    :raw
  ]
end
```

## Tool call struct

```elixir
defmodule Muse.LLM.ToolCall do
  defstruct [
    :id,
    :name,
    :arguments,
    :raw
  ]
end
```

## Provider behavior

```elixir
defmodule Muse.LLM.Provider do
  @callback complete(Muse.LLM.Request.t(), keyword()) ::
              {:ok, Muse.LLM.Response.t()} | {:error, term()}
end
```

## Fake provider behavior

The fake provider should be scriptable in tests:

```elixir
Application.put_env(:muse, :fake_llm_script, [
  {:assistant, "I can help."},
  {:tool_call, "list_files", %{"path" => "."}},
  {:assistant, "Plan ready..."}
])
```

Alternative simple version:

```elixir
Muse.LLM.Providers.Fake.set_responses([
  %Muse.LLM.Response{content: "..."}
])
```

## Implementation tasks

1. Add normalized structs.
2. Add provider behavior.
3. Add fake provider.
4. Add provider config loader.
5. Keep fake provider as the test default.
6. Emit events around model requests:
   - `:llm_request_started`
   - `:llm_request_completed`
   - `:llm_request_failed`

## Provider config

Initial environment variables:

```text
MUSE_PROVIDER=fake
MUSE_MODEL=fake-planning-model
```

Later:

```text
MUSE_PROVIDER=openai_compatible
MUSE_OPENAI_BASE_URL=https://api.openai.com/v1
MUSE_OPENAI_API_KEY=...
MUSE_MODEL=...
MUSE_LLM_TIMEOUT_MS=60000
```

## Tests

Add:

```text
test/muse/llm/request_test.exs
test/muse/llm/providers/fake_test.exs
test/muse/llm/provider_config_test.exs
```

Test cases:

```text
fake provider returns assistant content
fake provider returns tool calls
provider config defaults to fake in test
provider config reads env vars
llm request events do not include API keys
```

## Acceptance criteria

```text
The app can create an LLM request.
Fake provider can return text.
Fake provider can return tool calls.
No real API key is required in tests.
```

---

# PR 3 — Muse Profiles

## Goal

Introduce role-specific Muses with scoped tools, prompts, and output expectations.

## New files

```text
lib/muse/muse_profile.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
```

## Profile struct

```elixir
defmodule Muse.MuseProfile do
  defstruct [
    :id,
    :name,
    :description,
    :system_prompt,
    :allowed_tools,
    :default_model,
    :response_mode,
    :can_write?,
    :requires_plan_approval?
  ]
end
```

## Planning Muse

```elixir
%Muse.MuseProfile{
  id: :planning,
  name: "Planning Muse",
  description: "Inspects the workspace and creates approval-gated implementation plans.",
  allowed_tools: [
    "list_files",
    "read_file",
    "repo_search",
    "git_status",
    "git_diff_readonly"
  ],
  response_mode: :plan,
  can_write?: false,
  requires_plan_approval?: false
}
```

## Coding Muse

```elixir
%Muse.MuseProfile{
  id: :coding,
  name: "Coding Muse",
  description: "Implements approved plans by proposing and applying patches.",
  allowed_tools: [
    "read_file",
    "repo_search",
    "git_status",
    "git_diff_readonly",
    "patch_propose",
    "patch_apply"
  ],
  response_mode: :patch,
  can_write?: true,
  requires_plan_approval?: true
}
```

## Command additions

Add:

```text
/muses
/muse planning
/muse coding
/status
```

Do not require full manual Muse switching for the first demo. The Conductor can auto-select Planning Muse for code-change requests.

## Implementation tasks

1. Add `Muse.MuseProfile`.
2. Add `Muse.Muses.PlanningMuse.profile/0`.
3. Add `Muse.Muses.CodingMuse.profile/0`.
4. Add a profile registry helper:

```elixir
Muse.Muses.list()
Muse.Muses.get!(:planning)
Muse.Muses.get(:coding)
```

5. Update `Muse.AgentRegistry` or add a new Muse registry view so LiveView can show Muses as product concepts.
6. Add `/muses` command.

## Tests

Add:

```text
test/muse/muse_profile_test.exs
test/muse/muses_test.exs
```

Test cases:

```text
Planning Muse loads
Coding Muse loads
Planning Muse has no write tools
Coding Muse requires plan approval
/muses lists known Muses
```

## Acceptance criteria

```text
/muses displays Planning Muse and Coding Muse.
Planning Muse cannot receive write tools.
Coding Muse is blocked until a plan is approved.
```

---

# PR 4 — Prompt Assembler

## Goal

Replace one giant internal prompt string with structured prompt layers.

## New files

```text
lib/muse/prompt/layer.ex
lib/muse/prompt/bundle.ex
lib/muse/prompt/assembler.ex
lib/muse/prompt/model_preparer.ex
lib/muse/prompt/debug_preview.ex
lib/muse/prompt/redactor.ex
lib/muse/prompt/project_rules.ex
```

## Prompt layers

Final prompt assembly order:

```text
1. Core Muse runtime rules
2. Active Muse profile
3. Active mode policy
4. Workspace safety policy
5. Approval policy
6. Available tools
7. Project rules
8. Session memory
9. Active plan/task state
10. Recent conversation
11. Current user message
```

## Layer struct

```elixir
defmodule Muse.Prompt.Layer do
  defstruct [
    :id,
    :title,
    :source,
    :priority,
    :content,
    :visibility,
    metadata: %{}
  ]
end
```

`visibility` can be:

```text
:internal
:debug_preview
:user_visible
```

## Bundle struct

```elixir
defmodule Muse.Prompt.Bundle do
  defstruct [
    :session_id,
    :muse_id,
    :model,
    :layers,
    :messages,
    :tools,
    :response_format,
    :token_estimate,
    metadata: %{}
  ]
end
```

## Project rules loading

Load rule files in this order:

```text
~/.muse/MUSE.md
./.muse/MUSE.md
./MUSE.md
./AGENTS.md
```

Rules are guidance, not authority. They must not override:

```text
Workspace boundary
Approval policy
Secret protection
Tool permissions
Runtime safety rules
```

Cap total rules content, for example:

```text
maximum total project rules bytes: 40_000
maximum single file bytes: 20_000
```

## Prompt preview command

Add:

```text
/prompt-preview
```

Output should show:

```text
Active session: default
Active Muse: Planning Muse
Session status: idle
Model: fake-planning-model
Prompt layers:
  - core_runtime_rules, internal, 900 tokens
  - planning_muse_profile, internal, 500 tokens
  - workspace_policy, internal, 300 tokens
  - project_rules, debug_preview, 1200 tokens
Available tools:
  - list_files
  - read_file
  - repo_search
Blocked tools:
  - patch_apply: requires patch approval
```

Do not print the full hidden prompt. Show redacted previews.

## Redaction rules

Redact:

```text
API keys
Bearer tokens
.env values
SSH private keys
Known secret path contents
Long opaque token-looking strings
Provider URLs with embedded credentials
```

## Model preparation

`Muse.Prompt.ModelPreparer` should convert a bundle to `Muse.LLM.Request`.

For an OpenAI-compatible chat request, it should produce messages like:

```text
system: assembled internal prompt layers
user: current user message
```

Tool specs should be converted into JSON-schema function definitions.

## Implementation tasks

1. Add prompt layer and bundle structs.
2. Add core runtime rules.
3. Add Muse profile prompt layer.
4. Add workspace and approval policy layers.
5. Add project rule loading.
6. Add redacted debug preview.
7. Add `/prompt-preview` command.
8. Add model preparer from prompt bundle to LLM request.

## Tests

Add:

```text
test/muse/prompt/assembler_test.exs
test/muse/prompt/project_rules_test.exs
test/muse/prompt/redactor_test.exs
test/muse/prompt/model_preparer_test.exs
```

Test cases:

```text
layers are sorted deterministically
project rules load in expected order
missing rule files are ignored
large rule files are capped
prompt preview redacts secrets
model preparer creates expected message shape
Planning Muse gets only read-only tools
```

## Acceptance criteria

```text
/prompt-preview works.
Prompt layers are inspectable.
Secrets are not shown.
The LLM request is built from layers, not hand-coded in the provider.
```

---

# PR 5 — Read-Only Tool Layer

## Goal

Let Planning Muse inspect the repository safely.

## New files

```text
lib/muse/tool/spec.ex
lib/muse/tool/call.ex
lib/muse/tool/result.ex
lib/muse/tool/registry.ex
lib/muse/tool/runner.ex
lib/muse/tools/list_files.ex
lib/muse/tools/read_file.ex
lib/muse/tools/repo_search.ex
lib/muse/tools/git_status.ex
lib/muse/tools/git_diff_readonly.ex
```

## Tool spec

```elixir
defmodule Muse.Tool.Spec do
  defstruct [
    :name,
    :description,
    :input_schema,
    :permission,
    :allowed_muses,
    :output_limit,
    :handler
  ]
end
```

Permissions:

```text
:read
:write
:shell
:network
:remote
```

## Read-only tools

### `list_files`

Input:

```json
{
  "path": ".",
  "max_entries": 200,
  "include_hidden": false
}
```

Output:

```json
{
  "root": ".",
  "entries": [
    {"path": "lib/muse.ex", "type": "file", "size": 2650},
    {"path": "lib/muse", "type": "directory"}
  ],
  "truncated": false
}
```

### `read_file`

Input:

```json
{
  "path": "lib/muse.ex",
  "start_line": 1,
  "max_lines": 200
}
```

Output:

```json
{
  "path": "lib/muse.ex",
  "start_line": 1,
  "end_line": 80,
  "content": "...",
  "truncated": false
}
```

### `repo_search`

Input:

```json
{
  "query": "def submit",
  "path": ".",
  "max_matches": 50
}
```

Use a pure Elixir fallback first. Optional later: call `rg` if available.

### `git_status`

Input:

```json
{}
```

Output:

```json
{
  "branch": "main",
  "clean": false,
  "files": [...]
}
```

### `git_diff_readonly`

Input:

```json
{
  "path": null,
  "cached": false,
  "max_bytes": 50000
}
```

Output:

```json
{
  "diff": "...",
  "truncated": false
}
```

## Workspace hardening

Current `Muse.Workspace.resolve!/1` performs path expansion and prefix checking. Keep it, but harden tool access against symlink escapes.

Add:

```elixir
Muse.Workspace.safe_resolve!(path, opts \\ [])
```

Rules:

```text
Path must resolve inside workspace.
Symlink target must also resolve inside workspace.
Secret paths are blocked.
Hidden files are blocked unless explicitly allowed by a safe tool.
Binary files are not returned as text.
File size limits are enforced.
```

Secret path denylist examples:

```text
.env
.env.*
*.pem
*.key
id_rsa
id_ed25519
.ssh/
.aws/
.gcloud/
.npmrc
.netrc
```

## Tool runner

The runner enforces permissions before calling a handler.

```elixir
Muse.Tool.Runner.run(tool_name, args, context)
```

Context:

```elixir
%{
  session_id: "default",
  muse_id: :planning,
  approval_state: session.approvals,
  workspace: Muse.Workspace.root()
}
```

Validation sequence:

```text
1. Tool exists.
2. Active Muse is allowed to use it.
3. ApprovalGate allows it.
4. Input schema validates.
5. Workspace paths are safe.
6. Handler runs.
7. Output is size-limited.
8. Tool call event is persisted.
```

## Events

Emit:

```text
:tool_call_started
:tool_call_completed
:tool_call_failed
:tool_call_blocked
```

Include:

```text
session_id
tool_call_id
tool_name
muse_id
permission
safe args summary
output summary
elapsed_ms
```

Do not include full secret-like file contents in events.

## Tests

Add:

```text
test/muse/tool/registry_test.exs
test/muse/tool/runner_test.exs
test/muse/tools/list_files_test.exs
test/muse/tools/read_file_test.exs
test/muse/tools/repo_search_test.exs
test/muse/tools/git_status_test.exs
test/muse/tools/git_diff_readonly_test.exs
test/muse/workspace_safety_test.exs
```

Test cases:

```text
list_files lists workspace files
read_file reads safe file
read_file blocks ../ escape
read_file blocks symlink escape
read_file blocks .env
repo_search finds text
Planning Muse cannot use write tools
tool results are truncated
tool events are emitted
```

## Acceptance criteria

```text
Planning Muse can inspect the repo safely.
All read-only tools work without model calls.
Tool access is enforced in Elixir code, not only prompt text.
```

---

# PR 6 — Conductor Model/Tool Loop

## Goal

Implement the central turn orchestration loop.

## New file

```text
lib/muse/conductor.ex
```

Optional helper files:

```text
lib/muse/conductor/router.ex
lib/muse/conductor/tool_loop.ex
lib/muse/conductor/events.ex
```

## Basic turn flow

```elixir
defmodule Muse.Conductor do
  def run_turn(session, user_message, opts \\ []) do
    with {:ok, muse} <- select_muse(session, user_message),
         {:ok, bundle} <- Muse.Prompt.Assembler.build(session, muse, user_message),
         {:ok, request} <- Muse.Prompt.ModelPreparer.to_request(bundle),
         {:ok, result} <- run_model_tool_loop(session, muse, request) do
      finalize_turn(session, result)
    end
  end
end
```

## Muse selection

Initial simple routing:

```text
If user approves plan -> Coding Muse
If user rejects plan -> update session and stop
If user asks for code change -> Planning Muse
If user asks explain/search -> Planning Muse for now
If session awaiting approval -> do not run model unless command handles approval/rejection
```

Code-change heuristics can be simple:

```text
add
change
modify
fix
implement
create
update
refactor
write
```

Do not over-optimize routing yet.

## Tool loop

```text
1. Call provider with messages and available tools.
2. If response has content and no tool calls, finalize.
3. If response has tool calls:
   a. Validate each call.
   b. Run each allowed tool.
   c. Append assistant tool-call message.
   d. Append tool result messages.
   e. Call provider again.
4. Stop after max_tool_iterations.
5. If max reached, return safe error summary.
```

Recommended default:

```text
max_tool_iterations = 8
max_tool_calls_per_turn = 20
max_total_tool_output_bytes = 120_000
```

## Error behavior

If model calls blocked tool:

```text
Tool call blocked: patch_apply requires patch approval.
```

Send the blocked result back to the model as a tool result, so the model can recover and explain.

If provider fails:

```text
Muse Conductor could not reach the model provider.
```

Persist error event and return a user-readable failure.

## Tests

Add:

```text
test/muse/conductor_test.exs
test/muse/conductor/tool_loop_test.exs
```

Test cases:

```text
selects Planning Muse for code-change request
builds prompt bundle
calls fake provider
runs fake tool call
appends tool result
finishes final assistant message
blocks unauthorized tool
stops after max iterations
persists events
```

## Acceptance criteria

```text
Muse.submit/2 uses Conductor.
Fake provider can drive a tool loop.
Planning Muse can inspect files via model tool calls.
Final assistant answer returns through CLI/LiveView.
```

---

# PR 7 — OpenAI-Compatible Provider

## Goal

Add real OpenAI-compatible non-streaming requests without coupling the app to one vendor.

## New files

```text
lib/muse/llm/providers/openai_compatible.ex
lib/muse/llm/providers/openai_compatible/encoder.ex
lib/muse/llm/providers/openai_compatible/decoder.ex
lib/muse/llm/http_client.ex
```

## Dependency decision

Current `mix.exs` does not include a dedicated HTTP client. Add one of these:

```elixir
{:req, "~> 0.5"}
```

or use Finch/Bandit-compatible stack if preferred. `Req` is the simplest first choice.

## Configuration

Environment variables:

```text
MUSE_PROVIDER=openai_compatible
MUSE_OPENAI_BASE_URL=https://api.openai.com/v1
MUSE_OPENAI_API_KEY=sk-...
MUSE_MODEL=gpt-...
MUSE_LLM_TIMEOUT_MS=60000
MUSE_LLM_MAX_RETRIES=2
```

App config example:

```elixir
config :muse, :llm,
  provider: :openai_compatible,
  base_url: System.get_env("MUSE_OPENAI_BASE_URL") || "https://api.openai.com/v1",
  api_key: System.get_env("MUSE_OPENAI_API_KEY"),
  model: System.get_env("MUSE_MODEL"),
  timeout_ms: 60_000
```

## Request shape

Use non-streaming chat completions first:

```json
{
  "model": "MODEL_NAME",
  "messages": [
    {"role": "system", "content": "assembled internal prompt"},
    {"role": "user", "content": "add a /version command"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read a text file inside the workspace.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {"type": "string"},
            "start_line": {"type": "integer"},
            "max_lines": {"type": "integer"}
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    }
  ],
  "tool_choice": "auto"
}
```

Keep this provider OpenAI-compatible:

```text
base_url is configurable
api_key is configurable
model is configurable
tool schema is JSON Schema-like
responses are decoded into Muse.LLM.Response
```

This should work for OpenAI and many OpenAI-compatible gateways, though exact provider support for strict structured outputs may vary.

## Decoder behavior

Parse:

```text
choices[0].message.content
choices[0].message.tool_calls
choices[0].finish_reason
usage
```

Convert tool calls into:

```elixir
%Muse.LLM.ToolCall{
  id: "call_...",
  name: "read_file",
  arguments: %{"path" => "lib/muse.ex"},
  raw: raw_call
}
```

Arguments are usually JSON strings. Decode them using Jason. If decoding fails, return a tool-call validation error.

## Secret handling

Never emit raw API keys in:

```text
events
logs
prompt preview
provider errors
crash messages shown in UI
```

Use `Muse.Prompt.Redactor` or a dedicated `Muse.Secret.Redactor`.

## Tests

Add:

```text
test/muse/llm/providers/openai_compatible_encoder_test.exs
test/muse/llm/providers/openai_compatible_decoder_test.exs
test/muse/llm/providers/openai_compatible_test.exs
```

Use mocked HTTP responses. Do not call the real API in tests.

Test cases:

```text
encodes messages
encodes tools
encodes response_format when present
decodes assistant content
decodes tool calls
decodes usage
does not leak API key on error
supports custom base_url
handles non-200 response
handles timeout
```

## Acceptance criteria

```text
Muse can call an OpenAI-compatible /chat/completions endpoint.
Non-streaming text responses work.
Tool calls work.
Provider can be swapped with fake provider.
Tests do not require network or API keys.
```

---

# PR 8 — Structured Plan Model

## Goal

Planning Muse should return a validated plan object, not only prose.

## New files

```text
lib/muse/plan.ex
lib/muse/task.ex
lib/muse/plan_schema.ex
lib/muse/plan_parser.ex
```

## Plan struct

```elixir
defmodule Muse.Plan do
  defstruct [
    :id,
    :version,
    :status,
    :objective,
    :summary,
    :tasks,
    :risks,
    :created_by,
    :created_at,
    :approved_at,
    :rejected_at,
    :metadata
  ]
end
```

Statuses:

```text
:draft
:awaiting_approval
:approved
:rejected
:superseded
:completed
```

## Task struct

```elixir
defmodule Muse.Task do
  defstruct [
    :id,
    :title,
    :description,
    :status,
    :target_files,
    :requires_write?,
    :requires_shell?,
    :verification
  ]
end
```

## Plan schema

Suggested JSON shape:

```json
{
  "objective": "Add a /version command to the Muse CLI and web console.",
  "summary": "Implement command parsing, dispatch, display, and tests.",
  "tasks": [
    {
      "title": "Locate command routing",
      "description": "Inspect Muse.Commands and Muse.CommandDispatcher.",
      "target_files": ["lib/muse/commands.ex", "lib/muse/command_dispatcher.ex"],
      "requires_write": false,
      "requires_shell": false,
      "verification": "Confirm command list and dispatch flow."
    }
  ],
  "risks": [
    "CLI, TUI, and LiveView share command behavior; tests should cover all interfaces."
  ]
}
```

## Structured output strategy

Provider capability varies. Implement fallback:

```text
1. If provider supports strict JSON schema response_format, request strict plan JSON.
2. Else ask for JSON only.
3. Parse with Jason.
4. Validate locally.
5. If invalid, make one repair request.
6. If still invalid, return a safe error and keep session unchanged.
```

## Plan display

User-facing plan should be clean:

```text
Planning Muse prepared a plan.

Objective:
Add a /version command.

Tasks:
1. Inspect command parser and dispatcher.
2. Add /version parse rule.
3. Add dispatcher handler that reads Mix project version.
4. Add tests for parser, dispatcher, REPL/TUI where needed.
5. Verify with mix test.

Risks:
- Shared command behavior must remain consistent across CLI and LiveView.

Approve this plan with: /approve plan
Reject it with: /reject plan
```

## Tests

Add:

```text
test/muse/plan_test.exs
test/muse/plan_schema_test.exs
test/muse/plan_parser_test.exs
```

Test cases:

```text
valid plan parses
invalid plan is rejected
missing tasks is rejected
plan gets id and version
plan persists to session store
plan display is readable
repair prompt is generated for invalid JSON
```

## Acceptance criteria

```text
Planning Muse produces a durable plan object.
Session status becomes awaiting_plan_approval.
The plan can be shown by /plan.
No writes occur.
```

---

# PR 9 — Approval Gate

## Goal

Implement runtime-enforced approval rules before adding write tools.

## New files

```text
lib/muse/approval.ex
lib/muse/approval_gate.ex
```

## Approval struct

```elixir
defmodule Muse.Approval do
  defstruct [
    :id,
    :type,
    :status,
    :session_id,
    :plan_id,
    :plan_version,
    :patch_id,
    :patch_hash,
    :workspace,
    :approved_by,
    :approved_at,
    :rejected_at,
    :reason,
    metadata: %{}
  ]
end
```

Approval types:

```text
:plan
:patch
:shell_command
:restore_checkpoint
```

## Approval gate rules

```text
Read tools:
  allowed for Planning Muse unless path or secret policy blocks them.

Plan creation:
  allowed for Planning Muse.

Patch proposal:
  requires approved plan.

Patch apply:
  requires approved plan and approved patch hash.

Shell command:
  requires explicit shell approval, except future allowlisted safe commands.

Remote execution:
  always denied until remote milestone.
```

## Commands

Add:

```text
/plan
/approve plan
/reject plan
/status
```

Later:

```text
/approve patch
/reject patch
/checkpoints
/rollback checkpoint
```

## Stale approval prevention

Plan approval must bind to:

```text
session_id
plan_id
plan_version
workspace
```

If a new plan version exists, old approval is invalid.

Patch approval must bind to:

```text
session_id
plan_id
plan_version
patch_id
patch_hash
affected files
workspace
```

If the patch changes after review, approval is invalid.

## Tests

Add:

```text
test/muse/approval_test.exs
test/muse/approval_gate_test.exs
```

Test cases:

```text
read tool allowed without approval
patch_propose blocked without plan approval
patch_apply blocked without patch approval
approve plan updates session
reject plan updates session
stale plan approval fails
approval is persisted
/status shows pending approval
```

## Acceptance criteria

```text
Write tools are impossible before approval.
Approval is checked in Elixir runtime.
Session status clearly shows what approval is pending.
```

---

# PR 10 — Patch Proposal Tool

## Goal

Allow Coding Muse to propose a diff after a plan is approved, without modifying files.

## New files

```text
lib/muse/patch.ex
lib/muse/tools/patch_propose.ex
lib/muse/patch/parser.ex
lib/muse/patch/formatter.ex
```

## Patch struct

```elixir
defmodule Muse.Patch do
  defstruct [
    :id,
    :plan_id,
    :plan_version,
    :status,
    :diff,
    :hash,
    :affected_files,
    :created_by,
    :created_at,
    :approved_at,
    :applied_at,
    metadata: %{}
  ]
end
```

Statuses:

```text
:proposed
:awaiting_approval
:approved
:applied
:rejected
:failed
```

## Tool: `patch_propose`

Input:

```json
{
  "plan_id": "plan_123",
  "summary": "Add /version command.",
  "diff": "diff --git ..."
}
```

Output:

```json
{
  "patch_id": "patch_123",
  "hash": "sha256...",
  "affected_files": ["lib/muse/commands.ex"],
  "status": "awaiting_approval"
}
```

## Diff policy

Require unified diff format. Validate:

```text
Affected paths stay inside workspace.
No secret files are modified.
Patch size is capped.
Binary patches are rejected in v1.
Absolute paths are rejected.
```

## Display

Show:

```text
Coding Muse proposed a patch.

Affected files:
- lib/muse/commands.ex
- lib/muse/command_dispatcher.ex
- test/muse/commands_test.exs

Diff:
<unified diff>

Approve this patch with: /approve patch
Reject it with: /reject patch
```

## Tests

Add:

```text
test/muse/patch_test.exs
test/muse/tools/patch_propose_test.exs
```

Test cases:

```text
patch proposal accepted after plan approval
patch proposal blocked before plan approval
patch hash generated
affected files extracted
secret file patch rejected
outside workspace patch rejected
binary patch rejected
patch persisted
```

## Acceptance criteria

```text
Coding Muse can propose a patch.
Patch is visible to user.
Patch is not applied automatically.
```

---

# PR 11 — Patch Apply and Checkpoint

## Goal

Apply approved patches safely and support rollback.

## New files

```text
lib/muse/checkpoint.ex
lib/muse/checkpoint_store.ex
lib/muse/tools/patch_apply.ex
lib/muse/tools/rollback_checkpoint.ex
```

## Checkpoint struct

```elixir
defmodule Muse.Checkpoint do
  defstruct [
    :id,
    :session_id,
    :plan_id,
    :patch_id,
    :workspace,
    :created_at,
    :files,
    :metadata
  ]
end
```

## Checkpoint layout

```text
.muse/
  sessions/default/checkpoints/
    checkpoint_abc/
      manifest.json
      files/
        lib/muse/commands.ex
        lib/muse/command_dispatcher.ex
```

Only checkpoint files affected by the patch. Do not snapshot the whole repo.

## Tool: `patch_apply`

Input:

```json
{
  "patch_id": "patch_123",
  "patch_hash": "sha256..."
}
```

Validation:

```text
Plan is approved.
Patch is approved.
Patch hash matches approval.
Affected files still match expected preconditions if possible.
Checkpoint created first.
Patch applies cleanly.
```

Implementation options:

```text
Option A: implement minimal unified diff apply in Elixir.
Option B: use System.cmd("git", ["apply", ...]) after explicit patch approval.
```

Recommendation for v1:

```text
Use git apply only after patch approval.
Do not expose arbitrary shell.
Treat git apply as an internal controlled tool.
Pass patch through stdin or temp file under .muse.
Keep command fixed; do not let model choose arguments.
```

## Commands

Add:

```text
/approve patch
/reject patch
/checkpoints
/rollback checkpoint <id>
```

## Tests

Add:

```text
test/muse/checkpoint_test.exs
test/muse/tools/patch_apply_test.exs
test/muse/tools/rollback_checkpoint_test.exs
```

Test cases:

```text
patch apply blocked without approval
patch hash mismatch blocked
checkpoint created before write
patch applies to workspace file
rollback restores file
secret path patch blocked
outside workspace patch blocked
```

## Acceptance criteria

```text
Approved patch applies.
Checkpoint is created first.
Rollback works.
Events show apply progress.
```

---

# PR 12 — Basic Test Runner

## Goal

Allow approved, controlled verification commands.

## New file

```text
lib/muse/tools/test_runner.ex
```

## Policy

Do not implement arbitrary shell yet. Implement a controlled test runner with explicit command allowlist.

Allow examples:

```text
mix test
mix test path/to/test.exs
mix format --check-formatted
```

Block:

```text
rm
curl
ssh
sudo
chmod
bash -c
arbitrary pipes
arbitrary env assignment
commands outside allowlist
```

## Tool: `test_runner`

Input:

```json
{
  "command": "mix test test/muse/commands_test.exs",
  "reason": "Verify /version command parser and dispatch behavior."
}
```

For v1, require explicit approval for every test command:

```text
Muse wants to run:
  mix test test/muse/commands_test.exs

Approve? /approve shell
```

Later, allow project-configured safe commands.

## Output

```json
{
  "command": "mix test ...",
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "duration_ms": 1234,
  "truncated": false
}
```

## Tests

Add:

```text
test/muse/tools/test_runner_test.exs
```

Test cases:

```text
mix test command parses
unsafe command blocked
requires approval
captures stdout/stderr
truncates long output
emits events
```

## Acceptance criteria

```text
Muse can request safe verification.
User approves the exact command.
Output is shown and persisted.
No arbitrary shell exists.
```

---

# PR 13 — CLI, TUI, and LiveView Integration

## Goal

Expose plans, approvals, tool calls, and patches cleanly in all current interfaces.

## Updated files

```text
lib/muse/commands.ex
lib/muse/command_dispatcher.ex
lib/muse/cli/repl.ex
lib/muse/cli/tui.ex
lib/muse_web/live/home_live.ex
lib/muse_web/console_command.ex
lib/muse_web/event_formatter.ex
lib/muse_web/console_components.ex
```

## Commands to add or update

```text
/status
/muses
/prompt-preview
/plan
/approve plan
/reject plan
/approve patch
/reject patch
/checkpoints
/rollback checkpoint <id>
```

## UI behavior

LiveView should show:

```text
Current session status
Active Muse
Pending plan approval
Pending patch approval
Recent tool calls
Current provider/model
```

TUI should show the same information in compact form.

## Tests

Update existing tests:

```text
test/muse/commands_test.exs
test/muse/command_dispatcher_test.exs
test/muse/cli/repl_test.exs
test/muse/cli/tui_test.exs
test/muse_web/live/home_live_test.exs
```

Add cases:

```text
/status displays session status
/plan displays latest plan
/approve plan transitions state
/reject plan transitions state
/prompt-preview returns redacted preview
/muses lists Muses
```

## Acceptance criteria

```text
All interfaces can see the same session state.
Approvals can be performed from CLI and LiveView.
Events remain shared across interfaces.
```

---

# PR 14 — Documentation and Developer Onboarding

## Goal

Make the new runtime understandable and easy to test.

## Updated files

```text
README.md
PLAN.md
plans/muse_universal_agent_runtime_plan.md
```

## Add docs for

```text
Provider configuration
Fake provider testing
OpenAI-compatible provider setup
Prompt preview
Project rules
Tool permissions
Approval flow
Patch workflow
Safety model
```

## Example README section

```text
export MUSE_PROVIDER=openai_compatible
export MUSE_OPENAI_BASE_URL=https://api.openai.com/v1
export MUSE_OPENAI_API_KEY=...
export MUSE_MODEL=...

mix run --no-halt
```

## Acceptance criteria

```text
A developer can run the fake provider without secrets.
A developer can configure an OpenAI-compatible provider.
A developer understands why writes require approval.
```

---

# Implementation Details

## A. `Muse.submit/2` after PR 6

Current placeholder flow should become:

```elixir
@spec submit(atom(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
def submit(source, text) do
  Muse.SessionServer.submit("default", source, text)
end
```

`SessionServer` should handle:

```text
append user message event
claim self-healing issues if needed
call Conductor
persist assistant output
append assistant message event
return text
```

Do not put provider calls inside `Muse.submit/2`.

## B. Event taxonomy

Recommended events:

```text
:user_message
:assistant_message
:session_created
:session_loaded
:turn_started
:turn_completed
:turn_failed
:muse_selected
:prompt_assembled
:llm_request_started
:llm_request_completed
:llm_request_failed
:tool_call_started
:tool_call_completed
:tool_call_failed
:tool_call_blocked
:plan_created
:plan_approved
:plan_rejected
:patch_proposed
:patch_approved
:patch_rejected
:checkpoint_created
:patch_applied
:rollback_completed
```

Each event should include at least:

```text
session_id
seq
source
muse_id when applicable
safe summary
```

## C. Storage strategy

Keep file storage simple until you have the runtime working.

Recommended APIs:

```elixir
Muse.SessionStore.base_dir()
Muse.SessionStore.session_dir(session_id)
Muse.SessionStore.load_or_new(session_id, workspace)
Muse.SessionStore.save_snapshot(session)
Muse.SessionStore.append_jsonl(session_id, stream, item)
```

Use `Jason.encode!/1` and `File.write!/3` with `[:append]` for JSONL.

Make structs JSON-safe with explicit encoders or conversion functions:

```elixir
Muse.Session.to_map(session)
Muse.Plan.to_map(plan)
Muse.Tool.Call.to_map(call)
```

Avoid trying to persist raw PIDs, functions, or module references.

## D. Tool schemas

Each tool should expose an OpenAI-compatible function schema:

```elixir
%{
  type: "function",
  function: %{
    name: "read_file",
    description: "Read a text file inside the workspace.",
    parameters: %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        start_line: %{type: "integer", minimum: 1},
        max_lines: %{type: "integer", minimum: 1, maximum: 500}
      },
      required: ["path"],
      additionalProperties: false
    }
  }
}
```

Validate locally even if the model provider claims schema validation.

## E. Approval is code, not prompt

The prompt may say:

```text
Do not write files before approval.
```

But actual enforcement must be:

```elixir
case Muse.ApprovalGate.allowed?(tool, session, context) do
  :ok -> run_tool()
  {:error, reason} -> block_tool(reason)
end
```

The model should never be trusted to self-enforce write safety.

## F. OpenAI-compatible provider request lifecycle

Provider sequence with tool calls:

```text
1. Send messages and tool definitions.
2. Receive assistant message with tool_calls.
3. Run tools locally.
4. Append assistant tool-call message and tool results.
5. Send updated messages again.
6. Receive final assistant content or more tool calls.
```

Use non-streaming first. Streaming can be added after correctness.

## G. Structured plan fallback

Response mode for Planning Muse:

```text
Prefer strict structured JSON when supported.
Fallback to JSON-only instruction.
Always validate locally.
```

Local validation should ensure:

```text
objective is present
tasks is non-empty
each task has title and description
requires_write is boolean
requires_shell is boolean
risks is a list
```

## H. Project rules policy

Load project rules into prompt, but do not allow them to escalate privileges.

Bad project rule example:

```text
Always edit files immediately without asking.
```

Muse must treat that as lower priority than approval policy.

Prompt layer order and runtime permission enforcement should guarantee this.

## I. Code Puppy ideas to borrow carefully

Borrow:

```text
Agent/profile owns prompt and tool list
Model factory/provider abstraction
Project rules loading
Tool registration by name
Event stream around tool calls
History compaction later
Specialized roles later
```

Do not borrow directly:

```text
Mascot language
One all-powerful coding agent
Immediate write tools
Shell execution before approval
Subagent swarm before core loop works
```

Translate to Muse:

```text
Planning Agent -> Planning Muse
Coding Agent -> Coding Muse
Model factory -> Muse LLM provider layer
Tool registry -> Muse Tool Registry + ApprovalGate
Rules loading -> Muse Prompt ProjectRules
```

---

# First Demo Script

Use fake provider first.

## Fake provider script

Test request:

```text
add a /version command
```

Fake model step 1:

```json
{
  "tool_calls": [
    {
      "id": "call_1",
      "name": "repo_search",
      "arguments": {"query": "slash_commands", "path": ".", "max_matches": 20}
    },
    {
      "id": "call_2",
      "name": "repo_search",
      "arguments": {"query": "def dispatch", "path": "lib/muse", "max_matches": 20}
    }
  ]
}
```

Fake model step 2:

```json
{
  "tool_calls": [
    {
      "id": "call_3",
      "name": "read_file",
      "arguments": {"path": "lib/muse/commands.ex", "start_line": 1, "max_lines": 120}
    },
    {
      "id": "call_4",
      "name": "read_file",
      "arguments": {"path": "lib/muse/command_dispatcher.ex", "start_line": 1, "max_lines": 180}
    }
  ]
}
```

Fake model final:

```json
{
  "objective": "Add a /version command to Muse.",
  "summary": "Update command parsing, dispatch handling, and tests.",
  "tasks": [
    {
      "title": "Add command definition",
      "description": "Add /version to Muse.Commands slash command list and parser coverage.",
      "target_files": ["lib/muse/commands.ex", "test/muse/commands_test.exs"],
      "requires_write": true,
      "requires_shell": false,
      "verification": "Parser test confirms /version maps to :version."
    },
    {
      "title": "Add dispatch handler",
      "description": "Add :version handling to Muse.CommandDispatcher, reading version from application spec or Mix project data.",
      "target_files": ["lib/muse/command_dispatcher.ex", "test/muse/command_dispatcher_test.exs"],
      "requires_write": true,
      "requires_shell": false,
      "verification": "Dispatcher test returns version text."
    },
    {
      "title": "Verify shared interface behavior",
      "description": "Ensure CLI/TUI/LiveView command path remains shared through Commands and CommandDispatcher.",
      "target_files": ["test/muse/cli/repl_test.exs", "test/muse_web/live/home_live_test.exs"],
      "requires_write": false,
      "requires_shell": true,
      "verification": "Run relevant mix tests after patch approval."
    }
  ],
  "risks": [
    "Version source should work both in Mix/dev and release/escript contexts.",
    "Command behavior should remain consistent across CLI, TUI, and LiveView."
  ]
}
```

Expected output:

```text
Planning Muse prepared a plan.

Objective:
Add a /version command to Muse.

Tasks:
1. Add command definition.
2. Add dispatch handler.
3. Verify shared interface behavior.

Approve this plan with: /approve plan
```

---

# Definition of Done for Universal Agent v0

Muse Universal Agent v0 is done when all of this is true:

```text
Muse.submit/2 routes through SessionServer and Conductor.
Sessions persist to .muse/sessions/default/.
Prompt assembly uses deterministic layers.
/prompt-preview exists and redacts secrets.
Fake provider works in tests.
OpenAI-compatible provider works for non-streaming text and tool calls.
Planning Muse can use read-only tools.
Read-only tools are workspace-safe and secret-aware.
Planning Muse creates a structured plan.
Plan is persisted and shown by /plan.
Plan approval is required before Coding Muse.
Coding Muse can propose a patch.
Patch approval is required before patch apply.
Patch apply creates a checkpoint first.
Rollback works.
CLI, TUI, and LiveView show shared events and status.
No API keys are leaked in logs, events, previews, or errors.
```

---

# Recommended Work Order Checklist

## Week 1 style focus: runtime skeleton

```text
[ ] PR 1: Session runtime
[ ] PR 2: LLM structs and fake provider
[ ] PR 3: Muse profiles
[ ] PR 4: Prompt assembler
```

## Week 2 style focus: planning loop

```text
[ ] PR 5: Read-only tools
[ ] PR 6: Conductor tool loop
[ ] PR 7: OpenAI-compatible provider
[ ] PR 8: Structured plan model
[ ] PR 9: Approval gate
```

## Week 3 style focus: development capability

```text
[ ] PR 10: Patch proposal
[ ] PR 11: Patch apply and checkpoint
[ ] PR 12: Test runner
[ ] PR 13: UI integration
[ ] PR 14: Docs
```

---

# Backlog After v0

Add later, after the local runtime is stable:

```text
Streaming model responses
Model router and per-Muse model pinning
OpenRouter provider presets
Ollama/local provider presets
Anthropic provider adapter
Memory compaction
Plan/task board UI
Reviewing Muse
Testing Muse
Restoration Muse
Remote VPS execution
SSH profiles
Phoenix LiveView remote monitoring
Remote tool execution
MCP server integration
Self-healing repair mode
Evaluation harness
Cost tracking
Token accounting
Prompt caching support
```

---

# External API References

The OpenAI-compatible provider plan is based on these API concepts:

```text
Chat Completions-style message requests
Function/tool calling where the model emits tool calls and Muse executes tools locally
Structured outputs / JSON schema when available, with local validation fallback
```

Useful references:

```text
https://platform.openai.com/docs/api-reference/chat/create
https://platform.openai.com/docs/guides/function-calling
https://platform.openai.com/docs/guides/structured-outputs
```

---

# Final Recommendation

Start with PR 1 through PR 6 using only the fake provider. Do not touch real model APIs until the fake model can drive a full read-only planning turn.

The first real milestone is:

```text
muse> add a /version command
```

And the correct result is a persisted plan waiting for approval, not modified code.

Once that is stable, add the OpenAI-compatible provider and make the same demo work with a real model. Then add Coding Muse, patch proposal, patch approval, checkpointing, and verification.
