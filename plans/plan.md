# Muse Universal Runtime MVP — Implementation Plan

This file is written for a planning/coding agent that will start implementing the next Muse milestone. It should be placed at the root of the Muse repository as `plan.md` or used as the active implementation brief.

## 0. Mission

Turn Muse from a placeholder CLI/Web shell into a basic universal coding-agent runtime with:

1. session-aware turns,
2. layered internal prompting,
3. streaming events to CLI and LiveView,
4. a provider abstraction,
5. OpenAI-compatible request support,
6. OpenAI native Responses API support,
7. OpenAI/Codex-style auth support,
8. read-only planning tools,
9. an approval-gated Planning Muse,
10. basic development capability through patch proposal first, then patch apply.

The first useful product experience should be:

```text
muse> add a /version command

Planning Muse:
I will inspect the CLI command structure, find the project version source,
create an implementation plan, and wait for approval before changes.

[read-only inspection events stream]

Plan ready:
1. Locate CLI command routing.
2. Add /version handling.
3. Source version from mix.exs.
4. Add tests.
5. Run the relevant test suite.

Approve this plan? [y/N]
```

Do **not** try to implement remote VPS execution, full self-healing, distributed workers, multi-agent swarms, or shell autonomy in this milestone. Build the local runtime loop first.

---

## 1. Current repository facts

The current Muse repo already contains these useful foundations:

```text
lib/muse.ex                         # public Muse.submit/2 placeholder
lib/muse/event.ex                   # immutable event struct
lib/muse/state.ex                   # GenServer event log + Phoenix.PubSub broadcast
lib/muse/application.ex             # runtime supervisor
lib/muse/workspace.ex               # workspace root/path safety foundation
lib/muse/commands.ex                # slash-command parser
lib/muse/command_dispatcher.ex      # shared command dispatch
lib/muse/agent_registry.ex          # placeholder agent registry
lib/muse/agent_runtime.ex           # placeholder runtime connection state
lib/muse_web/live/home_live.ex      # LiveView shell
lib/muse/cli/repl.ex                # CLI REPL
lib/muse/cli/tui.ex                 # ExRatatui TUI
```

Current behavior:

```text
Muse.submit/2
  -> appends :user_message event
  -> claims queued self-healing issues if any
  -> appends placeholder :assistant_message event
  -> returns {:ok, placeholder_text}
```

Current dependency set is intentionally small:

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

Do not add HTTP/WebSocket dependencies until the provider phases. The first phases must pass with the fake provider only.

---

## 2. Implementation contract

Follow these rules while implementing:

1. Work in small PR-sized phases. Do not jump directly to OpenAI networking.
2. Keep all tests deterministic and offline by default.
3. Preserve `Muse.submit/2` as a public API, even if it delegates to a new runtime.
4. Use Muse-first user-facing names: `Planning Muse`, `Coding Muse`, `Muse Conductor`, `Muse Runtime`, `Muse Tools`.
5. Runtime safety must be enforced in Elixir code, not only in prompts.
6. Planning may use read-only tools before approval.
7. File writes require patch approval.
8. Shell commands require explicit approval unless configured as safe read-only commands.
9. Secrets must never appear in prompt previews, logs, events, or crash text.
10. Run `mix format && mix test` after every phase.

When a phase asks for tests, add/update tests in the same phase. Some existing tests currently expect placeholder behavior; migrate them deliberately instead of deleting coverage.

---

## 3. Official API assumptions to respect

Use these assumptions when implementing the OpenAI provider. Verify against docs again before coding network adapters.

1. OpenAI Responses API supports HTTP streaming using `stream=true` over server-sent events.
2. OpenAI Responses API also supports persistent WebSocket mode at `/v1/responses`; the client sends `response.create` and can continue with new input plus `previous_response_id`.
3. Function/tool calling is an app-side loop: define tools, receive tool calls, execute them in Muse, send function-call outputs back, and continue the response.
4. API-key auth is the simplest programmatic OpenAI path.
5. ChatGPT/Codex-style OAuth should be treated as a Codex auth bridge, not hand-rolled OAuth token refresh. If using Codex-managed ChatGPT auth, let Codex refresh its auth cache instead of calling token endpoints directly.
6. `~/.codex/auth.json` contains access tokens and must be treated like a password.

Useful references:

```text
OpenAI streaming responses:
https://developers.openai.com/api/docs/guides/streaming-responses

OpenAI Responses WebSocket mode:
https://developers.openai.com/api/docs/guides/websocket-mode

OpenAI function calling:
https://developers.openai.com/api/docs/guides/function-calling

OpenAI Responses connect reference:
https://developers.openai.com/api/reference/python/resources/responses/methods/connect

Codex auth:
https://developers.openai.com/codex/auth

Codex CI auth guidance:
https://developers.openai.com/codex/auth/ci-cd-auth

Codex config reference:
https://developers.openai.com/codex/config-reference
```

---

## 4. Target architecture

Replace the placeholder submit path with this runtime path:

```text
User input
  ↓
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
Muse.State + PubSub + LiveView + CLI/TUI
```

Module map for the MVP:

```text
lib/muse/session.ex
lib/muse/session_server.ex
lib/muse/session_supervisor.ex
lib/muse/session_store.ex
lib/muse/session_router.ex

lib/muse/conductor.ex
lib/muse/turn.ex
lib/muse/muse_profile.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex

lib/muse/prompt/layer.ex
lib/muse/prompt/bundle.ex
lib/muse/prompt/assembler.ex
lib/muse/prompt/project_rules.ex
lib/muse/prompt/redactor.ex
lib/muse/prompt/debug_preview.ex

lib/muse/llm/message.ex
lib/muse/llm/request.ex
lib/muse/llm/event.ex
lib/muse/llm/response.ex
lib/muse/llm/provider.ex
lib/muse/llm/providers/fake.ex
lib/muse/llm/providers/openai_compatible.ex
lib/muse/llm/transports/http_sse.ex
lib/muse/llm/transports/responses_websocket.ex
lib/muse/llm/openai/responses_mapper.ex
lib/muse/llm/openai/chat_completions_mapper.ex
lib/muse/llm/openai/event_normalizer.ex

lib/muse/config.ex
lib/muse/llm/provider_config.ex
lib/muse/auth/credential.ex
lib/muse/auth/store.ex
lib/muse/auth/api_key.ex
lib/muse/auth/bearer_command.ex
lib/muse/auth/codex_cache.ex
lib/muse/auth/openai_oauth.ex

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

lib/muse/plan.ex
lib/muse/task.ex
lib/muse/approval.ex
lib/muse/approval_gate.ex
lib/muse/patch.ex
lib/muse/checkpoint.ex
```

Add additional specialist Muses only after the Planning Muse and Coding Muse loop is stable.

---

## 5. Data model design

### 5.1 Event model

Current `Muse.Event` has:

```elixir
%Muse.Event{id, timestamp, source, type, data}
```

Extend it in a backwards-compatible way:

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

Keep `Event.new/3` working exactly as before. Add `Event.new/4` or `Event.new/5` for metadata:

```elixir
Event.new(:planning_muse, :assistant_delta, %{text: "..."},
  session_id: session.id,
  turn_id: turn.id,
  seq: 12,
  visibility: :user
)
```

Event visibility values:

```elixir
:user       # safe to show in CLI/LiveView chat
:debug      # safe for event log only
:internal   # persisted but not normally shown
:sensitive  # should not be stored unless redacted first
```

Initial event types:

```text
:user_message
:turn_started
:turn_completed
:turn_failed
:muse_selected
:prompt_bundle_built
:provider_request_started
:provider_stream_started
:assistant_delta
:assistant_message
:tool_call_started
:tool_call_delta
:tool_call_completed
:tool_call_failed
:plan_created
:approval_requested
:approval_granted
:approval_rejected
:patch_proposed
:patch_applied
:checkpoint_created
:auth_status
:provider_error
```

Acceptance:

```text
- Existing Event.new/3 tests still pass.
- Existing State append/subscribe tests still pass.
- New metadata fields default to nil or safe values.
```

### 5.2 Session model

Create:

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
    artifacts: []
  ]
end
```

Statuses:

```text
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
      memory.md
      artifacts/
      checkpoints/
```

For the first implementation, persistence can be simple JSON/JSONL using Jason. Do not introduce Ecto or a database.

### 5.3 Turn model

Create:

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
    result: nil
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

### 5.4 LLM provider data model

Create provider-neutral request structs:

```elixir
defmodule Muse.LLM.Message do
  defstruct [:role, :content, :name, :metadata]
end

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
    :metadata,
    options: %{}
  ]
end

defmodule Muse.LLM.Event do
  defstruct [:type, :text, :tool_call, :raw, :usage, :error]
end

defmodule Muse.LLM.Response do
  defstruct [:id, :text, :tool_calls, :usage, :provider_state, :finish_reason, :raw]
end
```

Provider behavior:

```elixir
defmodule Muse.LLM.Provider do
  @callback stream(Muse.LLM.Request.t(), (Muse.LLM.Event.t() -> :ok)) ::
              {:ok, Muse.LLM.Response.t()} | {:error, term()}
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

### 5.5 Tool data model

Create:

```elixir
defmodule Muse.Tool.Spec do
  defstruct [
    :name,
    :description,
    :input_schema,
    :kind,
    :permission,
    :visibility,
    :module
  ]
end

defmodule Muse.Tool.Call do
  defstruct [
    :id,
    :name,
    :arguments,
    :session_id,
    :turn_id,
    :muse_id,
    :status,
    :requested_at
  ]
end

defmodule Muse.Tool.Result do
  defstruct [:call_id, :status, :output, :error, :metadata]
end
```

Tool permissions:

```text
:read_workspace
:write_workspace
:shell_readonly
:shell_write
:network
:delete
:remote_execution
```

Approval categories:

```text
:always_allowed
:approval_required
:blocked
```

---

## 6. Phase plan

### Phase 0 — Baseline and guardrails

Goal: verify the repo state and prepare the codebase for incremental changes.

Tasks:

```text
1. Run mix format --check-formatted.
2. Run mix test.
3. Record any existing failures before changing code.
4. Add this file as plan.md at repo root.
5. Do not alter behavior yet.
```

Acceptance:

```text
- Baseline test status is known.
- plan.md is committed or available at repo root.
```

---

### Phase 1 — SessionServer and session-scoped events

Goal: route `Muse.submit/2` through a session process while preserving simple synchronous usage.

Create files:

```text
lib/muse/session.ex
lib/muse/session_server.ex
lib/muse/session_supervisor.ex
lib/muse/session_router.ex
lib/muse/session_store.ex
lib/muse/turn.ex
```

Application changes:

```text
- Add Muse.SessionSupervisor to runtime_children/1 after Muse.State.
- Keep tests from auto-starting runtime children unless configured.
- In tests, allow SessionServer to be started manually with a temporary workspace.
```

Public API changes:

```elixir
Muse.submit(source, text)
# still returns {:ok, final_text} | {:error, text}

Muse.submit_async(source, text, opts \\ [])
# returns {:ok, %{session_id: id, turn_id: turn_id}}

Muse.default_session()
# returns or creates a default session for current workspace
```

SessionServer responsibilities:

```text
- Own one Muse.Session struct.
- Accept submit requests.
- Create a Muse.Turn.
- Append :user_message and :turn_started events.
- For now, call a placeholder conductor/fake provider path.
- Append :assistant_message and :turn_completed events.
- Persist session/event/message records through SessionStore.
```

Keep `Muse.submit/2` synchronous by collecting final assistant text. Streaming will be added in Phase 2.

Compatibility strategy:

```text
- Existing Muse.submit/2 tests expecting placeholder text may continue passing if the fake conductor returns the same text.
- Tests that assert exactly 2 events should be updated only when Phase 1 intentionally adds turn lifecycle events.
- Do not remove self-healing queue attachment behavior; move it into SessionServer or Conductor.
```

Tests to add/update:

```text
test/muse/session_test.exs
test/muse/session_server_test.exs
test/muse/session_store_test.exs
test/muse/event_test.exs
test/muse_test.exs
```

Acceptance:

```text
- Muse.submit(:cli, "hello") returns {:ok, text}.
- A default session exists after submit.
- User and assistant messages include session_id and turn_id.
- Event.new/3 still works.
- SessionStore writes JSONL under a temp .muse/sessions path in tests.
- Self-healing queued issues still attach once and transition to :in_progress.
- mix format && mix test passes.
```

---

### Phase 2 — Streaming event API for CLI and LiveView

Goal: make the runtime stream deltas through one canonical event path.

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
- REPL should print deltas as they arrive.
- Avoid printing both every delta and the final full response duplicated.
- A simple first version may print:

  Planning Muse> <streamed text>

  and then only a newline at completion.
```

Recommended CLI implementation:

```text
1. CLI starts async submit.
2. CLI subscribes to Muse.State events.
3. CLI prints deltas matching the current turn_id.
4. CLI waits for :turn_completed or :turn_failed.
```

LiveView behavior:

```text
- HomeLive already subscribes to Muse.State.
- Add streaming assign state, for example:

  streaming_turns: %{
    turn_id => %{role: :assistant, text: "...", source: "Planning Muse"}
  }

- :assistant_delta updates the buffer.
- :assistant_message finalizes and removes the streaming buffer.
- Existing event tab should still show all events.
```

TUI behavior:

```text
- Initially, TUI can continue showing events tab updates.
- Later, add chat-style streaming if desired.
```

Tests:

```text
test/muse/cli/stream_printer_test.exs
test/muse_web/home_live_streaming_test.exs, if LiveView test support is already present
```

Acceptance:

```text
- Fake provider can stream multiple deltas.
- CLI displays deltas during the turn.
- LiveView updates before final response is complete.
- Final assistant message is persisted once.
- No duplicate final text in CLI output.
```

---

### Phase 3 — Muse profiles and internal prompt assembler

Goal: build deterministic prompt bundles before connecting real models.

Create:

```text
lib/muse/muse_profile.ex
lib/muse/muses/planning_muse.ex
lib/muse/muses/coding_muse.ex
lib/muse/prompt/layer.ex
lib/muse/prompt/bundle.ex
lib/muse/prompt/assembler.ex
lib/muse/prompt/project_rules.ex
lib/muse/prompt/redactor.ex
lib/muse/prompt/debug_preview.ex
```

Muse profile structure:

```elixir
defmodule Muse.MuseProfile do
  defstruct [
    :id,
    :display_name,
    :role,
    :prompt,
    :tools,
    :permissions,
    :output_schema,
    :default_model,
    :handoff_targets,
    style: %{}
  ]
end
```

Planning Muse:

```text
Display name: Planning Muse
Role: planning
Allowed tools:
- list_files
- read_file
- repo_search
- git_status
- git_diff_readonly
- ask_user_question, optional later
Permissions:
- read: true
- write: false
- shell: false
- network: false
- can_create_plan: true
- can_execute_plan: false
```

Coding Muse:

```text
Display name: Coding Muse
Role: coding
Allowed tools:
- list_files
- read_file
- repo_search
- git_status
- git_diff_readonly
- patch_propose
- patch_apply, approval required later
- test_runner, approval required later
Permissions:
- read: true
- write: approval_required
- shell: approval_required
- network: false
- can_create_plan: false
- can_execute_plan: true
```

Prompt layer order:

```text
1. Muse core runtime rules
2. Active session state
3. Selected Muse profile prompt
4. Workspace safety policy
5. Approval policy
6. Tool policy
7. Provider/model requirements
8. Global user rules, if configured
9. Project MUSE.md / AGENTS.md rules
10. Session memory
11. Active plan/task state
12. Recent conversation history
13. Current user message
```

Prompt bundle:

```elixir
defmodule Muse.Prompt.Bundle do
  defstruct [
    :id,
    :session_id,
    :turn_id,
    :muse_id,
    :layers,
    :messages,
    :tools,
    :token_estimate,
    :created_at,
    metadata: %{}
  ]
end
```

Project rule loading:

```text
- Load MUSE.md if present.
- Load AGENTS.md if present.
- Consider .muse/rules.md later.
- Project rules are lower priority than Muse core safety rules.
- Redact secrets before debug preview.
```

Commands to add:

```text
/muses          # list available Muses
/status         # current session/provider/runtime status
/prompt preview # redacted prompt stack preview
/tools          # tools visible to current Muse
```

Command parser updates:

```text
lib/muse/commands.ex
lib/muse/command_dispatcher.ex
lib/muse_web/console_command.ex, if needed
```

Tests:

```text
test/muse/muse_profile_test.exs
test/muse/muses/planning_muse_test.exs
test/muse/prompt/assembler_test.exs
test/muse/prompt/project_rules_test.exs
test/muse/prompt/redactor_test.exs
test/muse/commands_test.exs
test/muse/command_dispatcher_test.exs
```

Acceptance:

```text
- /muses shows Planning Muse and Coding Muse.
- /prompt preview shows layer IDs, layer order, token estimates, selected Muse, available tools, blocked tools.
- /prompt preview never shows env vars, API keys, bearer tokens, SSH keys, .env values, or Codex auth tokens.
- Prompt assembly is deterministic in tests.
```

---

### Phase 4 — Provider interface and fake streaming provider

Goal: make model execution pluggable and test the whole streaming/tool loop offline.

Create:

```text
lib/muse/llm/message.ex
lib/muse/llm/request.ex
lib/muse/llm/event.ex
lib/muse/llm/response.ex
lib/muse/llm/provider.ex
lib/muse/llm/providers/fake.ex
```

Fake provider scenarios:

```text
:echo
  Streams "Placeholder response: received ..." for compatibility.

:planning_plan
  Streams a plan-like response and no tool calls.

:read_file_tool_call
  Emits a tool call for read_file with JSON args.

:list_files_then_plan
  Emits list_files, waits for tool result, then emits a plan.

:malformed_tool_call
  Emits invalid tool arguments to test recovery.

:mid_stream_error
  Emits deltas then fails to test error handling.
```

Conductor responsibilities in this phase:

```text
- Select Planning Muse for coding/development requests by default.
- Build prompt bundle.
- Build LLM request.
- Call configured provider.
- Convert provider events into Muse events.
- Accumulate assistant text.
- Return final response.
```

Initial provider selection:

```text
- Use fake provider by default in all environments.
- Allow config/env override later.
```

Tests:

```text
test/muse/llm/provider_test.exs
test/muse/llm/providers/fake_test.exs
test/muse/conductor_test.exs
```

Acceptance:

```text
- Conductor can stream fake provider deltas.
- Provider errors become :provider_error and :turn_failed events.
- The system remains offline in tests.
- Fake provider can produce a deterministic plan response.
```

---

### Phase 5 — Read-only tool layer

Goal: add safe read-only workspace tools and a Tool Runner.

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
```

Tool registry:

```text
- Registry returns all known tool specs.
- Registry can filter by Muse profile and approval state.
- Tool specs expose JSON schemas for providers.
```

Read-only tools:

```text
list_files
  Input: {"path": string?, "max_entries": integer?}
  Output: tree/list with capped entries.

read_file
  Input: {"path": string, "start_line": integer?, "end_line": integer?}
  Output: text, capped by bytes/lines.

repo_search
  Input: {"query": string, "path": string?, "max_results": integer?}
  Output: matching file paths and line snippets.
  Use pure Elixir scanning first. Shell out to ripgrep only later and only if approved/configured.

git_status
  Input: {}
  Output: porcelain-like summary.
  Can use System.cmd("git", ["status", "--short"], cd: workspace) if treated as read-only and allowed.

git_diff_readonly
  Input: {"path": string?}
  Output: capped diff text.
```

Workspace safety:

```text
- Normalize paths.
- Resolve symlinks when possible.
- Block outside-workspace paths.
- Block secret-like files by default:
  .env
  .env.*
  id_rsa
  id_ed25519
  *.pem
  *.key
  ~/.codex/auth.json
  files under .git except safe read-only status/diff usage
- Cap output size.
- Redact obvious secrets in tool output.
```

ApprovalGate initial rules:

```text
Planning Muse:
  list_files/read_file/repo_search/git_status/git_diff_readonly => allowed
  write/patch/shell/network/delete/remote => blocked

Coding Muse before approved plan:
  read-only => allowed
  patch_propose => blocked until plan approved
  patch_apply/test_runner/shell => blocked

Coding Muse after approved plan:
  patch_propose => allowed
  patch_apply => approval_required
  test_runner => approval_required unless command is configured safe
```

Tests:

```text
test/muse/tool/registry_test.exs
test/muse/tool/runner_test.exs
test/muse/tools/list_files_test.exs
test/muse/tools/read_file_test.exs
test/muse/tools/repo_search_test.exs
test/muse/tools/git_status_test.exs
test/muse/approval_gate_test.exs
```

Acceptance:

```text
- Planning Muse can call read-only tools.
- Tool calls emit started/completed/failed events.
- Tool results are persisted in session JSONL.
- Outside-workspace reads are blocked.
- Secret-like files are blocked or redacted.
- Tool output caps are enforced.
```

---

### Phase 6 — Tool-call loop

Goal: connect provider tool calls to Muse tools and feed results back to the provider.

Conductor loop:

```text
1. Build prompt bundle and LLM request with visible tool schemas.
2. Provider streams assistant deltas and/or tool-call events.
3. Conductor accumulates tool-call arguments.
4. Tool Runner checks ApprovalGate.
5. Tool executes or is blocked.
6. Tool result is appended to the session.
7. Conductor continues provider request with tool output.
8. Loop ends with assistant final response or approval wait state.
```

Implementation details:

```text
- Use fake provider first.
- Add a max tool loop count, e.g. 8 per turn.
- Add max runtime per turn, e.g. configurable default 120 seconds.
- Unknown tool names produce a safe tool error result.
- Malformed JSON args produce a safe tool error result.
- Blocked tools produce a tool result that tells the model the tool is unavailable due to approval/safety state.
```

Provider continuation model:

```text
For fake provider:
  Call provider again with appended tool results.

For OpenAI Responses later:
  Use function_call_output input items and previous_response_id when available.

For Chat Completions later:
  Append tool role messages.
```

Tests:

```text
test/muse/conductor_tool_loop_test.exs
test/muse/llm/providers/fake_tool_loop_test.exs
```

Acceptance:

```text
- Fake provider can request list_files and receive results.
- Fake provider can request read_file and receive results.
- Conductor emits a final plan response after tool inspection.
- Malformed tool calls do not crash the session.
- Tool-loop max prevents infinite loops.
```

---

### Phase 7 — Planning Muse MVP

Goal: create approval-gated plans from read-only inspection.

Create:

```text
lib/muse/plan.ex
lib/muse/task.ex
lib/muse/approval.ex
lib/muse/approval_gate.ex
```

Plan struct:

```elixir
defmodule Muse.Plan do
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
    steps: [],
    risks: [],
    files_expected: [],
    commands_expected: [],
    approvals: []
  ]
end
```

Plan statuses:

```text
:draft
:awaiting_approval
:approved
:rejected
:executing
:completed
:cancelled
```

Planning Muse output format:

```text
OBJECTIVE
What the user wants.

PROJECT ANALYSIS
What files/modules were inspected and what was found.

EXECUTION PLAN
Numbered implementation steps.

RISKS & CONSIDERATIONS
Potential breakages, tests, compatibility risks.

APPROVAL REQUEST
Ask user to approve this specific plan version.
```

Commands:

```text
/plan                # show active plan
/approve plan        # approve exactly one pending active plan
/reject plan         # reject active plan
/status              # show session and approval state
```

Approval handling:

```text
- Approval must bind to session_id + plan_id + version.
- "proceed" can be treated as /approve plan only when exactly one plan is pending.
- If no plan is pending, "proceed" should not do anything destructive.
- If multiple approvals are pending, ask the user to choose.
```

Tests:

```text
test/muse/plan_test.exs
test/muse/approval_test.exs
test/muse/approval_gate_test.exs
test/muse/command_dispatcher_approval_test.exs
test/muse/conductor_planning_test.exs
```

Acceptance:

```text
- A coding request selects Planning Muse by default.
- Planning Muse can inspect files with read-only tools.
- Planning Muse creates a plan and session status becomes :awaiting_plan_approval.
- /approve plan marks the correct plan version approved.
- /reject plan marks it rejected.
- Plan survives process restart through SessionStore.
```

---

### Phase 8 — Provider config and OpenAI-compatible request layer

Goal: configure providers without making real network calls yet.

Create:

```text
lib/muse/config.ex
lib/muse/llm/provider_config.ex
lib/muse/llm/providers/openai_compatible.ex
lib/muse/llm/openai/responses_mapper.ex
lib/muse/llm/openai/chat_completions_mapper.ex
```

Config locations:

```text
1. Environment variables
2. Workspace .muse/config.toml, if implemented
3. User config ~/.muse/config.toml, optional later
4. Application env defaults
```

Do not add TOML parsing until needed. A simple Elixir config map + env support is acceptable first. If TOML is added, use a small maintained parser and test it thoroughly.

Provider config struct:

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
    timeout_ms: 120_000,
    max_retries: 2
  ]
end
```

Provider examples:

```elixir
%ProviderConfig{
  id: "openai",
  name: "OpenAI",
  base_url: "https://api.openai.com/v1",
  wire_api: :responses,
  transport: :sse,
  auth: :openai,
  env_key: "OPENAI_API_KEY",
  supports_streaming: true,
  supports_websockets: true,
  supports_tools: true
}

%ProviderConfig{
  id: "openrouter",
  name: "OpenRouter",
  base_url: "https://openrouter.ai/api/v1",
  wire_api: :chat_completions,
  transport: :sse,
  auth: :api_key,
  env_key: "OPENROUTER_API_KEY",
  supports_streaming: true,
  supports_websockets: false,
  supports_tools: true
}

%ProviderConfig{
  id: "ollama",
  name: "Ollama",
  base_url: "http://localhost:11434/v1",
  wire_api: :chat_completions,
  transport: :sse,
  auth: :none,
  supports_streaming: true,
  supports_websockets: false,
  supports_tools: false
}
```

Wire APIs:

```text
:responses
  OpenAI native Responses API.

:chat_completions
  OpenAI-compatible fallback for routers/local providers.
```

Transports:

```text
:none
  fake provider/no network

:sse
  HTTP server-sent events

:websocket
  OpenAI Responses WebSocket
```

Add request snapshot tests:

```text
- Build Responses request JSON from a prompt bundle.
- Build Chat Completions request JSON from the same prompt bundle.
- Include tool schemas.
- Exclude secrets from snapshots.
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
- Provider configs validate required fields.
- OpenAI-compatible request JSON can be produced without sending network calls.
- Responses and Chat Completions mappers handle messages and tools.
- Invalid config returns clear errors.
```

---

### Phase 9 — Auth layer: API key first, Codex/OpenAI OAuth bridge second

Goal: separate credentials from providers and support OpenAI auth safely.

Create:

```text
lib/muse/auth/credential.ex
lib/muse/auth/store.ex
lib/muse/auth/api_key.ex
lib/muse/auth/bearer_command.ex
lib/muse/auth/codex_cache.ex
lib/muse/auth/openai_oauth.ex
```

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

No OPENAI_API_KEY, Codex auth cache present and config allows it:
  Use Codex-managed access token, redacted in logs.

/auth login openai:
  Prefer shelling out to codex login if codex is installed.
  Do not manually invent refresh endpoints.

/auth login openai --device:
  Prefer codex login --device-auth if codex is installed.
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

Credential return shape:

```elixir
%Muse.Auth.Credential{
  type: :bearer,
  value: "...",
  source: :env | :codex_cache | :command,
  expires_at: nil,
  redacted: "sk-...REDACTED"
}
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
- OPENAI_API_KEY auth works in unit tests with fake value.
- Codex cache parser can detect auth_mode and token presence using fixture files.
- /auth status shows auth mode and source, not token values.
- Provider request headers are redacted in logs/events.
- 401 refresh behavior is planned but can wait for real OpenAI provider phase.
```

---

### Phase 10 — OpenAI-compatible SSE provider

Goal: implement real HTTP streaming provider after the fake runtime is stable.

Add dependencies only in this phase:

```text
- Add a maintained HTTP client that supports streaming responses.
- Prefer a small dependency such as Req if compatible with the project.
- Do not add WebSocket dependency yet.
```

Create:

```text
lib/muse/llm/transports/http_sse.ex
lib/muse/llm/openai/event_normalizer.ex
```

SSE transport responsibilities:

```text
- POST request to configured base_url endpoint.
- Add Authorization header from Auth layer.
- Add stream=true for supported wire APIs.
- Parse SSE data frames incrementally.
- Decode JSON events.
- Normalize provider events into Muse.LLM.Event.
- Redact errors before event/log output.
```

Responses API path:

```text
POST {base_url}/responses
```

Responses request shape:

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

Chat Completions path:

```text
POST {base_url}/chat/completions
```

Chat Completions request shape:

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

Normalizing rules:

```text
- Text deltas become :assistant_delta.
- Function/tool-call argument deltas become :tool_call_delta.
- Completed tool calls become :tool_call_completed.
- Usage info is stored if available.
- Unknown provider events become debug events, not crashes.
```

Testing strategy:

```text
- Unit test event normalization with fixture JSON.
- Unit test SSE parser with chunked strings.
- Do not call OpenAI in normal test suite.
- Optional integration test behind MUSE_OPENAI_TEST=1.
```

Tests:

```text
test/muse/llm/transports/http_sse_test.exs
test/muse/llm/openai/event_normalizer_test.exs
test/muse/llm/providers/openai_compatible_test.exs
```

Acceptance:

```text
- SSE parser handles split chunks.
- OpenAI Responses streaming fixtures normalize correctly.
- Chat Completions streaming fixtures normalize correctly.
- Provider can be configured but remains fake by default.
- No secrets in failed request output.
```

---

### Phase 11 — OpenAI Responses WebSocket provider

Goal: add persistent WebSocket transport for long tool-call-heavy workflows.

Add dependency only in this phase:

```text
- Add a maintained WebSocket client dependency.
- Candidate choices: WebSockex or Mint/WebSocket.
- Pick one after checking compatibility with current Elixir/OTP and project style.
```

Create:

```text
lib/muse/llm/transports/responses_websocket.ex
lib/muse/llm/transports/responses_ws_connection.ex
```

WebSocket responsibilities:

```text
- Connect to wss://api.openai.com/v1/responses or configured equivalent.
- Send Authorization bearer header.
- Send response.create events.
- Receive response stream events.
- Maintain previous_response_id in session.provider_state.
- Continue turns with incremental input plus previous_response_id.
- Enforce one in-flight response per connection unless docs/client support says otherwise.
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
- Never silently duplicate tool side effects. For read-only tool loops, retry is safer; for write tools, require user confirmation.
```

Tests:

```text
test/muse/llm/transports/responses_websocket_test.exs
test/muse/llm/transports/responses_ws_connection_test.exs
```

Acceptance:

```text
- WebSocket messages can be encoded/decoded in unit tests.
- previous_response_id persists in session.provider_state.
- WebSocket provider normalizes text and tool events to the same Muse.LLM.Event types as SSE.
- SSE fallback is explicit and observable in events.
```

---

### Phase 12 — Optional external Muse WebSocket channel

Goal: provide an external WebSocket event feed for non-LiveView clients.

Important: LiveView already streams through Phoenix’s socket. This phase is for external clients only.

Create:

```text
lib/muse_web/channels/user_socket.ex
lib/muse_web/channels/session_channel.ex
```

Router/Endpoint changes:

```text
- Add socket "/socket", MuseWeb.UserSocket.
- Allow topic session:<session_id>.
- Subscribe channel process to Muse.State and forward matching events.
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

Security:

```text
- Bind web server to 127.0.0.1 by default.
- Do not expose channel externally without auth.
- Add token auth later if needed.
```

Tests:

```text
test/muse_web/channels/session_channel_test.exs
```

Acceptance:

```text
- External clients can subscribe to a session topic.
- Only events for that session are forwarded.
- Sensitive/internal events are not forwarded by default.
```

---

### Phase 13 — Basic development capability: patch proposal

Goal: after plan approval, Coding Muse can inspect files and propose a patch, but not apply it yet.

Create:

```text
lib/muse/patch.ex
lib/muse/tools/patch_propose.ex
```

Patch struct:

```elixir
defmodule Muse.Patch do
  defstruct [
    :id,
    :session_id,
    :plan_id,
    :status,
    :summary,
    :diff,
    :created_by,
    :created_at,
    files: []
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

Flow:

```text
1. User approves plan.
2. Session status becomes :executing.
3. Conductor selects Coding Muse.
4. Coding Muse reads approved plan and relevant files.
5. Coding Muse emits patch proposal.
6. Muse stores patch and asks for approval.
7. No files are changed.
```

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

Tests:

```text
test/muse/patch_test.exs
test/muse/tools/patch_propose_test.exs
test/muse/conductor_coding_test.exs
```

Acceptance:

```text
- Coding Muse cannot run before plan approval.
- Coding Muse can propose a patch after plan approval.
- Patch proposal is visible in CLI and LiveView.
- No file content changes occur in this phase.
```

---

### Phase 14 — Patch apply with checkpoints

Goal: apply approved patches safely.

Create:

```text
lib/muse/checkpoint.ex
lib/muse/tools/patch_apply.ex
```

Checkpoint behavior:

```text
- Before applying patch, create checkpoint metadata.
- Save original file contents for files that will change.
- Store checkpoint under .muse/sessions/<session_id>/checkpoints/<checkpoint_id>/.
- Apply unified diff only after patch approval.
- Emit checkpoint_created and patch_applied events.
```

Patch apply rules:

```text
- Only apply patches generated/stored in this session.
- Only apply approved patch version.
- Reject patches that target outside-workspace paths.
- Reject delete operations until explicit delete approval exists.
- Reject binary patches for MVP.
```

Commands:

```text
/checkpoints
/restore <checkpoint_id>
```

Restoration can be implemented later, but checkpoint creation should exist before patch apply.

Tests:

```text
test/muse/checkpoint_test.exs
test/muse/tools/patch_apply_test.exs
```

Acceptance:

```text
- Approved patch applies to temp workspace in tests.
- Checkpoint contains original file contents.
- Unapproved patch cannot apply.
- Outside-workspace patch cannot apply.
- mix format && mix test passes after patch operations.
```

---

### Phase 15 — Test runner and review loop

Goal: let Coding Muse request verification in a controlled way.

Create:

```text
lib/muse/tools/test_runner.ex
lib/muse/muses/reviewing_muse.ex
lib/muse/muses/testing_muse.ex
```

Safe commands config:

```text
.muse/config.toml or application env later:

safe_test_commands = [
  "mix test",
  "mix test test/muse/commands_test.exs"
]
```

Initial rule:

```text
- Do not auto-run arbitrary shell commands.
- Allow configured safe test commands.
- Otherwise create :approval_requested with category :shell.
```

Flow:

```text
1. Patch applied.
2. Testing Muse requests configured test command.
3. ApprovalGate allows or asks user.
4. Test output is capped and summarized.
5. Reviewing Muse may inspect diff/test output and produce final summary.
```

Tests:

```text
test/muse/tools/test_runner_test.exs
test/muse/conductor_verification_test.exs
```

Acceptance:

```text
- Safe configured test command can run in temp workspace.
- Unsafe command asks for approval.
- Test output is capped.
- Final response summarizes changes and verification.
```

---

## 7. How to choose the active Muse

Initial heuristic in `Muse.Conductor`:

```text
If session.status == :awaiting_plan_approval:
  handle approval commands or explain pending approval.

If user input is /approve plan or equivalent and one plan is pending:
  approve plan and hand off to Coding Muse.

If session has approved plan but no patch proposed:
  Coding Muse.

If session has patch awaiting approval:
  handle patch approval/rejection.

If user asks for code changes and no active plan:
  Planning Muse.

If user asks a general question:
  Planning Muse for MVP, or generic Muse later.
```

Do not build a large classifier yet. Add a simple deterministic router and test it.

---

## 8. Internal prompts

### 8.1 Core runtime prompt

Use this as the core Muse rule layer:

```text
You are running inside Muse, a local coding-agent runtime.
You must follow the active Muse role, available tools, and approval state.
Do not claim to inspect files unless you used tools or were given file content.
Do not modify files, run shell commands, access the network, delete files, or perform remote execution unless the tool is available and approval state allows it.
When a task requires code changes, first inspect the project with read-only tools, then produce an implementation plan and wait for approval.
Keep user-visible output clear and concise.
When creating a plan, include objective, project analysis, execution steps, risks, and approval request.
```

### 8.2 Planning Muse prompt

```text
You are Planning Muse.
Your job is to understand coding requests, inspect the workspace with read-only tools, and create implementation plans.

Allowed before approval:
- list_files
- read_file
- repo_search
- git_status
- git_diff_readonly

Blocked before approval:
- file writes
- patch apply
- shell commands with side effects
- package installation
- network calls
- remote execution
- implementation handoff

Planning process:
1. Restate the objective.
2. Inspect relevant project structure with read-only tools.
3. Read likely files before making assumptions.
4. Identify dependencies and tests.
5. Produce a numbered execution plan.
6. List risks and alternatives when relevant.
7. Ask for approval of the specific plan.

Output sections:
OBJECTIVE
PROJECT ANALYSIS
EXECUTION PLAN
RISKS & CONSIDERATIONS
APPROVAL REQUEST
```

### 8.3 Coding Muse prompt

```text
You are Coding Muse.
Your job is to implement an approved Muse Plan safely.

Rules:
- Only work from an approved plan.
- Inspect files before proposing changes.
- Keep patches focused and minimal.
- Propose patches before applying them.
- Do not apply patches until patch approval exists.
- Do not run arbitrary shell commands unless approval or safe-command config allows it.
- After changes, request or run verification according to approval policy.

Output sections:
IMPLEMENTATION SUMMARY
FILES INSPECTED
PATCH PROPOSAL or CHANGES MADE
VERIFICATION
NEXT STEP
```

---

## 9. Commands to add or update

Add to `Muse.Commands`:

```text
/muses
/status
/prompt preview
/tools
/plan
/approve plan
/reject plan
/patch
/approve patch
/reject patch
/auth status
/auth login openai
/auth login openai --device
/auth logout openai
/checkpoints
```

Potential aliases:

```text
proceed       # only maps to /approve plan or /approve patch when exactly one pending approval exists
approve       # ambiguous unless exactly one pending approval exists
cancel        # cancel current turn or reject current pending request, depending on state
```

Update `Muse.CommandDispatcher` to return effects where useful:

```text
{:refresh, :session}
{:refresh, :runtime}
{:refresh, :events}
{:toast, :info | :success | :warning | :error, message}
{:copy_to_clipboard, text, label}
```

---

## 10. Testing strategy

### 10.1 No-network default

Normal test suite must not call OpenAI or other providers.

```text
mix test
```

Optional external tests:

```text
MUSE_OPENAI_TEST=1 OPENAI_API_KEY=... mix test --only external
```

### 10.2 Fixture types

Add fixtures for:

```text
- OpenAI Responses SSE text delta stream
- OpenAI Responses function-call stream
- Chat Completions text delta stream
- Chat Completions tool-call stream
- Codex auth.json with token values redacted/fake
- Malformed provider events
```

### 10.3 Must-have invariants

Add tests for these invariants:

```text
- Prompt preview redacts secrets.
- Planning Muse cannot write.
- Coding Muse cannot patch before plan approval.
- Patch apply cannot happen before patch approval.
- Tool paths cannot escape workspace through ../.
- Tool paths cannot escape workspace through symlinks.
- Tool outputs are capped.
- Provider errors do not crash SessionServer.
- Unknown provider events are ignored or logged as debug.
- Existing State PubSub behavior remains stable.
```

---

## 11. Security checklist

Before shipping the MVP:

```text
[ ] No API keys in events.
[ ] No bearer tokens in logs.
[ ] No Codex auth tokens in prompt preview.
[ ] Secret-like files blocked or redacted.
[ ] Workspace path checks are symlink-aware.
[ ] Patch apply blocks outside-workspace paths.
[ ] Shell commands are approval-gated.
[ ] Network calls are approval-gated or disabled.
[ ] Web server defaults to localhost.
[ ] External WebSocket channel does not forward internal/sensitive events.
[ ] Provider request debug snapshots redact Authorization headers.
```

---

## 12. Definition of done for the first MVP

The first MVP is complete when all of this works:

```text
1. User enters a coding request in CLI or LiveView.
2. Muse creates/uses a session.
3. Muse selects Planning Muse.
4. Prompt Assembler builds a layered prompt bundle.
5. Fake provider or configured OpenAI provider streams output.
6. Planning Muse uses read-only tools.
7. Muse shows streaming deltas in CLI and LiveView.
8. Muse creates a structured plan.
9. Muse asks for plan approval.
10. /approve plan changes approval state.
11. Coding Muse proposes a patch.
12. Muse asks for patch approval.
13. /approve patch creates checkpoint and applies patch.
14. Optional safe tests run or ask for shell approval.
15. Final summary is shown.
16. Session, events, tool calls, plans, approvals, and checkpoint metadata persist under .muse/sessions.
```

OpenAI-specific done criteria:

```text
1. OPENAI_API_KEY auth can stream a Responses API answer over SSE.
2. OpenAI-compatible Chat Completions provider can stream text from a compatible endpoint.
3. OpenAI Responses WebSocket can connect, send response.create, receive text deltas, and store previous_response_id.
4. Tool-call events from OpenAI normalize into the same Conductor loop as fake provider events.
5. Codex auth cache can be detected and used only when explicitly configured.
6. OAuth/token material is never logged or shown.
```

---

## 13. Recommended PR order

```text
PR 01  Add plan.md, baseline checks, Event metadata extension
PR 02  SessionServer, SessionSupervisor, SessionStore, Turn
PR 03  Streaming event API and CLI/LiveView streaming display
PR 04  Muse profiles and Prompt Assembler
PR 05  Fake streaming provider and Conductor basic loop
PR 06  Read-only Tool Registry and Tool Runner
PR 07  Tool-call loop with fake provider
PR 08  Planning Muse MVP and plan approval commands
PR 09  Provider config and request JSON mappers
PR 10  Auth layer: API key, bearer command, Codex cache bridge
PR 11  OpenAI-compatible SSE provider
PR 12  OpenAI Responses WebSocket provider
PR 13  Optional Phoenix SessionChannel for external WS clients
PR 14  Coding Muse patch proposal
PR 15  Patch apply and checkpoints
PR 16  Test runner and review loop
```

Do not merge PR 11+ until PR 01–08 are stable with fake provider.

---

## 14. First task for the implementing agent

Start with PR 01 and PR 02 only.

Concrete first steps:

```text
1. Run mix test and record baseline.
2. Extend Muse.Event with optional metadata fields while keeping Event.new/3 passing.
3. Add Event.new/4 with metadata opts.
4. Add Muse.Session struct.
5. Add Muse.Turn struct.
6. Add Muse.SessionStore with JSON/JSONL write/read functions using temp workspaces in tests.
7. Add Muse.SessionServer that can handle a submit with fake placeholder response.
8. Add Muse.SessionSupervisor and Muse.SessionRouter.
9. Change Muse.submit/2 to delegate to the default session path.
10. Preserve self-healing issue attachment behavior.
11. Update tests intentionally.
12. Run mix format && mix test.
```

Expected first PR result:

```text
Muse still appears to behave simply from the CLI, but internally every submit now has session_id, turn_id, lifecycle events, and persistence. No real model calls yet.
```

---

## 15. Do not implement yet

These are explicitly out of scope until the local runtime loop is solid:

```text
- Remote VPS execution
- SSH control
- Remote agent sessions
- Nano repair mode
- Autonomous shell loops
- MCP servers
- Multi-agent delegation/swarm behavior
- Browser automation
- Package installation
- Network search
- Database persistence
- Cloud sync
```

