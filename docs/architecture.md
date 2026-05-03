# Muse Universal Runtime — Architecture Document

> **Companion docs:** [Prompts](prompts.md) · [Provider Roadmap](provider-roadmap.md) · [Testing](testing.md) · [Security](security.md) · [Executive Summary](../PLAN.md)
>
> **Canonical source:** Runtime process architecture, module map, data models, normalized event types, Conductor behavior, tool system, streaming API, telemetry, approvals, patch/checkpoint/rollback behavior.

---

## Table of Contents

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
  → Muse.Tool.Runner
  → Muse.ApprovalGate
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

- Synchronous calls: `submit`, `approve`, `reject`, `status`, `cancel`
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
| `:verifying` | Testing Muse is running verification |
| `:reviewing` | Reviewing Muse is reviewing changes |
| `:repairing` | Restoration Muse is recovering from failure |
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

#### Suggested Structured Plan JSON Schema

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
- objective is present
- tasks is non-empty
- each task has title and description
- requires_write is boolean
- requires_shell is boolean
- risks is a list
```

---

### 3.9 Approval Model

#### Muse.Approval Struct

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

#### Approval Kinds/Types

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

#### Plan Approval Bindings

Plan approvals bind to:

```text
session_id
plan_id
plan_version
workspace
approved_by
approved_at
approval_scope
```

If a plan version changes, old approvals are **invalid**.

#### Patch Approval Bindings

Patch approvals bind to:

```text
session_id
plan_id
plan_version
patch_id
patch_hash
affected files
workspace
```

If a patch hash changes, old patch approvals are **invalid**.

#### ApprovalGate API

```elixir
defmodule Muse.ApprovalGate do
  @doc "Check if a tool call is allowed under current session approval state."
  def allowed?(session, tool_call) do
    # returns {:ok, :allowed} or {:blocked, reason}
  end

  @doc "Store an approval request and emit an event."
  def request_approval(session, approval_request) do
    # stores approval request and emits event
  end

  @doc "Mark an approval as accepted and emit an event."
  def approve(session, approval_id, approver) do
    # marks approval accepted and emits event
  end

  @doc "Mark an approval as rejected and emit an event."
  def reject(session, approval_id, approver) do
    # marks approval rejected and emits event
  end
end
```

#### Runtime Enforcement Pattern

Every tool execution path enforces the approval gate:

```elixir
case Muse.ApprovalGate.allowed?(session, tool_call) do
  {:ok, :allowed} -> run_tool()
  {:blocked, reason} -> block_tool(reason)
end
```

Prompt text is guidance, not a security boundary. Runtime safety is always enforced in Elixir code.

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

#### Patch Statuses

| Status | Meaning |
|---|---|
| `:proposed` | Patch has been generated but not yet submitted for approval |
| `:awaiting_approval` | Patch is waiting for user approval |
| `:approved` | Patch has been approved by the user |
| `:applied` | Patch has been applied to the workspace |
| `:rejected` | Patch has been rejected by the user |
| `:failed` | Patch failed to apply |

#### Patch Proposal Tool Input (JSON)

```json
{
  "plan_id": "plan_123",
  "summary": "Add /version command.",
  "diff": "diff --git ..."
}
```

#### Patch Proposal Tool Output (JSON)

```json
{
  "patch_id": "patch_123",
  "hash": "sha256...",
  "affected_files": ["lib/muse/commands.ex"],
  "status": "awaiting_approval"
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
lib/muse.ex                  Public API. Delegates submit/resume/approve to SessionServer.
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
lib/muse/muses.ex                   Muse registry and discovery.
lib/muse/muses/planning_muse.ex     Planning Muse profile.
lib/muse/muses/coding_muse.ex       Coding Muse profile.
lib/muse/muses/reviewing_muse.ex    Reviewing Muse profile.
lib/muse/muses/testing_muse.ex      Testing Muse profile.
lib/muse/muses/research_muse.ex     Research Muse profile.
lib/muse/muses/memory_muse.ex       Memory Muse profile.
lib/muse/muses/restoration_muse.ex  Restoration Muse profile.
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
lib/muse/llm/providers/fake.ex      Deterministic fake provider for tests.
lib/muse/llm/providers/openai_compatible.ex   OpenAI-compatible provider.
lib/muse/llm/providers/openai_compatible/encoder.ex   Request encoder.
lib/muse/llm/providers/openai_compatible/decoder.ex   Response decoder.
lib/muse/llm/providers/openai.ex    OpenAI provider.
lib/muse/llm/providers/anthropic.ex Anthropic provider (future).
lib/muse/llm/providers/openrouter.ex OpenRouter provider (future).
lib/muse/llm/providers/ollama.ex    Ollama provider (future).
lib/muse/llm/transports/http_sse.ex HTTP SSE transport.
lib/muse/llm/transports/responses_websocket.ex    Responses WebSocket transport.
lib/muse/llm/transports/responses_ws_connection.ex WebSocket connection handler.
lib/muse/llm/openai/responses_mapper.ex       Responses API request mapper.
lib/muse/llm/openai/chat_completions_mapper.ex Chat Completions request mapper.
lib/muse/llm/openai/event_normalizer.ex       Provider event normalizer.
lib/muse/llm/http_client.ex         Shared HTTP client (req-based).
```

### Config and Auth

```text
lib/muse/config.ex                   Configuration loading and validation.
lib/muse/auth/credential.ex         Credential struct.
lib/muse/auth/store.ex              Auth credential store.
lib/muse/auth/api_key.ex            API key auth.
lib/muse/auth/bearer_command.ex     Bearer token command auth.
lib/muse/auth/codex_cache.ex        Codex auth cache bridge.
lib/muse/auth/openai_oauth.ex       OpenAI OAuth (future).
```

### Tool System

```text
lib/muse/tool/spec.ex               Tool specification struct.
lib/muse/tool/call.ex               Tool call struct.
lib/muse/tool/result.ex             Tool result struct.
lib/muse/tool/runner.ex             Tool execution with validation and approval gating.

lib/muse/tools/list_files.ex
lib/muse/tools/read_file.ex
lib/muse/tools/repo_search.ex
lib/muse/tools/git_status.ex
lib/muse/tools/git_diff_readonly.ex
lib/muse/tools/patch_propose.ex
lib/muse/tools/patch_apply.ex
lib/muse/tools/write_file.ex
lib/muse/tools/replace_in_file.ex
lib/muse/tools/delete_file.ex
lib/muse/tools/test_runner.ex
lib/muse/tools/shell_command.ex
lib/muse/tools/rollback_checkpoint.ex
lib/muse/tools/checkpoint_create.ex
lib/muse/tools/checkpoint_restore.ex
```

### Planning / Approval / Patch / Checkpoint / Memory

```text
lib/muse/plan.ex                    Plan struct definition.
lib/muse/task.ex                    Task struct definition.
lib/muse/plan_schema.ex             Plan JSON schema.
lib/muse/plan_parser.ex            Plan parsing and validation.
lib/muse/approval.ex                Approval struct definition.
lib/muse/approval_gate.ex           Approval enforcement API.
lib/muse/patch.ex                   Patch struct definition.
lib/muse/patch/parser.ex            Patch/diff parsing.
lib/muse/patch/formatter.ex         Patch display formatting.
lib/muse/checkpoint.ex              Checkpoint struct definition.
lib/muse/checkpoint_store.ex        Checkpoint persistence.
lib/muse/memory/compactor.ex        Session memory compaction.
```

### Streaming

```text
lib/muse/streaming.ex               Shared streaming event helpers.
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

### 6.2 Write/Execution Tools (Later)

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

### 6.3 Tool Permissions Matrix

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
| `write_file` | 🚫 block | ⚠️ approval-gated | yes | Prefer patch workflow |
| `replace_in_file` | 🚫 block | ⚠️ approval-gated | yes | Checkpoint first |
| `delete_file` | 🚫 block | ⚠️ explicit delete approval | explicit delete approval | High risk |
| `test_runner` | 🚫 block | ⚠️ conditional | command approval unless configured safe | No arbitrary shell |
| `shell_command` | 🚫 block | ⚠️ conditional | yes | Command allowlist recommended |
| `network_call` | 🚫 block | ⚠️ conditional | yes | Default block |
| `remote_execution` | 🚫 block | 🚫 later only | yes | Implement late |

### 6.4 Read-Only Tool Schemas and Behavior

#### `list_files`

**Input:**

```json
{
  "path": ".",
  "max_entries": 200,
  "include_hidden": false
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
  "query": "def submit",
  "path": ".",
  "max_matches": 50,
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
  approval_state: session.approvals,
  workspace: Muse.Workspace.root()
}
```

#### Validation Sequence (10 Steps)

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

### 7.4 Muse Selection and Routing

Initial deterministic rules based on `session.status`:

```text
If session.status == :awaiting_plan_approval:
  Handle approval commands or explain pending approval.
  Do not run model for destructive behavior.

If user input is /approve plan or equivalent and exactly one plan is pending:
  Approve plan and hand off to Coding Muse.

If user rejects plan:
  Mark plan rejected, update session, stop.

If session has approved plan but no patch proposed:
  Coding Muse.

If session has patch awaiting approval:
  Handle patch approval/rejection.

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

**Code-change heuristic terms** for v1:

```text
add, change, modify, fix, implement, create, update, refactor, write
```

Do not overbuild routing. A simple rule-based router plus optional model fallback is sufficient.

### 7.5 Tool Loop

#### The 8-Step Loop

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

#### Full Canonical Command List with Aliases

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
- Coding Muse: implements approved plans through patches.
- Reviewing Muse: reviews diffs and risks.
- Testing Muse: runs and interprets verification.
- Research Muse: searches the repository and gathers context.
- Memory Muse: summarizes session context.
- Restoration Muse: recovers from failed or unsafe states.
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
Tools: list_files, read_file, repo_search, git_status
Blocked tools: patch_apply, shell_command, delete_file, network_call
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

### 8.5 Optional External Phoenix WebSocket Channel

For non-LiveView clients only. LiveView already streams through Phoenix.

Create later:

```text
lib/muse_web/channels/user_socket.ex
lib/muse_web/channels/session_channel.ex
```

#### Socket and Channel Setup

```text
- Add socket "/socket", MuseWeb.UserSocket.
- Allow topic session:<session_id>.
- Subscribe channel process to Muse.State and forward matching events.
- Bind web server to 127.0.0.1 by default.
- Do not expose externally without auth.
```

#### Message Envelope Format

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

#### Filtering Rules

Sensitive/internal events are **not forwarded** by default. Only events with `visibility: :user` or that are explicitly safe are forwarded to WebSocket clients.

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
- Patch hash is generated.
- Patch is persisted and displayed.
```

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

### Plan Approval

**Commands:**

```text
/plan
/approve plan
/reject plan
/status
```

**Natural language handling:** Natural language approval (e.g., "proceed", "go ahead") can map to plan approval **only when** session state is unambiguous:

- Exactly one pending plan approval exists
- No pending patch or command approval conflicts
- The plan version matches the displayed plan

If no plan is pending, `proceed` must **not** do anything destructive. If multiple approvals are pending, ask the user to choose.

### Patch Approval

**Commands:**

```text
/patch
/approve patch
/reject patch
```

**Patch proposal format:**

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

### Shell/Test Approval

**Commands:**

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

### Restore Approval

**Commands:**

```text
/checkpoints
/restore <checkpoint_id>
/rollback checkpoint <id>
```

**Rollback response example:**

```text
Restoration Muse:
A checkpoint exists from before the last patch.

Restore checkpoint chk_123?
This will revert:
- lib/muse/cli/repl.ex
- test/muse/cli/repl_test.exs

Approve restore? [y/N]
```
