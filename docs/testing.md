# Muse Universal Runtime — Testing Strategy

> **Maxims:** Tests run offline by default. Every provider obeys the same contract. Safety is never optional.
>
> **Canonical source:** Testing strategy and acceptance checks. Provider/event assertions should reference the canonical normalized event types in [`architecture.md`](architecture.md#35-llm-provider-neutral-models).

---

## Table of Contents

1. [No-Network Default](#1-no-network-default)
2. [Shared Provider Test Suite](#2-shared-provider-test-suite)
3. [Fixture Types](#3-fixture-types)
4. [Unit Tests](#4-unit-tests)
5. [Integration Tests](#5-integration-tests)
6. [Safety Tests](#6-safety-tests)
7. [Product-Language Tests](#7-product-language-tests)
8. [First Demo Fake Provider Script](#8-first-demo-fake-provider-script)

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

All fixtures live under `test/fixtures/` and are version-controlled.

| Fixture | Path | Description |
|---------|------|-------------|
| **OpenAI Responses SSE — text delta stream** | `fixtures/openai_responses/sse_text_delta.txt` | ND-JSON lines of `response.output_text.delta` events followed by `response.completed`. |
| **OpenAI Responses SSE — function-call stream** | `fixtures/openai_responses/sse_function_call.txt` | Stream that includes `response.function_call_arguments.delta` events building up a JSON tool call. |
| **OpenAI Responses WebSocket — response events** | `fixtures/openai_responses/ws_response_events.json` | Array of WebSocket frame payloads representing a full Responses API conversation. |
| **Chat Completions — text delta stream** | `fixtures/chat_completions/sse_text_delta.txt` | Classic `data: {"choices":[{"delta":{"content":"..."}}]}` SSE chunks. |
| **Chat Completions — tool-call stream** | `fixtures/chat_completions/sse_tool_call.txt` | SSE chunks with `function.name` and `function.arguments` deltas. |
| **Codex auth.json (redacted)** | `fixtures/codex/auth.json` | Simulated Codex `auth.json` with **fake** token values for testing credential loading. |
| **Malformed provider events** | `fixtures/malformed/provider_events.jsonl` | ND-JSON with missing fields, invalid UTF-8, truncated JSON, and unknown event types. |
| **Malformed tool calls** | `fixtures/malformed/tool_calls.json` | Tool calls with missing `name`, non-JSON `arguments`, and empty `call_id`. |
| **Fake provider scripts — planning flow** | `fixtures/fake_provider/planning_flow.jsonl` | Scripted responses for a complete Planning Muse turn (search → read → plan). |
| **Fake provider scripts — coding flow** | `fixtures/fake_provider/coding_flow.jsonl` | Scripted responses for a Coding Muse turn (propose patch). |
| **Fake provider scripts — testing flow** | `fixtures/fake_provider/testing_flow.jsonl` | Scripted responses for a Testing Muse turn (run validation). |

### Fixture Principles

- **Redacted** — no real API keys ever appear in fixtures.
- **Deterministic** — same input, same output. No randomness.
- **Compact** — minimal valid payloads. No 500-line real-world dumps.

---

## 4. Unit Tests

Complete checklist. Every item must have at least one passing test before merge.

### Profile & Muse Configuration

- [ ] `MuseProfile` loads all Muses from config
- [ ] Planning Muse has no write tools in its tool set
- [ ] Coding Muse requires plan approval before write access is granted
- [ ] Each Muse reports the correct `id`, `name`, and `description`

### Prompt Assembly

- [ ] `PromptAssembler` orders layers in the correct priority: core → project → user → session
- [ ] Project rules load with correct priority (later layers can extend, never override core)
- [ ] Project rules **cannot** override core rules (e.g., a project rule cannot re-enable shell access if core disables it)
- [ ] Duplicate rules from different layers are deduplicated (latest wins within same layer)

### Debug & Preview

- [ ] Debug preview output redacts all secret values (API keys, tokens) with `***`
- [ ] Debug preview shows layer ordering clearly for troubleshooting

### Model Preparation

- [ ] `ModelPreparer` creates the expected request shape for each provider
- [ ] Model preparer injects the correct tool definitions for the active Muse
- [ ] Model preparer omits tools that the active Muse does not have access to

### Approval Gate

- [ ] `ApprovalGate` blocks write operations before plan approval
- [ ] `ApprovalGate` binds approval to a specific plan version (content hash)
- [ ] `ApprovalGate` rejects stale plan approval (plan changed since user saw it)
- [ ] `ApprovalGate` rejects patch approval for a different patch hash

### Workspace Path Safety

- [ ] Workspace path safety blocks `../` traversal outside the project root
- [ ] Workspace path safety blocks symlink escapes that resolve outside the project root
- [ ] Read-file operations block paths matching secret patterns (`.env`, `credentials.json`, `auth.json`, etc.)
- [ ] Hidden files (dotfiles) are blocked unless explicitly allowed by config

### Tool Execution

- [ ] `ToolRunner` emits `:tool_start`, `:tool_output`, and `:tool_end` events
- [ ] Fake provider returns scripted tool calls from fixture data
- [ ] Tool runner respects the active Muse's allowed tool set — disallowed tools are rejected

### Conductor & Session

- [ ] `Conductor` handles the full tool-call loop: model → tool call → tool result → model → … → done
- [ ] `SessionStore` persists session state and can resume from disk
- [ ] Provider errors do **not** crash `SessionServer` — errors are captured and reported
- [ ] Unknown provider events are ignored (or logged at debug level) without crashing
- [ ] Existing State PubSub behavior remains stable (subscriptions, broadcasts)
- [ ] `SessionServer` remains responsive to queries during a long model turn
- [ ] Cancellation works mid-turn — calling cancel during a streaming response stops the turn cleanly

---

## 5. Integration Tests

The full happy-path integration flow, tested end-to-end with the fake provider:

| Step | Action | Expected State |
|------|--------|----------------|
| 1 | User asks for a code change (e.g., `"add a /version command"`) | Session starts, Planning Muse activated |
| 2 | Planning Muse inspects files via `repo_search` | Tool calls issued and results returned |
| 3 | Planning Muse creates a structured plan | Plan stored in session state |
| 4 | Session enters `awaiting_plan_approval` | No write operations allowed |
| 5 | User approves plan with `/approve plan` | ApprovalGate records plan hash |
| 6 | Coding Muse is activated | Coding Muse receives plan + file contents |
| 7 | Coding Muse proposes a patch | Patch stored but **not** applied yet |
| 8 | Patch is not applied before approval | Verify file unchanged on disk |
| 9 | User approves patch with `/approve patch` | ApprovalGate records patch hash |
| 10 | Checkpoint is created | Snapshot of current file state saved |
| 11 | Patch is applied | File on disk matches patch content |
| 12 | Testing Muse runs or requests validation | Test tools invoked or validation prompt shown |
| 13 | Reviewing Muse can review the diff | Diff shown, review notes emitted |
| 14 | Session completes or waits for next approval | Terminal or `awaiting_approval` state |

### Integration Test Principles

- **Fake provider only** — no real API calls.
- **Full round-trip** — from user input to final state change.
- **Observable** — every state transition is asserted.
- **No timing assumptions** — use message passing / polling, never `Process.sleep`.

---

## 6. Safety Tests

Every safety boundary must have a dedicated test. No exceptions.

### Filesystem Boundaries

- [ ] Blocked: read outside workspace (e.g., `/etc/passwd`)
- [ ] Blocked: write outside workspace (e.g., `/tmp/evil.sh`)
- [ ] Blocked: `../` traversal (e.g., `../../.ssh/id_rsa`)
- [ ] Blocked: symlink write — symlink pointing outside workspace
- [ ] Blocked: symlink read escape — reading through symlink outside workspace
- [ ] Blocked: secret read — paths matching `**/.env`, `**/credentials.json`, `**/auth.json`, `**/.netrc`
- [ ] Blocked: hidden file read — dotfiles unless explicitly in allowlist

### Approval Boundaries

- [ ] Blocked: shell command execution before shell approval
- [ ] Blocked: file delete before explicit delete approval (separate from write approval)
- [ ] Blocked: stale plan approval — plan content hash has changed since presented
- [ ] Blocked: patch approval for different patch hash — hash mismatch rejected
- [ ] Blocked: patch apply without a prior checkpoint — checkpoint must exist first
- [ ] Blocked: tool not available to active Muse — a tool outside the Muse's toolset is rejected

### Data Boundaries

- [ ] Provider request debug snapshots redact `Authorization` headers (show `Bearer sk-...****`)
- [ ] External WebSocket channel does **not** forward internal/sensitive events (e.g., `secret_read_attempt`, `approval_state_change`)

---

## 7. Product-Language Tests

Muse-first naming is a product commitment. These tests verify that user-facing surfaces do not use "Agent," "Bot," mascot names, or Code Puppy branding. Technical LLM protocol roles and internal event names such as `role: :assistant`, `:assistant_delta`, and `:assistant_message` are allowed where they are implementation details rather than product labels.

### Surfaces to Check

- [ ] `/muses` lists **Planning Muse**, **Coding Muse**, **Reviewing Muse**, **Testing Muse** — no generic names
- [ ] `/status` says **Active Muse** (not "Active Agent" or "Current Assistant")
- [ ] Plan output says **Recommended Muse** (not "Recommended Agent")
- [ ] Approval messages say **Muse Plan** and **Patch Proposal** (not "Agent Plan" or "Bot Patch")
- [ ] LiveView panels use **Muse** labels in headers, badges, and status indicators
- [ ] Documentation and examples do **not** use "mascot" or generic "Agent" naming in user-facing text

### Enforcement

- [ ] A grep-based CI check (`grep -r "Active Agent\|Current Agent\|Agent Plan" lib/ test/`) fails the build on violation
- [ ] I18n/localization keys use `muse.*` namespace, not `agent.*`

---

## 8. First Demo Fake Provider Script

This section defines the complete scripted demo for the **first milestone**: adding a `/version` command to Muse using the Planning Muse flow.

### 8.1 Test Request

```
add a /version command
```

### 8.2 Fake Model Step 1 — Search

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

### 8.3 Fake Model Step 2 — Read Files

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

### 8.4 Fake Model Final — Structured Plan

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

### 8.5 Expected Output

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
