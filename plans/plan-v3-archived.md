# Muse Universal Runtime — Ultimate Final Implementation Plan

**Generated:** 2026-05-03  
**Version:** 3.0 FINAL  
**Merged from:** `implementation_plan.md` and `implementation_plan 2.md`  
**Recommended repo filename:** `PLAN.md` or `docs/muse_universal_runtime_plan.md`

---

## A. Merge analysis and final decisions

### A.1 What changed from the uploaded plans

The two uploaded files describe the same Muse runtime program. `implementation_plan.md` is the cleaner baseline, while `implementation_plan 2.md` is the stronger expanded draft. This final plan keeps the v2 backbone, removes its wrapper/meta prose, preserves v1 defaults where they are safer, and resolves conflicts into one implementation contract.

| Area | Final decision |
|---|---|
| Architecture backbone | Use the v2 architecture: `SessionServer` owns state; `Muse.Conductor`/`TurnRunner` runs long work outside the GenServer. |
| PR sizing | Keep v2's split roadmap: PR 01a/01b/01c and PR 07a/07b to reduce implementation risk. |
| Naming | Enforce Muse-first language in all user-facing surfaces; legacy technical modules can be wrapped temporarily. |
| Repo search | Merge v1 safety with v2 performance: pure Elixir scanner is mandatory; `rg`/`grep` are controlled, read-only, configured backends. |
| Checkpoints | Use a hybrid strategy: `git stash create` where available, affected-file snapshots as fallback. |
| Provider work | Fake provider first; real providers only after deterministic tests, config validation, redaction, and auth safety are in place. |
| Persistence | Use crash-safe JSONL/snapshots with schema versions, atomic writes, and corrupt-line handling. |
| Streaming | Add sequence-based replay and a `streamed?` marker so CLI/LiveView do not duplicate final responses. |
| Observability | Add telemetry events early enough to debug provider/tool loops without leaking secrets. |
| Safety | Runtime safety is enforced in Elixir code. Prompt text is guidance only. |

### A.2 Critical path summary

1. **Stabilize the baseline:** verify repo facts, preserve `Muse.submit/2`, document current self-healing behavior, and clean user-facing naming.
2. **Add stateful runtime foundations:** event metadata, session/turn structs, crash-safe persistence, session routing, and supervised turn execution.
3. **Add visibility:** streaming event API for CLI/TUI/LiveView with event replay.
4. **Add deterministic intelligence path:** provider-neutral LLM contracts, fake provider, Muse profiles, prompt stack, and redacted prompt preview.
5. **Add read-only tools:** workspace-safe file listing, reading, repo search, git status, and read-only diff.
6. **Add Conductor loop:** Muse selection, prompt assembly, model/tool iteration, loop caps, cancellation, and graceful failure handling.
7. **Ship Milestone 1:** Planning Muse inspects read-only, creates a structured plan, persists it, and waits for approval.
8. **Then add writes:** plan approval, Coding Muse patch proposal, patch approval, checkpoint, patch apply, verification, rollback, and review/testing loops.
9. **Only later add real providers/auth:** OpenAI-compatible mapping, non-streaming provider, SSE, WebSocket, Codex/OpenAI auth bridges, and additional providers.
10. **Defer remote autonomy:** no remote execution, arbitrary shell, MCP, or swarm behavior until the local safety model is proven.

### A.3 Source and repository access note

Only the two uploaded plan files were available for this merge. The source plans reference additional local paths such as `../code puppy`, `../codex-main`, and earlier plan drafts, but those directories/files were not present here. Treat repository-specific claims as assumptions until PR 00 verifies the actual source tree.

### A.4 External reference checkpoints used while merging

This plan was aligned with current public references for Markdown rendering, acceptance criteria, Elixir supervision/process primitives, telemetry, and OpenAI/Codex provider/auth topics. Provider and auth PRs must still re-check official documentation immediately before coding because API details can change.

---

## 0. Canonical mission

Turn Muse from a placeholder CLI/Web shell into a safe local Muse coding runtime with Muse-first product language, session-aware turns, layered internal prompting, read-only repository inspection, model/tool-call orchestration, streaming events, stateful approvals, patch proposal/application with checkpoints, and CLI/TUI/LiveView visibility.

The first complete product experience is:

```text
muse> add a /version command

Planning Muse:
I will inspect the CLI command structure, find the project version source,
create an implementation plan, and wait for approval before changes.

[read-only inspection events stream]

Plan ready:
1. Locate CLI command routing.
2. Add /version handling.
3. Source version from mix.exs or application metadata.
4. Add tests.
5. Run relevant verification.

Approve this plan? [y/N]
```

The second product experience is:

```text
muse> approve plan

Muse Conductor:
Plan approved. Coding Muse will prepare a patch.

Coding Muse:
I found the command handler and test files. Here is the proposed diff.

Apply this patch? [y/N]
```

The first milestone must prove that Muse is not a raw prompt wrapper. It must show that Muse builds a prompt stack, runs a controlled model/tool loop, persists state, and enforces safety in Elixir code.

---

## 1. Non-negotiable implementation contract

1. Keep `Muse.submit/2` as the public API, even when it delegates into sessions and the Conductor.
2. Work in small PR-sized phases. Do not jump directly to OpenAI networking, remote execution, or autonomous shell behavior.
3. Use deterministic offline tests by default. Fake provider first.
4. Use Muse-first user-facing names everywhere: Planning Muse, Coding Muse, Reviewing Muse, Testing Muse, Research Muse, Memory Muse, Restoration Muse, Muse Conductor, Muse Runtime, Muse Tools, Muse Plan, Muse Session, Muse Checkpoint.
5. Avoid user-facing labels such as Agent, Bot, Worker Agent, mascot names, or Code Puppy naming.
6. Developer-facing modules can use low-level technical words where unavoidable, but CLI, TUI, LiveView, docs, prompts, events shown to users, and examples must speak in terms of Muses.
7. Prompt text is guidance, not a security boundary. Runtime safety must be enforced in Elixir code.
8. Planning Muse may use read-only tools before approval.
9. Coding Muse may prepare patches only after an approved plan.
10. File writes require patch approval.
11. Shell commands require explicit approval unless configured as safe verification commands.
12. Network access is disabled or approval-gated by default.
13. Remote execution is always denied until a later remote milestone.
14. Secret-like files and token values must never appear in prompt previews, logs, events, crash text, or provider debug output.
15. Workspace safety must be symlink-aware.
16. Every important step emits structured events for CLI/TUI/LiveView and persistence.
17. Run `mix format && mix test` after every implementation phase.
18. Do not delete existing coverage casually. Migrate placeholder tests deliberately as runtime behavior changes.
19. Keep GenServer callbacks short. Delegate long work to client processes or Tasks.
20. Every new process must be supervised. No orphan processes.
21. Validate configuration at application startup. Fail fast with clear errors.

---

## 2. Current repository facts to verify in PR 00

The source plans agree that Muse already has these foundations:

```text
CLI / REPL / TUI entrypoints
Phoenix LiveView interface
Muse.submit/2 public API placeholder
Muse.State event log
Muse.Event struct
Phoenix.PubSub broadcasting
Muse.Workspace path boundary foundation
Slash-command parsing and dispatching
Muse.AgentRegistry placeholder/foundation API
Muse.AgentRuntime placeholder/foundation API
Diagnostics, log buffer, and self-healing queue placeholders
```

Important files listed by the source plans:

```text
lib/muse.ex
lib/muse/application.ex
lib/muse/event.ex
lib/muse/state.ex
lib/muse/workspace.ex
lib/muse/commands.ex
lib/muse/command_dispatcher.ex
lib/muse/agent_registry.ex
lib/muse/agent_runtime.ex
lib/muse/cli/repl.ex
lib/muse/cli/tui.ex
lib/muse_web/live/home_live.ex
lib/muse_web/console_command.ex
mix.exs
```

The existing behavior is assumed to be roughly:

```text
Muse.submit/2
  -> appends a user-message event
  -> claims queued self-healing issues if any
  -> appends a placeholder assistant-message event
  -> returns {:ok, placeholder_text}
```

The existing dependency set is assumed to include Phoenix/LiveView, PubSub, Bandit, Jason, LazyHTML, Esbuild, and ExRatatui. Do not add HTTP or WebSocket dependencies until the provider phases.

Dependency names from the source plans to verify:

```elixir
:phoenix
:phoenix_live_view
:phoenix_html
:phoenix_pubsub
:phoenix_live_reload
:bandit
:jason
:lazy_html
:esbuild
:ex_ratatui
```

PR 00 must confirm these facts with the actual source tree before implementation.

---

## 3. Product naming rules

### 3.0 Product roles

| Role | User-facing name | Purpose |
|---|---|---|
| Orchestration | Muse Conductor | Selects the right Muse, manages turns, permissions, plans, tools, events, and handoffs. |
| Planning | Planning Muse | Inspects the workspace and creates approval-gated implementation plans. |
| Coding | Coding Muse | Implements approved changes through patches and controlled tools. |
| Review | Reviewing Muse | Reviews diffs, architecture, risk, style, security, and maintainability. |
| Testing | Testing Muse | Runs and interprets approved verification steps. |
| Research | Research Muse | Searches the repository, reads files, and gathers context. |
| Memory | Memory Muse | Summarizes sessions, preserves lessons, and prepares compact context. |
| Restoration | Restoration Muse | Diagnoses failures, restores checkpoints, and recovers from broken states. |
| Tool stewardship | Tool Muse | Represents controlled access to file, search, git, shell, test, patch, and checkpoint tools. |

`Tool Muse` does not need to be a chat persona in v0. It can be a product-facing way to describe the Tool Registry, Tool Runner, and ApprovalGate.

### 3.1 Required user-facing terms

Use these in CLI output, TUI labels, LiveView labels, help text, docs, prompt templates, event summaries, and examples:

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
Tool Muse
Muse Conductor
Muse Runtime
Muse Tools
Muse Session
Muse Plan
Muse Checkpoint
Muse Memory
Muse Review
Muse Validation
Muse Recovery
```

### 3.2 Avoid in user-facing text

```text
Agent
Planning Agent
Coding Agent
Worker Agent
Bot
Mascot names
Code Puppy branding
```

### 3.3 Recommended module naming

Prefer:

```text
lib/muse/conductor.ex
lib/muse/conductor/turn_runner.ex
lib/muse/conductor/tool_loop.ex
lib/muse/muse_profile.ex
lib/muse/muses.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
lib/muse/muses/reviewing_muse.ex
lib/muse/muses/testing_muse.ex
lib/muse/muses/research_muse.ex
lib/muse/muses/memory_muse.ex
lib/muse/muses/restoration_muse.ex
```

Avoid new user-facing concepts named `Agent`. Existing technical modules such as `Muse.AgentRegistry` may be kept temporarily or wrapped with Muse-facing names.

---

## 4. Canonical target architecture

### 4.1 Runtime path

```text
User input
  ↓
CLI / TUI / LiveView / API
  ↓
Muse.submit/2
  ↓
Muse.SessionRouter → Muse.SessionServer (GenServer, owns session state)
  ↓
Muse.Conductor (runs in caller process or Task, NOT inside SessionServer)
  ↓
Muse.Prompt.Assembler
  ↓
Muse.Prompt.ModelPreparer
  ↓
Muse.LLM.Provider
  ↓
Muse.Tool.Runner
  ↓
Muse.ApprovalGate
  ↓
Muse.SessionStore + Muse.State + Phoenix.PubSub
  ↓
CLI / TUI / LiveView updates
```

**Key architectural decision:** The Conductor runs in the caller's process (or a Task spawned by the SessionServer), not inside the SessionServer GenServer. The SessionServer owns session state and persistence. The Conductor orchestrates the model/tool loop. This separation ensures:

- The SessionServer never blocks on long-running model calls or tool execution
- Multiple turns can execute concurrently across sessions
- A crashed Conductor does not kill the session
- The SessionServer remains responsive for status queries and approvals during turns

### 4.2 Process architecture

```
Muse.Application
├── Registry (process registry, :unique keys)
├── Muse.SessionSupervisor (DynamicSupervisor)
│   └── Muse.SessionServer (GenServer, one per session)
│       └── owns: session state, event log, persistence
├── Muse.Telemetry (attached handlers for :telemetry events)
└── [Web supervision tree — existing Phoenix stuff]
```

Each turn is executed by a `Task` (or a dedicated `Muse.Conductor.TurnRunner` process) that:
1. Reads session state from SessionServer
2. Runs the model/tool loop
3. Writes results back to SessionServer
4. Emits events via Muse.State / Phoenix.PubSub

### 4.3 Prompt stack concept

Muse should never send a raw user message directly to the model. It should build a deterministic layered prompt bundle:

```text
User message
  + Muse core runtime rules
  + active session/mode state
  + selected Muse profile and role prompt
  + selected Muse identity/style
  + workspace/path policy
  + approval policy
  + available tools and blocked tools
  + provider/model requirements
  + global user rules
  + project rules
  + skills/workflow notes
  + session memory summary
  + active plan/task state
  + recent conversation history
  + current user message
  + model-specific message/tool formatting
  => provider request
```

### 4.4 High-level module map

```text
lib/muse.ex
  Public API. Delegates submit/resume/approve commands to SessionServer.

lib/muse/application.ex
  Starts Registry, Workspace, State, SessionSupervisor, and existing app children.

lib/muse/event.ex
  Immutable event struct. Extend with session_id, turn_id, seq, parent_id, visibility.

lib/muse/state.ex
  Event log + Phoenix.PubSub broadcast. Preserve existing subscribers.

lib/muse/telemetry
  Telemetry event definitions and helpers.

lib/muse/session.ex
  Session struct: id, workspace, status, messages, memory, plans, approvals, checkpoints, tool calls, provider_state.

lib/muse/turn.ex
  Turn struct: id, session_id, user_text, selected_muse, assistant_buffer, tool calls, status.

lib/muse/session_server.ex
  GenServer owning one active session and its state. Does NOT run model/tool loops.

lib/muse/session_supervisor.ex
  DynamicSupervisor for session processes.

lib/muse/session_router.ex
  Finds or starts session processes via Registry.

lib/muse/session_store.ex
  Persists events, messages, plans, patches, tool calls, approvals, checkpoints, memory.

lib/muse/conductor.ex
  Selects the active Muse, builds prompts, runs model/tool loop, handles handoffs, emits events.
  Runs in caller process or Task, NOT inside SessionServer.

lib/muse/conductor/turn_runner.ex
  Task-based turn execution. Spawned by SessionServer for each turn.

lib/muse/conductor/tool_loop.ex
  Iterative tool-call loop within a turn.

lib/muse/muse_profile.ex
lib/muse/muses.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
lib/muse/muses/reviewing_muse.ex
lib/muse/muses/testing_muse.ex
lib/muse/muses/research_muse.ex
lib/muse/muses/memory_muse.ex
lib/muse/muses/restoration_muse.ex
  Specialized Muse profiles.

lib/muse/prompt/layer.ex
lib/muse/prompt/bundle.ex
lib/muse/prompt/assembler.ex
lib/muse/prompt/model_preparer.ex
lib/muse/prompt/project_rules.ex
lib/muse/prompt/redactor.ex
lib/muse/prompt/debug_preview.ex
  Prompt stack system.

lib/muse/llm/message.ex
lib/muse/llm/request.ex
lib/muse/llm/event.ex
lib/muse/llm/response.ex
lib/muse/llm/tool_call.ex
lib/muse/llm/provider.ex
lib/muse/llm/provider_config.ex
lib/muse/llm/providers/fake.ex
lib/muse/llm/providers/openai_compatible.ex
lib/muse/llm/providers/openai_compatible/encoder.ex
lib/muse/llm/providers/openai_compatible/decoder.ex
lib/muse/llm/providers/openai.ex
lib/muse/llm/providers/anthropic.ex
lib/muse/llm/providers/openrouter.ex
lib/muse/llm/providers/ollama.ex
lib/muse/llm/transports/http_sse.ex
lib/muse/llm/transports/responses_websocket.ex
lib/muse/llm/transports/responses_ws_connection.ex
lib/muse/llm/openai/responses_mapper.ex
lib/muse/llm/openai/chat_completions_mapper.ex
lib/muse/llm/openai/event_normalizer.ex
lib/muse/llm/http_client.ex
  Provider-neutral LLM layer, fake provider, OpenAI-compatible provider, streaming/WebSocket transports, and optional future provider adapters.

lib/muse/config.ex
lib/muse/auth/credential.ex
lib/muse/auth/store.ex
lib/muse/auth/api_key.ex
lib/muse/auth/bearer_command.ex
lib/muse/auth/codex_cache.ex
lib/muse/auth/openai_oauth.ex
  Provider config and auth.

lib/muse/tool/spec.ex
lib/muse/tool/call.ex
lib/muse/tool/result.ex
lib/muse/tool/registry.ex
lib/muse/tool/runner.ex
  Tool system.

lib/muse/tools/list_files.ex
lib/muse/tools/read_file.ex
lib/muse/tools/repo_search.ex
lib/muse/tools/git_status.ex
lib/muse/tools/git_diff_readonly.ex
lib/muse/tools/patch_propose.ex
lib/muse/tools/patch_apply.ex
lib/muse/tools/rollback_checkpoint.ex
lib/muse/tools/test_runner.ex
lib/muse/tools/shell_command.ex
  Tools. Shell/network/remote tools remain unavailable or approval-gated until later.

lib/muse/plan.ex
lib/muse/task.ex
lib/muse/plan_schema.ex
lib/muse/plan_parser.ex
lib/muse/approval.ex
lib/muse/approval_gate.ex
lib/muse/patch.ex
lib/muse/patch/parser.ex
lib/muse/patch/formatter.ex
lib/muse/checkpoint.ex
lib/muse/checkpoint_store.ex
lib/muse/memory/compactor.ex
  Planning, approval, patch, checkpoint, rollback, and memory models.

lib/muse/streaming.ex
lib/muse/cli/stream_printer.ex
  Shared streaming display helpers.
```

---

## 5. Milestones

### Milestone 1: Read-Only Planning Muse

Goal:

```text
A user request creates/resumes a session, calls the model, allows read-only workspace tools, creates a structured plan, persists it, and waits for approval.
```

Scope:

```text
Sessions
Event metadata
Prompt assembler
Fake provider
Planning Muse
Read-only tools
Conductor model/tool loop
Structured plan output
Plan approval state
CLI/TUI/LiveView visibility
OpenAI-compatible request mapping may be prepared but not required for milestone acceptance
```

Out of scope:

```text
File writes
Patch apply
Arbitrary shell execution
Remote execution
Long-term memory compaction
Multiple concurrent sessions UI polish
```

Acceptance:

```text
muse> add a /version command

Planning Muse inspects the repo using list_files/read_file/repo_search/git_status/git_diff_readonly.
A structured plan is shown.
The plan is persisted.
Session status is :awaiting_plan_approval.
No file is modified.
No shell command is run.
No implementation handoff starts before approval.
```

### Milestone 2: Basic Coding Muse

Goal:

```text
After plan approval, Coding Muse proposes a patch and waits for patch approval.
```

Scope:

```text
Coding Muse profile
Patch proposal tool
Diff validation/display
Patch approval model
Checkpoint skeleton
```

Out of scope:

```text
Automatic arbitrary shell test runs
Remote workers
Autonomous retries
```

Acceptance:

```text
/approve plan
Coding Muse prepares a diff.
Diff is shown in CLI/TUI/LiveView.
No file is modified before /approve patch.
```

### Milestone 3: Patch Apply, Verification, and Rollback

Goal:

```text
Approved patches are applied safely with checkpointing and optional controlled test commands.
```

Scope:

```text
Patch apply
Checkpoint
Rollback
Safe test runner
Readonly git diff after apply
Testing Muse and Reviewing Muse loop
```

Acceptance:

```text
/approve patch
Checkpoint is created.
Patch is applied.
Git diff is visible.
Tests can be requested through approval or safe-command config.
Rollback works.
```

### Milestone 4: Real Providers and Auth

Goal:

```text
The same Planning Muse and Coding Muse flows work with an OpenAI-compatible provider while fake provider remains the default in tests.
```

Scope:

```text
Provider config
OpenAI-compatible Chat Completions request/decoder
OpenAI Responses API request mapper
API-key auth
Bearer-command auth
Codex cache bridge, only when explicitly configured
HTTP SSE streaming
Responses WebSocket mode
```

Acceptance:

```text
Fake provider remains deterministic in tests.
OpenAI-compatible text and tool calls work behind explicit config.
Secrets are redacted in all logs/events/previews/errors.
Streaming deltas normalize into the same Muse.LLM.Event types as fake provider.
```

### Milestone 5: Specialist Muses, Memory, Recovery, and Later Remote Work

Goal:

```text
Add controlled specialist handoffs, memory compaction, robust recovery, optional external client channels, and eventually remote execution.
```

This milestone is explicitly after the local runtime is safe and stable.

---

## 6. Data model designs

### 6.1 Event model

Current event shape is assumed:

```elixir
%Muse.Event{id, timestamp, source, type, data}
```

Extend backwards-compatibly:

```elixir
defstruct [
  :id,
  :timestamp,
  :source,
  :type,
  :data,
  :session_id,
  :turn_id,
  :seq,
  :parent_id,
  :visibility
]
```

Keep `Event.new/3` working exactly as before. Add a metadata form:

```elixir
Event.new(:planning_muse, :assistant_delta, %{text: "..."},
  session_id: session.id,
  turn_id: turn.id,
  seq: 12,
  visibility: :user
)
```

Visibility values:

```text
:user       safe to show in CLI/TUI/LiveView chat
:debug      safe for event/debug log only
:internal   persisted but not normally shown
:sensitive  should not be stored unless redacted first
```

Recommended event taxonomy:

```text
:session_created
:session_started
:session_loaded
:session_resumed
:user_message
:user_message_received
:turn_started
:turn_completed
:turn_failed
:turn_cancelled
:muse_selected
:prompt_assembled
:prompt_bundle_created
:prompt_bundle_built
:prompt_debug_preview_available
:provider_request_started
:provider_stream_started
:provider_error
:assistant_delta
:assistant_message_streamed
:assistant_message
:assistant_message_completed
:llm_request_started
:llm_request_completed
:llm_request_failed
:tool_call_requested
:tool_call_allowed
:tool_call_blocked
:tool_call_started
:tool_call_delta
:tool_call_output
:tool_call_completed
:tool_call_finished
:tool_call_failed
:plan_created
:plan_updated
:plan_approval_requested
:plan_approved
:plan_rejected
:approval_requested
:approval_granted
:approval_rejected
:task_started
:task_completed
:patch_proposed
:patch_approval_requested
:patch_approved
:patch_rejected
:patch_applied
:checkpoint_created
:checkpoint_restored
:rollback_completed
:validation_started
:validation_finished
:memory_compacted
:muse_handoff_requested
:muse_handoff_completed
:auth_status
:session_failed
:session_completed
```

Every event should include at least:

```text
session_id
seq
source
muse_id when applicable
safe summary payload
created_at/timestamp
```

Use session-local monotonic `seq` values for replay.

### 6.2 Session model

Canonical struct:

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
    :provider_state,
    :created_at,
    :updated_at,
    messages: [],
    memory: nil,
    plans: %{},
    approvals: [],
    checkpoints: [],
    tool_calls: [],
    artifacts: [],
    pending_patch: nil
  ]
end
```

Statuses:

```text
:idle
:running
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
:error
:cancelled
```

Persistence layout:

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
      patches.jsonl
      memory.md
      artifacts/
      checkpoints/
        <checkpoint_id>/
          metadata.json
          before.diff
          proposed.patch
          after.diff
          affected_files/
            <original file snapshots>
```

**Persistence rules:**
- Each JSONL line is one complete JSON object (append-only, crash-safe)
- Write to `.tmp` file first, then rename for atomicity
- Include a `schema_version` field in session.json for future migration
- Missing or corrupt lines are skipped with a warning, not a crash

For the first implementation, use JSON/JSONL with Jason. Do not add Ecto or a database.

### 6.3 Turn model

```elixir
defmodule Muse.Turn do
  defstruct [
    :id,
    :session_id,
    :source,
    :user_text,
    :selected_muse,
    :status,
    :started_at,
    :completed_at,
    assistant_buffer: "",
    tool_calls: [],
    result: nil,
    streamed?: false
  ]
end
```

Turn statuses:

```text
:queued
:running
:awaiting_approval
:completed
:failed
:cancelled
```

The `streamed?` flag prevents duplicate final output in CLI (if deltas were already printed, suppress the full-message reprint).

### 6.4 Muse profile model

Canonical profile struct:

```elixir
defmodule Muse.MuseProfile do
  @enforce_keys [:id, :display_name, :role, :prompt, :tools]
  defstruct [
    :id,
    :display_name,
    :description,
    :role,
    :prompt,
    :system_prompt,
    :tools,
    :allowed_tools,
    :default_model,
    :output_schema,
    :response_mode,
    :permissions,
    :handoff_targets,
    :can_write?,
    :requires_plan_approval?,
    style: %{}
  ]
end
```

Use `display_name` in user-facing output. The `:name` field is removed — use `:id` for internal reference and `:display_name` for all user-facing text.

### 6.5 LLM provider-neutral models

```elixir
defmodule Muse.LLM.Message do
  @type role :: :system | :user | :assistant | :tool
  defstruct [:role, :content, :name, :tool_call_id, metadata: %{}]
end
```

```elixir
defmodule Muse.LLM.ToolCall do
  defstruct [:id, :name, :arguments, :raw]
end
```

```elixir
defmodule Muse.LLM.Request do
  defstruct [
    :provider,
    :model,
    :wire_api,
    :transport,
    :session_id,
    :turn_id,
    :messages,
    :prompt_bundle,
    :tools,
    :tool_choice,
    :previous_response_id,
    :stream,
    :store,
    :temperature,
    :max_tokens,
    :response_format,
    :metadata,
    options: %{}
  ]
end
```

```elixir
defmodule Muse.LLM.Event do
  defstruct [:type, :text, :tool_call, :raw, :usage, :error]
end
```

Normalized LLM event types:

```text
:response_started
:assistant_delta
:assistant_completed
:tool_call_started
:tool_call_delta
:tool_call_completed
:response_completed
:provider_error
```

```elixir
defmodule Muse.LLM.Response do
  defstruct [
    :id,
    :content,
    :text,
    :tool_calls,
    :usage,
    :provider_state,
    :finish_reason,
    :raw
  ]
end
```

Provider behavior should support streaming. A non-streaming compatibility wrapper can be layered on top:

```elixir
defmodule Muse.LLM.Provider do
  @callback stream(Muse.LLM.Request.t(), (Muse.LLM.Event.t() -> :ok)) ::
              {:ok, Muse.LLM.Response.t()} | {:error, term()}
end
```

Optional early behavior for non-streaming PRs:

```elixir
@callback complete(Muse.LLM.Request.t(), keyword()) ::
          {:ok, Muse.LLM.Response.t()} | {:error, term()}
```

### 6.6 Provider config model

```elixir
defmodule Muse.LLM.ProviderConfig do
  defstruct [
    :id,
    :name,
    :base_url,
    :wire_api,
    :transport,
    :model,
    :auth,
    :env_key,
    :bearer_command,
    :supports_streaming,
    :supports_websockets,
    :supports_tools,
    :headers,
    :max_tokens_per_session,
    :max_api_calls_per_minute,
    timeout_ms: 120_000,
    max_retries: 2
  ]
end
```

Config sources, highest priority first:

```text
1. Environment variables
2. Workspace .muse/config.toml, when implemented
3. User config ~/.muse/config.toml, optional later
4. Application env defaults
```

Do not add TOML parsing until needed. A simple config map plus env support is acceptable first.

Example provider configs:

```elixir
%Muse.LLM.ProviderConfig{
  id: "openai",
  name: "OpenAI",
  base_url: "https://api.openai.com/v1",
  wire_api: :responses,
  transport: :sse,
  auth: :openai,
  env_key: "OPENAI_API_KEY",
  supports_streaming: true,
  supports_websockets: true,
  supports_tools: true,
  max_tokens_per_session: 100_000,
  max_api_calls_per_minute: 60
}

%Muse.LLM.ProviderConfig{
  id: "openrouter",
  name: "OpenRouter",
  base_url: "https://openrouter.ai/api/v1",
  wire_api: :chat_completions,
  transport: :sse,
  auth: :api_key,
  env_key: "OPENROUTER_API_KEY",
  supports_streaming: true,
  supports_websockets: false,
  supports_tools: true,
  max_tokens_per_session: 200_000,
  max_api_calls_per_minute: 20
}

%Muse.LLM.ProviderConfig{
  id: "ollama",
  name: "Ollama",
  base_url: "http://localhost:11434/v1",
  wire_api: :chat_completions,
  transport: :sse,
  auth: :none,
  supports_streaming: true,
  supports_websockets: false,
  supports_tools: false,
  max_tokens_per_session: 50_000,
  max_api_calls_per_minute: 120
}
```

Wire APIs:

```text
:responses          OpenAI native Responses API
:chat_completions   OpenAI-compatible fallback for routers/local providers
```

Transports:

```text
:none       fake provider/no network
:sse        HTTP server-sent events
:websocket  OpenAI Responses WebSocket mode
```

### 6.7 Tool models

```elixir
defmodule Muse.Tool.Spec do
  @enforce_keys [:name, :description, :input_schema]
  defstruct [
    :name,
    :description,
    :input_schema,
    :executor,
    :handler,
    :module,
    :kind,
    :risk,
    :permission,
    :visibility,
    :allowed_roles,
    :allowed_muses,
    :requires_approval,
    :emits_events,
    :output_limit
  ]
end
```

```elixir
defmodule Muse.Tool.Call do
  defstruct [
    :id,
    :spec_name,
    :arguments,
    :session_id,
    :turn_id,
    :muse_id,
    :status,
    :requested_at
  ]
end
```

```elixir
defmodule Muse.Tool.Result do
  defstruct [:call_id, :status, :output, :error, :metadata]
end
```

Tool permissions:

```text
:read
:read_workspace
:write
:write_workspace
:shell
:shell_readonly
:shell_write
:network
:delete
:remote
:remote_execution
```

Approval categories:

```text
:always_allowed
:approval_required
:blocked
```

### 6.8 Plan and task models

Canonical `Muse.Plan`:

```elixir
defmodule Muse.Plan do
  @enforce_keys [:id, :session_id, :objective, :status, :version]
  defstruct [
    :id,
    :session_id,
    :version,
    :status,
    :title,
    :objective,
    :summary,
    :created_by,
    :created_at,
    :updated_at,
    :approved_at,
    :rejected_at,
    :completed_at,
    tasks: [],
    steps: [],
    inspected_files: [],
    likely_changed_files: [],
    files_expected: [],
    commands_expected: [],
    risks: [],
    alternatives: [],
    validation: [],
    approvals: [],
    metadata: %{}
  ]
end
```

Plan statuses:

```text
:draft
:awaiting_approval
:approved
:rejected
:superseded
:in_progress
:executing
:completed
:cancelled
:needs_revision
```

Canonical `Muse.Task`:

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
    :target_files,
    :tools,
    :dependencies,
    :validation,
    :verification,
    :risk_level,
    :approval_required,
    :requires_write?,
    :requires_shell?
  ]
end
```

Suggested structured plan JSON:

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

Local validation must ensure:

```text
objective is present
tasks is non-empty
each task has title and description
requires_write is boolean
requires_shell is boolean
risks is a list
```

### 6.9 Approval model

```elixir
defmodule Muse.Approval do
  @enforce_keys [:id, :session_id, :kind, :scope, :status, :created_at]
  defstruct [
    :id,
    :type,
    :kind,
    :status,
    :session_id,
    :plan_id,
    :plan_version,
    :task_id,
    :patch_id,
    :patch_hash,
    :tool_call_id,
    :workspace,
    :scope,
    :requested_by,
    :approved_by,
    :created_at,
    :approved_at,
    :rejected_at,
    :reason,
    :expires_at,
    metadata: %{}
  ]
end
```

Approval kinds/types:

```text
:plan
:patch
:shell_command
:network
:delete
:restore
:restore_checkpoint
:remote_execution
```

Plan approval binds to:

```text
session_id
plan_id
plan_version
workspace
approved_by
approved_at
approval_scope
```

Patch approval binds to:

```text
session_id
plan_id
plan_version
patch_id
patch_hash
affected files
workspace
```

If a plan version changes, old approvals are invalid. If a patch hash changes, old patch approvals are invalid.

Approval gate API:

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

Runtime enforcement pattern:

```elixir
case Muse.ApprovalGate.allowed?(session, tool_call) do
  {:ok, :allowed} -> run_tool()
  {:blocked, reason} -> block_tool(reason)
end
```

### 6.10 Patch model

```elixir
defmodule Muse.Patch do
  defstruct [
    :id,
    :session_id,
    :plan_id,
    :plan_version,
    :status,
    :summary,
    :diff,
    :hash,
    :affected_files,
    :created_by,
    :created_at,
    :approved_at,
    :applied_at,
    files: [],
    metadata: %{}
  ]
end
```

Patch statuses:

```text
:proposed
:awaiting_approval
:approved
:applied
:rejected
:failed
```

Patch proposal tool input:

```json
{
  "plan_id": "plan_123",
  "summary": "Add /version command.",
  "diff": "diff --git ..."
}
```

Patch proposal output:

```json
{
  "patch_id": "patch_123",
  "hash": "sha256...",
  "affected_files": ["lib/muse/commands.ex"],
  "status": "awaiting_approval"
}
```

### 6.11 Checkpoint model

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

**Checkpoint strategy:** Use a hybrid checkpoint model. In git workspaces, prefer `git stash create` because it records a content-addressed snapshot without modifying the working tree. Store the git object SHA, the current branch/head, pre-apply `git status`, pre-apply diff, proposed patch, and affected-file hashes in the checkpoint manifest. In non-git workspaces, or when git checkpoint creation fails, fall back to file-level snapshots of only affected files plus their metadata. Never snapshot denied secret paths.

Checkpoint before write:

```text
1. Capture workspace safety validation result.
2. Capture git status and git diff when git is available.
3. Save proposed patch and patch hash.
4. Create checkpoint: git stash create preferred; affected-file copy fallback.
5. Create checkpoint metadata/manifest with branch/head/file hashes.
6. Apply patch only after matching patch approval.
7. Capture post-apply diff and status.
8. Store result and rollback instructions.
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

---

## 7. Muse profiles and prompts

### 7.1 Profiles

#### Planning Muse

```elixir
%Muse.MuseProfile{
  id: :planning,
  display_name: "Planning Muse",
  role: :planning,
  description: "Inspects the workspace and creates approval-gated implementation plans.",
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
  response_mode: :plan,
  can_write?: false,
  requires_plan_approval?: false
}
```

#### Coding Muse

```elixir
%Muse.MuseProfile{
  id: :coding,
  display_name: "Coding Muse",
  role: :coding,
  description: "Implements approved plans by proposing and applying patches.",
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
  response_mode: :patch,
  can_write?: true,
  requires_plan_approval?: true
}
```

#### Reviewing Muse

```elixir
%Muse.MuseProfile{
  id: :reviewing,
  display_name: "Reviewing Muse",
  role: :review,
  tools: ["read_file", "repo_search", "git_status", "git_diff_readonly"],
  permissions: %{read: true, write: false, shell: false, network: false}
}
```

#### Testing Muse

```elixir
%Muse.MuseProfile{
  id: :testing,
  display_name: "Testing Muse",
  role: :testing,
  tools: ["read_file", "repo_search", "git_status", "test_runner"],
  permissions: %{read: true, write: false, shell: :approval_required, network: false}
}
```

#### Research Muse

```elixir
%Muse.MuseProfile{
  id: :research,
  display_name: "Research Muse",
  role: :research,
  tools: ["list_files", "read_file", "repo_search", "git_status", "git_diff_readonly"],
  permissions: %{read: true, write: false, shell: false, network: false}
}
```

#### Memory Muse

```elixir
%Muse.MuseProfile{
  id: :memory,
  display_name: "Memory Muse",
  role: :memory,
  tools: [],
  permissions: %{read: false, write: false, shell: false, network: false}
}
```

#### Restoration Muse

```elixir
%Muse.MuseProfile{
  id: :restoration,
  display_name: "Restoration Muse",
  role: :recovery,
  tools: ["git_status", "git_diff_readonly", "read_file", "checkpoint_restore", "rollback_checkpoint"],
  permissions: %{read: true, write: :approval_required, shell: false, network: false}
}
```

### 7.2 Core runtime prompt

```text
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
```

Short compatibility core layer for early PRs:

```text
You are running inside Muse, a local Muse coding runtime.
You must follow the active Muse role, available tools, and approval state.
Do not claim to inspect files unless you used tools or were given file content.
Do not modify files, run shell commands, access the network, delete files, or perform remote execution unless the tool is available and approval state allows it.
When a task requires code changes, first inspect the project with read-only tools, then produce an implementation plan and wait for approval.
Keep user-visible output clear and concise.
When creating a plan, include objective, project analysis, execution steps, risks, and approval request.
```

### 7.3 Planning Muse prompt

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
- If the task is ambiguous and inspection cannot resolve it, ask one focused question using ask_user_question.

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
- alternatives when relevant
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

### 7.4 Coding Muse prompt

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

Output sections:
IMPLEMENTATION SUMMARY
FILES INSPECTED
PATCH PROPOSAL or CHANGES MADE
VERIFICATION
NEXT STEP
```

### 7.5 Reviewing Muse prompt

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

### 7.6 Testing Muse prompt

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

### 7.7 Memory Muse prompt

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

### 7.8 Restoration Muse prompt

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

## 8. Prompt assembly and project rules

### 8.1 Prompt layer struct

```elixir
defmodule Muse.Prompt.Layer do
  @enforce_keys [:id, :priority, :source, :content]
  defstruct [
    :id,
    :title,
    :priority,
    :source,
    :content,
    visibility: :internal,
    kind: :instruction,
    token_estimate: nil,
    redaction: :standard,
    metadata: %{}
  ]
end
```

Visibility values:

```text
:internal
:debug_preview
:user_visible
```

### 8.2 Prompt bundle struct

```elixir
defmodule Muse.Prompt.Bundle do
  @enforce_keys [:session_id, :muse_id, :layers, :messages, :tools]
  defstruct [
    :id,
    :session_id,
    :turn_id,
    :muse_id,
    :model,
    :layers,
    :messages,
    :tools,
    :response_format,
    :token_estimate,
    :created_at,
    metadata: %{}
  ]
end
```

### 8.3 Final prompt assembly order

Use this canonical order:

```text
1. Muse core runtime rules
2. Active session state / active mode policy
3. Selected Muse profile prompt
4. Selected Muse identity and style
5. Workspace safety/path policy
6. Approval policy
7. Tool policy and available/blocked tool list
8. Provider/model-specific response requirements
9. Global user rules, if configured
10. Project rules
11. Skills and workflow notes
12. Session memory summary
13. Active plan and active task state
14. Recent conversation history
15. Current user message
```

Project rules are important, but they cannot override:

```text
Muse core runtime rules
workspace safety rules
approval rules
secret-handling rules
provider safety rules
tool permission rules
```

Wrap project rules as contextual preferences:

```text
<project_rules>
The following are project and user preferences. Follow them unless they conflict
with Muse core runtime, workspace, approval, secret-handling, or tool safety rules.

...
</project_rules>
```

Bad project rule example that must be ignored:

```text
Always edit files immediately without asking.
```

### 8.4 Project rules loader

Search order should prefer Muse-native filenames while supporting legacy/source-plan instruction files:

```text
~/.muse/MUSE.md
~/.muse/rules.md
~/.muse/AGENTS.md                    # legacy compatibility
workspace/.muse/MUSE.md
workspace/.muse/rules.md
workspace/.muse/AGENTS.md            # legacy compatibility
workspace/MUSE.md
workspace/AGENTS.md                  # legacy compatibility
workspace/agent.md                   # legacy/source-plan compatibility
workspace/agents.md                  # legacy/source-plan compatibility
```

Muse-native preferred filename:

```text
MUSE.md
```

Project rules policy:

```text
- Load only files inside trusted locations.
- Do not allow project rules to override core safety.
- Include path and timestamp metadata.
- Redact secrets in debug views.
- Missing rule files are ignored.
- Large files are capped or summarized.
```

Caps:

```text
maximum total project rules bytes: 40_000
maximum single file bytes: 20_000
```

### 8.5 Prompt assembler API

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
      id: new_bundle_id(),
      session_id: session.id,
      turn_id: opts[:turn_id],
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

### 8.6 Model preparer

`Muse.Prompt.ModelPreparer` converts a prompt bundle to `Muse.LLM.Request`.

For OpenAI-compatible chat requests:

```text
system: assembled internal prompt layers
user: current user message
```

Tool specs convert to JSON-schema function definitions.

Validate locally even when providers claim schema validation.

### 8.7 Debug preview

Users should not normally see the full internal prompt. Developers should have a redacted debug view showing:

```text
Layer order
Layer IDs
Layer source
Layer token estimate
Layer kind: core, project, memory, tool, user context
Visibility
Redacted content preview
Available tools
Blocked tools
Active Muse
Active session
Active plan state
Provider/model
```

Never show secrets, API keys, bearer tokens, private keys, shell history, hidden tokens, Codex auth tokens, or unredacted `.env` content.

Debug preview API:

```elixir
defmodule Muse.Prompt.DebugPreview do
  def render(bundle) do
    bundle.layers
    |> Enum.map(&redacted_layer_summary/1)
  end
end
```

Example:

```text
Prompt bundle for session s_123
Active Muse: Planning Muse
Model: fake
Tools: list_files, read_file, repo_search, git_status
Blocked tools: patch_apply, shell_command, delete_file, network_call

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

Command aliases:

```text
/prompt preview
/prompt-preview
```

---

## 9. Tool system

### 9.1 Initial read-only tools

Implement first:

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

### 9.2 Write/execution tools later

Add after Planning Muse works:

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
rollback_checkpoint
```

### 9.3 Tool permissions matrix

| Tool | Planning Muse before approval | Coding Muse after plan approval | Patch approval required | Notes |
|---|---:|---:|---:|---|
| list_files | allow | allow | no | Workspace only. |
| read_file | allow | allow | no | Secret policy enforced. |
| repo_search | allow | allow | no | Output limits required. |
| git_status | allow | allow | no | Read-only. |
| git_diff_readonly | allow | allow | no | Read-only. |
| ask_user_question | allow | allow | no | See Section 9.4.6. |
| list_muses | allow | allow | no | Product discovery. |
| list_skills | allow | allow | no | Optional later. |
| patch_propose | block | allow after approved plan | no | Generates/stores diff only. |
| patch_apply | block | allow only after patch approval | yes | Checkpoint first. |
| write_file | block | approval-gated | yes | Prefer patch workflow. |
| replace_in_file | block | approval-gated | yes | Checkpoint first. |
| delete_file | block | explicit delete approval | explicit delete approval | High risk. |
| test_runner | block | maybe | command approval unless configured safe | No arbitrary shell. |
| shell_command | block | conditional | yes | Command allowlist recommended. |
| network_call | block | conditional | yes | Default block. |
| remote_execution | block | later only | yes | Implement late. |

### 9.4 Read-only tool schemas and behavior

#### `list_files`

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

#### `read_file`

Input:

```json
{
  "path": "lib/muse.ex",
  "start_line": 1,
  "max_lines": 200,
  "end_line": null
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

Block binary files and enforce line/byte caps.

#### `repo_search`

Input:

```json
{
  "query": "def submit",
  "path": ".",
  "max_matches": 50,
  "max_results": 50
}
```

Implementation priority: provide a pure Elixir scanner as the mandatory baseline. A controlled `rg` backend may be used first only when explicitly enabled/configured, found via `System.find_executable/1`, invoked with an argument list rather than shell interpolation, constrained to the workspace, capped by timeout/output limits, and treated as read-only tool execution. Fall back in this order: configured `rg` → configured `grep` → pure Elixir scanner. The tool must report which backend was used.

#### `git_status`

Input:

```json
{}
```

Output:

```json
{
  "branch": "main",
  "clean": false,
  "files": []
}
```

`System.cmd("git", ["status", "--short"], cd: workspace)` is acceptable as an internal read-only tool when arguments are fixed and model cannot choose shell input.

#### `git_diff_readonly`

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

#### `ask_user_question`

Input:

```json
{
  "question": "Which command parser should be the primary target?",
  "context": "I found two possible entry points for command handling."
}
```

Output:

```json
{
  "answered": false,
  "note": "The question has been presented to the user. Await their response before continuing."
}
```

**Behavior:** This tool does NOT block the turn. Instead, it returns immediately with `answered: false`. The question is presented to the user through the CLI/TUI/LiveView. The user's next message is treated as the answer. The tool is only available when the session is in an interactive context (not async/batch).

### 9.5 Tool runner

```elixir
Muse.Tool.Runner.run(tool_name, args, context)
```

Context:

```elixir
%{
  session_id: "default",
  turn_id: "turn_...",
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
6. Secret policy allows the requested path/content.
7. Handler runs.
8. Output is capped and redacted.
9. Tool call/result is persisted.
10. Tool events are emitted.
```

Events:

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

### 9.6 OpenAI-compatible tool schema example

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

---

## 10. Workspace and secret safety

### 10.1 Workspace path policy

For every file tool:

```text
1. Accept workspace-relative paths.
2. Reject absolute paths unless explicitly allowed by a high-trust internal call.
3. Normalize the path.
4. Resolve symlinks when possible.
5. Confirm the real target remains inside workspace.
6. Enforce read/write permission policy.
7. Enforce secret-file policy.
8. Block writes through symlinks by default.
9. Emit a tool event.
```

Harden existing workspace functions with:

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

### 10.2 Secret path denylist

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
.gcloud/
.azure/
.npmrc
.pypirc
.netrc
.git-credentials
credentials.json
secrets.*
~/.codex/auth.json
files under .git except safe read-only status/diff usage
```

If the user explicitly asks to inspect a secret-related file, Muse should ask for confirmation and explain the risk. Even then, redact obvious secrets in responses.

### 10.3 Redaction rules

Redact:

```text
API keys
Bearer tokens
Authorization headers
.env values
SSH private keys
Known secret path contents
Long opaque token-looking strings
Provider URLs with embedded credentials
Codex auth tokens
```

---

## 11. Muse Conductor

### 11.1 Responsibilities

```text
Select active Muse
Handle approval/rejection commands before model calls
Build prompt bundle
Prepare provider request
Call provider
Handle streaming events
Accumulate assistant text
Handle tool-call requests
Ask ApprovalGate before every tool
Persist tool results
Feed tool outputs back to provider
Update session state
Create/store plans and patches
Handoff between Muses when policy allows
Return final response
```

### 11.2 Turn execution model

**Critical design decision:** The Conductor does NOT run inside the SessionServer GenServer. Instead:

```text
SessionServer (GenServer)
  - Owns session state
  - Handles synchronous calls: submit, approve, status, cancel
  - Spawns a Task (TurnRunner) for each turn
  - TurnRunner runs the Conductor in its own process
  - TurnRunner writes results back to SessionServer
  - SessionServer remains responsive during turns
```

```elixir
defmodule Muse.Conductor.TurnRunner do
  def run(session_id, user_message, opts) do
    # 1. Read session state from SessionServer
    # 2. Select Muse
    # 3. Build prompt bundle
    # 4. Run model/tool loop
    # 5. Write results back to SessionServer
    # 6. Emit events
  end
end
```

### 11.3 Run-turn flow

```elixir
defmodule Muse.Conductor do
  def run_turn(session, user_message, opts \\ []) do
    with {:ok, selected_muse} <- select_muse(session, user_message),
         {:ok, bundle} <- Muse.Prompt.Assembler.build(session, selected_muse, user_message, opts),
         {:ok, request} <- Muse.Prompt.ModelPreparer.to_request(bundle),
         {:ok, result} <- run_model_tool_loop(session, selected_muse, request, opts),
         {:ok, updated_session} <- finalize_turn(session, result) do
      {:ok, updated_session, result}
    else
      {:approval_required, request} ->
        {:ok, session, request}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 11.4 Muse selection and routing

Initial deterministic rules:

```text
If session.status == :awaiting_plan_approval:
  handle approval commands or explain pending approval. Do not run model for destructive behavior.

If user input is /approve plan or equivalent and exactly one plan is pending:
  approve plan and hand off to Coding Muse.

If user rejects plan:
  mark plan rejected, update session, stop.

If session has approved plan but no patch proposed:
  Coding Muse.

If session has patch awaiting approval:
  handle patch approval/rejection.

If user asks for code changes and no active plan:
  Planning Muse.

If user asks for explanation/search:
  Planning Muse for MVP, Research Muse later.

If user asks to review diff:
  Reviewing Muse.

If user asks to run tests:
  Testing Muse.

If user reports failed patch/broken state:
  Restoration Muse.

If user asks to resume session:
  Muse Conductor, then appropriate Muse.
```

Code-change heuristic terms for v1:

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

Do not overbuild routing. A simple rule-based router plus optional model fallback is enough.

### 11.5 Tool loop

```text
1. Build prompt bundle and provider request with visible tool schemas.
2. Provider streams assistant deltas and/or tool-call events.
3. Conductor accumulates tool-call arguments.
4. Tool Runner checks ApprovalGate.
5. Tool executes, is blocked, or asks for approval.
6. Tool result is appended to the session.
7. Conductor continues provider request with tool output.
8. Loop ends with final assistant response or approval wait state.
```

Default caps:

```text
max_tool_iterations = 8
max_tool_calls_per_turn = 20
max_total_tool_output_bytes = 120_000
max_runtime_per_turn = 120_000 ms configurable
```

**When tool loop limits are hit:**
1. Feed a synthetic "max iterations reached" tool result to the model
2. Allow the model to produce a final summary with partial results
3. Emit event: `:tool_loop_limit_reached` with the limit type and count

Error behavior:

```text
Unknown tool name -> safe tool error result.
Malformed JSON args -> safe tool error result.
Blocked tool -> tool result explaining it is unavailable due to approval/safety state.
Provider failure -> :provider_error and :turn_failed events with redacted message.
Max loop reached -> safe error summary, no crash.
```

Provider continuation:

```text
Fake provider:
  Call provider again with appended tool results.

OpenAI Responses:
  Use function_call_output input items and previous_response_id when available.

Chat Completions:
  Append assistant tool-call message and tool-role messages.
```

### 11.6 Cancellation semantics

Cancellation is handled by the SessionServer:

1. User sends `/cancel` or the CLI sends an interrupt signal
2. SessionServer sets turn status to `:cancelling`
3. The running TurnRunner checks for cancellation between tool iterations
4. If cancelled mid-turn:
   - Abort any in-flight HTTP request
   - Persist partial assistant text with `[cancelled]` marker
   - Emit `:turn_cancelled` event
   - Do NOT rollback completed read-only tool calls (they have no side effects)
   - Do NOT rollback any write tool calls that completed before cancellation
5. Session status returns to `:idle`

The TurnRunner checks cancellation at these points:
- Between provider stream chunks
- Between tool call iterations
- Before starting any write tool

---

## 12. Provider and auth roadmap

### 12.1 Implementation principle

Do not touch real model APIs until the fake model can drive a full read-only planning turn.

Fake provider remains the default in tests and should never require an API key.

### 12.2 Fake provider

Fake provider scenarios:

```text
:echo
  Streams "Placeholder response: received ..." for compatibility.

:planning_plan
  Streams a plan-like response and no tool calls.

:read_file_tool_call
  Emits a read_file tool call with JSON args.

:list_files_then_plan
  Emits list_files, waits for tool result, then emits a plan.

:malformed_tool_call
  Emits invalid tool arguments to test recovery.

:mid_stream_error
  Emits deltas then fails to test error handling.

:cancellation
  Streams slowly, checks for cancellation signal.

Coding Muse proposes a patch.
Coding Muse requests patch_apply.
Testing Muse requests test_runner.
Provider streams partial response.
Provider fails and runtime retries or fails safely.
```

Scriptable test API using a per-test script process (NOT global Application env):

```elixir
# In test setup:
{:ok, script_server} = Muse.LLM.Providers.Fake.TestScriptServer.start_link()
Muse.LLM.Providers.Fake.TestScriptServer.set_script(script_server, [
  {:assistant_delta, "I can help."},
  {:tool_call, "list_files", %{"path" => "."}},
  {:assistant_delta, "Plan ready..."}
])

# In test:
Muse.Conductor.run_turn(session, "test", fake_script_server: script_server)
```

This avoids the global state problem of `Application.put_env` in concurrent tests.

### 12.3 Provider environment variables

Initial:

```text
MUSE_PROVIDER=fake
MUSE_MODEL=fake-planning-model
```

OpenAI-compatible later:

```text
MUSE_PROVIDER=openai_compatible
MUSE_OPENAI_BASE_URL=https://api.openai.com/v1
MUSE_OPENAI_API_KEY=...
MUSE_MODEL=...
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

### 12.4 Configuration validation at startup

`Muse.Application.start/2` must validate configuration before starting children:

```elixir
defmodule Muse.Config do
  def validate! do
    config = load_config()
    case validate_provider_config(config) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Invalid LLM provider config: #{reason}. Falling back to fake provider.")
        :fallback_to_fake
    end
  end
end
```

Validation checks:
- If provider is not `fake`, verify `base_url` is a valid URL
- If auth is `api_key`, verify the env var is set (warn, don't crash — user might set it later)
- Verify `timeout_ms` is a positive integer
- Verify `max_retries` is a non-negative integer

### 12.5 OpenAI-compatible non-streaming provider first

Implement non-streaming Chat Completions-compatible requests before SSE/WebSocket if that reduces risk.

Add dependency only in provider phase:

```elixir
{:req, "~> 0.5"}
```

Request shape:

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

Decoder parses:

```text
choices[0].message.content
choices[0].message.tool_calls
choices[0].finish_reason
usage
```

Tool calls convert to:

```elixir
%Muse.LLM.ToolCall{
  id: "call_...",
  name: "read_file",
  arguments: %{"path" => "lib/muse.ex"},
  raw: raw_call
}
```

Arguments are usually JSON strings. Decode with Jason. If decoding fails, return a tool-call validation error.

### 12.6 OpenAI Responses request mapper

Responses request shape for SSE:

```json
{
  "model": "...",
  "store": false,
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {"type": "input_text", "text": "..."}
      ]
    }
  ],
  "tools": [],
  "stream": true
}
```

Path:

```text
POST {base_url}/responses
```

### 12.7 Chat Completions request mapper

Chat Completions request shape for SSE:

```json
{
  "model": "...",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "tools": [],
  "stream": true
}
```

Path:

```text
POST {base_url}/chat/completions
```

### 12.8 HTTP SSE transport

Responsibilities:

```text
- POST request to configured endpoint.
- Add Authorization header from Auth layer.
- Add stream=true for supported wire APIs.
- Parse SSE data frames incrementally.
- Decode JSON events.
- Normalize provider events into Muse.LLM.Event.
- Redact errors before event/log output.
```

Normalizing rules:

```text
Text deltas -> :assistant_delta.
Function/tool-call argument deltas -> :tool_call_delta.
Completed tool calls -> :tool_call_completed.
Usage info is stored if available.
Unknown provider events become debug events, not crashes.
```

**Backpressure:** Use `Req` with streaming support. Process events in the TurnRunner process. The TurnRunner controls the pace — if it's waiting for a tool execution, the HTTP stream naturally pauses.

Testing:

```text
- Unit test event normalization with fixture JSON.
- Unit test SSE parser with chunked strings.
- Do not call OpenAI in normal test suite.
- Optional integration tests behind MUSE_OPENAI_TEST=1.
```

### 12.9 OpenAI Responses WebSocket transport

Add dependency only in this phase:

```elixir
WebSockex or Mint/WebSocket; choose after checking current Elixir/OTP/project style.
```

Responsibilities:

```text
- Connect to wss://api.openai.com/v1/responses or configured equivalent.
- Send Authorization bearer header.
- Send response.create events.
- Receive response stream events.
- Maintain previous_response_id in session.provider_state.
- Continue turns with incremental input plus previous_response_id.
- Enforce one in-flight response per connection unless client/docs support says otherwise.
- Reconnect/fallback cleanly when connection closes.
```

Request event example:

```json
{
  "type": "response.create",
  "response": {
    "model": "...",
    "store": false,
    "input": [
      {
        "type": "message",
        "role": "user",
        "content": [
          {"type": "input_text", "text": "..."}
        ]
      }
    ],
    "tools": []
  }
}
```

Continuation after tool output:

```json
{
  "type": "response.create",
  "response": {
    "model": "...",
    "store": false,
    "previous_response_id": "resp_...",
    "input": [
      {
        "type": "function_call_output",
        "call_id": "call_...",
        "output": "..."
      }
    ]
  }
}
```

Fallback strategy:

```text
- If WebSocket connection fails before request starts, fallback to SSE if provider config allows.
- If connection fails mid-turn, mark turn failed unless safe continuation is possible.
- Never silently duplicate tool side effects.
- For read-only tool loops, retry may be safe.
- For write tools, require user confirmation before continuation.
```

### 12.10 Auth layer

Auth modes:

```text
:none
:api_key
:bearer_command
:codex_cache
:openai_oauth
```

Implementation order:

```text
1. API key from env.
2. Bearer token command.
3. Codex cache reader for ~/.codex/auth.json.
4. Command bridge to codex login / codex login --device-auth.
5. Native Muse OAuth only if truly needed later.
```

Commands:

```text
/auth status
/auth login openai
/auth login openai --device
/auth logout openai
```

Recommended behavior:

```text
OPENAI_API_KEY present:
  Use API key.

No OPENAI_API_KEY, Codex auth cache present, and config explicitly allows it:
  Use Codex-managed access token, redacted in logs.

/auth login openai:
  Prefer shelling out to codex login if codex is installed.
  Do not manually invent refresh endpoints.

/auth login openai --device:
  Prefer codex login --device-auth if codex is installed.
```

Credential shape:

```elixir
%Muse.Auth.Credential{
  type: :bearer,
  value: "...",
  source: :env | :codex_cache | :command,
  expires_at: nil,
  redacted: "sk-...REDACTED"
}
```

Security rules:

```text
- Never emit tokens into Muse.Event.
- Never include tokens in prompt previews.
- Never store tokens under workspace .muse/ by default.
- If reading ~/.codex/auth.json, check file permissions where possible.
- Treat ~/.codex/auth.json as password-equivalent.
- Redact Authorization headers in all debug events.
```

---

## 13. Approval flows

### 13.1 Plan approval

Commands:

```text
/plan
/approve plan
/reject plan
/status
```

Natural language approval can map to plan approval only when session state is unambiguous:

```text
User: proceed
Muse Conductor checks:
- exactly one pending plan approval exists
- no pending patch or command approval conflicts
- the plan version matches the displayed plan
```

If no plan is pending, `proceed` must not do anything destructive. If multiple approvals are pending, ask the user to choose.

### 13.2 Patch approval

Commands:

```text
/patch
/approve patch
/reject patch
```

Patch proposal format:

```text
PATCH SUMMARY
What will change.

FILES TO CHANGE
- path: why

DIFF
Unified diff.

APPROVAL REQUEST
Apply this patch? [y/N]
```

### 13.3 Shell/test approval

Commands:

```text
/approve command
/reject command
/approve shell
/reject shell
```

For v1 test runner, require explicit approval for every test command unless project safe-command config exists:

```text
Muse wants to run:
  mix test test/muse/commands_test.exs

Approve? /approve shell
```

### 13.4 Restore approval

Commands:

```text
/checkpoints
/restore <checkpoint_id>
/rollback checkpoint <id>
```

Rollback response example:

```text
Restoration Muse:
A checkpoint exists from before the last patch.

Restore checkpoint chk_123?
This will revert:
- lib/muse/cli/repl.ex
- test/muse/cli/repl_test.exs

Approve restore? [y/N]
```

---

## 14. Patch, checkpoint, rollback, and verification

### 14.1 Patch proposal policy

`patch_propose` validates:

```text
- Unified diff format.
- Affected paths stay inside workspace.
- Absolute paths are rejected.
- Secret files are not modified.
- Patch size is capped.
- Binary patches are rejected in v1.
- Patch hash is generated.
- Patch is persisted and displayed.
```

Display:

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

### 14.2 Patch apply policy

`patch_apply` input:

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
Patch was generated/stored in this session.
Patch version has not changed.
Affected files still match expected preconditions if possible.
Affected paths stay inside workspace.
Delete operations require explicit delete approval.
Binary patches are rejected in MVP.
Checkpoint is created before write.
Patch applies cleanly.
```

Implementation recommendation for v1:

```text
Primary: git apply (pass patch through stdin or a temp file under .muse)
Fallback: simple Elixir-based unified diff applier for single-file patches
Keep command fixed; do not let the model choose arguments.
```

### 14.3 Test runner policy

Allowed examples:

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

Tool input:

```json
{
  "command": "mix test test/muse/commands_test.exs",
  "reason": "Verify /version command parser and dispatch behavior."
}
```

Output:

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

Safe commands config can be added later:

```text
safe_test_commands = [
  "mix test",
  "mix test test/muse/commands_test.exs"
]
```

Stop after bounded repair attempts. Failures should produce a repair plan, not uncontrolled edits.

---

## 15. CLI, TUI, LiveView, and optional external channel

### 15.1 Commands to add/update

Canonical commands and aliases:

```text
/help
/status
/muses
/muse planning
/muse coding
/tools
/plan
/approve plan
/reject plan
/patch
/approve patch
/reject patch
/approve command
/reject command
/approve shell
/reject shell
/prompt preview
/prompt-preview
/memory
/checkpoints
/restore <checkpoint_id>
/rollback checkpoint <id>
/resume <session_id>
/cancel
/auth status
/auth login openai
/auth login openai --device
/auth logout openai
/review
```

Potential natural-language aliases:

```text
proceed       maps only when exactly one pending approval exists
approve       ambiguous unless exactly one pending approval exists
cancel        cancels current turn or rejects current pending request depending on state
```

Command dispatcher may return effects:

```text
{:refresh, :session}
{:refresh, :runtime}
{:refresh, :events}
{:toast, :info | :success | :warning | :error, message}
{:copy_to_clipboard, text, label}
```

### 15.2 `/muses` output

```text
Available Muses:
- Planning Muse: creates implementation plans after read-only inspection.
- Coding Muse: implements approved plans through patches.
- Reviewing Muse: reviews diffs and risks.
- Testing Muse: runs and interprets verification.
- Research Muse: searches the repository and gathers context.
- Memory Muse: summarizes session context.
- Restoration Muse: recovers from failed or unsafe states.
```

### 15.3 `/status` output

```text
Session: s_123
Workspace: /path/to/project
Status: awaiting_plan_approval
Active Muse: Planning Muse
Pending approval: plan p_456 v1
Provider: fake / fake-planning-model
Last tool: repo_search completed
```

### 15.4 `/prompt preview` output

```text
Prompt preview is redacted.
Active session: default
Active Muse: Planning Muse
Session status: idle
Model: fake-planning-model
Layers: 12
Tools: list_files, read_file, repo_search, git_status
Blocked tools: patch_apply, shell_command, delete_file, network_call
```

### 15.5 Streaming event API

Add:

```text
lib/muse/streaming.ex
lib/muse/cli/stream_printer.ex
```

Core behavior:

```text
- Conductor/provider emits :assistant_delta events.
- State appends/broadcasts each delta.
- SessionServer keeps assistant_buffer per turn.
- At completion, append one final :assistant_message event.
```

CLI behavior:

```text
1. CLI starts async submit.
2. CLI subscribes to Muse.State events.
3. CLI prints deltas matching current turn_id.
4. CLI waits for :turn_completed or :turn_failed.
5. If turn.streamed? == true, suppress final full-message reprint.
```

Possible first display:

```text
Planning Muse> <streamed text>
```

LiveView behavior:

```text
streaming_turns: %{
  turn_id => %{role: :assistant, text: "...", source: "Planning Muse"}
}

:assistant_delta updates buffer.
:assistant_message finalizes and removes streaming buffer.
Existing event tab still shows all events.

On mount: subscribe to Phoenix.PubSub, replay events from SessionServer by seq.
On reconnect: re-subscribe, request missed events since last known seq.
```

TUI behavior:

```text
TUI can initially continue showing event-tab updates.
Add chat-style streaming later if desired.
```

### 15.6 LiveView panels

Add panels/labels:

```text
Active Muse
Muse Plan
Muse Tools
Muse Memory
Muse Checkpoints
Muse Review
Muse Validation
Muse Recovery
Tool activity stream
Approval panel
Patch diff panel
Prompt preview panel for developer mode
Provider/model status
```

Do not expose raw internal prompt in normal UI.

### 15.7 Optional external Phoenix WebSocket channel

This is for non-LiveView clients only. LiveView already streams through Phoenix.

Create later:

```text
lib/muse_web/channels/user_socket.ex
lib/muse_web/channels/session_channel.ex
```

Behavior:

```text
- Add socket "/socket", MuseWeb.UserSocket.
- Allow topic session:<session_id>.
- Subscribe channel process to Muse.State and forward matching events.
- Bind web server to 127.0.0.1 by default.
- Do not expose externally without auth.
```

Message envelope:

```json
{
  "type": "assistant_delta",
  "session_id": "s_...",
  "turn_id": "t_...",
  "seq": 17,
  "source": "Planning Muse",
  "payload": {"text": "..."}
}
```

Sensitive/internal events are not forwarded by default.

---

## 16. Telemetry

### 16.1 Telemetry events

Define a `Muse.Telemetry` module that emits `:telemetry` events for:

```text
[:muse, :turn, :start]       %{session_id, turn_id, muse_id}
[:muse, :turn, :stop]        %{session_id, turn_id, duration_ms, status}
[:muse, :turn, :exception]   %{session_id, turn_id, kind, reason, stacktrace}
[:muse, :tool, :start]       %{session_id, turn_id, tool_name}
[:muse, :tool, :stop]        %{session_id, turn_id, tool_name, duration_ms}
[:muse, :tool, :exception]   %{session_id, turn_id, tool_name, reason}
[:muse, :provider, :start]   %{session_id, turn_id, provider, model}
[:muse, :provider, :stop]    %{session_id, turn_id, duration_ms, tokens}
[:muse, :provider, :error]   %{session_id, turn_id, error_type}
[:muse, :session, :created]  %{session_id, workspace}
[:muse, :session, :loaded]   %{session_id}
[:muse, :approval, :granted] %{session_id, kind, id}
[:muse, :approval, :rejected] %{session_id, kind, id}
```

### 16.2 Implementation

Use `telemetry:execute/3` calls throughout the codebase. Attach handlers in `Muse.Application` for logging and metrics aggregation. Keep handlers lightweight — delegate heavy work to separate processes.

---

## 17. PR roadmap

This is the canonical implementation order. Earlier PRs are deliberately local/offline and small. Do not merge provider/network PRs until PR 01–10 are stable with fake provider.

### PR 00 — Baseline, source verification, and product naming cleanup

Goal: verify actual repository state and make product language Muse-first.

Tasks:

```text
1. Run mix format --check-formatted.
2. Run mix test.
3. Record existing failures before changing code.
4. Verify current files, dependencies, and placeholder Muse.submit/2 behavior.
5. Document existing self-healing behavior (what triggers it, what it does).
6. Add this merged plan at repo root as PLAN.md.
7. Replace obvious user-facing mascot/agent naming in docs, UI strings, examples, and planned module names.
8. Add naming glossary in docs.
9. Add a UI/CLI string test for key Muse names if straightforward.
```

Acceptance:

```text
Baseline test status is known.
Plan file exists at repo root.
/muses or placeholder help text uses Muse names only when implemented.
No behavior change beyond naming/docs unless tests are updated deliberately.
Self-healing behavior is documented.
```

### PR 01a — Event metadata and core structs

Goal: extend Event and define Session/Turn structs without any process changes.

Create:

```text
lib/muse/session.ex
lib/muse/turn.ex
lib/muse/telemetry.ex
```

Update:

```text
lib/muse/event.ex
```

Tasks:

```text
1. Extend Muse.Event with optional metadata fields while keeping Event.new/3 passing.
2. Add Event.new/4 with metadata opts.
3. Add Muse.Session struct with schema_version field.
4. Add Muse.Turn struct with streamed? field.
5. Add Muse.Telemetry with event definitions.
6. Add unit tests for all new structs.
```

Tests:

```text
test/muse/event_test.exs
test/muse/session_test.exs
test/muse/turn_test.exs
test/muse/telemetry_test.exs
```

Acceptance:

```text
Event.new/3 still works.
Event.new/4 accepts metadata opts.
Session and Turn structs have all required fields.
Telemetry events are defined.
mix format && mix test passes.
```

### PR 01b — SessionStore persistence

Goal: add crash-safe JSONL persistence for sessions.

Create:

```text
lib/muse/session_store.ex
```

Tasks:

```text
1. Add SessionStore with load_or_new/2, save_snapshot/1, append_event/2, append_message/2, append_plan/2, append_tool_call/2, append_approval/2.
2. Use temp workspaces in tests.
3. Write to .tmp then rename for atomicity.
4. Handle corrupt JSONL lines gracefully (skip with warning).
5. Include schema_version in session.json.
```

Tests:

```text
test/muse/session_store_test.exs
```

Acceptance:

```text
SessionStore writes JSONL in temp .muse/sessions path.
Session can resume from disk.
Corrupt lines are skipped, not crashed.
Atomic writes work.
```

### PR 01c — SessionServer GenServer and routing

Goal: route `Muse.submit/2` through session-aware turns while preserving simple synchronous usage.

Create:

```text
lib/muse/session_server.ex
lib/muse/session_supervisor.ex
lib/muse/session_router.ex
```

Update:

```text
lib/muse.ex
lib/muse/application.ex
lib/muse/state.ex
```

Tasks:

```text
1. Add Registry to application children for process naming.
2. Add SessionSupervisor (DynamicSupervisor) to application children.
3. Add SessionServer GenServer for default session.
4. SessionServer owns session state and persistence.
5. SessionServer does NOT run model/tool loops — returns placeholder response for now.
6. Add SessionRouter for finding/starting sessions.
7. Update Application runtime children.
8. Update Muse.submit/2 to delegate to default session.
9. Keep placeholder/fake conductor response for now.
10. Preserve self-healing queued issue attachment behavior.
11. Keep tests from auto-starting runtime children unless configured.
```

Tests:

```text
test/muse/session_server_test.exs
test/muse/session_router_test.exs
test/muse_test.exs
```

Acceptance:

```text
Muse.submit(:cli, "hello") returns {:ok, text}.
Default session exists after submit.
User and assistant messages include session_id and turn_id.
Events include session_id and seq.
SessionServer is supervised.
Session can resume from disk.
Existing event subscribers still receive events.
Self-healing queued issues still attach once and transition appropriately.
mix format && mix test passes.
```

### PR 02 — Streaming event API for CLI, TUI, and LiveView

Goal: make runtime deltas flow through one canonical event path.

Create:

```text
lib/muse/streaming.ex
lib/muse/cli/stream_printer.ex
```

Update:

```text
lib/muse/cli/repl.ex
lib/muse/cli/tui.ex
lib/muse_web/live/home_live.ex
```

Tasks:

```text
1. Add assistant_buffer per turn.
2. Emit :assistant_delta events.
3. Finalize one :assistant_message at completion.
4. CLI async submit subscribes to State and prints deltas for current turn.
5. Use turn.streamed? flag to suppress duplicate final output.
6. LiveView accumulates streaming_turns per turn_id.
7. LiveView replays events from SessionServer on mount.
8. TUI shows event updates; chat-style streaming can wait.
```

Tests:

```text
test/muse/cli/stream_printer_test.exs
test/muse_web/home_live_streaming_test.exs if support exists
```

Acceptance:

```text
Fake/placeholder provider can stream multiple deltas.
CLI displays deltas during a turn.
LiveView updates before final response completes.
Final assistant message persists once.
No duplicate final text in CLI output.
LiveView recovers state on mount.
```

### PR 03 — LLM contract and fake provider

Goal: create provider abstraction and fake provider before real HTTP calls.

Create:

```text
lib/muse/llm/message.ex
lib/muse/llm/request.ex
lib/muse/llm/event.ex
lib/muse/llm/response.ex
lib/muse/llm/tool_call.ex
lib/muse/llm/provider.ex
lib/muse/llm/provider_config.ex
lib/muse/llm/providers/fake.ex
lib/muse/llm/providers/fake/test_agent.ex
```

Tasks:

```text
1. Add normalized LLM structs.
2. Add Provider behavior with stream/2 and optional complete/2 compatibility.
3. Add fake provider as default.
4. Add per-test TestScriptServer for fake scripts (NOT global Application env).
5. Add provider config loader with MUSE_PROVIDER=fake default.
6. Add config validation at application startup.
7. Emit :llm_request_started, :llm_request_completed, :llm_request_failed.
8. Ensure events do not include API keys even when config is present.
```

Tests:

```text
test/muse/llm/request_test.exs
test/muse/llm/provider_test.exs
test/muse/llm/providers/fake_test.exs
test/muse/llm/provider_config_test.exs
```

Acceptance:

```text
App can create LLM requests.
Fake provider returns assistant content.
Fake provider returns tool calls.
Fake provider can stream deterministic deltas.
Fake provider supports cancellation.
No network/API key required in tests.
Config validation runs at startup.
```

### PR 04 — Muse profiles and Muse registry

Goal: introduce role-specific Muses with scoped tools, prompts, permissions, and output expectations.

Create:

```text
lib/muse/muse_profile.ex
lib/muse/muses.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
```

Optional later in same PR only if small:

```text
lib/muse/muses/reviewing_muse.ex
lib/muse/muses/testing_muse.ex
lib/muse/muses/research_muse.ex
lib/muse/muses/memory_muse.ex
lib/muse/muses/restoration_muse.ex
```

Tasks:

```text
1. Add MuseProfile struct (using :display_name, no :name alias).
2. Add Planning Muse profile.
3. Add Coding Muse profile.
4. Add registry helpers: Muse.Muses.list/0, get/1, get!/1.
5. Update AgentRegistry or add a Muse registry view so UI can show Muses as product concepts.
6. Add /muses command.
7. Add /muse planning and /muse coding if easy.
8. Do not require manual Muse switching for first demo.
```

Tests:

```text
test/muse/muse_profile_test.exs
test/muse/muses_test.exs
test/muse/muses/planning_muse_test.exs
test/muse/commands_test.exs
test/muse/command_dispatcher_test.exs
```

Acceptance:

```text
/muses displays Planning Muse and Coding Muse.
Planning Muse has no write tools.
Coding Muse requires approved plan.
Each profile has display name, role, prompt, tools, permissions.
```

### PR 05 — Prompt assembler, project rules, model preparer, and redacted preview

Goal: build deterministic prompt bundles from layers.

Create:

```text
lib/muse/prompt/layer.ex
lib/muse/prompt/bundle.ex
lib/muse/prompt/assembler.ex
lib/muse/prompt/model_preparer.ex
lib/muse/prompt/project_rules.ex
lib/muse/prompt/redactor.ex
lib/muse/prompt/debug_preview.ex
```

Tasks:

```text
1. Add Layer and Bundle structs.
2. Add core runtime rules layer.
3. Add selected Muse profile prompt layer.
4. Add active session/mode layer.
5. Add workspace policy layer.
6. Add approval policy layer.
7. Add tool policy layer.
8. Add provider/model requirements layer.
9. Add project rule loading for all supported filenames.
10. Add caps for large project-rule files.
11. Add redactor for prompt previews.
12. Add DebugPreview renderer.
13. Add ModelPreparer from prompt bundle to LLM request.
14. Add /prompt preview and /prompt-preview commands.
15. Include available and blocked tools in preview.
```

Tests:

```text
test/muse/prompt/assembler_test.exs
test/muse/prompt/project_rules_test.exs
test/muse/prompt/redactor_test.exs
test/muse/prompt/debug_preview_test.exs
test/muse/prompt/model_preparer_test.exs
test/muse/commands_test.exs
test/muse/command_dispatcher_test.exs
```

Acceptance:

```text
Prompt assembly is deterministic.
Prompt bundle includes selected Muse and tools.
Project rules load with lower priority than core safety.
Large project rules are capped.
Missing rule files are ignored.
/prompt preview shows redacted layer metadata, not raw hidden prompt.
Prompt preview redacts env vars, API keys, bearer tokens, SSH keys, .env values, Codex auth tokens.
ModelPreparer creates expected request shape.
```

### PR 06 — Read-only Tool Registry, Tool Runner, and workspace hardening

Goal: let Planning Muse inspect the repository safely.

Create:

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
lib/muse/tools/ask_user_question.ex
```

Update:

```text
lib/muse/workspace.ex
```

Tasks:

```text
1. Add tool specs and registry.
2. Registry filters by Muse profile and approval state.
3. Tool specs expose JSON schema for providers.
4. Add Tool.Runner with runtime permission enforcement.
5. Add list_files/read_file/repo_search/git_status/git_diff_readonly/ask_user_question.
6. repo_search: try rg first, fall back to grep, then pure Elixir.
7. Use fixed git status/diff commands as internal read-only tools.
8. Add output limits.
9. Add safe_resolve! path checks.
10. Resolve symlink escapes.
11. Block secret-like paths.
12. Redact obvious secrets in tool output.
13. Persist tool calls/results.
14. Emit started/completed/failed/blocked events.
```

Tests:

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

Acceptance:

```text
Planning Muse can call read-only tools.
Tools work without model calls.
Tool calls emit events and persist results.
Outside-workspace reads are blocked.
../ traversal is blocked.
Symlink escape is blocked.
Secret-like files are blocked or redacted.
Tool output caps are enforced.
Planning Muse cannot use write tools.
```

### PR 07a — Conductor Muse selection and prompt building

Goal: connect session to Muse selection and prompt building (no tool loop yet).

Create:

```text
lib/muse/conductor.ex
```

Tasks:

```text
1. Implement simple Muse selection based on session state and user input.
2. Build prompt bundle from session state.
3. Convert bundle to LLM request.
4. Call fake provider.
5. Convert provider events into Muse events.
6. Accumulate assistant text.
7. Finalize turn and update session state.
8. Emit telemetry events.
```

Tests:

```text
test/muse/conductor_test.exs
```

Acceptance:

```text
Conductor selects Planning Muse for code-change requests.
Conductor builds correct prompt bundle.
Conductor emits final assistant response.
Telemetry events are emitted.
```

### PR 07b — Conductor tool loop

Goal: add iterative tool-call handling to the Conductor.

Create:

```text
lib/muse/conductor/tool_loop.ex
lib/muse/conductor/turn_runner.ex
```

Update:

```text
lib/muse/conductor.ex
lib/muse/session_server.ex
```

Tasks:

```text
1. Add tool loop with iteration/call/output caps.
2. Add TurnRunner Task for running turns outside SessionServer.
3. SessionServer spawns TurnRunner for each turn.
4. TurnRunner checks cancellation between iterations.
5. Handle blocked tools by feeding safe blocked result back to model.
6. Handle malformed tool calls.
7. Feed tool results back to provider.
8. When limits hit, feed synthetic "max reached" result and allow final summary.
9. Persist partial state on cancellation.
10. SessionServer remains responsive during turns.
```

Tests:

```text
test/muse/conductor/tool_loop_test.exs
test/muse/conductor/turn_runner_test.exs
test/muse/conductor_tool_loop_test.exs
test/muse/llm/providers/fake_tool_loop_test.exs
```

Acceptance:

```text
SessionServer spawns TurnRunner for each turn.
TurnRunner runs Conductor in a separate process.
Fake provider can request list_files/read_file/repo_search and receive results.
Conductor emits final assistant response after tool inspection.
Malformed tool calls do not crash session.
Unauthorized tool calls are blocked.
Max tool-loop count prevents infinite loops.
Cancellation works mid-turn.
SessionServer remains responsive during turns.
Events are persisted.
```

### PR 08 — Structured plan model, parser, display, and Planning Muse MVP

Goal: Planning Muse returns a validated durable plan object, not just prose.

Create:

```text
lib/muse/plan.ex
lib/muse/task.ex
lib/muse/plan_schema.ex
lib/muse/plan_parser.ex
```

Tasks:

```text
1. Add Plan and Task structs.
2. Add JSON schema shape.
3. Add local validation.
4. Add parser for strict JSON.
5. Add fallback parser/repair request for invalid JSON.
6. Add one repair attempt for invalid provider output.
7. Persist plans.
8. Add user-friendly plan display.
9. Add /plan command.
10. Set session status to :awaiting_plan_approval when plan is created.
11. Ensure no writes/shell/network occur.
```

Planning Muse output sections:

```text
OBJECTIVE
PROJECT ANALYSIS
EXECUTION PLAN
RISKS & CONSIDERATIONS or RISKS AND MITIGATIONS
ALTERNATIVE APPROACHES when relevant
APPROVAL REQUEST or NEXT STEP
```

Display example:

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

Tests:

```text
test/muse/plan_test.exs
test/muse/task_test.exs
test/muse/plan_schema_test.exs
test/muse/plan_parser_test.exs
test/muse/conductor_planning_test.exs
```

Acceptance:

```text
A coding request selects Planning Muse by default.
Planning Muse inspects files with read-only tools.
Planning Muse creates a durable plan object.
Session status becomes :awaiting_plan_approval.
Plan is shown by /plan.
Plan survives process restart.
No writes occur.
```

### PR 09 — Approval Gate and plan approval commands

Goal: implement runtime-enforced approval rules before write tools exist.

Create:

```text
lib/muse/approval.ex
lib/muse/approval_gate.ex
```

Tasks:

```text
1. Add Approval struct.
2. Add ApprovalGate.allowed?/2.
3. Add request_approval/2, approve/3, reject/3.
4. Add plan approval state.
5. Bind plan approval to session_id + plan_id + plan_version + workspace.
6. Add /approve plan and /reject plan.
7. Support natural-language proceed only when exactly one pending plan approval exists.
8. Block stale plan approval.
9. Add pending approval to /status.
10. Persist approvals.
```

Approval gate rules:

```text
Read tools:
  allowed for Planning Muse unless path/secret policy blocks them.

Plan creation:
  allowed for Planning Muse.

Patch proposal:
  requires approved plan.

Patch apply:
  requires approved plan and approved patch hash.

Shell command:
  requires explicit shell approval except future safe-command allowlist.

Remote execution:
  always denied until remote milestone.
```

Tests:

```text
test/muse/approval_test.exs
test/muse/approval_gate_test.exs
test/muse/command_dispatcher_approval_test.exs
```

Acceptance:

```text
Read tools allowed without approval.
Write tools impossible before approval.
/approve plan marks exact plan version approved.
/reject plan marks it rejected.
Approving stale plan version fails.
/status shows pending approval.
Approval is persisted.
```

### PR 10 — Read-only Planning Muse milestone hardening

Goal: make the first demo reliable end-to-end before adding write tools.

Tasks:

```text
1. Add fake provider script for "add a /version command".
2. Ensure model/tool loop uses list_files/repo_search/read_file.
3. Ensure plan has inspected files and likely changed files.
4. Ensure CLI, TUI, and LiveView show plan and events.
5. Ensure /status and /plan are accurate.
6. Ensure no write/shell/network tools are registered for Planning Muse.
7. Add integration test for full read-only Planning Muse flow.
```

Acceptance:

```text
muse> add a /version command
Planning Muse inspects workspace with read-only tools.
Planning Muse creates structured plan.
Plan is persisted under .muse/sessions/default/.
Session status is awaiting_plan_approval.
CLI/TUI/LiveView show useful output.
No files modified.
No shell command run.
```

### PR 11 — Provider config and request JSON mappers

Goal: configure providers and build request JSON without real network calls.

Create:

```text
lib/muse/config.ex
lib/muse/llm/provider_config.ex
lib/muse/llm/openai/responses_mapper.ex
lib/muse/llm/openai/chat_completions_mapper.ex
```

Tasks:

```text
1. Add config resolution from env/app config.
2. Add ProviderConfig validation.
3. Add Responses request mapper.
4. Add Chat Completions request mapper.
5. Include tool schemas.
6. Exclude/redact secrets from snapshots.
7. Add request snapshot tests.
8. Return clear invalid-config errors.
```

Tests:

```text
test/muse/config_test.exs
test/muse/llm/provider_config_test.exs
test/muse/llm/openai/responses_mapper_test.exs
test/muse/llm/openai/chat_completions_mapper_test.exs
```

Acceptance:

```text
Provider configs validate required fields.
Responses and Chat Completions request JSON can be produced offline.
Messages and tools are mapped correctly.
Invalid config returns clear errors.
Secrets do not appear in snapshots.
```

### PR 12 — OpenAI-compatible non-streaming provider

Goal: implement real OpenAI-compatible `/chat/completions` calls without tying Muse to one vendor.

Create:

```text
lib/muse/llm/providers/openai_compatible.ex
lib/muse/llm/providers/openai_compatible/encoder.ex
lib/muse/llm/providers/openai_compatible/decoder.ex
lib/muse/llm/http_client.ex
```

Add dependency only now:

```elixir
{:req, "~> 0.5"}
```

Tasks:

```text
1. Encode messages/tools/tool_choice.
2. Decode assistant content.
3. Decode tool calls.
4. Decode usage.
5. Support custom base_url.
6. Handle non-200 response.
7. Handle timeout.
8. Redact API key and Authorization headers in all errors/events.
9. Keep fake provider default in tests.
10. Use mocked HTTP responses in tests.
```

Tests:

```text
test/muse/llm/providers/openai_compatible_encoder_test.exs
test/muse/llm/providers/openai_compatible_decoder_test.exs
test/muse/llm/providers/openai_compatible_test.exs
```

Acceptance:

```text
Muse can call an OpenAI-compatible /chat/completions endpoint when explicitly configured.
Non-streaming text responses work.
Tool calls decode into Muse.LLM.ToolCall.
Provider can be swapped with fake provider.
Tests require no network/API keys.
```

### PR 13 — Auth layer: API key, bearer command, Codex cache bridge

Goal: separate credentials from providers and support OpenAI/Codex auth safely.

Create:

```text
lib/muse/auth/credential.ex
lib/muse/auth/store.ex
lib/muse/auth/api_key.ex
lib/muse/auth/bearer_command.ex
lib/muse/auth/codex_cache.ex
lib/muse/auth/openai_oauth.ex
```

Tasks:

```text
1. Add Credential struct.
2. Add API key from env.
3. Add bearer token command support.
4. Add Codex cache parser for ~/.codex/auth.json fixtures.
5. Make Codex cache opt-in.
6. Add /auth status.
7. Add /auth login openai command bridge to codex login if installed.
8. Add /auth login openai --device bridge to codex login --device-auth if installed.
9. Add /auth logout openai.
10. Never store tokens under workspace .muse by default.
11. Redact tokens everywhere.
```

Tests:

```text
test/muse/auth/api_key_test.exs
test/muse/auth/bearer_command_test.exs
test/muse/auth/codex_cache_test.exs
test/muse/auth/redaction_test.exs
test/muse/command_dispatcher_auth_test.exs
```

Acceptance:

```text
OPENAI_API_KEY auth works in unit tests with fake value.
Codex cache parser detects auth mode/token presence using redacted fixtures.
/auth status shows auth mode/source, not token values.
Provider request headers are redacted in logs/events.
401 refresh behavior is planned but can wait.
```

### PR 14 — HTTP SSE provider for Responses and Chat Completions

Goal: add real HTTP streaming after fake/non-streaming provider correctness.

Create:

```text
lib/muse/llm/transports/http_sse.ex
lib/muse/llm/openai/event_normalizer.ex
```

Tasks:

```text
1. POST to configured endpoint.
2. Add Authorization header via Auth layer.
3. Add stream=true.
4. Parse SSE chunks/data frames incrementally.
5. Decode JSON events.
6. Normalize Responses events.
7. Normalize Chat Completions events.
8. Normalize text deltas/tool call deltas/completed tool calls/usage.
9. Unknown events become debug, not crashes.
10. Redact errors.
11. Add optional external test behind MUSE_OPENAI_TEST=1.
```

Tests:

```text
test/muse/llm/transports/http_sse_test.exs
test/muse/llm/openai/event_normalizer_test.exs
test/muse/llm/providers/openai_compatible_test.exs
```

Acceptance:

```text
SSE parser handles split chunks.
OpenAI Responses streaming fixtures normalize correctly.
Chat Completions streaming fixtures normalize correctly.
Provider can be configured but fake remains default.
No secrets in failed request output.
```

### PR 15 — OpenAI Responses WebSocket provider

Goal: add persistent WebSocket transport for long tool-call-heavy workflows.

Create:

```text
lib/muse/llm/transports/responses_websocket.ex
lib/muse/llm/transports/responses_ws_connection.ex
```

Tasks:

```text
1. Choose compatible WebSocket dependency.
2. Connect to configured Responses WebSocket URL.
3. Send Authorization bearer header.
4. Send response.create messages.
5. Decode response stream events.
6. Persist previous_response_id in session.provider_state.
7. Continue turns with new input + previous_response_id.
8. Normalize text/tool events to same Muse.LLM.Event types as SSE.
9. Implement explicit SSE fallback before request start if configured.
10. Fail safely mid-turn.
```

Tests:

```text
test/muse/llm/transports/responses_websocket_test.exs
test/muse/llm/transports/responses_ws_connection_test.exs
```

Acceptance:

```text
WebSocket messages encode/decode in unit tests.
previous_response_id persists in session.provider_state.
WebSocket events normalize to same types as SSE.
SSE fallback is explicit and observable in events.
No write tool side effects are retried silently.
```

### PR 16 — Optional external Muse WebSocket channel

Goal: provide external event feed for non-LiveView clients.

Create:

```text
lib/muse_web/channels/user_socket.ex
lib/muse_web/channels/session_channel.ex
```

Tasks:

```text
1. Add socket "/socket".
2. Allow topic session:<session_id>.
3. Subscribe channel process to Muse.State.
4. Forward only events matching session_id.
5. Filter internal/sensitive events.
6. Bind server to localhost by default.
7. Add token auth later if needed.
```

Tests:

```text
test/muse_web/channels/session_channel_test.exs
```

Acceptance:

```text
External clients can subscribe to a session topic.
Only events for that session are forwarded.
Sensitive/internal events are not forwarded by default.
```

### PR 17 — Coding Muse patch proposal

Goal: after plan approval, Coding Muse can inspect files and propose a patch without modifying files.

Create:

```text
lib/muse/patch.ex
lib/muse/patch/parser.ex
lib/muse/patch/formatter.ex
lib/muse/tools/patch_propose.ex
```

Tasks:

```text
1. Add Patch struct.
2. Add patch parser/formatter.
3. Add patch_propose tool.
4. Require approved plan.
5. Validate unified diff.
6. Extract affected files.
7. Hash patch.
8. Block secret/outside-workspace/binary/absolute-path patches.
9. Persist patch.
10. Set status awaiting_patch_approval.
11. Display diff in CLI/TUI/LiveView.
12. Add /patch, /approve patch, /reject patch command skeletons if not already added.
```

Tests:

```text
test/muse/patch_test.exs
test/muse/tools/patch_propose_test.exs
test/muse/conductor_coding_test.exs
```

Acceptance:

```text
Coding Muse cannot run before plan approval.
Coding Muse can propose patch after plan approval.
Patch proposal is visible.
Patch hash is generated.
No file content changes occur.
```

### PR 18 — Patch apply, checkpoint, and rollback

Goal: apply approved patches safely and support rollback.

Create:

```text
lib/muse/checkpoint.ex
lib/muse/checkpoint_store.ex
lib/muse/tools/patch_apply.ex
lib/muse/tools/rollback_checkpoint.ex
```

Tasks:

```text
1. Add Checkpoint struct/store.
2. Add /checkpoints.
3. Add /rollback checkpoint <id> or /restore <id>.
4. Require approved plan + approved patch hash.
5. Check patch hash matches.
6. Create checkpoint before write (git stash create preferred, file snapshot fallback).
7. Save original file contents for affected files.
8. Apply patch with controlled git apply (primary) or Elixir diff applier (fallback).
9. Emit checkpoint_created and patch_applied events.
10. Add rollback tool requiring approval.
11. Reject outside-workspace/secret/delete/binary patches unless specifically approved/allowed.
```

Tests:

```text
test/muse/checkpoint_test.exs
test/muse/checkpoint_store_test.exs
test/muse/tools/patch_apply_test.exs
test/muse/tools/rollback_checkpoint_test.exs
```

Acceptance:

```text
Approved patch applies in temp workspace.
Unapproved patch cannot apply.
Patch hash mismatch is blocked.
Checkpoint contains original file contents.
Checkpoint is created before write.
Rollback restores file.
Applied patch visible in git diff.
Events show apply progress.
```

### PR 19 — Test runner, Testing Muse, and Reviewing Muse loop

Goal: let Muse request controlled verification and produce review summaries.

Create:

```text
lib/muse/tools/test_runner.ex
lib/muse/muses/reviewing_muse.ex
lib/muse/muses/testing_muse.ex
```

Tasks:

```text
1. Add controlled test_runner.
2. Parse safe command allowlist.
3. Require explicit approval for test commands in v1 unless configured safe.
4. Capture stdout/stderr/exit code/duration.
5. Cap and summarize output.
6. Add Testing Muse handoff after patch apply.
7. Add Reviewing Muse turn path.
8. Allow /review on proposed/applied diff.
9. Reviewing Muse outputs approve/revise/reject recommendation.
10. Stop after bounded repair attempts.
```

Tests:

```text
test/muse/tools/test_runner_test.exs
test/muse/conductor_verification_test.exs
test/muse/muses/reviewing_muse_test.exs
test/muse/muses/testing_muse_test.exs
```

Acceptance:

```text
Safe configured test command can run in temp workspace.
Unsafe command asks for approval.
Output is capped.
User can run /review on proposed diff.
Review includes findings and validation gaps.
Failures produce repair plan, not uncontrolled edits.
Final response summarizes changes and verification.
```

### PR 20 — CLI, TUI, and LiveView integration polish

Goal: expose shared session state cleanly in all current interfaces.

Update:

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

Tasks:

```text
1. Ensure /status, /muses, /tools, /prompt preview, /plan, /patch, approvals, /checkpoints work in CLI.
2. Ensure TUI shows current session status, active Muse, pending approvals, recent tool calls, provider/model.
3. Ensure LiveView has panels for Active Muse, Plan, Tools, Approvals, Patch Diff, Validation, Memory, Checkpoints, Prompt Preview developer mode.
4. Ensure all interfaces share command dispatch.
5. Ensure no raw prompt or sensitive events are displayed.
```

Tests:

```text
test/muse/commands_test.exs
test/muse/command_dispatcher_test.exs
test/muse/cli/repl.exs
test/muse/cli/tui_test.exs
test/muse_web/live/home_live_test.exs
```

Acceptance:

```text
All interfaces can see the same session state.
Approvals can be performed from CLI and LiveView.
Events remain shared across interfaces.
UI strings use Muse-first language.
```

### PR 21 — Memory Muse, Restoration Muse, and specialist handoffs

Goal: add controlled collaboration after planning/coding/test/review loop is stable.

Create/update:

```text
lib/muse/muses/memory_muse.ex
lib/muse/muses/restoration_muse.ex
lib/muse/memory/compactor.ex
```

Tasks:

```text
1. Add Memory Muse profile and prompt.
2. Add compaction thresholds.
3. Summarize old messages/tool results into memory.md.
4. Exclude secrets and hidden reasoning.
5. Add memory layer to prompt bundle.
6. Add Restoration Muse profile and prompt.
7. Add handoff events.
8. Allow Planning Muse to recommend another Muse.
9. Allow Conductor to execute handoff only when policy allows.
10. Keep all tools gated by ApprovalGate.
```

Acceptance:

```text
Long sessions compact without losing approved plan state.
Memory excludes secrets and hidden reasoning.
Planning Muse can hand off to Coding Muse after plan approval.
Coding Muse can request Testing Muse after patch application.
Reviewing Muse can request Planning Muse revision.
Restoration Muse can inspect checkpoints and request restore approval.
```

### PR 22 — Documentation and developer onboarding

Goal: make the runtime understandable and testable.

Update:

```text
README.md
PLAN.md
```

Add docs for:

```text
Provider configuration
Fake provider testing
OpenAI-compatible provider setup
Prompt preview
Project rules
Tool permissions
Approval flow
Patch workflow
Checkpoint/rollback
Safety model
No-network test strategy
Auth modes and token redaction
Architecture overview (process model, SessionServer vs Conductor)
Cancellation behavior
```

Example README snippet:

```text
export MUSE_PROVIDER=openai_compatible
export MUSE_OPENAI_BASE_URL=https://api.openai.com/v1
export MUSE_OPENAI_API_KEY=...
export MUSE_MODEL=...

mix run --no-halt
```

Acceptance:

```text
A developer can run fake provider without secrets.
A developer can configure OpenAI-compatible provider.
A developer understands why writes require approval.
A developer understands the process architecture.
Docs use Muse-first language.
```

### PR 23 — Additional providers and model routing

Goal: add optional provider presets after OpenAI-compatible path works.

Scope:

```text
OpenRouter provider presets
Ollama/local provider presets
Anthropic adapter
Model router and per-Muse model pinning
Provider error handling and retries
Cost tracking and token accounting
Prompt caching support
```

Acceptance:

```text
Provider can be selected from config.
Fake provider remains default in tests.
Tool-call loop works with at least one real provider and configured optional providers.
```

### PR 24 — Remote execution later

Goal: add remote execution only after local runtime is safe.

Tasks:

```text
1. Add runner abstraction.
2. Add local runner.
3. Add remote SSH runner later.
4. Add artifact sync.
5. Add strict approvals.
6. Add timeout and output limits.
7. Use same tool and ApprovalGate policies.
```

Acceptance:

```text
Remote execution uses the same tool and approval policies.
Local execution remains default.
Remote execution is never available before this milestone.
```

---

## 18. First task for implementation team

Start with PR 00, then PR 01a, 01b, 01c in sequence.

Concrete first steps:

```text
1. Inspect the actual repo tree and confirm files/dependencies from this plan.
2. Run mix format --check-formatted and mix test; record baseline.
3. Document existing self-healing behavior.
4. Add this plan as PLAN.md at the repo root.
5. Extend Muse.Event with optional metadata fields while keeping Event.new/3 passing.
6. Add Event.new/4 with metadata opts.
7. Add Muse.Session struct with schema_version field.
8. Add Muse.Turn struct with streamed? field.
9. Add Muse.Telemetry with event definitions.
10. Run mix format && mix test.
```

Then proceed to PR 01b (SessionStore) and PR 01c (SessionServer).

Expected first PR result:

```text
Muse still appears simple from CLI, but internally every submit now has session_id, turn_id, lifecycle events, and persistence. No real model calls yet.
```

---

## 19. First demo fake provider script

Use fake provider first.

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

## 20. Testing strategy

### 20.1 No-network default

Normal test suite must not call OpenAI or other providers:

```text
mix test
```

Optional external tests:

```text
MUSE_OPENAI_TEST=1 OPENAI_API_KEY=... mix test --only external
```

### 20.2 Shared provider test suite

Define a shared test suite of provider interaction scenarios that both fake and real providers must satisfy:

```elixir
defmodule Muse.LLM.ProviderContractTest do
  # Tests that any provider implementation must pass:
  # - Returns assistant content for simple prompts
  # - Returns tool calls when tools are available
  # - Handles malformed tool call arguments gracefully
  # - Reports errors without crashing
  # - Supports cancellation
  # - Normalizes events to the same Muse.LLM.Event types
end
```

### 20.3 Fixture types

Add fixtures for:

```text
OpenAI Responses SSE text delta stream
OpenAI Responses function-call stream
OpenAI Responses WebSocket response events
Chat Completions text delta stream
Chat Completions tool-call stream
Codex auth.json with token values redacted/fake
Malformed provider events
Malformed tool calls
Fake provider scripts for planning/coding/testing flows
```

### 20.4 Unit tests

```text
MuseProfile loads all Muses.
Planning Muse has no write tools.
Coding Muse requires plan approval.
Prompt Assembler orders layers correctly.
Project rules load with correct priority.
Project rules cannot override core rules.
Debug preview redacts secrets.
Model preparer creates expected request shape.
ApprovalGate blocks writes before approval.
ApprovalGate binds approval to plan version.
Workspace path safety blocks traversal.
Workspace path safety blocks symlink escape.
Read file blocks secret paths.
Tool runner emits events.
Fake provider returns scripted tool calls.
Conductor handles tool-call loop.
Session store persists and resumes state.
Provider errors do not crash SessionServer.
Unknown provider events are ignored or logged as debug.
Existing State PubSub behavior remains stable.
SessionServer remains responsive during turns.
Cancellation works mid-turn.
```

### 20.5 Integration tests

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
Testing Muse runs or requests validation.
Reviewing Muse can review diff.
Session completes or waits for next approval.
```

### 20.6 Safety tests

```text
Blocked outside-workspace read.
Blocked outside-workspace write.
Blocked ../ traversal.
Blocked symlink write.
Blocked symlink read escape.
Blocked secret read.
Blocked hidden file unless explicitly allowed.
Blocked shell command before approval.
Blocked delete before explicit delete approval.
Blocked stale plan approval.
Blocked patch approval for different patch hash.
Blocked patch apply without checkpoint.
Blocked tool not available to active Muse.
Provider request debug snapshots redact Authorization headers.
External WebSocket channel does not forward internal/sensitive events.
```

### 20.7 Product-language tests

```text
/muses lists Planning Muse, Coding Muse, Reviewing Muse, Testing Muse.
/status says Active Muse.
Plan output says recommended Muse.
Approval messages say Muse Plan and Patch Proposal.
LiveView panels use Muse labels.
Docs/examples do not use mascot or generic Agent naming in user-facing text.
```

---

## 21. Security checklist before MVP

```text
[ ] No API keys in events.
[ ] No bearer tokens in logs.
[ ] No Codex auth tokens in prompt preview.
[ ] Authorization headers redacted from provider debug output.
[ ] Secret-like files blocked or redacted.
[ ] Workspace path checks are symlink-aware.
[ ] Patch apply blocks outside-workspace paths.
[ ] Patch apply blocks secret file paths.
[ ] Patch apply creates checkpoint first.
[ ] Shell commands are approval-gated.
[ ] Network calls are approval-gated or disabled.
[ ] Remote execution is disabled.
[ ] Web server defaults to localhost.
[ ] External WebSocket channel does not forward internal/sensitive events.
[ ] Prompt preview is redacted and does not show full hidden prompt.
[ ] Tool outputs are capped.
[ ] Provider errors do not leak secrets.
[ ] Configuration validated at startup.
[ ] All processes are supervised.
[ ] No orphan processes on turn crash.
```

---

## 22. Definition of done

### 22.1 Read-only Planning Muse milestone

```text
1. Muse creates or resumes a session.
2. Muse Conductor selects Planning Muse.
3. Prompt Assembler builds a prompt bundle.
4. Fake provider drives a model/tool loop.
5. Planning Muse lists the workspace.
6. Planning Muse reads relevant files.
7. Planning Muse searches for CLI command patterns.
8. Planning Muse creates a structured plan.
9. Plan is persisted.
10. Session status becomes :awaiting_plan_approval.
11. CLI/TUI/LiveView show the plan/events.
12. No files are modified.
13. No shell command runs.
14. No implementation Muse starts yet.
```

### 22.2 Muse Runtime v0

```text
Muse.submit/2 routes through SessionServer and Conductor.
Sessions persist to .muse/sessions/default/ or session id directories.
Prompt assembly uses deterministic layers.
/prompt-preview and /prompt preview exist and redact secrets.
Fake provider works in tests.
OpenAI-compatible provider works for non-streaming text and tool calls.
SSE provider normalizes streaming deltas/tool calls.
Planning Muse can use read-only tools.
Read-only tools are workspace-safe and secret-aware.
Planning Muse creates structured plan.
Plan is persisted and shown by /plan.
Plan approval is required before Coding Muse.
Coding Muse can propose a patch.
Patch approval is required before patch apply.
Patch apply creates checkpoint first.
Rollback works.
Safe test runner requests or uses approved commands.
CLI, TUI, and LiveView show shared events and status.
No API keys are leaked in logs, events, previews, or errors.
SessionServer remains responsive during turns.
Cancellation works correctly.
```

### 22.3 OpenAI-specific done criteria

```text
1. OPENAI_API_KEY auth can stream a Responses API answer over SSE when explicitly configured.
2. OpenAI-compatible Chat Completions provider can stream text from compatible endpoint.
3. OpenAI Responses WebSocket can connect, send response.create, receive text deltas, and store previous_response_id.
4. Tool-call events from real providers normalize into the same Conductor loop as fake provider events.
5. Codex auth cache can be detected and used only when explicitly configured.
6. OAuth/token material is never logged or shown.
```

---

## 23. Do not implement yet

Explicitly out of scope until the local runtime loop is stable:

```text
Remote VPS execution
SSH control
Remote Muse sessions
Phoenix remote LiveView monitoring
Remote tool execution
Nano repair mode
Autonomous shell loops
Browser automation
Package installation
Network search
MCP servers / MCP ecosystem
Multi-Muse delegation/swarm behavior
Subagent swarm before core loop works
Database persistence
Cloud sync
Large UI redesign
Complex memory systems before read-only planning works
Complex model router before one provider works
```

---

## 24. Backlog after v0

```text
Streaming model responses, if not already done before v0
Model router and per-Muse model pinning
OpenRouter provider presets
Ollama/local provider presets
Anthropic provider adapter
Memory compaction enhancements
Plan/task board UI
Reviewing Muse polish
Testing Muse polish
Restoration Muse polish
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
History compaction improvements
Specialized roles beyond core Muses
Tool search support when provider/model supports it
```

---

## 25. Ideas to borrow carefully from Code Puppy / Codex-style systems

Borrow:

```text
Muse profile owns prompt and tool list.
Model factory/provider abstraction.
Project rules loading.
Tool registration by name.
Event stream around tool calls.
History compaction later.
Specialized roles later.
Approval and sandboxing concepts.
```

Do not borrow directly:

```text
Mascot language.
One all-powerful Coding Muse.
Immediate write tools.
Shell execution before approval.
Subagent swarm before core loop works.
Unbounded repair loops.
```

Translate concepts into Muse naming:

```text
Planning Agent -> Planning Muse
Coding Agent -> Coding Muse
Model factory -> Muse LLM provider layer
Tool registry -> Muse Tool Registry + ApprovalGate
Rules loading -> Muse Prompt ProjectRules
Runtime coordinator -> Muse Conductor
```

---

## 26. Source coverage matrix

This merged plan incorporates the unique content from all three uploaded plans:

```text
Product naming and Muse-first glossary:
  captured in sections 3, 7, 15, 20.

Layered internal prompt system and redacted preview:
  captured in sections 4, 8, PR 05.

Specialist Muse prompts for Planning/Coding/Reviewing/Testing/Memory/Restoration:
  captured in section 7.

Current repository facts and placeholder behavior:
  captured in section 2 and PR 00.

Session, turn, event, persistence models:
  captured in sections 6 and PR 01a/01b/01c.

Streaming CLI/LiveView event API:
  captured in sections 15 and PR 02.

Provider-neutral LLM contracts and fake provider:
  captured in sections 6, 12, PR 03.

OpenAI-compatible request mapping, non-streaming provider, SSE, Responses WebSocket:
  captured in sections 12, PR 11–15.

OpenAI/Codex auth, API key, bearer command, Codex cache bridge:
  captured in section 12.10 and PR 13.

Read-only tools, schemas, workspace hardening, symlink-aware safety:
  captured in sections 9, 10, PR 06.

Approval gate, stale approval prevention, patch hash binding:
  captured in sections 6.9, 13, PR 09, PR 17–18.

Plan model, structured JSON, parser, fallback repair request:
  captured in sections 6.8, PR 08.

Patch proposal/apply, checkpoint, rollback:
  captured in sections 6.10–6.11, 14, PR 17–18.

Test runner and review loop:
  captured in sections 14.3, PR 19.

CLI, TUI, LiveView, optional external Phoenix channel:
  captured in section 15 and PR 16/20.

Security checklist and testing strategy:
  captured in sections 20–21.

First demo script:
  captured in section 19.

Implementation details and first task:
  captured in sections 17–18.

Deferred/backlog items including remote execution, MCP, memory compaction, model router:
  captured in sections 23–24.

Process architecture (SessionServer vs Conductor separation):
  captured in sections 4.2, 11.2, PR 07a/07b.

Telemetry:
  captured in section 16.

Cancellation semantics:
  captured in section 11.6.

Configuration validation:
  captured in section 12.4.

Persistence crash-safety:
  captured in section 6.2.

Shared provider test suite:
  captured in section 20.2.

ask_user_question tool specification:
  captured in section 9.4.6.

repo_search backend priority:
  captured in section 9.4.

Checkpoint git-based strategy:
  captured in section 6.11.

Streaming deduplication (streamed? flag):
  captured in sections 6.3, 15.5.

LiveView reconnection:
  captured in section 15.5.

Rate limiting / cost controls:
  captured in section 6.6.

Tool loop limit behavior:
  captured in section 11.5.

Partial stream failure recovery:
  captured in section 11.5.
```

---

## 27. External API references to verify before coding provider PRs

The provider PRs must re-check official documentation immediately before implementation. The source plans referenced OpenAI Responses streaming, Responses WebSocket mode, function/tool calling, Codex auth, Codex device auth, and Codex configuration. Treat docs as the source of truth for wire formats.

Reference topics:

```text
OpenAI Responses API HTTP streaming over SSE using stream=true
OpenAI Responses WebSocket mode with /v1/responses and previous_response_id
OpenAI function/tool calling with app-side tool execution
Structured outputs / JSON schema support and provider-specific limitations
Codex auth methods: ChatGPT sign-in and API-key sign-in
Codex login cache at ~/.codex/auth.json and token-safety handling
Codex login --device-auth for headless/device-code flows
```

---

## 28. Changelog from v1/v2 to final

Key changes retained from the v2 revision and normalized in this final v3 plan:

1. **Process architecture clarified (Section 4.2, 11.2):** Conductor runs in a Task/TurnRunner, NOT inside SessionServer. SessionServer owns state and remains responsive during turns.
2. **PR 01 split into 01a/01b/01c:** Smaller increments — structs first, then persistence, then GenServer.
3. **PR 07 split into 07a/07b:** Muse selection first, then tool loop.
4. **Cancellation semantics defined (Section 11.6):** Explicit behavior for mid-turn cancellation.
5. **Telemetry added (Section 16):** `:telemetry` events for observability.
6. **Configuration validation at startup (Section 12.4):** Fail fast with clear errors.
7. **Fake provider uses per-test TestScriptServer (Section 12.2):** No global `Application.put_env` in concurrent tests.
8. **`streamed?` flag on Turn (Section 6.3):** Prevents duplicate final CLI output.
9. **`ask_user_question` tool specified (Section 9.4.6):** Non-blocking behavior defined.
10. **`repo_search` backend priority (Section 9.4):** controlled configured `rg`/`grep` may be used, but pure Elixir scanner is mandatory fallback and safety baseline.
11. **Checkpoint git-based strategy (Section 6.11):** `git stash create` preferred over file copies.
12. **Patch apply fallback (Section 14.2):** Elixir-based diff applier as fallback for non-git environments.
13. **Tool loop limit behavior (Section 11.5):** Synthetic "max reached" result fed to model for graceful summary.
14. **Rate limiting / cost controls (Section 6.6):** `max_tokens_per_session` and `max_api_calls_per_minute` in provider config.
15. **Shared provider test suite (Section 20.2):** Contract tests that all providers must satisfy.
16. **Persistence crash-safety (Section 6.2):** Atomic writes, corrupt line handling, schema versioning.
17. **LiveView reconnection (Section 15.5):** Event replay by sequence number on mount/reconnect.
18. **`MuseProfile` uses `:display_name` only (Section 6.4):** Removed ambiguous `:name` alias.
19. **`Tool.Call` uses `:spec_name` (Section 6.7):** Clearer field naming.
20. **Self-healing documentation task (PR 00):** Explicit task to document existing behavior before modifying it.
21. **v3 merge cleanup:** Removed v2 wrapper/code-fence artifact, added merge analysis, and renamed the plan to the ultimate final implementation plan.
22. **v3 safety reconciliation:** Combined v1's conservative search/checkpoint defaults with v2's performance/process improvements.
23. **v3 product-language cleanup:** Replaced incidental implementation-agent phrasing with implementation team / Muse language where possible while preserving explicit "avoid Agent" and translation sections.
