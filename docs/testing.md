# Muse Universal Runtime — Testing Strategy

> **Maxims:** Tests run offline by default. Every provider obeys the same contract. Safety is never optional.
>
> **Canonical source:** Testing strategy and acceptance checks. Provider/event assertions should reference the canonical normalized event types in [`architecture.md`](architecture.md#35-llm-provider-neutral-models).

---

## Developer Onboarding

### Standard Quality Gates

Before submitting any PR, run these commands:

```bash
mix format --check-formatted  # All files must be formatted
mix compile --warnings-as-errors  # Zero warnings allowed
mix test  # Full test suite, runs offline with fake provider
```

All three must pass. CI enforces these gates automatically.

### Runtime Provider Safety

`Muse.RuntimeProvider` routes LiveView submits through the configured
LLM provider in dev/prod. In `MIX_ENV=test` and `MIX_ENV=smoke`, it
always returns empty opts, so the fake provider is used regardless of
`MUSE_*` environment variables. This ensures `mix test` never makes
network calls even if the developer's shell has provider env vars set.

The `RuntimeProvider` test suite explicitly enables runtime provider
resolution via `config :muse, :runtime_provider_enabled, true` to test
the provider routing logic without network calls, using `MUSE_PROVIDER=fake`
where needed.

### LiveView Browser Smoke (Optional)

For HTTP-level verification of the running web interface:

```bash
./script/liveview-browser-smoke  # Starts server + runs assertions, non-interactive
```

See [§11 LiveView Browser Smoke](#11-liveview-browser-smoke) for details.

### Running Focused Tests

For faster iteration during development:

```bash
# Run tests matching a pattern
mix test test/muse/conductor_test.exs
mix test --only planning

# Run a single test file
mix test test/muse/session_server_test.exs

# Run with trace output
mix test --trace test/muse/plan_test.exs
```

### External Provider Tests (Opt-In Only)

Tests that call real APIs require explicit opt-in:

```bash
# OpenAI integration tests
MUSE_OPENAI_TEST=1 OPENAI_API_KEY=sk-... mix test --only external
```

External tests are **disabled by default** and never run in CI. They are for manual verification only.

---

## Table of Contents

1. [No-Network Default](#1-no-network-default)
2. [Shared Provider Test Suite](#2-shared-provider-test-suite)
3. [Fixture Types](#3-fixture-types)
4. [PR09 ApprovalGate Contract Coverage](#4-pr09-approvalgate-contract-coverage)
5. [Unit Tests](#5-unit-tests)
6. [Integration Tests](#6-integration-tests)
7. [Safety Tests](#7-safety-tests)
8. [PR16 External WebSocket Channel Testing](#8-pr16--external-websocket-channel-testing)
9. [Product-Language Tests](#9-product-language-tests)
10. [First Demo Fake Provider Script](#10-first-demo-fake-provider-script)
11. [LiveView Browser Smoke](#11-liveview-browser-smoke)

---

## 1. No-Network Default

The normal test suite **must never** call OpenAI, Anthropic, or any other live provider. Tests that depend on external services are opt-in only.

| Mode | Command | Network | When |
|------|---------|---------|------|
| **Default** | `mix test` | ❌ None | Every CI run, every local run |
| **External** | `MUSE_OPENAI_TEST=1 OPENAI_API_KEY=sk-... mix test --only external` | ✅ OpenAI only | Manual / scheduled nightly |

### Rules

- Any test that touches a real API **must** be tagged `@tag :external`.
- CI runs the default suite with zero API keys in the environment.
- If a test accidentally dials out without the tag, it must fail (use a custom ExUnit formatter or a `Bypass` assert that no HTTP calls were made).
- The `external` tag is the **only** approved network escape hatch. No other environment variables open the network.

---

## 2. Shared Provider Test Suite

Every LLM provider adapter **must** pass the same contract tests. This guarantees that swapping providers doesn't break Muse.

### Module

```elixir
defmodule Muse.LLM.ProviderContractTest do
  @moduledoc """
  Shared contract that ANY Muse.LLM.Provider implementation must satisfy.
  """
  use ExUnit.Case, async: false

  # Implementations include themselves like:
  #   use Muse.LLM.ProviderContractTest, provider: Muse.LLM.OpenAI.ResponsesProvider
end
```

### Required Scenarios

| # | Scenario | What it proves |
|---|----------|----------------|
| 1 | **Returns assistant content for simple prompts** | A plain `"Hello"` prompt produces `:response_started`, one or more `:assistant_delta` events, and a final `:assistant_completed` / `:response_completed` event. |
| 2 | **Returns tool calls when tools are available** | When tools are registered, the provider emits normalized tool-call events such as `:tool_call_started`, `:tool_call_delta`, and/or `:tool_call_completed`, carrying `Muse.LLM.ToolCall` data. |
| 3 | **Handles malformed tool call arguments gracefully** | Malformed tool-call arguments produce a safe validation/tool-call error result and never crash the provider, Conductor, or SessionServer. |
| 4 | **Reports errors without crashing** | Provider-level failures such as 429, 500, timeout, or connection reset normalize to `:provider_error` with redacted error data. |
| 5 | **Supports cancellation** | Cancellation terminates the stream safely and the runtime emits cancellation state/events according to the SessionServer cancellation policy, including `:turn_cancelled` where appropriate. |
| 6 | **Normalizes events to the same Muse.LLM.Event types** | Regardless of provider wire format, all streams normalize to the canonical `Muse.LLM.Event` types defined in [`docs/architecture.md`](../docs/architecture.md#35-llm-provider-neutral-models). |

### How to Use

A concrete provider test module does:

```elixir
defmodule Muse.LLM.OpenAI.ResponsesProviderTest do
  use Muse.LLM.ProviderContractTest, provider: Muse.LLM.OpenAI.ResponsesProvider

  # Provider-specific setup (mocks, fixtures) goes here
end
```

The shared macro injects all six scenario tests automatically. The provider module supplies `setup_all` to configure its fake/streaming backend.

---

## 3. Fixture Types

Fixtures are version-controlled under `test/fixtures/` and `test/support/fixtures/`.

| Fixture | Path | Description |
|---------|------|-------------|
| **Chat Completions — text delta stream** | `test/fixtures/chat_completions/sse_text_delta.txt` | SSE chunks with assistant text deltas. |
| **Chat Completions — tool-call stream** | `test/fixtures/chat_completions/sse_tool_call.txt` | SSE chunks with tool-call deltas. |
| **Chat Completions — error stream** | `test/fixtures/chat_completions/sse_error.txt` | Error-oriented stream fixture. |
| **Responses WS — text events** | `test/fixtures/openai_responses/ws_text_events.json` | Responses WebSocket text frame sequence. |
| **Responses WS — tool-call events** | `test/fixtures/openai_responses/ws_tool_call_events.json` | Responses WebSocket function-call frame sequence. |
| **Responses WS — error events** | `test/fixtures/openai_responses/ws_error_events.json` | Responses WebSocket error frame sequence. |
| **Fake provider planning flow** | `test/fixtures/fake_provider/planning_flow.jsonl` | Scripted Planning Muse flow with read-only tool calls then structured plan JSON. |
| **Fake provider planning flow (batched)** | `test/fixtures/fake_provider/planning_flow_batches.json` | Multi-batch Planning Muse fixture: two tool-call batches then structured plan JSON. |
| **Fake provider tool-call flow** | `test/fixtures/fake_provider/tool_calls_then_text.jsonl` | Multiple tool calls followed by assistant text with usage. |
| **Planning parser fixtures** | `test/fixtures/planning/*.json` and `test/fixtures/planning/*.md` | Valid, minimal, fenced, prose-wrapped, invalid, and extra-key structured plan examples. |

### Fixture Principles

- **Redacted** — no real API keys ever appear in fixtures.
- **Deterministic** — same input, same output. No randomness.
- **Compact** — minimal valid payloads. No 500-line real-world dumps.

---

## 4. PR09 ApprovalGate Contract Coverage

PR09 contract coverage focuses on explicit plan lifecycle approvals, stale rejection, and deny-by-default execution boundaries.

Primary coverage areas:

- `test/muse/conductor_planning_test.exs`
  - structured JSON plan parse path
  - rendered plan output (`Muse.Plan.render/1`)
  - `:plan_created` event assertions
  - session transition to `:awaiting_plan_approval`
- `test/muse/session_server_test.exs`
  - `/approve plan` and `/reject plan` lifecycle transitions
  - active plan id handling and status transitions
  - auditable lifecycle event assertions (`:approval_*`, `:plan_*`, status changes)
  - non-executing boundary checks (no turn execution side-effects)
- `test/muse/approval_test.exs`, `test/muse/approval_gate_test.exs`, `test/muse/plan_binding_test.exs`, and `test/muse/approval_persistence_test.exs`
  - robust approval records, content-bound plan identity, persistence/restore, and redaction
  - content-bound approval identity (`session_id`, `plan_id`, `plan_version`, `plan_hash`/`content_hash`, `workspace`)
  - stale/mismatched approval rejection behavior
- `test/muse/pr09_approval_gate_e2e_test.exs`
  - fake-provider end-to-end planning flow, content binding, approve/reject commands, and no workspace writes after approval
- `test/muse/tool/runner_test.exs` and `test/muse/tool/registry_test.exs`
  - read-only tool allowlists
  - dangerous tool-name blocking and deny-by-default behavior

All default tests remain offline (`mix test`) and no-network by default.
Live provider integration remains opt-in via env-gated `:external` tests.

---

## 4.5 PR17 Patch Proposal & Approval Contract Coverage

PR17 contract coverage focuses on patch proposal after plan approval, content-hashed patch identity, patch approval lifecycle, and the explicit boundary that patch approval does not apply/checkpoint files.

Primary coverage areas:

- `test/muse/patch_test.exs`
  - Patch struct construction, status transitions, field validation, and deterministic hashing
- `test/muse/patch/diff_parser_test.exs` and `test/muse/patch/validator_test.exs`
  - Diff parsing, canonicalization, path safety, size limits, binary rejection, and secret detection
- `test/muse/approval_test.exs` (extended)
  - `:patch` kind approvals carry `patch_id` and `patch_hash`
  - patch approval kind normalization and serialization
- `test/muse/approval_gate_test.exs` (extended)
  - patch approval binding validation with stale/mismatch rejection
- `test/muse/session_server_test.exs` (extended)
  - patch creation/approval/rejection lifecycle via SessionServer
  - session transition to `:awaiting_patch_approval` is valid
  - patch approval does not apply files by itself
- `test/muse/muse_registry_test.exs` and `test/muse/tool/registry_test.exs` (extended)
  - `patch_propose` blocked for Planning Muse; available to Coding Muse after plan approval
  - `patch_apply` requires separate PR18 approved-plan/approved-patch context

**Gaps:** Full end-to-end patch proposal flow with a live Coding Muse turn (Conductor → `patch_propose` tool → `:awaiting_patch_approval` → `/approve patch`) is covered across unit/integration layers. Keep future regressions focused on behavior and event/state transitions rather than provider implementation details.

---

## 4.6 PR18 Patch Apply, Checkpoint, and Rollback Coverage

PR18 coverage focuses on explicit patch application, checkpoint creation before writes, rollback, and failure recovery.

Primary coverage areas:

- `test/muse/tools/patch_apply_test.exs`
  - approved patch application with checkpoint protection
  - path, secret, and hash validation before writes
  - safe failure behavior and redacted reports
- `test/muse/tools/rollback_checkpoint_test.exs`
  - checkpoint-scoped rollback and workspace restoration
  - invalid/mismatched checkpoint rejection
- `test/muse/checkpoint/store_test.exs`
  - checkpoint persistence, load/update, path traversal rejection, tamper detection
- `test/muse/session_server_test.exs` and `test/muse/command_dispatcher_test.exs`
  - `/apply patch` and `/rollback checkpoint <id>` command/session integration
  - events and session state remain auditable

## 4.7 PR19 Test Runner, Reviewing Muse, and Testing Muse Coverage

PR19 coverage focuses on preset-only verification commands, bounded repair/review behavior, and non-arbitrary-shell safety.

Primary coverage areas:

- `test/muse/tools/test_runner_test.exs`
  - allowed presets (`mix_format_check`, `mix_compile`, `mix_test`, `mix_test_file`)
  - strict test-file path validation for `mix_test_file`
  - timeout/exit handling, output capping, and redaction
- `test/muse/tool/registry_test.exs` and `test/muse/tool/runner_test.exs`
  - `test_runner` is Testing-Muse-only
  - arbitrary shell-like or network-like tool names remain blocked
- `test/muse/reports/*_test.exs`
  - verification/review report structure and safe rendering
- `test/muse/repair_policy_test.exs`
  - bounded repair attempts; no autonomous infinite shell loops

## 4.8 PR21 Memory & Restoration Muse Coverage

PR21 adds memory compaction, session handoffs, and restoration support.

Primary coverage areas:

- `test/muse/memory_test.exs`
  - Memory compaction produces a valid memory artifact
  - Compaction preserves critical context while reducing token count
  - Memory file persistence and loading
- `test/muse/session_server_test.exs` (extended)
  - Session handoff to Memory Muse for compaction
  - Handoff completion and session state restoration
  - Memory summary injection into prompt layers
- `test/muse/prompt/assembler_test.exs` (extended)
  - Memory layer integration in prompt bundle
  - Memory summary ordering in layer stack

All tests remain offline by default. Memory compaction is exercised with deterministic fixtures.

---

## 5. Unit Tests

Unit tests cover individual modules and functions. Key test files and their focus areas:

### Session & State

**Key files:** `test/muse/session_server_test.exs`, `test/muse/session_store_test.exs`, `test/muse/state_test.exs`

- Session creation, lookup, persistence, and state transitions
- SessionServer remains responsive during long model turns
- Event log replay and PubSub broadcasting
- Cancellation mid-turn stops streaming cleanly

### Conductor & Turns

**Key files:** `test/muse/conductor_test.exs`, `test/muse/conductor/turn_runner_test.exs`, `test/muse/conductor/tool_loop_test.exs`

- Muse selection logic (Planning Muse default, Coding Muse after plan approval)
- Tool-call loop iteration with caps and limits
- Provider error handling without crashing session
- Turn cancellation checkpoints

### Planning & Plan Lifecycle

**Key files:** `test/muse/plan_test.exs`, `test/muse/plan_parser_test.exs`, `test/muse/plan_schema_test.exs`, `test/muse/plan_history_test.exs`

- Plan parsing from structured JSON
- Plan schema validation (required fields, optional fields)
- Plan status transitions and rendering
- Plan history queries

### Approval & Binding

**Key files:** `test/muse/approval_test.exs`, `test/muse/approval_gate_test.exs`, `test/muse/plan_binding_test.exs`, `test/muse/approval_persistence_test.exs`

- Plan approval/rejection lifecycle commands
- Content-bound approval binding (session_id, plan_id, version, hash, workspace)
- Stale approval rejection
- Approval persistence and audit trail

### Patch Proposal & Approval

**Key files:** `test/muse/patch_test.exs`, `test/muse/patch/diff_parser_test.exs`, `test/muse/patch/validator_test.exs`

- Patch struct construction and deterministic hashing
- Diff parsing, canonicalization, and validation
- Path safety, size limits, binary rejection, secret detection
- Patch approval lifecycle (lifecycle-only in PR17)

### Tools & Registry

**Key files:** `test/muse/tool/registry_test.exs`, `test/muse/tool/runner_test.exs`, `test/muse/tools/*_test.exs`

- Tool registration and spec validation
- Blocked-tool enforcement (write/shell/network/delete/remote)
- Role-based tool access (Planning vs Coding Muse)
- Individual tool behavior (list_files, read_file, repo_search, git_*, etc.)

### Execution (PR24)

**Key files:** `test/muse/execution/*_test.exs`

- Command validation (executable, args, timeout, output bounds)
- Result construction and safe summaries
- LocalRunner execution (argv-vector, no shell, timeout, output capping)
- Policy routing (local allowed, remote/ssh denied)
- No `String.to_atom/1` on user input
- Secret redaction in output and errors

### Memory & Handoff

**Key files:** `test/muse/memory_test.exs`

- Memory compaction and summarization
- `memory.json` persistence and restoration
- Muse handoff coordination

### Prompt Assembly

**Key files:** `test/muse/prompt/assembler_test.exs`, `test/muse/prompt/project_rules_test.exs`, `test/muse/prompt/debug_preview_test.exs`

- Layer ordering and priority (core → project → user → session)
- Project rules loading from trusted locations
- Debug preview redaction of secrets
- Model preparer output shape

### Auth & Provider

**Key files:** `test/muse/auth/*_test.exs`, `test/muse/llm/*_test.exs`

- Credential resolution (API key, bearer command, Codex cache)
- Provider contract compliance
- Fake provider scripted responses
- SSE and WebSocket transport decoding

### Workspace Safety

**Key files:** `test/muse/workspace_test.exs`

- Path traversal blocking (`../` outside workspace)
- Symlink escape prevention
- Secret file blocking (`.env`, `credentials.json`, etc.)
- Hidden file handling

---

## 6. Integration Tests

Current fake-provider integration happy path:

| Step | Action | Expected State |
|------|--------|----------------|
| 1 | User asks for a code change (e.g., `"add a /version command"`) | Session starts, Planning Muse turn runs |
| 2 | Planning Muse inspects files via read-only tools | Tool calls issued and results returned |
| 3 | Planning Muse emits structured JSON plan | `PlanParser` + `PlanSchema` accept output |
| 4 | Runtime renders plan and emits `:plan_created` + `:approval_requested` | User sees plan id/version/hash binding and `/approve plan` + `/reject plan` guidance |
| 5 | Session enters `:awaiting_plan_approval` | Active plan id, pending approval record, and approval binding are set |
| 6 | User runs `/approve plan` or `/reject plan` | Plan status updates; approval record is persisted; session returns to `:idle` |

> Patch approval remains lifecycle-only: `/approve patch` does not apply files. Patch application, checkpoint orchestration, rollback, and preset verification are covered by the PR18/PR19 test areas above and by focused command/session tests.

### Integration Test Principles

- **Fake provider only** — no real API calls.
- **Full round-trip** — from user input to final state change.
- **Observable** — every state transition is asserted.
- **No timing assumptions** — use message passing / polling, never `Process.sleep`.

---

## 7. Safety Tests

Every safety boundary has dedicated test coverage. Key safety test areas:

### Filesystem Boundaries

**Key files:** `test/muse/workspace_test.exs`, `test/muse/tool/runner_test.exs`, `test/muse/tools/read_file_test.exs`

Blocked operations:
- Read outside workspace (e.g., `/etc/passwd`)
- Write outside workspace (e.g., `/tmp/evil.sh`)
- `../` traversal (e.g., `../../.ssh/id_rsa`)
- Symlink write/read escapes pointing outside workspace
- Secret file reads (`.env`, `credentials.json`, `auth.json`, `.netrc`)
- Hidden files (dotfiles) unless explicitly allowed

### Approval / Blocking Boundaries (PR09)

**Key files:** `test/muse/approval_gate_test.exs`, `test/muse/tool/registry_test.exs`, `test/muse/tool/runner_test.exs`

Blocked operations:
- Dangerous tool names (`write_file`, `shell_command`, `network_call`, `remote_execution`, etc.)
- Destructive unknown tool-name shapes (write/patch/shell/network/remote-like)
- Tools not available to active Muse role
- Unknown tool names return safe error result
- Approval-scoped tools cannot execute unless their current approval policy/context matches
- `/approve plan` or `/reject plan` when no active plan awaiting approval
- Stale/mismatched plan approval binding

### Approval / Blocking Boundaries (PR17)

**Key files:** `test/muse/patch_test.exs`, `test/muse/tool/registry_test.exs`, `test/muse/session_server_test.exs`

Blocked operations:
- `patch_apply` without approved-plan and approved-patch context
- `patch_propose` for Planning Muse (Coding Muse only, after plan approval)

Valid transitions:
- Session transition to `:awaiting_patch_approval`
- `:patch` kind approval with `patch_id`/`patch_hash` binding

Rejections:
- Stale/mismatched patch approval binding
- Patch approval does not apply files, create checkpoints, or run shell/network
- No file modifications occur before patch approval

### Data Boundaries

**Key files:** `test/muse/event_payload_redactor_test.exs`, `test/muse_web/external_event_filter_test.exs`

- Provider request debug snapshots redact `Authorization` headers
- External WebSocket channel does not forward internal/sensitive events
- Payload redaction for secrets (API keys, tokens, credentials)

---

## 8. PR16 — External WebSocket Channel Testing

The external WebSocket channel (`MuseWeb.SessionChannel`) is tested through:

| Test file | Scope |
|---|---|
| `test/muse_web/external_event_filter_test.exs` | Visibility filtering, nil-visibility allowlist, session matching, envelope structure, JSON safety |
| `test/muse_web/external_event_security_test.exs` | Security boundary: redaction, secret suppression, struct omission, session ID validation |
| `test/muse_web/external_socket_config_test.exs` | Config defaults: enabled/disabled, replay_limit |
| `test/muse_web/channels/session_channel_test.exs` | Channel join/replay/live forwarding: session isolation, topic validation, config guard |
| `test/muse/event_stream_test.exs` | `external_replay/1,2` and `external_envelope/2` integration tests |
| `test/muse/event_payload_redactor_test.exs` | Enhanced redaction patterns (OAuth, JWT, Codex, GitHub PAT) |

---

## 9. Product-Language Tests

Muse-first naming is a product commitment. These tests verify that user-facing surfaces do not use "Agent," "Bot," mascot names, or Code Puppy branding. Technical LLM protocol roles and internal event names such as `role: :assistant`, `:assistant_delta`, and `:assistant_message` are allowed where they are implementation details rather than product labels.

### Surfaces Verified

**Key files:** `test/muse/cli/tui_test.exs`, `test/muse_web/live/*_test.exs`, `test/muse/commands_test.exs`

- `/muses` lists **Planning Muse** and **Coding Muse** with Muse-first naming
- `/status` says **Active Muse** (not "Active Agent" or "Current Assistant")
- Plan output says **Recommended Muse** (not "Recommended Agent")
- Approval messages say **Muse Plan** and **Patch Proposal** (not "Agent Plan" or "Bot Patch")
- LiveView panels use **Muse** labels in headers, badges, and status indicators
- Documentation and examples do not use "mascot" or generic "Agent" naming in user-facing text

### Enforcement

A grep-based CI check fails the build on violation:

```bash
grep -r "Active Agent\|Current Agent\|Agent Plan" lib/ test/
# Should return no matches
```

I18n/localization keys use `muse.*` namespace, not `agent.*`.

### Known Internal Exceptions

These internal identifiers are intentionally preserved and are not user-facing:
- Module names: `Muse.AgentRegistry`, `Muse.AgentRuntime`
- Data keys: `agent_snapshot`, `agent_runtime`, `agents` (map fields)
- CSS classes: `agent-*` (e.g., `agent-runtime-card`, `agent-entry`)
- Phoenix event names: `connect_agent_runtime`, `disconnect_agent_runtime`
- PubSub messages: `:muse_agent_registry_updated`, `:muse_agent_runtime_updated`
- Process names: `Muse.AgentRegistry`, `Muse.AgentRuntime`

---

## 10. First Demo Fake Provider Script

This section defines the complete scripted demo for the **first milestone**: adding a `/version` command to Muse using the Planning Muse flow.

### 10.1 Test Request

```
add a /version command
```

### 10.2 Fake Model Step 1 — Search

The model's first response asks to search the codebase:

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

The fake provider returns search results containing references to `commands.ex` and `command_dispatcher.ex`.

### 10.3 Fake Model Step 2 — Read Files

After receiving search results, the model asks to read the relevant files:

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

The fake provider returns the contents of both files (from fixtures).

### 10.4 Fake Model Final — Structured Plan

After reading the files, the model produces the structured plan:

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

### 10.5 Expected Output

The CLI renders the plan for user approval:

```
Planning Muse prepared a plan.

Objective:
Add a /version command to Muse.

Tasks:
1. Add command definition.
2. Add dispatch handler.
3. Verify shared interface behavior.

Approve this plan with: /approve plan
```

### Demo Test Assertion

The integration test asserts:

1. The session received the user request.
2. The Planning Muse issued `repo_search` tool calls.
3. The Planning Muse issued `read_file` tool calls.
4. The session entered `awaiting_plan_approval` state.
5. The rendered output matches the expected CLI display above (exact or normalized whitespace).
6. No write operations were performed — files are unchanged on disk.

---

## 11. LiveView Browser Smoke

An executable QA smoke that starts the Muse web interface on a non-default port with the fake provider and verifies the home page renders correctly with proper accessibility markers, command discoverability, and no leaked secrets.

### 11.1 Quick Start

```bash
./script/liveview-browser-smoke
```

This single command:

1. Compiles the project in the `smoke` Mix environment
2. Starts Muse with `MUSE_PROVIDER=fake` on port 4101
3. Waits for HTTP readiness
4. Runs `mix muse.smoke` — HTTP/HTML assertions against the running server
5. Tears down the server cleanly (trap-based cleanup)
6. Exits 0 on success, 1 on failure

### 11.2 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MUSE_BROWSER_SMOKE_PORT` | 4101 | HTTP port for the smoke server; must be in `1..65535` and free before launch |
| `MUSE_BROWSER_SMOKE_HOST` | 127.0.0.1 | Local host passed to both `mix muse --host` and `mix muse.smoke --host`; accepted values are `127.0.0.1`, `localhost`, and `0.0.0.0` (no URL scheme, port, or path) |
| `MUSE_BROWSER_SMOKE_TIMEOUT` | 60 | Server readiness timeout in seconds; must be a positive integer |

The orchestration script validates these values before compiling or starting Muse. It also refuses to continue if `http://HOST:PORT/` already responds before the script launches its own server, which prevents false success against a stale or unrelated local process.

### 11.3 Manual / Standalone Usage

If the server is already running, assertions can be run independently:

```bash
# Start the server manually
MIX_ENV=smoke MUSE_PROVIDER=fake mix muse --web-only --host 127.0.0.1 --port 4101 --no-watch

# In another terminal, run just the assertions
mix muse.smoke --port 4101
```

### 11.4 What the Smoke Checks

| Check | What it verifies |
|-------|-----------------|
| Home page loads | HTTP GET `/` returns 200 with substantial HTML body |
| Accessibility markers | ARIA roles (`region`, `log`, `complementary`, `status`), `aria-label` attributes, `aria-live` regions on chat panel, context panel, toast container, and composer |
| Command discoverability | `/help` hints visible, `data-slash-commands` attribute, placeholder text, descriptive ARIA labels on input and buttons |
| Session/context panel | Context sidebar renders, session labels present, `role="complementary"`, `aria-label` for workspace context and session status |
| No visible secrets | HTML does not contain `sk-` prefixes, `Bearer` tokens, API key env var names, or `secret_key_base` |
| Keyboard focus indicators | Focusable chat textarea markers, accessible input label, concise placeholder text, `role="form"` on composer, submit button, sidebar collapse label |

### 11.5 Mix Environment

The `smoke` Mix environment (`config/smoke.exs`) is a minimal variant of `dev` with:

- `code_reloader: false` — no file watching or live reload
- `watchers: []` — no esbuild watcher
- `debug_errors: false` — no Phoenix debug error pages
- Quiet logging (`:error` level)
- `start_runtime_children?: true` — full application starts, including the endpoint

This environment does NOT interfere with the default `mix test` suite.

### 11.6 No-Network Invariant Preserved

The browser smoke uses `MUSE_PROVIDER=fake` (the project default). No real API keys, no network calls to LLM providers, no browser downloads required. Running `mix test` (the default test suite) is unchanged.

### 11.7 Playwright / Real Browser QA

The HTTP-based smoke (§11.1–11.6) verifies server-rendered HTML content but **cannot detect JavaScript runtime errors** in the browser. The Playwright browser smoke provides full console-error detection and keyboard focus verification.

#### Quick Start

```bash
./script/liveview-browser-smoke-playwright
```

This single command:

1. Checks prerequisites (Node.js, npm, Playwright)
2. Compiles and starts Muse with `MUSE_PROVIDER=fake` on port 4101
3. Waits for HTTP readiness
4. Runs HTTP smoke assertions (`mix muse.smoke`)
5. Runs Playwright headless browser tests against the LiveView page
6. Tears down the server cleanly (trap-based cleanup)
7. Exits 0 on success, 1 on failure, 2 on missing prerequisites

#### Prerequisites

```bash
npm install                     # Install @playwright/test
npm run browser:install        # Download Chromium browser
```

Node.js 18+ and npm are required. These are **not** required for `mix test` — the default Elixir test suite remains unaffected.

#### What the Browser Smoke Checks

| Check | What it verifies |
|-------|-----------------|
| No console.error / pageerror / unhandledrejection | No JavaScript runtime errors during page load, LiveView connect, or hook mount |
| LiveView WebSocket connected | `phx-loading` class removed, `data-phx-session` element present |
| Command discoverability | Input `aria-label` mentions `/help`, placeholder text, `data-slash-commands`, composer `role="form"`, send button label |
| Keyboard focusability | Tab navigation reaches the chat input textarea; Enter submit doesn't throw errors |
| Session/context panel markers | `role="complementary"`, `aria-label` for workspace context, `role="status"` elements |
| No visible secrets | Visible page text doesn't contain API key prefixes, bearer tokens, or secret env var names |
| ARIA landmarks | Chat region, log role, live region, toast status, form role, textarea accessible name |
| Page load success | Main shell element present, substantial HTML content |

#### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MUSE_BROWSER_SMOKE_PORT` | 4101 | HTTP port for the smoke server; must be in `1..65535` and free before launch |
| `MUSE_BROWSER_SMOKE_HOST` | 127.0.0.1 | Local host passed to `mix muse --host`, HTTP smoke assertions, and Playwright's `baseURL`; accepted values are `127.0.0.1`, `localhost`, and `0.0.0.0` (no URL scheme, port, or path) |
| `MUSE_BROWSER_SMOKE_TIMEOUT` | 60 | Server readiness timeout in seconds; must be a positive integer |

The Playwright orchestration uses the same validated launch behavior as the HTTP smoke: it refuses a pre-existing responder at `http://HOST:PORT/` and fails immediately with server logs if the launched `mix muse` process exits before readiness.

#### Running Without the Orchestration Script

If the server is already running:

```bash
# Terminal 1: start server
MIX_ENV=smoke MUSE_PROVIDER=fake mix muse --web-only --host 127.0.0.1 --port 4101 --no-watch

# Terminal 2: run just the Playwright tests
npm run smoke:liveview:browser
# Or directly:
MUSE_BROWSER_SMOKE_PORT=4101 npx playwright test
```

#### No-Network Invariant Preserved

The browser smoke uses `MUSE_PROVIDER=fake`. No real API keys, no network calls to LLM providers. The `npm install` step downloads Playwright and Chromium but this is separate from `mix deps.get` — the default Elixir quality gates (`mix test`, `mix compile --warnings-as-errors`) remain unchanged and do not require Node.js or browser downloads.
