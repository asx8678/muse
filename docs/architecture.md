# Muse Universal Runtime — Architecture Document

> **Companion docs:** [Prompts](prompts.md) · [Provider Roadmap](provider-roadmap.md) · [Testing](testing.md) · [Security](security.md) · [Executive Summary](../PLAN.md)
>
> **Canonical source:** Runtime process architecture, module map, data models, normalized event types, Conductor behavior, tool system, streaming API, telemetry, approvals, patch/checkpoint/rollback behavior.

---

## Developer Onboarding Map

New to the Muse codebase? Start here:

### Quick Start

1. **Read this document** — especially §0 (Implemented Contract), §1 (Runtime Path), §2 (Process Architecture), and §7 (Conductor).
2. **Run the tests** — `mix test` runs offline by default with the fake provider. See [`testing.md`](testing.md) for the full testing strategy.
3. **Explore the module map** — §4 lists all modules by category. Key entry points:
   - `Muse.submit/2` — public API
   - `Muse.SessionRouter` — session lookup/creation
   - `Muse.SessionServer` — GenServer per session, owns state
   - `Muse.Conductor` — orchestrates turns, Muse selection, tool loops
   - `Muse.Tool.Runner` — tool execution with safety checks
4. **Try the CLI** — `iex -S mix` then `Muse.CLI.TUI.start/1` or use the `muse` escript.

### What's Implemented (through PR23)

| Feature | Status | Notes |
|---|---|---|
| Session management | ✅ Implemented | SessionRouter, SessionServer, SessionStore, persistence |
| Event streaming | ✅ Implemented | Delta events, PubSub, replay, `streamed?` flag |
| Fake provider | ✅ Implemented | Deterministic, offline-first testing |
| Planning Muse | ✅ Implemented | Read-only inspection, structured JSON plans |
| Coding Muse routing | ✅ Implemented | Conductor routes to Coding Muse after plan approval |
| Plan approval lifecycle | ✅ Implemented | `/approve plan`, `/reject plan`, content-bound binding |
| Patch proposal | ✅ Implemented | `patch_propose` tool, hash, `/approve patch`, `/reject patch` |
| Patch apply and rollback | ✅ Implemented (PR18) | `/apply patch`, `patch_apply`, checkpoints, `/rollback checkpoint <id>` |
| Test runner | ✅ Implemented (PR19) | Preset-only safe commands with bounded output/timeouts |
| Reviewing/Testing Muses | ✅ Implemented (PR19) | Registered profiles, review findings, verification reporting |
| Memory compaction | ✅ Implemented (PR21) | Memory Muse, `memory.md`, handoff support |
| Restoration support | ✅ Implemented (PR21) | Checkpoint listing/restore request commands and Restoration Muse profile |
| Auth layer | ✅ Implemented | API key, bearer command, Codex cache bridge |
| SSE provider | ✅ Implemented | HTTP SSE streaming for OpenAI-compatible |
| Responses WebSocket | ✅ Implemented | OpenAI Responses API with previous_response_id |
| External WS channel | ✅ Implemented | Phoenix channel for non-LiveView clients |
| CLI/TUI/LiveView | ✅ Implemented | Unified commands, Muse-first strings |
| Additional providers | ✅ Implemented (PR23) | OpenRouter, Ollama, Anthropic provider presets |
| Model routing | ✅ Implemented (PR23) | Per-Muse model/provider pinning via env or opts |

### What's Roadmap (PR24+)

| Feature | Status | Notes |
|---|---|---|
| Remote execution | 🗓️ PR24+ | SSH/remote runners, strict approvals |

### Key Files by Area

- **Session:** `lib/muse/session*.ex`, `lib/muse/state.ex`
- **Conductor/Turns:** `lib/muse/conductor*.ex`, `lib/muse/turn.ex`
- **Tools:** `lib/muse/tool/*.ex`, `lib/muse/tools/*.ex`
- **Execution:** `lib/muse/execution/*.ex` (PR24)
- **Planning:** `lib/muse/plan*.ex`, `lib/muse/task.ex`
- **Patches:** `lib/muse/patch*.ex`, `lib/muse/checkpoint*.ex`
- **Memory:** `lib/muse/memory.ex`
- **Auth:** `lib/muse/auth/*.ex`
- **Prompts:** `lib/muse/prompt/*.ex`
- **LLM/Providers:** `lib/muse/llm/**/*.ex`
- **CLI/TUI:** `lib/muse/cli/*.ex`
- **Tests:** `test/muse/**/*.exs`

---

## Table of Contents

0. [PR09 ApprovalGate MVP — Implemented Contract](#0-pr09-approvalgate-mvp--implemented-contract)
1. [Runtime Path](#1-runtime-path)
2. [Process Architecture](#2-process-architecture)
3. [Data Models](#3-data-models)
   - 3.1 [Event Model](#31-event-model)
   - 3.2 [Session Model](#32-session-model)
   - 3.3 [Turn Model](#33-turn-model)
   - 3.4 [Muse Profile Model](#34-muse-profile-model)
   - 3.5 [LLM Provider-Neutral Models](#35-llm-provider-neutral-models)
   - 3.6 [Provider Config Model](#36-provider-config-model)
   - 3.7 [Tool Models](#37-tool-models)
   - 3.8 [Plan and Task Models](#38-plan-and-task-models)
   - 3.9 [Approval Model](#39-approval-model)
   - 3.10 [Patch Model](#310-patch-model)
   - 3.11 [Checkpoint Model](#311-checkpoint-model)
4. [Module Map](#4-module-map)
5. [Prompt Assembly System](#5-prompt-assembly-system)
   - 5.1 [Prompt Layer Struct](#51-prompt-layer-struct)
   - 5.2 [Prompt Bundle Struct](#52-prompt-bundle-struct)
   - 5.3 [Final Prompt Assembly Order](#53-final-prompt-assembly-order)
   - 5.4 [Project Rules Loader](#54-project-rules-loader)
   - 5.5 [Prompt Assembler API](#55-prompt-assembler-api)
   - 5.6 [Debug Preview](#56-debug-preview)
6. [Tool System](#6-tool-system)
   - 6.1 [Initial Read-Only Tools](#61-initial-read-only-tools)
   - 6.2 [Write/Execution Tools (Later)](#62-writeexecution-tools-later)
   - 6.3 [Tool Permissions Matrix](#63-tool-permissions-matrix)
   - 6.4 [Read-Only Tool Schemas and Behavior](#64-read-only-tool-schemas-and-behavior)
   - 6.5 [Tool Runner](#65-tool-runner)
   - 6.6 [OpenAI-Compatible Tool Schema Example](#66-openai-compatible-tool-schema-example)
7. [Muse Conductor](#7-muse-conductor)
   - 7.1 [Responsibilities](#71-responsibilities)
   - 7.2 [Turn Execution Model](#72-turn-execution-model)
   - 7.3 [Run-Turn Flow](#73-run-turn-flow)
   - 7.4 [Muse Selection and Routing](#74-muse-selection-and-routing)
   - 7.5 [Tool Loop](#75-tool-loop)
   - 7.6 [Cancellation Semantics](#76-cancellation-semantics)
8. [CLI, TUI, LiveView, and External Channel](#8-cli-tui-liveview-and-external-channel)
   - 8.1 [Commands](#81-commands)
   - 8.2 [Key Command Outputs](#82-key-command-outputs)
   - 8.3 [Streaming Event API](#83-streaming-event-api)
   - 8.4 [LiveView Panels](#84-liveview-panels)
   - 8.5 [Optional External Phoenix WebSocket Channel](#85-optional-external-phoenix-websocket-channel)
9. [Telemetry](#9-telemetry)
10. [Patch, Checkpoint, Rollback, and Verification](#10-patch-checkpoint-rollback-and-verification)
    - 10.1 [Patch Proposal Policy](#101-patch-proposal-policy)
    - 10.2 [Patch Apply Policy](#102-patch-apply-policy)
    - 10.3 [Test Runner Policy](#103-test-runner-policy)
11. [Approval Flows](#11-approval-flows)

---

## 0. PR09 ApprovalGate MVP — Implemented Contract

This section is the **source of truth for the PR09 approval contract**.

### Implemented now

- `Muse.Conductor.select_muse/2` still executes active turns with **Planning Muse**.
- Structured plan output is parsed by `Muse.PlanParser` + `Muse.PlanSchema`.
- On successful parse, Conductor:
  - stores `%Muse.Plan{}` in result/session flow,
  - emits `:plan_created`,
  - renders user-facing plan text via `Muse.Plan.render/1`,
  - transitions session status to `:awaiting_plan_approval`.
- Plan lifecycle commands are wired and auditable:
  - `/plan`, `/plans`, `/plan history`, `/plan status`, `/plan show <id>`
  - `/approve plan`, `/reject plan`
  - lifecycle events are emitted (`:plan_approved`, `:plan_rejected`, and `:session_status_changed` when applicable).
- Plan approval is content-bound and stale-safe via approval binding rules:
  - `session_id`, `plan_id`, `plan_version`, `plan_hash`, `workspace`.
- Runtime enforcement remains deny-by-default for risky tool categories via `Muse.Tool.Registry` + `Muse.Tool.Runner`.

### Explicit PR09 boundaries (still out of scope)

Plan approval in PR09 is **lifecycle-only**. It does **not**:

- apply patches,
- write files,
- run shell commands,
- run arbitrary network calls,
- or hand off automatically to Coding Muse execution.

### Later gates implemented after PR09

- PR17 added Coding Muse patch proposals and patch approval lifecycle.
- PR18 added explicit patch apply with checkpoint/rollback (`patch_apply`, `/apply patch`, `/rollback checkpoint <id>`).
- PR19 added preset-only safe test execution and Reviewing/Testing Muse profiles.
- PR21 added memory compaction, Restoration Muse support, and explicit handoff commands.

### PR17 additions (implemented alongside PR09 contract)

- `Muse.Conductor.select_muse/2` routes to **Coding Muse** when the session is `:idle` with an approved plan.
- `patch_propose` is a registered tool available to Coding Muse after plan approval.
- Patch approval lifecycle (`/approve patch`, `/reject patch`) is wired through CommandDispatcher and SessionServer.
- Patch approval remains lifecycle-only: it records approval but does not itself call `patch_apply`, create a checkpoint, or modify files. `/apply patch` is the separate PR18 application command.
- Session supports `:awaiting_patch_approval` status and `pending_patch` field.
- Event types `:patch_proposed`, `:patch_approval_requested`, `:patch_approved`, `:patch_rejected`, `:patch_applied`, and `:checkpoint_created` are emitted and forwarded on the external WS channel when allowed by visibility filtering.

Use the remaining sections in this document as architecture context; where they diverge, the current code is authoritative.

---

## 1. Runtime Path

The full flow from user input to response:

```text
User input
  → CLI / TUI / LiveView / API
  → Muse.submit/2
  → Muse.SessionRouter
  → Muse.SessionServer (GenServer, owns session state)
  → Muse.Conductor (runs in caller process or Task, NOT inside SessionServer)
  → Muse.Prompt.Assembler
  → Muse.Prompt.ModelPreparer
  → Muse.LLM.Provider
  → Muse.Tool.Runner (registry/role checks + blocked-tool enforcement)
  → Muse.SessionStore + Muse.State + Phoenix.PubSub
  → CLI / TUI / LiveView updates
```

### Key Architectural Decision: Conductor Runs Outside SessionServer

The Conductor runs in the caller's process (or a Task spawned by the SessionServer), **not inside the SessionServer GenServer**. The SessionServer owns session state and persistence. The Conductor orchestrates the model/tool loop. This separation ensures:

- **Non-blocking:** The SessionServer never blocks on long-running model calls or tool execution. It remains responsive for status queries and approvals during turns.
- **Concurrent turns:** Multiple turns can execute concurrently across sessions.
- **Crash isolation:** A crashed Conductor does not kill the session. The SessionServer survives and can report the failure, preserve state, and accept new turns.
- **Responsiveness:** Users can send `/cancel`, `/status`, or approval commands while a turn is in progress.

---

## 2. Process Architecture

### Supervision Tree

```text
Muse.Application
├── Registry (process registry, :unique keys)
├── Muse.SessionSupervisor (DynamicSupervisor)
│   └── Muse.SessionServer (GenServer, one per session)
│       └── owns: session state, event log, persistence
├── Muse.Telemetry (attached handlers for :telemetry events)
└── [Web supervision tree — existing Phoenix]
```

### SessionServer Responsibilities

The `Muse.SessionServer` GenServer owns one active session and its state. It handles:

- Synchronous calls: `submit`, `approve_plan`, `reject_plan`, `status`, `cancel`
- Session state persistence via `Muse.SessionStore`
- Event broadcasting via `Muse.State` and `Phoenix.PubSub`
- Spawning a `Muse.Conductor.TurnRunner` Task for each turn

**The SessionServer does NOT run model/tool loops.** Long work is delegated to `TurnRunner` Tasks.

### Turn Execution via Task

Each turn is executed by a `Task` (`Muse.Conductor.TurnRunner`) that:

1. Reads session state from `SessionServer`
2. Runs the model/tool loop via `Muse.Conductor`
3. Writes results back to `SessionServer`
4. Emits events via `Muse.State` / `Phoenix.PubSub`

---

## 3. Data Models

### 3.1 Event Model

#### Current Shape (Backward Compatible)

```elixir
%Muse.Event{id: nil, timestamp: nil, source: nil, type: nil, data: nil}
```

#### Extended Shape

```elixir
defmodule Muse.Event do
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
end
```

#### Backward-Compatible Constructors

`Event.new/3` continues to work exactly as before:

```elixir
Event.new(:planning_muse, :assistant_delta, %{text: "..."})
```

New metadata form via `Event.new/4`:

```elixir
Event.new(:planning_muse, :assistant_delta, %{text: "..."},
  session_id: session.id,
  turn_id: turn.id,
  seq: 12,
  visibility: :user
)
```

#### Visibility Values

| Value | Meaning |
|---|---|
| `:user` | Safe to show in CLI/TUI/LiveView chat |
| `:debug` | Safe for event/debug log only |
| `:internal` | Persisted but not normally shown |
| `:sensitive` | Should not be stored unless redacted first |

#### Event Taxonomy

Full list of event types:

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
:patch_applied              # PR18
:checkpoint_created         # PR18
:checkpoint_restored        # PR18
:rollback_completed         # PR18
:validation_started
:validation_finished
:memory_compacted
:muse_handoff_requested
:muse_handoff_completed
:auth_status
:session_failed
:session_completed
```

#### Required Fields for Every Event

```text
session_id
seq
source
muse_id (when applicable)
safe summary payload
created_at / timestamp
```

Events use session-local monotonic `seq` values for replay.

---

### 3.2 Session Model

```elixir
defmodule Muse.Session do
  @enforce_keys [:workspace, :status, :created_at, :updated_at]
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

#### Session Statuses

| Status | Meaning |
|---|---|
| `:idle` | Session is waiting for input |
| `:running` | A turn is actively executing |
| `:planning` | Planning Muse is inspecting the workspace |
| `:awaiting_plan_approval` | A plan has been created and is waiting for user approval |
| `:executing` | An approved plan is being executed |
| `:awaiting_patch_approval` | A patch has been proposed and is waiting for approval |
| `:awaiting_shell_approval` | A shell/test command is waiting for approval |
| `:verifying` | Verification workflow status used by Testing Muse / test-runner flows when active |
| `:reviewing` | Review workflow status used by Reviewing Muse flows when active |
| `:repairing` | Reserved status for future recovery workflow |
| `:done` | Session has completed its objective |
| `:failed` | Session has encountered an unrecoverable failure |
| `:error` | Session is in an error state |
| `:cancelled` | Session or turn was cancelled |

#### Persistence Layout

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

#### Persistence Rules

- **JSONL format:** Each JSONL line is one complete JSON object (append-only, crash-safe)
- **Atomic writes:** Write to `.tmp` file first, then rename for atomicity
- **Schema versioning:** Include a `schema_version` field in `session.json` for future migration
- **Corrupt line handling:** Missing or corrupt lines are skipped with a warning, not a crash
- **Storage:** Use JSON/JSONL with Jason. Do not add Ecto or a database in v0

---

### 3.3 Turn Model

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

#### Turn Statuses

| Status | Meaning |
|---|---|
| `:queued` | Turn has been submitted but not yet started |
| `:running` | Turn is actively executing the model/tool loop |
| `:awaiting_approval` | Turn is paused waiting for an approval |
| `:completed` | Turn has finished successfully |
| `:failed` | Turn has encountered an error |
| `:cancelled` | Turn was cancelled by user |

#### The `streamed?` Flag

The `streamed?` boolean prevents duplicate final output in the CLI. If deltas were already printed to the terminal during streaming, the CLI suppresses the full-message reprint when the turn completes. This ensures the user sees smooth streaming output without a jarring duplicate of the complete text.

---

### 3.4 Muse Profile Model

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

> **Note:** Uses `:display_name` for user-facing text. The `:name` field is removed — use `:id` for internal reference and `:display_name` for all user-facing text. No `:name` alias.

---

### 3.5 LLM Provider-Neutral Models

#### Muse.LLM.Message

```elixir
defmodule Muse.LLM.Message do
  @type role :: :system | :user | :assistant | :tool
  defstruct [:role, :content, :name, :tool_call_id, metadata: %{}]
end
```

#### Muse.LLM.ToolCall

```elixir
defmodule Muse.LLM.ToolCall do
  defstruct [:id, :name, :arguments, :raw]
end
```

#### Muse.LLM.Request

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

#### Muse.LLM.Event (Normalized Types)

```elixir
defmodule Muse.LLM.Event do
  defstruct [:type, :text, :tool_call, :raw, :usage, :error]
end
```

Normalized LLM event types:

| Type | Meaning |
|---|---|
| `:response_started` | Provider has begun streaming a response |
| `:assistant_delta` | Partial text from the assistant |
| `:assistant_completed` | Full assistant text is complete |
| `:tool_call_started` | A tool call has been initiated by the model |
| `:tool_call_delta` | Partial tool-call argument text |
| `:tool_call_completed` | A tool call is fully specified |
| `:response_completed` | The provider response is fully done |
| `:provider_error` | The provider returned an error |

#### Muse.LLM.Response

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

#### Provider Behavior Callbacks

Streaming is the primary callback. A non-streaming compatibility wrapper can be layered on top:

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

---

### 3.6 Provider Config Model

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

#### Config Sources Priority (Highest First)

```text
1. Environment variables
2. Workspace .muse/config.toml (when implemented)
3. User config ~/.muse/config.toml (optional, later)
4. Application env defaults
```

Do not add TOML parsing until needed. A simple config map plus env support is acceptable first.

#### Example Provider Configs

**OpenAI:**

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
```

**OpenRouter:**

```elixir
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
```

**Ollama:**

```elixir
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

#### Wire APIs

| Wire API | Description |
|---|---|
| `:responses` | OpenAI native Responses API |
| `:chat_completions` | OpenAI-compatible fallback for routers/local providers |

#### Transports

| Transport | Description |
|---|---|
| `:none` | Fake provider / no network |
| `:sse` | HTTP server-sent events |
| `:websocket` | OpenAI Responses WebSocket mode |

---

### 3.7 Tool Models

#### Muse.Tool.Spec

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

#### Muse.Tool.Call

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

#### Muse.Tool.Result

```elixir
defmodule Muse.Tool.Result do
  defstruct [:call_id, :status, :output, :error, :metadata]
end
```

#### Tool Permissions

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

#### Approval Categories

| Category | Meaning |
|---|---|
| `:always_allowed` | Tool can run without user confirmation |
| `:approval_required` | Tool must receive explicit user approval before running |
| `:blocked` | Tool is not available in the current context |

---

### 3.8 Plan and Task Models

#### Muse.Plan

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

**Plan statuses:**

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

#### Muse.Task

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

#### Structured Plan JSON Schema (PR09 current)

`Muse.PlanSchema.schema/0` defines a schema-map contract used for prompt guidance and validation behavior.

**Required fields (input JSON):**

- `objective` — non-empty string
- `tasks` — non-empty array
- each task requires `title` and `description` (non-empty strings)

**Optional fields (input JSON):**

- `summary`, `risks`, `alternatives`, `validation`, `inspected_files`, `likely_changed_files`
- task-level `target_files`, `requires_write`, `requires_shell`, `verification`, `recommended_muse`

**Versioning behavior:**

- The provider output schema does **not** currently require a `version` or `schema_version` field.
- `%Muse.Plan{}` is created with `version: 1` by default in `Muse.Plan.new/1`.

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

#### Local Validation Rules

```text
- objective is required, string, and non-empty
- tasks is required, list, and non-empty
- each task has non-empty title and description
- requires_write and requires_shell (when present) must be booleans
- risks (when present) must be a list
- normalization defaults task requires_* booleans to false
```

---

### 3.9 Approval Model

PR09 introduces explicit approval records and stale-approval checks for **plan lifecycle commands**.

#### Muse.Approval Struct (PR09)

```elixir
defmodule Muse.Approval do
  @enforce_keys [:id, :plan_id, :kind, :status, :source, :created_at]
  defstruct [
    :id,
    :plan_id,
    :kind,
    :status,
    :source,
    :reason,
    :metadata,
    :created_at
  ]
end
```

#### Approval Kinds (PR09 MVP)

```text
:plan
:shell
:patch
```

#### Approval Statuses (PR09 MVP)

```text
:approved
:rejected
```

#### Content-Bound Plan Approval Binding

PR09 binds plan lifecycle approval to stable identity + content:

```text
session_id
plan_id
plan_version
plan_hash
workspace
```

`plan_hash` is a deterministic content hash (`Muse.PlanBinding.content_hash/1`) used to reject stale approvals when plan content changes.

#### Stale Approval Rejection

`Muse.ApprovalGate` rejects mismatched or expired lifecycle actions with explicit reasons such as:

```text
:no_approval_binding
:stale_content
:wrong_session
:wrong_workspace
:expired
:stale_approval
```

This prevents approving or rejecting the wrong plan revision/content.

#### PR09 Runtime Enforcement Boundary

Plan lifecycle approval (`/approve plan`, `/reject plan`) is implemented and auditable, but remains **non-executing**:

- transitions only the active `%Muse.Plan{}` status,
- emits lifecycle events,
- returns session status to `:idle` when appropriate,
- does not apply patches or run file/shell/network operations.

`Muse.Tool.Runner` + `Muse.Tool.Registry` remain deny-by-default for dangerous categories:

- known dangerous names are blocked,
- destructive unknown tool-name shapes are blocked,
- unknown non-dangerous tools are rejected,
- `requires_approval: true` specs are still blocked until later gates.

Prompt text is guidance, not a security boundary. Runtime safety is enforced in Elixir code.

---

### 3.10 Patch Model

#### Muse.Patch Struct

```elixir
defmodule Muse.Patch do
  defstruct [
    :id,
    :session_id,
    :plan_id,
    :plan_version,
    :plan_hash,
    :diff,
    :hash,
    :affected_files,
    :status,
    :created_at,
    :approved_at,
    :rejected_at,
    :applied_at,
    :verified_at,
    :metadata
  ]
end
```

The `hash` field is a deterministic SHA-256 computed over `session_id`, `plan_id`, `plan_version`, `plan_hash`, and canonicalized diff content. Identical patches always produce the same hash; volatile fields (timestamps, status, metadata) are excluded.

#### Patch Statuses

| Status | Meaning |
|---|---|
| `:proposed` | Patch has been generated and is awaiting user approval |
| `:approved` | Patch has been approved by the user (lifecycle-only in PR17; no apply) |
| `:rejected` | Patch has been rejected by the user |
| `:applied` | Patch has been applied to the workspace (PR18) |
| `:verified` | Applied patch has passed verification (PR18) |
| `:cancelled` | Patch has been cancelled from any status |

#### Patch Proposal Tool Input (JSON)

```json
{
  "diff": "diff --git a/foo.ex b/foo.ex\n--- a/foo.ex\n+++ b/foo.ex\n@@ -1 +1 @@\n-old\n+new\n",
  "summary": "Add /version command.",
  "affected_files": ["lib/muse/commands.ex"]
}
```

#### Patch Proposal Tool Output (JSON)

```json
{
  "patch_id": "patch_a1b2c3d4e5f6",
  "hash": "sha256...",
  "diff_size": 234,
  "affected_files": ["lib/muse/commands.ex"],
  "summary": "Add /version command.",
  "approval_required": true,
  "message": "Patch proposal patch_a1b2c3d4e5f6 created. Review the diff and use /approve patch to authorize application. No files have been modified."
}
```

---

### 3.11 Checkpoint Model

#### Muse.Checkpoint Struct

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

#### Hybrid Checkpoint Strategy

Use a hybrid checkpoint model depending on workspace type:

**Git workspace (preferred):** `git stash create` records a content-addressed snapshot without modifying the working tree. Store:
- Git object SHA
- Current branch/head
- Pre-apply `git status`
- Pre-apply diff
- Proposed patch
- Affected-file hashes

**Non-git workspace (fallback):** When git is unavailable or `git stash create` fails, fall back to file-level snapshots of only affected files plus their metadata. **Never** snapshot denied secret paths.

#### Checkpoint Before Write Steps

Before any write operation, the following steps are taken:

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

#### Checkpoint Layout on Disk

```text
.muse/sessions/<session_id>/checkpoints/<checkpoint_id>/
  metadata.json
  before.diff
  proposed.patch
  affected_files/
  after.diff
```

---

## 4. Module Map

The full high-level module map, organized by category:

### Public API

```text
lib/muse.ex                  Public API. Muse.submit/2 delegates to SessionRouter; plan approval/rejection routed via /approve plan and /reject plan slash commands through SessionRouter → SessionServer.
```

### Application

```text
lib/muse/application.ex      Starts Registry, Workspace, State, SessionSupervisor, and app children.
```

### Core

```text
lib/muse/event.ex            Immutable event struct with metadata fields.
lib/muse/state.ex            Event log + Phoenix.PubSub broadcast.
lib/muse/telemetry.ex        Telemetry event definitions and helpers.
```

### Session Layer

```text
lib/muse/session.ex              Session struct definition.
lib/muse/turn.ex                 Turn struct definition.
lib/muse/session_server.ex       GenServer owning one active session and its state.
lib/muse/session_supervisor.ex   DynamicSupervisor for session processes.
lib/muse/session_router.ex       Finds or starts session processes via Registry.
lib/muse/session_store.ex        Persists events, messages, plans, patches, approvals, checkpoints, memory.
```

### Conductor Layer

```text
lib/muse/conductor.ex                Selects Muse, builds prompts, runs model/tool loop, handles handoffs.
lib/muse/conductor/turn_runner.ex    Task-based turn execution. Spawned by SessionServer.
lib/muse/conductor/tool_loop.ex      Iterative tool-call loop within a turn.
```

### Muse Profiles

```text
lib/muse/muse_profile.ex            MuseProfile struct definition.
lib/muse/muse_registry.ex           Static registry of built-in profiles.
                                    PR09 currently registers :planning and :coding.
```

### Prompt System

```text
lib/muse/prompt/layer.ex            Prompt layer struct.
lib/muse/prompt/bundle.ex           Prompt bundle struct.
lib/muse/prompt/assembler.ex        Assembles layers into a prompt bundle.
lib/muse/prompt/model_preparer.ex   Converts bundle to Muse.LLM.Request.
lib/muse/prompt/project_rules.ex    Loads project rules from trusted locations.
lib/muse/prompt/redactor.ex         Redacts secrets from debug output.
lib/muse/prompt/debug_preview.ex    Renders redacted prompt preview for developers.
```

### LLM Layer

```text
lib/muse/llm/message.ex             Provider-neutral message struct.
lib/muse/llm/request.ex             Provider-neutral request struct.
lib/muse/llm/event.ex               Normalized LLM event struct.
lib/muse/llm/response.ex            Provider-neutral response struct.
lib/muse/llm/tool_call.ex           Provider-neutral tool call struct.
lib/muse/llm/provider.ex            Provider behavior definition.
lib/muse/llm/provider_config.ex     Provider configuration struct.
lib/muse/llm/provider_router.ex     Provider module resolver.
lib/muse/llm/fake_provider.ex       Deterministic fake provider for tests.
lib/muse/llm/openai_compatible_provider.ex  OpenAI-compatible provider.
lib/muse/llm/openai/request_builder.ex                 OpenAI request builder.
lib/muse/llm/openai/chat_completions_mapper.ex         Chat Completions mapper.
lib/muse/llm/openai/chat_completions_decoder.ex        Chat Completions decoder.
lib/muse/llm/openai/chat_completions_stream_decoder.ex Chat Completions SSE stream decoder.
lib/muse/llm/openai/responses_mapper.ex                Responses API mapper.
lib/muse/llm/openai/responses_stream_decoder.ex        Responses shared decoder.
lib/muse/llm/openai/responses_websocket/request_builder.ex  Responses WS request builder.
lib/muse/llm/transport/sse/parser.ex                   SSE parser.
lib/muse/llm/transport/sse/req_stream.ex               Req streaming adapter.
lib/muse/llm/transport/websocket/stream.ex             WS transport abstraction.
lib/muse/llm/transport/websocket/safe_error.ex         WS transport redacted errors.
```

### Config and Auth

```text
lib/muse/config.ex                  Configuration loading and validation.
lib/muse/auth/credential.ex         Credential struct.
lib/muse/auth/resolver.ex           Credential resolution from configured modes.
lib/muse/auth/status.ex             Auth status reporting for commands/UI.
lib/muse/auth/api_key.ex            API key auth.
lib/muse/auth/bearer_command.ex     Bearer token command auth.
lib/muse/auth/codex_cache.ex        Codex auth cache bridge.
```

### Tool System

```text
lib/muse/tool/spec.ex               Tool specification struct.
lib/muse/tool/call.ex               Tool call struct.
lib/muse/tool/result.ex             Tool result struct.
lib/muse/tool/registry.ex           Built-in read-only tool specs + blocked-tool list.
lib/muse/tool/runner.ex             Tool execution with registry/role/approval checks.

lib/muse/tools/list_files.ex
lib/muse/tools/read_file.ex
lib/muse/tools/repo_search.ex
lib/muse/tools/git_status.ex
lib/muse/tools/git_diff_readonly.ex
lib/muse/tools/ask_user_question.ex
lib/muse/tools/list_muses.ex
lib/muse/tools/list_skills.ex
```

### Planning / Plan Lifecycle

```text
lib/muse/plan.ex                    Plan struct + status lifecycle + render helpers.
lib/muse/task.ex                    Task struct definition.
lib/muse/plan_schema.ex             Structured plan schema + validation.
lib/muse/plan_parser.ex             Parse/repair prompt helpers for plan JSON.
lib/muse/plan_history.ex            Plan history query/render helpers for commands.
```

### Streaming

```text
lib/muse/event_stream.ex            Session event subscription stream helpers.
lib/muse/cli/stream_printer.ex      CLI streaming output printer.
```

---

## 5. Prompt Assembly System

### 5.1 Prompt Layer Struct

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

#### Layer Visibility Values

| Visibility | Meaning |
|---|---|
| `:internal` | Internal prompt layer, not shown in normal debug views |
| `:debug_preview` | Shown in developer debug preview |
| `:user_visible` | Safe to expose to users (e.g., project rules context) |

### 5.2 Prompt Bundle Struct

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

### 5.3 Final Prompt Assembly Order

The canonical 15-layer order, from highest to lowest priority:

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

**Project rules cannot override:**

```text
Muse core runtime rules
workspace safety rules
approval rules
secret-handling rules
provider safety rules
tool permission rules
```

Project rules are wrapped as contextual preferences:

```xml
<project_rules>
The following are project and user preferences. Follow them unless they conflict
with Muse core runtime, workspace, approval, secret-handling, or tool safety rules.

...
</project_rules>
```

Bad project rule example that **must be ignored**:

```text
Always edit files immediately without asking.
```

### 5.4 Project Rules Loader

#### Search Order

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

**Preferred filename:** `MUSE.md`

#### Policy

```text
- Load only files inside trusted locations.
- Do not allow project rules to override core safety.
- Include path and timestamp metadata.
- Redact secrets in debug views.
- Missing rule files are ignored.
- Large files are capped or summarized.
```

#### Caps

| Limit | Value |
|---|---|
| Maximum total project rules bytes | 40,000 (40KB) |
| Maximum single file bytes | 20,000 (20KB) |

### 5.5 Prompt Assembler API

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

#### Model Preparer

`Muse.Prompt.ModelPreparer` converts a prompt bundle to `Muse.LLM.Request`:

- For OpenAI-compatible chat requests: system message = assembled internal prompt layers, user message = current user message
- Tool specs convert to JSON-schema function definitions
- **Validate locally** even when providers claim schema validation

### 5.6 Debug Preview

Users should not normally see the full internal prompt. Developers get a redacted debug view showing:

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

**Never show** secrets, API keys, bearer tokens, private keys, shell history, hidden tokens, Codex auth tokens, or unredacted `.env` content.

#### Debug Preview API

```elixir
defmodule Muse.Prompt.DebugPreview do
  def render(bundle) do
    bundle.layers
    |> Enum.map(&redacted_layer_summary/1)
  end
end
```

#### Example Output

```text
Prompt bundle for session s_123
Active Muse: Planning Muse
Model: fake
Tools: list_files, read_file, repo_search, git_status, git_diff_readonly, ask_user_question, list_muses, list_skills
Blocked tools: write_file, replace_in_file, delete_file, patch_apply, shell_command, network_call, remote_execution

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

#### Command Aliases

```text
/prompt preview
/prompt-preview
```

---

## 6. Tool System

### 6.1 Initial Read-Only Tools

Implement first (available to Planning Muse before plan approval):

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

### 6.2 Write/Execution Tools

Current registered non-read-only tools are deliberately narrow and approval/context gated:

```text
patch_propose        # Coding Muse after approved plan; stores a proposal only
patch_apply          # Coding Muse after approved plan + approved patch; checkpoint first
rollback_checkpoint  # Coding Muse with approved plan context; checkpoint-scoped rollback
test_runner          # Testing Muse only; preset verification commands only
```

The following names remain hard-denied or future scope:

```text
write_file
replace_in_file
delete_file
shell_command
network_call
remote_execution
```

### 6.3 Tool Permissions Matrix

> Current scope: the first eight read-only tools plus `patch_propose`, `patch_apply`, `rollback_checkpoint`, and `test_runner` are registered in `Muse.Tool.Registry`. `patch_propose` is available to Coding Muse after plan approval. `patch_apply` and `rollback_checkpoint` require approved-plan/approved-patch or checkpoint context. `test_runner` is Testing-Muse-only and preset-limited. Generic write/shell/network/remote tools remain blocked.

| Tool | Planning Muse (before approval) | Coding Muse (after plan approval) | Patch approval required | Notes |
|---|:---:|:---:|:---:|---|
| `list_files` | ✅ allow | ✅ allow | no | Workspace only |
| `read_file` | ✅ allow | ✅ allow | no | Secret policy enforced |
| `repo_search` | ✅ allow | ✅ allow | no | Output limits required |
| `git_status` | ✅ allow | ✅ allow | no | Read-only |
| `git_diff_readonly` | ✅ allow | ✅ allow | no | Read-only |
| `ask_user_question` | ✅ allow | ✅ allow | no | Non-blocking (see §6.4) |
| `list_muses` | ✅ allow | ✅ allow | no | Product discovery |
| `list_skills` | ✅ allow | ✅ allow | no | Optional later |
| `patch_propose` | 🚫 block | ✅ allow after approved plan | no | Generates/stores diff only |
| `patch_apply` | 🚫 block | ✅ allow only after patch approval | yes | Checkpoint first |
| `write_file` | 🚫 block | 🚫 block | n/a | Prefer patch workflow; not registered |
| `replace_in_file` | 🚫 block | 🚫 block | n/a | Prefer patch workflow; not registered |
| `delete_file` | 🚫 block | 🚫 block | explicit future approval | High risk; hard-denied |
| `rollback_checkpoint` | 🚫 block | ✅ with approved plan/checkpoint context | restore checkpoint approval/context | Checkpoint-scoped rollback |
| `test_runner` | 🚫 block | 🚫 block | preset policy | Testing Muse only; no arbitrary shell |
| `shell_command` | 🚫 block | 🚫 block | future | Hard-denied |
| `network_call` | 🚫 block | 🚫 block | future | Hard-denied |
| `remote_execution` | 🚫 block | 🚫 block | future | Implement late |

### 6.4 Read-Only Tool Schemas and Behavior

#### `list_files`

**Input:**

```json
{
  "path": ".",
  "max_entries": 200,
  "allow_hidden": false
}
```

**Output:**

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

**Key behavioral notes:** Workspace-relative paths only. Enforce `max_entries` cap. Hidden files require explicit opt-in.

---

#### `read_file`

**Input:**

```json
{
  "path": "lib/muse.ex",
  "start_line": 1,
  "max_lines": 200,
  "end_line": null
}
```

**Output:**

```json
{
  "path": "lib/muse.ex",
  "start_line": 1,
  "end_line": 80,
  "content": "...",
  "truncated": false
}
```

**Key behavioral notes:** Block binary files. Enforce line/byte caps. Secret policy enforced on paths.

---

#### `repo_search`

**Input:**

```json
{
  "pattern": "def submit",
  "file_pattern": "*.ex",
  "max_results": 50
}
```

**Implementation priority:**

1. **Pure Elixir scanner is mandatory** — always available as the baseline
2. A controlled `rg` backend may be used first **only when** explicitly enabled/configured, found via `System.find_executable/1`, invoked with an argument list (not shell interpolation), constrained to the workspace, capped by timeout/output limits, and treated as read-only tool execution
3. Fall back in this order: configured `rg` → configured `grep` → pure Elixir scanner
4. The tool **must report which backend was used**

---

#### `git_status`

**Input:**

```json
{}
```

**Output:**

```json
{
  "branch": "main",
  "clean": false,
  "files": []
}
```

**Key behavioral notes:** Uses `System.cmd("git", ["status", "--short"], cd: workspace)` internally — arguments are fixed, model cannot choose shell input.

---

#### `git_diff_readonly`

**Input:**

```json
{
  "path": null,
  "cached": false,
  "max_bytes": 50000
}
```

**Output:**

```json
{
  "diff": "...",
  "truncated": false
}
```

**Key behavioral notes:** Read-only git diff. Respects `max_bytes` cap. Truncates if output exceeds limit.

---

#### `ask_user_question`

**Input:**

```json
{
  "question": "Which command parser should be the primary target?",
  "context": "I found two possible entry points for command handling."
}
```

**Output:**

```json
{
  "answered": false,
  "note": "The question has been presented to the user. Await their response before continuing."
}
```

**Key behavioral notes:** This tool does **NOT block the turn**. Instead, it returns immediately with `answered: false`. The question is presented to the user through the CLI/TUI/LiveView. The user's next message is treated as the answer. The tool is only available when the session is in an interactive context (not async/batch).

### 6.5 Tool Runner

#### API

```elixir
Muse.Tool.Runner.run(tool_name, args, context)
```

#### Context Map

```elixir
%{
  session_id: "default",
  turn_id: "turn_...",
  muse_id: :planning,
  workspace: Muse.Workspace.root()
}
```

#### Validation Sequence (9 Steps)

```text
1. Block known dangerous tool names (write/shell/network/delete/remote).
2. Ensure tool is registered.
3. Ensure active Muse is allowed to use it.
4. Enforce requires_approval flag (currently blocks approval-gated tools).
5. Validate required input keys.
6. Ensure workspace is present in context.
7. Handler runs.
8. Output is capped and redacted.
9. Tool events are emitted.
```

#### Events Emitted

```text
:tool_call_started
:tool_call_completed
:tool_call_failed
:tool_call_blocked
```

#### What's Included in Tool Events

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

#### What's NOT Included in Tool Events

Full secret-like file contents. Never include raw file contents from secret-adjacent paths, API keys, tokens, or credentials in events.

### 6.6 OpenAI-Compatible Tool Schema Example

The `read_file` tool schema in OpenAI function format:

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

## 7. Muse Conductor

### 7.1 Responsibilities

The Conductor is responsible for:

```text
Select active Muse
Build prompt bundle
Prepare provider request
Call provider and process streaming events
Run the iterative tool loop when tool calls are emitted
Accumulate assistant text
For Planning Muse: parse structured plan JSON and render plan output
Emit turn-level event specs (:muse_selected, :prompt_prepared, :plan_created, etc.)
Return final result payload to SessionServer
```

### 7.2 Turn Execution Model

**Critical design decision:** The Conductor does NOT run inside the SessionServer GenServer.

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

### 7.3 Run-Turn Flow

Current entrypoint is `Muse.Conductor.run/3`:

```elixir
defmodule Muse.Conductor do
  def run(session, turn, opts \\ []) do
    # 1. select_muse/2
    # 2. Prompt.Assembler.build/4
    # 3. Prompt.ModelPreparer.to_request/3
    # 4. provider stream + optional ToolLoop
    # 5. plan post-processing for Planning Muse
    # 6. return %{session, assistant_text, event_specs, ...}
  end
end
```

### 7.4 Muse Selection and Routing

Current PR09+PR17 behavior:

```text
Conductor.select_muse/2 returns:
  - Coding Muse when session is :idle with an approved plan
  - Planning Muse otherwise
```

- Session statuses `:idle`, `:running`, `:planning`, and `:awaiting_plan_approval`
  without an approved plan are treated as Planning-Muse-applicable.
- **Coding Muse is selected when the session is `:idle` with an approved plan.**
  This enables the patch-proposal path: Coding Muse can call `patch_propose`
  after plan approval.
- Plan approval/rejection is handled by command + `SessionServer` lifecycle APIs,
  not by automatic Conductor handoff.
- Patch approval/rejection is handled by `/approve patch` and `/reject patch`
  commands through `CommandDispatcher` and `SessionServer`.

### 7.5 Tool Loop

#### The 8-Step Loop

```text
1. Build prompt bundle and provider request with visible tool schemas.
2. Provider streams assistant deltas and/or tool-call events.
3. Conductor accumulates tool-call arguments.
4. Tool Runner enforces blocked-tool and role checks.
5. Tool executes, is blocked, or asks for approval.
6. Tool result is appended to the session.
7. Conductor continues provider request with tool output.
8. Loop ends with final assistant response or approval wait state.
```

#### Default Caps

| Cap | Default Value |
|---|---|
| `max_tool_iterations` | 8 |
| `max_tool_calls_per_turn` | 20 |
| `max_total_tool_output_bytes` | 120,000 |
| `max_runtime_per_turn` | 120,000 ms (configurable) |

#### Behavior When Limits Are Hit

1. Feed a synthetic `"max iterations reached"` tool result to the model
2. Allow the model to produce a final summary with partial results
3. Emit event: `:tool_loop_limit_reached` with the limit type and count

#### Error Behavior

| Error | Response |
|---|---|
| Unknown tool name | Safe tool error result |
| Malformed JSON args | Safe tool error result |
| Blocked tool | Tool result explaining it is unavailable due to approval/safety state |
| Provider failure | `:provider_error` and `:turn_failed` events with redacted message |
| Max loop reached | Safe error summary, no crash |

#### Provider Continuation

How tool results are fed back to each provider type:

```text
Fake provider:
  Call provider again with appended tool results.

OpenAI Responses:
  Use function_call_output input items and previous_response_id when available.

Chat Completions:
  Append assistant tool-call message and tool-role messages.
```

### 7.6 Cancellation Semantics

#### The 5-Step Cancellation Flow

```text
1. User sends /cancel or CLI sends an interrupt signal.
2. SessionServer sets turn status to :cancelling.
3. The running TurnRunner checks for cancellation between tool iterations.
4. If cancelled mid-turn:
   - Abort any in-flight HTTP request.
   - Persist partial assistant text with [cancelled] marker.
   - Emit :turn_cancelled event.
   - Do NOT rollback completed read-only tool calls (they have no side effects).
   - Do NOT rollback any write tool calls that completed before cancellation.
5. Session status returns to :idle.
```

#### TurnRunner Cancellation Check Points

The TurnRunner checks cancellation at these points:

- Between provider stream chunks
- Between tool call iterations
- Before starting any write tool

---

## 8. CLI, TUI, LiveView, and External Channel

### 8.1 Commands

#### Canonical Command List (PR09 docs focus)

`lib/muse/commands.ex` is the source of truth for all currently parsed slash commands.

For PR09 planning + approval lifecycle, the key commands are:

```text
/help
/muses
/plan
/plans
/plan history
/plan status
/plan show <id>
/approve plan
/reject plan
/approve patch
/reject patch
/prompt preview
/prompt-preview
/auth status
```

**Potential natural-language aliases:**

```text
proceed    maps only when exactly one pending approval exists
approve    ambiguous unless exactly one pending approval exists
cancel     cancels current turn or rejects current pending request depending on state
```

#### Command Dispatcher Effects

The command dispatcher may return effects:

```elixir
{:refresh, :session}
{:refresh, :runtime}
{:refresh, :events}
{:toast, :info | :success | :warning | :error, message}
{:copy_to_clipboard, text, label}
```

### 8.2 Key Command Outputs

#### `/muses` Output

```text
Available Muses:
- Planning Muse: creates implementation plans after read-only inspection.
- Coding Muse: implements approved plans via patch proposals (routed by Conductor after plan approval).
```

#### `/status` Output

```text
Session: s_123
Workspace: /path/to/project
Status: awaiting_plan_approval
Active Muse: Planning Muse
Pending approval: plan p_456 v1
Provider: fake / fake-planning-model
Last tool: repo_search completed
```

#### `/prompt preview` Output

```text
Prompt preview is redacted.
Active session: default
Active Muse: Planning Muse
Session status: idle
Model: fake-planning-model
Layers: 12
Tools: list_files, read_file, repo_search, git_status, git_diff_readonly, ask_user_question, list_muses, list_skills
Blocked tools: write_file, replace_in_file, delete_file, patch_apply, shell_command, network_call, remote_execution
```

### 8.3 Streaming Event API

#### Core Behavior

```text
- Conductor/provider emits :assistant_delta events.
- State appends/broadcasts each delta.
- SessionServer keeps assistant_buffer per turn.
- At completion, append one final :assistant_message event.
```

#### CLI Behavior

```text
1. CLI starts async submit.
2. CLI subscribes to Muse.State events.
3. CLI prints deltas matching current turn_id.
4. CLI waits for :turn_completed or :turn_failed.
5. If turn.streamed? == true, suppress final full-message reprint.
```

First display:

```text
Planning Muse> <streamed text>
```

#### LiveView Behavior

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

#### TUI Behavior

```text
TUI can initially continue showing event-tab updates.
Add chat-style streaming later if desired.
```

### 8.4 LiveView Panels

Panels/labels to add:

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
Prompt preview panel (developer mode only)
Provider/model status
```

Do not expose raw internal prompt in normal UI.

### 8.5 Optional External Phoenix WebSocket Channel (PR16)

For non-LiveView clients only. LiveView streams through `/live` unchanged.

**Important:** This channel is read-only. It does **not** grant tool, write, shell, or network permissions. Subscribing to the channel cannot invoke `Muse.submit/2`, execute tool calls, write files, run shell commands, or make network requests.

#### Socket and Channel Setup

```text
lib/muse_web/channels/user_socket.ex
lib/muse_web/channels/session_channel.ex
lib/muse_web/external_event_filter.ex
lib/muse_web/external_socket_config.ex
```

- Connect to `ws://host:port/socket` (or `wss://` behind a reverse proxy).
- Join topic `session:<session_id>` — only events for the joined session are forwarded.
- The channel process subscribes to `Muse.State` and forwards matching events.
- Server binds to `127.0.0.1` by default. **Do not expose externally without authentication and reverse-proxy controls.**
- External WS is **disabled by default**; opt-in via `config :muse, :external_ws, enabled: true` or `MUSE_EXTERNAL_WS` env var (accepted values: `true`, `1`, `yes`, `on`).

#### Topic

```text
session:<session_id>
```

A client must join the specific session topic. Only events matching the joined `session_id` are forwarded (exact match; nil session_id events are NOT forwarded).

#### Message Envelope Format

Every event pushed to the WebSocket client uses this envelope:

```json
{
  "id": 123,
  "type": "assistant_delta",
  "session_id": "s_abc123",
  "turn_id": "t_def456",
  "seq": 17,
  "source": "planning_muse",
  "visibility": "user",
  "timestamp": "2025-05-17T12:34:56.789Z",
  "payload": { "text": "..." },
  "muse_id": "planning"
}
```

| Field | Type | Description |
|---|---|---|
| `id` | integer | Event ID (unique within node) |
| `type` | string | Canonical event type |
| `session_id` | string | Session this event belongs to — always matches the joined topic |
| `turn_id` | string \| omitted | Turn identifier, omitted if nil |
| `seq` | integer \| omitted | Monotonic sequence number, omitted if nil |
| `source` | string | Origin (e.g., `planning_muse`, `conductor`, `cli`) |
| `visibility` | string \| omitted | `"user"` for allowed events; omitted if nil |
| `timestamp` | string | ISO 8601 UTC timestamp |
| `payload` | object | Event-specific data (redacted) |
| `muse_id` | string \| omitted | Muse profile identifier, omitted if nil |

#### Filtering Rules

The external channel applies strict filtering before forwarding any event:

```text
1. Session match  — only events for the joined session:<session_id> are forwarded.
2. :internal      — DENIED.  Never forwarded.
3. :sensitive     — DENIED.  Never forwarded.
4. :debug         — DENIED by default.  allow_debug? option exists but channel does not use it.
5. nil visibility — DENIED by default.  Only forwarded if the event type is on an explicit allowlist.
6. :user          — ALLOWED.  Forwarded after payload redaction.
```

**Allowlist for nil-visibility events:**

```text
user_message, assistant_delta, assistant_message,
plan_created, plan_approved, plan_rejected,
approval_requested, approval_approved, approval_rejected,
patch_proposed, patch_approval_requested, patch_approved, patch_rejected,
turn_completed, turn_failed, session_status_changed
```

**Provider/auth/debug denial:** Even if a nil-visibility event type is on the allowlist, it is denied when the source:type combination suggests provider/auth/debug content.

**Payload redaction:** Even for `:user` and allowlisted events, the channel redacts payload fields:

- Data passes through `Muse.EventDisplay.safe_data/1` first.
- Then converted to JSON-safe format with depth limits and struct suppression.
- No auth tokens, provider secrets, API keys, session secrets, or credential values are ever exposed.
- Arbitrary structs replaced with `[struct omitted]`; nested Event structs with `[event omitted]`.

#### Security Properties

- The channel does **not** grant tool, write, shell, or network permissions.
- No auth/provider/session secrets are exposed in any event envelope.
- Server binds to `127.0.0.1` by default.
- Events with `:internal` or `:sensitive` visibility are never forwarded.
- Events with `nil` visibility are denied unless explicitly allowlisted.
- All payloads are redacted/summarized before forwarding.
- See [`docs/security.md`](security.md#13-external-websocket-channel-security-pr16) for the full security rules.

---

## 9. Telemetry

### Telemetry Event Definitions

All telemetry events use `:telemetry.execute/3`. Attach handlers in `Muse.Application` for logging and metrics aggregation. Keep handlers lightweight — delegate heavy work to separate processes.

| Event Name | Measurements | Metadata |
|---|---|---|
| `[:muse, :turn, :start]` | — | `%{session_id, turn_id, muse_id}` |
| `[:muse, :turn, :stop]` | `%{duration_ms}` | `%{session_id, turn_id, status}` |
| `[:muse, :turn, :exception]` | — | `%{session_id, turn_id, kind, reason, stacktrace}` |
| `[:muse, :tool, :start]` | — | `%{session_id, turn_id, tool_name}` |
| `[:muse, :tool, :stop]` | `%{duration_ms}` | `%{session_id, turn_id, tool_name}` |
| `[:muse, :tool, :exception]` | — | `%{session_id, turn_id, tool_name, reason}` |
| `[:muse, :provider, :start]` | — | `%{session_id, turn_id, provider, model}` |
| `[:muse, :provider, :stop]` | `%{duration_ms}` | `%{session_id, turn_id, tokens}` |
| `[:muse, :provider, :error]` | — | `%{session_id, turn_id, error_type}` |
| `[:muse, :session, :created]` | — | `%{session_id, workspace}` |
| `[:muse, :session, :loaded]` | — | `%{session_id}` |
| `[:muse, :approval, :granted]` | — | `%{session_id, kind, id}` |
| `[:muse, :approval, :rejected]` | — | `%{session_id, kind, id}` |

### Implementation Approach

- Use `:telemetry.execute/3` calls throughout the codebase
- Attach handlers in `Muse.Application` for logging and metrics
- Keep handlers lightweight — delegate heavy work to separate processes
- Never include secrets, API keys, or tokens in telemetry metadata

---

## 10. Patch, Checkpoint, Rollback, and Verification

### 10.1 Patch Proposal Policy

`patch_propose` validates:

```text
- Unified diff format.
- Affected paths stay inside workspace.
- Absolute paths are rejected.
- Secret files are not modified.
- Patch size is capped.
- Binary patches are rejected in v1.
- Patch hash is generated (deterministic SHA-256 over canonical diff + binding metadata).
- Patch is persisted and displayed.
```

**Patch proposal scope:** `patch_propose` creates and stores a diff proposal only. No files are written. The session transitions to `:awaiting_patch_approval`. `/approve patch` records the approval decision but does **not** apply the patch, create a checkpoint, or modify any file. `/apply patch` is the separate PR18 application command/tool and requires approved patch context.

**Display format:**

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

### 10.2 Patch Apply Policy

#### Input

```json
{
  "patch_id": "patch_123",
  "patch_hash": "sha256..."
}
```

#### Validation

```text
- Plan is approved.
- Patch is approved.
- Patch hash matches approval.
- Patch was generated/stored in this session.
- Patch version has not changed.
- Affected files still match expected preconditions if possible.
- Affected paths stay inside workspace.
- Delete operations require explicit delete approval.
- Binary patches are rejected in MVP.
- Checkpoint is created before write.
- Patch applies cleanly.
```

#### Implementation Recommendation

```text
Primary: git apply (pass patch through stdin or a temp file under .muse)
Fallback: simple Elixir-based unified diff applier for single-file patches
Keep command fixed; do not let the model choose arguments.
```

### 10.3 Test Runner Policy

#### Allowed Examples

```text
mix test
mix test path/to/test.exs
mix format --check-formatted
```

#### Blocked Examples

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

#### Tool Input

```json
{
  "command": "mix test test/muse/commands_test.exs",
  "reason": "Verify /version command parser and dispatch behavior."
}
```

#### Tool Output

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

#### Safe Commands Config (Later)

```elixir
safe_test_commands = [
  "mix test",
  "mix test test/muse/commands_test.exs"
]
```

#### Bounded Repair

Stop after bounded repair attempts. Failures should produce a repair plan, not uncontrolled edits. Do not enter infinite repair loops.

---

## 11. Approval Flows

### PR09 Implemented Flow: Plan Lifecycle Only

**Lifecycle commands:**

```text
/plan
/plans
/plan history
/plan status
/plan show <id>
/approve plan
/reject plan
```

**PR09 behavior:**

1. Planning Muse creates a structured plan and session enters `:awaiting_plan_approval`.
2. Runtime records an approval binding (`session_id`, `plan_id`, `plan_version`, `plan_hash`, `workspace`).
3. User runs `/approve plan` or `/reject plan`.
4. `Muse.ApprovalGate` validates binding freshness (rejecting stale/mismatched approvals).
5. Session emits auditable lifecycle events and returns to `:idle` when applicable.

### PR09 Safety Guarantees

- Plan approval/rejection is explicit and auditable.
- Stale approval attempts are rejected.
- Lifecycle commands do not apply patches.
- Lifecycle commands do not write files.
- Lifecycle commands do not run shell/network actions.
- Lifecycle commands do not trigger automatic Coding Muse handoff.

### Approval Flows Added After PR17

The following are implemented as separate gates after patch approval:

- Patch apply with checkpoint/rollback (`patch_apply`, `/apply patch`, `/rollback checkpoint <id>`) — PR18.
- Preset-only safe verification through `test_runner` for Testing Muse — PR19.

Generic shell/network approval commands remain future scope; PR19 does not grant arbitrary shell or network execution.

### PR17 Patch Approval Flow

**Lifecycle commands:**

```text
/approve patch
/reject patch
```

**PR17 behavior:**

1. Conductor selects Coding Muse when the session is `:idle` with an approved plan.
2. Coding Muse calls `patch_propose` tool with unified diff.
3. `Muse.Patch` struct is created with deterministic content hash.
4. Session transitions to `:awaiting_patch_approval`; `:patch_proposed` and `:patch_approval_requested` events are emitted.
5. User runs `/approve patch` or `/reject patch`.
6. `Muse.ApprovalGate` validates binding freshness (rejecting stale/mismatched approvals).
7. Session emits auditable lifecycle events (`:patch_approved`/`:patch_rejected`) and returns to `:idle`.

**PR17 safety guarantees:**

- Patch approval/rejection is explicit and auditable.
- Stale approval attempts are rejected via content-bound binding checks.
- Patch approval is lifecycle-only — does **not** apply files, create checkpoints, run shell/network, or trigger automatic execution.
- No file modifications occur before patch approval. After patch approval, `/apply patch` is still required as a separate explicit PR18 command.
