# Muse Universal Runtime — Executive Summary

> **Archived source plan:** [`plans/plan-v3-archived.md`](plans/plan-v3-archived.md) · **Architecture:** [`docs/architecture.md`](docs/architecture.md) · **Prompts:** [`docs/prompts.md`](docs/prompts.md) · **Providers:** [`docs/provider-roadmap.md`](docs/provider-roadmap.md) · **Testing:** [`docs/testing.md`](docs/testing.md) · **Security:** [`docs/security.md`](docs/security.md) · **PR 00 Baseline:** [`docs/pr-00-baseline.md`](docs/pr-00-baseline.md)

---

## PR 00 — Baseline Verification & Naming Cleanup

**Status:** ✅ Complete

Baseline quality gates (all passing):

| Command | Exit Code | Notes |
|---|---|---|
| `mix format --check-formatted` | 0 | All files formatted |
| `mix compile --warnings-as-errors` | 0 | No warnings |
| `mix test` | 0 | 858 tests, 0 failures |

Product-language audit — user-facing "Agent/Bot" labels replaced with Muse-first terms:

- `Agents` → `Muses` (TUI tab, LiveView tab, sidebar card, status bar)
- `Agent registry` → `Muse registry` (command output, LiveView panel)
- `Agent runtime` → `Muse runtime` (command output, toasts, button titles, aria-labels)
- `Add to next agent turn` → `Add to next Muse turn` (diagnostic drawer)
- `Queued for next agent turn` → `Queued for next Muse turn` (diagnostic drawer)
- `Muse CLI Coding Agent` → `Muse CLI Coding Muse` (logo alt text)
- `/agents` → `/muses`, `/open agents` → `/open muses` (slash-command display; legacy aliases preserved)
- `Open Agents` → `Open Muses` (command palette)
- `Help me connect the agent runtime` → `Help me connect the Muse runtime` (empty-chat prompt chip)
- `Connect universal agent runtime` / `Register first agent` → Muse-first setup copy
- `coding-agent foundation` → `coding-runtime foundation` (README and public moduledocs)
- `agent workspace` → `Muse workspace` (README)

Planned exceptions (internal identifiers, not user-facing):
- Module names: `Muse.AgentRegistry`, `Muse.AgentRuntime`
- Data keys: `agent_snapshot`, `agent_runtime`, `agents` (map fields)
- CSS classes: `agent-*` (e.g., `agent-runtime-card`, `agent-entry`)
- Phoenix event names: `connect_agent_runtime`, `disconnect_agent_runtime`, etc.
- PubSub messages: `:muse_agent_registry_updated`, `:muse_agent_runtime_updated`
- Process names: `Muse.AgentRegistry`, `Muse.AgentRuntime`
- Anti-examples in PLAN.md §5 "Avoid in User-Facing Text" and docs/testing.md product-language checklist

---

## 1. Mission

Turn Muse from a placeholder CLI/Web shell into a **safe local Muse coding runtime** with Muse-first product language, session-aware turns, layered internal prompting, read-only repository inspection, model/tool-call orchestration, streaming events, stateful approvals, patch proposal/application with checkpoints, and CLI/TUI/LiveView visibility.

The first complete product experience:

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

The second product experience (future — requires patch-proposal gate, PR 17+):

```text
muse> approve plan

Muse Conductor:
Plan approved. The plan decision is recorded; no implementation,
patching, shell, or workspace writes will occur.

...after a scoped implementation/patch-proposal gate is introduced...

Coding Muse:
I found the command handler and test files. Here is the proposed diff.

Apply this patch? [y/N]
```

> **PR 09 guarantee:** `/approve plan` records the plan decision only.
> It does not start implementation, patching, shell/network access, or workspace writes.

---

## 2. Non-Negotiable Implementation Contract

1. **Keep `Muse.submit/2`** as the public API, even when it delegates into sessions and the Conductor
2. **Small PR-sized phases** — no jumping to OpenAI networking, remote execution, or autonomous shell
3. **Deterministic offline tests by default** — fake provider first
4. **Muse-first user-facing names everywhere** — Planning Muse, Coding Muse, Reviewing Muse, etc.
5. **No Agent/Bot/mascot labels** in CLI, TUI, LiveView, docs, prompts, events, or examples
6. **Prompt text is guidance, not security** — runtime safety enforced in Elixir code
7. **Planning Muse uses read-only tools only** before plan approval
8. **Coding Muse prepares patches only after plan approval AND a scoped implementation/patch-proposal gate** — not merely `/approve plan` in PR 09
9. **File writes require patch approval**; shell commands require explicit approval
10. **Network disabled or approval-gated by default**; remote execution always denied until later milestone
11. **Secrets never appear** in prompt previews, logs, events, crash text, or provider debug output
12. **Every important step emits structured events** for CLI/TUI/LiveView and persistence

---

## 3. Architecture

### Runtime Path

```text
User input
  → CLI / TUI / LiveView
  → Muse.submit/2
  → SessionRouter → SessionServer (GenServer, owns state)
  → Conductor (Task, NOT inside SessionServer)
  → Prompt.Assembler
  → LLM.Provider
  → Tool.Runner
  → ApprovalGate
  → SessionStore + State + PubSub
  → CLI / TUI / LiveView updates
```

### Process Architecture

```text
Muse.Application
├── Registry (:unique keys)
├── SessionSupervisor (DynamicSupervisor)
│   └── SessionServer (GenServer, one per session)
│       └── owns: session state, event log, persistence
├── Muse.Telemetry
└── [Phoenix web supervision tree]

Each turn → TurnRunner (Task):
  1. Reads state from SessionServer
  2. Runs Conductor model/tool loop
  3. Writes results back to SessionServer
  4. Emits events via State / PubSub
```

> **Key decision:** Conductor runs in caller process or Task, **not inside SessionServer**. This ensures SessionServer never blocks on model calls, remains responsive for status/approvals during turns, and a crashed Conductor doesn't kill the session.

---

## 4. PR Roadmap

| PR | Goal | Key Scope |
|---|---|---|
| 00 | Baseline verification & naming cleanup | Verify repo, record tests, add PLAN.md, Muse-first naming |
| 01a | Event metadata & core structs | Extend Event, add Session/Turn/Telemetry structs |
| 01b | SessionStore persistence | Crash-safe JSONL, atomic writes, corrupt-line handling |
| 01c | SessionServer & routing | GenServer per session, DynamicSupervisor, Registry, route submit/2 |
| 02 | Streaming event API | Delta events, CLI stream printer, LiveView replay, `streamed?` flag |
| 03 | LLM contract & fake provider | Provider behavior, normalized structs, fake provider, config validation |
| 04 | Muse profiles & registry | MuseProfile, Planning/Coding profiles, `/muses` command |
| 05 | Prompt assembler & redacted preview | Layer/Bundle, project rules, redactor, ModelPreparer, `/prompt preview` |
| 06 | Read-only tools & workspace hardening | Tool Spec/Registry/Runner, list_files/read_file/repo_search/git_*, symlink & secret safety |
| 07a | Conductor — Muse selection & prompt building | Select Muse, build bundle, call fake provider, emit events |
| 07b | Conductor — tool loop | TurnRunner Task, iterative tool calls, caps, cancellation, blocked-tool handling |
| 08 | Structured plan model & Planning Muse MVP | Plan/Task structs, parser, validation, `/plan`, session `:awaiting_plan_approval` |
| 09 | Approval Gate & plan approval | Approval struct, ApprovalGate, `/approve plan`, `/reject plan`, stale prevention · *approval records plan decision only — no implementation, patching, or workspace writes* |
| 10 | **Read-only Planning Muse milestone** 🔒 | End-to-end hardening, integration test, fake provider script, no writes |
| 11 | Provider config & request mappers | ProviderConfig, Responses/ChatCompletions JSON mappers, secret redaction |
| 12 | OpenAI-compatible non-streaming provider | Encoder/decoder, req dep, custom base_url, redacted errors |
| 13 | Auth layer | API key, bearer command, Codex cache bridge, `/auth status` |
| 14 | HTTP SSE provider | SSE parser, event normalizer, streaming deltas/tool calls |
| 15 | Responses WebSocket provider | Persistent WS, previous_response_id, SSE fallback |
| 16 | Optional external WebSocket channel | Phoenix channel for non-LiveView clients, event filtering |
| 17 | Coding Muse patch proposal | Patch struct/parser/formatter, `patch_propose` tool, hash, `/approve patch` |
| 18 | Patch apply, checkpoint, rollback | Checkpoint store, `patch_apply`/`rollback_checkpoint` tools, git stash preferred |
| 19 | Test runner, Testing & Reviewing Muse | Safe test commands, bounded repair, review findings & recommendations |
| 20 | CLI/TUI/LiveView integration polish | Unified commands, session panels, Muse-first strings everywhere |
| 21 | Memory & Restoration Muse, handoffs | Compaction, memory.md, specialist handoffs via Conductor |
| 22 | Documentation & developer onboarding | README, provider setup, safety model, architecture docs |
| 23 | Additional providers & model routing | OpenRouter, Ollama, Anthropic, per-Muse model pinning |
| 24 | Remote execution (later) | Runner abstraction, local runner, future SSH/remote, strict approvals |

**Critical path:** `00 → 01a/01b/01c → 02 → 03 → 04 → 05 → 06 → 07a/07b → 08 → 09 → 10` (Milestone 1) `→ 11-15` (Providers) `→ 17-19` (Patch/Test/Review) `→ 20-24` (Polish/Extensions)

---

## 5. Naming Rules

### Product Roles

| Role | User-Facing Name | Purpose |
|---|---|---|
| Orchestration | Muse Conductor | Selects Muse, manages turns, permissions, plans, tools, handoffs |
| Planning | Planning Muse | Inspects workspace, creates approval-gated plans |
| Coding | Coding Muse | Implements approved changes via patches |
| Review | Reviewing Muse | Reviews diffs, architecture, risk, security |
| Testing | Testing Muse | Runs and interprets verification steps |
| Research | Research Muse | Searches repo, reads files, gathers context |
| Memory | Memory Muse | Summarizes sessions, preserves compact context |
| Restoration | Restoration Muse | Diagnoses failures, restores checkpoints |
| Tools | Tool Muse | Represents controlled tool access (v0: registry label, not chat persona) |

### Required User-Facing Terms

`Muse` · `Muses` · `Planning Muse` · `Coding Muse` · `Reviewing Muse` · `Testing Muse` · `Research Muse` · `Memory Muse` · `Restoration Muse` · `Tool Muse` · `Muse Conductor` · `Muse Runtime` · `Muse Tools` · `Muse Session` · `Muse Plan` · `Muse Checkpoint`

### Avoid in User-Facing Text

`Agent` · `Planning Agent` · `Coding Agent` · `Worker Agent` · `Bot` · `Mascot names` · `Code Puppy branding`

### Module Naming

```text
lib/muse/conductor.ex          lib/muse/muses/planning_muse.ex
lib/muse/conductor/turn_runner.ex   lib/muse/muses/coding_muse.ex
lib/muse/conductor/tool_loop.ex     lib/muse/muses/reviewing_muse.ex
lib/muse/muse_profile.ex            lib/muse/muses/testing_muse.ex
```

---

## 6. Milestones

**M1 — Read-Only Planning Muse.** User request → session → Planning Muse inspects with read-only tools → structured plan persisted → `:awaiting_plan_approval`. No files modified, no shell run, no implementation before approval.

**M2 — Basic Coding Muse.** After plan approval → Coding Muse proposes patch → diff shown → `:awaiting_patch_approval`. No file modified before `/approve patch`.

**M3 — Patch Apply, Verification, Rollback.** Approved patch → checkpoint → apply → git diff visible → optional safe test commands → rollback works. Bounded repair, not infinite loops.

**M4 — Real Providers & Auth.** Same M1/M2 flows work with OpenAI-compatible provider. Fake provider remains test default. SSE streaming normalizes to same event types. Secrets redacted everywhere.

**M5 — Specialist Muses, Memory, Recovery.** Memory compaction, Restoration Muse, controlled handoffs. Only after local runtime is safe and stable.

---

## 7. Definition of Done

### Read-Only Planning Muse (M1)

- Session created/resumed, Conductor selects Planning Muse
- Prompt bundle assembled, fake provider drives model/tool loop
- Planning Muse uses read-only tools (list, read, search, git)
- Structured plan created, persisted, shown by `/plan`
- Session status `:awaiting_plan_approval`; CLI/TUI/LiveView show plan
- `/approve plan` records the plan decision only — does not start implementation, patching, shell/network, or workspace writes
- **Zero files modified, zero shell commands, zero implementation handoffs**

### Muse Runtime v0

- `Muse.submit/2` routes through SessionServer + Conductor
- Sessions persist to `.muse/sessions/`; prompt assembly is deterministic
- `/prompt preview` redacts secrets; fake + OpenAI-compatible providers work
- Planning Muse → read-only tools → plan → approval required before Coding Muse
- Coding Muse → patch proposal → approval → checkpoint → apply → rollback works
- Safe test runner, Testing/Reviewing Muse loops, bounded repair
- CLI/TUI/LiveView share events; no API keys leaked anywhere
- SessionServer responsive during turns; cancellation works

### OpenAI-Specific

- `OPENAI_API_KEY` streams Responses API over SSE when configured
- Chat Completions provider streams text from compatible endpoint
- Responses WebSocket connects, stores `previous_response_id`
- Tool-call events from real providers normalize identically to fake provider
- Codex auth cache detected/used only when explicitly configured; OAuth tokens never logged

---

## 8. Detailed Docs

| Document | Content |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Process architecture, data models, module map, tool system, Conductor, CLI/TUI/LiveView, telemetry, approvals |
| [`docs/prompts.md`](docs/prompts.md) | All Muse profiles and prompt templates (core, planning, coding, reviewing, testing, memory, restoration) |
| [`docs/provider-roadmap.md`](docs/provider-roadmap.md) | Provider/auth implementation details, config models, wire APIs, transports |
| [`docs/testing.md`](docs/testing.md) | Testing strategy: fake provider, offline-first, integration tests |
| [`docs/security.md`](docs/security.md) | Security checklist: workspace safety, symlink awareness, secret redaction, approval enforcement |

---

## 9. Explicitly Out of Scope

Remote VPS/SSH execution · Remote Muse sessions · Phoenix remote LiveView monitoring · Remote tool execution · Autonomous shell loops · Browser automation · Package installation · Network search · MCP servers/ecosystem · Multi-Muse delegation/swarm · Subagent swarm · Database persistence · Cloud sync · Large UI redesign · Complex memory before read-only planning works · Complex model router before one provider works

---

## 10. Backlog After v0

Streaming model responses (if not in v0) · Model router & per-Muse pinning · OpenRouter/Ollama/Anthropic presets · Memory compaction enhancements · Plan/task board UI · Reviewing/Testing/Restoration Muse polish · Remote VPS execution · SSH profiles · Phoenix LiveView remote monitoring · MCP server integration · Self-healing repair mode · Evaluation harness · Cost tracking · Token accounting · Prompt caching · History compaction · Specialized roles beyond core Muses
