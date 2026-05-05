# PR17 — Patch Proposal & Approval Flow

> **Metadata** | | |
> ---|---|---|
> **PR** | PR17 | Coding Muse patch proposal |
> **Bead** | `muse-1ki.3.1` | Status: `OPEN` · Priority: P2 · Type: task |
> **Coordinator** | `planning-agent-17020a` | Coordination-only; no code delivered |
> **Dependency** | `muse-1ki.2.6` (PR16 — Optional external WS channel) | Blocks *implementation*, not planning |
> **Branch** | `pr17/patch-proposal-planning` | Planning artifact only |
> **Phase** | Planning only | No code changes, no tests, no beads closed |

---

## 1. Objective

Enable Coding Muse to **propose a structured, parseable, content-hash-stable patch proposal** after a plan is approved, and to **gate execution on user approval** without modifying any file before `/approve patch`.

PR17 introduces **two distinct gates**:

| Gate | Scope | Purpose |
|---|---|---|
| **Pre-proposal gate** | `:patch_proposal` | User-granted permission for Coding Muse to prepare a *non-mutating* proposal after an approved plan exists. Satisfied by `/propose patch`. |
| **Post-proposal gate** | `:patch` | Approval of the generated proposal after review, bound to patch id/hash. Satisfied by `/approve patch proposal`. Future PR18 extends this to unlock `patch_apply`. |

Plan approval alone satisfies **neither** gate.

### PR17 Acceptance Criteria (from bead `muse-1ki.3.1`)

1. Coding Muse can prepare a patch **only after an approved plan** exists and the pre-proposal `:patch_proposal` scope is active.
2. The patch proposal is **parseable, formatable, and includes a stable hash**.
3. The proposal **diff is displayed** for user review.
4. The session enters `:awaiting_patch_approval` after a valid non-mutating proposal is returned — no file is modified before `/approve patch`.
5. Approval of a plan alone **does not unlock** `patch_propose`, `patch_apply`, write, shell, or network tools.

---

## 2. Current-State Analysis (post-PR09/PR10a)

### Modules in scope

| Module | Current state | PR17 relevance |
|---|---|---|
| `Muse.Approval` | Already has `:patch` kind, `:patch_id`, `:patch_hash` fields. Accepts `"patch_propose"` → `:patch` kind mapping. | Reuse/extend; `:patch` kind already routed |
| `Muse.ApprovalGate` | Has `:patch` in `@denied_scopes`, `@approval_scoped_tool_permissions`. No `:patch_proposal` or proposal-before-patch flow yet. | Needs distinct `:patch_proposal` scope for pre-proposal gate + `:patch` scope for post-proposal approval |
| `Muse.PlanBinding` | Stable content-hash binding for plans. No patch binding. | Patch proposal needs analogous but separate binding/hash |
| `Muse.Tool.Registry` | `patch_propose` and `patch_apply` are **blocked names**, not registered tools. | Must register `patch_propose` as read-only/non-mutating; keep `patch_apply` blocked |
| `Muse.Tool.Runner` | Blocks `patch_propose`, `patch_apply`, and dangerous look-alikes. | Must allow `patch_propose` when approval-gated; keep `patch_apply` hard-blocked |
| `Muse.MuseRegistry` | Coding Muse profile lists `patch_propose`/`patch_apply` in tool list (roadmap-only). | Unblock `patch_propose` for Coding Muse; keep `patch_apply` roadmap-only |
| `Muse.CommandDispatcher` | Has `:approve_plan`, `:reject_plan` handlers. No patch approval commands. | Add `/propose patch`, `/approve patch proposal`, `/reject patch`, `/patch status` |
| `Muse.SessionServer` | Handles `:approve_plan` via `handle_plan_lifecycle_command`. Session state `:awaiting_patch_approval` already defined in `Muse.Session`. | Wire two-gate lifecycle: `/propose patch` grants `:patch_proposal` scope; `/approve patch` transitions `:patch` approval. Session enters `:awaiting_patch_approval` after `patch_propose` returns a valid proposal. |
| `Muse.Session` | Status flow: `… → :executing → :awaiting_patch_approval → :verifying → :reviewing`. Status `:awaiting_patch_approval` already valid. | Transition to `:awaiting_patch_approval` after `patch_propose` returns a valid non-mutating proposal |
| `Muse.Conductor` | Handles plan lifecycle routing, turn execution, tool loops. | Add `:patch_proposal` scope routing, `:patch_approval_requested` event, patch-proposal turn phase |
| Fake provider tests | Use scripted event batches. Reference events `:patch_approval_requested`, `:patch_approved`, `:patch_applied`. | Add PR17 fixtures: patch proposal tool-call events, approval flow batches |

---

## 3. Dependency Status: `muse-1ki.2.6` (PR16)

| Question | Answer |
|---|---|
| Does `muse-1ki.3.1` depend on `muse-1ki.2.6`? | **Yes** — `muse-1ki.3.1` `DEPENDS ON → muse-1ki.2.6` |
| Does PR16 block *planning*? | **No** — this plan artifact is independent of WS channel details |
| Does PR16 block *implementation*? | **Partially** — PR16 defines the external WS channel contract. If PR17 implementation exposes patch-proposal events to external clients, it must respect PR16 event-filtering/safety semantics. **Recommendation**: design events now, implement without external WS dependency, add WS integration in a separate pass after PR16 merges. |
| Mitigation | Finalize event names/types in this plan (`:patch_proposal_created`, `:patch_approval_requested`, `:patch_approved`, `:patch_rejected`). The actual WS delivery of these events becomes a PR16 integration task, not a PR17 blocker. |

---

## 4. Safety Invariant (Critical)

> **Plan approval alone does NOT unlock `patch_propose`, `patch_apply`, write, shell, or network tools.**

Enforcement chain:
1. `Muse.ApprovalGate.require_approved_scope(:patch_proposal, …)` requires an explicit pre-proposal scope for the session and plan — plan approval alone is insufficient.
2. `Muse.Tool.Runner` checks `:patch_proposal` scope before executing `patch_propose` — returns block error without valid scope.
3. `Muse.Tool.Registry` does NOT register `patch_apply` — still hard-blocked.
4. Write/shell/network tools remain blocked per existing registry rules.
5. `patch_propose` runs as a **non-mutating** read-only tool; session transitions to `:awaiting_patch_approval` only after it returns a valid `PatchProposal` artifact.
6. No apply/write/shell/network can occur before `/approve patch`. Even after approval, PR17 still does **not** apply files — that is PR18 scope.

---

## 5. Proposed Product Flow

```
Approved Plan exists  ──►  User: "/propose patch"
                                │
                    ┌─── Grant :patch_proposal scope ───┐
                    │                                    │
                    Coding Muse turn starts,             │
                    has :patch_proposal scope            │
                                │                        │
                    Coding Muse calls patch_propose tool │
                    (gated on :patch_proposal scope)     │
                                │                        │
                    Tool produces structured PatchProposal─┘
                        with stable hash, diff preview
                        (non-mutating — no files written)
                                │
                    Session → :awaiting_patch_approval
                    Event: :patch_approval_requested
                                │
                    ┌───────────┴───────────┐
                    │                       │
          User: "/approve patch"    User: "/reject patch"
          (:patch approval)       (reject)
                    │                       │
         Event: :patch_approved    Event: :patch_rejected
         Session stays in          Session → :idle (or :executing)
         :awaiting_patch_approval  Plan remains approved;
         (future PR18: transition  user may re-propose later
          to apply phase)
```

**Key constraint**: No file is modified before `/approve patch`. The `patch_propose` tool is non-mutating — it analyzes, sources the plan, and produces an artifact without writing to disk. Two distinct gates: `:patch_proposal` scope unlocks the non-mutating proposal tool; `:patch` scope (via `/approve patch`) approves the generated proposal for future PR18 apply.

---

## 6. Proposed Data Model: `Muse.PatchProposal`

### Module: `lib/muse/patch_proposal.ex`

```elixir
defmodule Muse.PatchProposal do
  @enforce_keys [:id, :session_id, :plan_id, :plan_version, :plan_hash, :status]
  defstruct [
    :id,              # unique patch proposal id
    :session_id,      # session that produced this proposal
    :plan_id,         # originating approved plan id
    :plan_version,    # plan version at proposal time
    :plan_hash,       # plan content hash at proposal time
    :patch_hash,      # stable SHA-256 of patch content (files + hunks)
    :workspace,       # workspace root
    :files,           # list of %{path: string, hunks: [hunk], new?: bool}
    :summary,         # human-readable summary of changes
    :status,          # :proposed | :approved | :rejected | :superseded
    :created_at,
    :approved_at,
    :rejected_at,
    :approved_by,
    :rejected_by,
    metadata: %{}
  ]

  @type t :: %__MODULE__{...}

  # Stable field list for content hash (excludes timestamps, status, metadata)
  @stable_fields [...]

  def content_hash(%__MODULE__{} = proposal)  # SHA-256 over stable fields
  def parse(json_string)                      # parse from LLM output
  def format(%__MODULE__{} = proposal)        # render for display
  def to_map(%__MODULE__{} = proposal)
  def from_map(map)
  def redacted_preview(%__MODULE__{} = proposal)  # safe for events/UI
end
```

### Fields detail

| Field | Type | Description |
|---|---|---|
| `id` | `String.t()` | Unique proposal id |
| `session_id` | `String.t()` | Session that owns the proposal |
| `plan_id` | `String.t()` | Originating approved plan |
| `plan_version` | `integer()` | Plan version at proposal time |
| `plan_hash` | `String.t()` | Plan content hash at proposal time |
| `patch_hash` | `String.t()` | Stable SHA-256 of patch content |
| `files` | `[file_entry()]` | List of file changes with hunks |
| `summary` | `String.t()` | Readable summary |
| `status` | `:proposed \| :approved \| :rejected \| :superseded` | Lifecycle |
| `created_at` | `DateTime.t()` | Creation timestamp |
| `approved_at` | `DateTime.t()` | Approval timestamp |
| `rejected_at` | `DateTime.t()` | Rejection timestamp |
| `approved_by` | `String.t()` | Approver identity |
| `rejected_by` | `String.t()` | Rejector identity |
| `metadata` | `map()` | Extensible metadata |

### File entry

```elixir
%{
  path: "lib/my_app/file.ex",
  hunks: [
    %{
      type: :edit | :add | :remove,
      old_start: 10, old_count: 5,
      new_start: 10, new_count: 7,
      lines: ["- old line", "+ new line", " unchanged"]
    }
  ],
  new?: false
}
```

### Hash stability

`content_hash/1` serializes only `@stable_fields` (sorted keys, deterministic encoding via `:erlang.term_to_binary([:deterministic])`), producing a SHA-256 hex digest. Excludes `status`, timestamps, `approved_by`, `metadata`, `summary`.

### Redacted preview

`redacted_preview/1` strips raw line content, keeping only file paths, hunk locations, and line counts. Safe for events, LiveView display, and WS delivery.

---

## 7. Proposed `ApprovalGate` Extension

### Module: `lib/muse/approval_gate.ex` — additions

| Function | Purpose |
|---|---|
| `capture_patch_binding(patch_proposal, opts)` | Capture binding when patch proposal is created (similar to `capture_binding` for plans) |
| `require_patch_proposal_scope(session, plan, opts)` | Gate producing a proposal: must have an approved plan AND an active `:patch_proposal` scope granted by `/propose patch` |
| `require_patch_approval(session, plan, patch_proposal, scope)` | Require a `:patch`-scope approval tied to the specific proposal id/hash |
| `approve_patch(session_id, plan, patch_proposal, opts)` | Transition patch approval to `:approved`; validate binding against current proposal |
| `reject_patch(session_id, plan, patch_proposal, opts)` | Transition patch approval to `:rejected` |

### Binding semantics

- A `:patch_proposal` scope binds to `plan_id`, `plan_version`, `plan_hash`, `session_id`, `workspace`. It does **not** require a patch to exist yet.
- A `:patch` approval binds to `plan_id`, `plan_version`, `plan_hash`, `patch_id`, `patch_hash`, `session_id`, `workspace`.
- Plan approval does NOT satisfy either `:patch_proposal` or `:patch` scope checks.
- Stale detection: if the plan is superseded or the patch hash changes, existing patch approvals become stale.

---

## 8. Proposed `Tool.Registry` / `Tool.Runner` Changes

### `Muse.Tool.Registry`

| Change | Detail |
|---|---|
| Remove `patch_propose` from `@blocked_tool_names` | It becomes a registered tool |
| Add `patch_propose` spec | Compile-time spec with `:read` permission (non-mutating). See spec below. |
| Keep `patch_apply` in `@blocked_tool_names` | Still blocked until PR18 |
| Keep destructive tokens in `@blocked_tool_tokens` | No change to token-based blocking |

### `patch_propose` spec

```elixir
Spec.new!(
  name: "patch_propose",
  description: "Propose a patch based on an approved plan. Analyzes workspace and produces a structured PatchProposal with stable hash. No files are modified.",
  handler: Muse.Tools.PatchPropose,
  permission: :read,        # Non-mutating — no write/shell/network
  input_schema: %{
    type: "object",
    properties: %{
      plan_id: %{type: "string", description: "Approved plan id to implement"},
      scope: %{type: "string", description: "Optional scope constraint"}
    }
  },
  output_schema: %{
    type: "object",
    properties: %{
      patch_proposal: %{type: "object"},
      summary: %{type: "string"},
      files_changed: %{type: "integer"},
      warning: %{type: "string"}
    }
  },
  requires_approval: :patch_proposal, # Must have pre-proposal scope — not :patch (no proposal exists yet)
  requires_plan_approval: true         # An approved plan must exist
)
```

### `Muse.Tool.Runner`

| Change | Detail |
|---|---|
| Gate `patch_propose` on `requires_approval: :patch_proposal` scope | Run `ApprovalGate.require_patch_proposal_scope/2` before executing |
| Add separate gate for `:patch` scope | `patch_propose` uses `:patch_proposal`; post-proposal `:patch` approval gates `patch_apply` (PR18) |
| Add check: `requires_plan_approval` | Verify plan is approved and not stale before allowing the tool |
| No change to `patch_apply` blocking | Still hard-blocked until PR18; even then requires `:patch` approval |
| Event emission: add `:tool_call_patch_proposed` event | Distinct from `:tool_call_completed`; includes proposal summary |

---

## 9. Proposed `SessionServer` / `Conductor` Flow

### Session states

```
:executing ──► [grant :patch_proposal scope] ──► Coding Muse runs patch_propose
                                                      │
                                              valid PatchProposal returned
                                                      │
                                              :awaiting_patch_approval ──► ... (future PR18)
                                                                   │
                                                         ┌─────────┴─────────┐
                                                    /approve patch    /reject patch
                                                    (:patch approve)  (reject)
                                                         │                    │
                                                   :awaiting_patch_   :executing (or :idle)
                                                   approval (stay)    plan stays approved
```

### Event names

| Event | Trigger |
|---|---|
| `:patch_proposal_scope_granted` | User runs `/propose patch` — `:patch_proposal` scope activated for session |
| `:patch_proposal_created` | `patch_propose` tool returns valid `PatchProposal` |
| `:patch_approval_requested` | Session transitions to `:awaiting_patch_approval` |
| `:patch_approved` | User runs `/approve patch proposal` — `:patch` scope approved |
| `:patch_rejected` | User runs `/reject patch` |
| `:patch_approval_expired` | Patch approval TTL elapsed (future) |

### `SessionServer` additions

| Handler | Route |
|---|---|
| `handle_call({:approve_patch, source}, …)` | Analogous to `handle_plan_lifecycle_command` |
| `handle_call({:reject_patch, source}, …)` | Analogous plan rejection |
| `handle_call({:patch_status, …})` | Returns patch proposal + approval status |
| `emit_event(:patch_approval_requested, …)` | New event emission helper |

### `Conductor` additions

| Change | Detail |
|---|---|
| `handle_turn_completed` → check for patch proposal | If turn output contains a parseable `PatchProposal`, extract, validate, emit events, transition session |
| `route_patch_approval(session, plan, proposal, :approved)` | Post-approval routing (for PR17: just ack; for PR18: trigger apply) |
| Tool-loop continuation after patch proposal | Stay in `:awaiting_patch_approval`, do not automatically continue the tool loop |

---

## 10. CLI Commands

### Proposed command set

| Command | Alias | Scope | Handler | Description |
|---|---|---|---|---|
| `/propose patch` | — | Grants `:patch_proposal` pre-proposal scope | `:propose_patch` | Request Coding Muse to produce a patch proposal from the approved plan. Activating `:patch_proposal` does not create a proposal — it only permits the tool call. |
| `/approve patch proposal` | `/approve patch` | Approves `:patch` scope | `:approve_patch` | Approve a pending patch proposal, bound to patch id/hash |
| `/reject patch` | — | Rejects `:patch` scope | `:reject_patch` | Reject a pending patch proposal |
| `/patch status` | — | — | `:patch_status` | Show current patch proposal + approval state |

### Tradeoff: long vs short command names

| Option | Pros | Cons |
|---|---|---|
| `/approve patch proposal` | Explicit, unambiguous, parallels `/approve plan` | Longer to type, more parsing surface |
| `/approve patch` | Shorter, natural | Ambiguous: overlaps with `:patch_apply` in future PR18. Could mean approve proposal vs approve apply. |

**Recommendation**: Accept both `/approve patch proposal` and `/approve patch` as aliases. When a `PatchProposal` exists and is pending, both resolve to approving the proposal. In PR18, `/approve patch` may additionally trigger apply — disambiguate by context (if proposal without apply, approve proposal; if apply pending, approve apply).

### `CommandDispatcher` additions

```elixir
# In parse/1:
"/propose patch"           -> {:approve_patch, :propose}
"/approve patch proposal"  -> {:approve_patch, :approve}
"/approve patch"           -> {:approve_patch, :approve}
"/reject patch"            -> {:approve_patch, :reject}
"/patch status"            -> {:approve_patch, :status}
```

### Add to `Muse.Commands`

```elixir
{"/propose patch", :propose_patch, ...},
{"/approve patch proposal", :approve_patch, ...},
{"/approve patch", :approve_patch, ...},
{"/reject patch", :reject_patch, ...},
{"/patch status", :patch_status, ...}
```

---

## 11. Persistence, UI, Docs, Redaction

### Persistence

| Requirement | Detail |
|---|---|
| Patch proposals persisted in session snapshots | `Muse.SessionStore` snapshots include patch proposals array |
| Patch approvals persisted in session approvals | Stored alongside plan approvals in session state |
| Patch proposal serialization | `Muse.PatchProposal.to_map/1` / `from_map/1` for JSON persistence |

### UI requirements

| Requirement | Detail |
|---|---|
| Patch proposal displayed in session | Show files changed, hunks summary, line counts, patch hash |
| Approval prompt rendered in LiveView | Similar to plan approval waiting state |
| Patch status in `/status` output | Show whether proposal exists, its status, approval status |

### Docs

| File | Change |
|---|---|
| `docs/architecture.md` | Add PatchProposal data model, approval flow diagram |
| `docs/prompts.md` | Add Coding Muse prompt changes for `patch_propose` tool |
| `docs/testing.md` | Add PR17 test suite documentation |
| `docs/security.md` | Add patch proposal security model: no mutation before approval, redaction rules |

### Redaction

- `Muse.Approval.event_payload/1` already strips raw content and redacts via `Muse.EventPayloadRedactor`.
- `Muse.PatchProposal.redacted_preview/1` must exclude raw file content, secrets, paths outside workspace.
- Events carry only `content_ref` (hash + byte count + algorithm), not hunks.

---

## 12. Test Matrix

### Core unit tests

| Test | File | Coverage |
|---|---|---|
| `Muse.PatchProposal` struct, parse/format roundtrip, content_hash, to_map/from_map, redacted_preview | `test/muse/patch_proposal_test.exs` | All fields, hash stability, JSON roundtrip, redaction safety |
| `Muse.ApprovalGate` patch scope | `test/muse/approval_gate_test.exs` | `capture_patch_binding`, `require_patch_approval`, stale detection, scope denial |
| `Muse.Tool.Registry` patch_propose registration | `test/muse/tool/registry_test.exs` | `patch_propose` registered, not blocked; `patch_apply` still blocked |
| `Muse.Tool.Runner` patch_propose gating | `test/muse/tool/runner_test.exs` | Patch proposal allowed with approval; blocked without; `patch_apply` still blocked |
| `Muse.CommandDispatcher` patch commands | `test/muse/command_dispatcher_test.exs` | Parse/dispatch for all 4 commands, unknown subcommand handling |
| `Muse.Session` patch proposal states | `test/muse/session_test.exs` | Valid transitions involving `:awaiting_patch_approval` |

### Integration tests

| Test | File | Coverage |
|---|---|---|
| Full flow: plan approved → patch proposed → approved | `test/muse/m1_read_only_planning_test.exs` (extend PR09 suite) | Scripted events: plan approved, Coding Muse turn, patch_propose tool call, patch approval requested, user approves |
| Full flow: plan approved → patch proposed → rejected | Same | Rejection path, session returns to idle/executing |
| Safety: no patch_propose without `:patch_proposal` scope | `test/muse/m1_read_only_planning_test.exs` | Assert block when no `:patch_proposal` scope granted |
| Safety: no patch_apply in PR17 | `test/muse/tool/runner_test.exs` | `patch_apply` hard-blocked |
| Fake provider: patch proposal tool batch | `test/support/muse/` (new fixture) | Scripted batch with `patch_propose` tool call, expected PatchProposal output |

### Property-based tests (optional, future)

| Test | Rationale |
|---|---|
| PatchProposal parse/format identity | Fuzz roundtrip property |
| Content hash determinism | Same content → same hash across serialization methods |

---

## 13. Parallel Lane Breakdown

| Lane | Recommended Agent | Scope |
|---|---|---|
| **Lane A — Data model** | `elixir-expert` | `Muse.PatchProposal` struct, parse/format, content_hash, to_map/from_map, redacted_preview |
| **Lane B — Approval gate** | `elixir-expert` or `code-puppy` | `ApprovalGate` `:patch_proposal` and `:patch` scopes: `require_patch_proposal_scope`, `require_patch_approval`, approve/reject_patch, stale detection |
| **Lane C — Tool registry/runner** | `code-puppy` | `Tool.Registry`: unblock `patch_propose`, add spec. `Tool.Runner`: gate on `:patch_proposal` scope, `requires_plan_approval` check |
| **Lane D — Command dispatcher** | `code-puppy` | `CommandDispatcher` `/propose patch`, `/approve patch`, `/reject patch`, `/patch status`; `Muse.Commands` registration |
| **Lane E — SessionServer/Conductor** | `elixir-expert` | SessionServer approve_patch/reject_patch/patch_status handlers; Conductor patch proposal turn routing; event emission |
| **Lane F — Tests** | `elixir-expert` | All unit, integration, and fixture tests from section 12 |
| **Lane G — Docs** | `code-puppy` | Architecture, prompts, testing, security doc updates |
| **Lane H — Security review** | `security-auditor` (role, not available as agent) | Verify patch proposal does not leak file contents, respects workspace bounds, cannot be used as side-channel for writes. If unavailable, `elixir-code-critic` can perform a focused review. |

### Agent availability notes

- `elixir-code-critic`: Available for review; not primary implementer.
- `qa-expert` / `qa-kitten`: Primarily for browser/LiveView QA — not primary for this PR (no new LiveView flows planned beyond status display). If LiveView patch-status UI is added, escalate to `qa-kitten`.
- `security-auditor`: Not available as named agent. Recommend manual review or `elixir-code-critic` for security-sensitive diff review.

### Lane ordering

```
Lane A (data model) ──► Lane B (approval gate)
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              Lane C (tool)   Lane D (cmd)   Lane E (session)
                    │              │              │
                    └──────────────┼──────────────┘
                                  ▼
                            Lane F (tests)
                                  │
                            Lane G (docs)
                                  │
                            Lane H (review)
```

Lanes A–E can run in parallel *after* A completes, since B–E depend on the `Muse.PatchProposal` struct. Lanes F–H depend on A–E.

---

## 14. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `patch_propose` tool runs long/complex analysis | Tool blocks session | Set tool timeout; run analysis as Task under supervisor; cap analysis scope |
| Patch proposal hash changes between creation and approval | Stale approval | Stale detection in `ApprovalGate.require_patch_approval` — reject if hash mismatches |
| `:patch_proposal` vs `:patch` scope confusion | Accidentally requiring proposal approval before proposal exists | Clear naming, distinct scope checks: `:patch_proposal` gates `patch_propose`; `:patch` gates approval of generated proposal |
| User approves patch, then uses `/propose patch` again | Multiple competing proposals | Session holds at most one pending patch proposal; new proposal supersedes old |
| LLM produces unparseable patch proposal | Flow blocked | `Muse.PatchProposal.parse` returns `:error`; session stays in `:executing`; emit parse-error event |
| LiveView coupling (if adding UI) | Not a blocker for PR17 | All flows are command-line based; LiveView patch-status view is optional scope |
| PR16 not merged before PR17 implementation | WS delivery delayed | Design events now; WS integration is a separate card after PR16 merges |

---

## 15. Alternative Approaches

### A. Pure text artifact (recommended baseline)

- Coding Muse outputs a JSON `PatchProposal` as its final turn text.
- `Muse.PatchProposal.parse/1` extracts from LLM response.
- No custom tool registration needed initially; `patch_propose` becomes a parsing step, not a tool call.
- **Pros**: Simpler initial implementation, no tool-registry change.  
- **Cons**: Loses tool-level gating, no structured handler, harder to extend in PR18.  
- **Recommendation**: Use as a fallback if tool-registry timeline is tight, but primary approach should be…

### B. Tool-call `patch_propose` (recommended primary)

- `patch_propose` is a registered read-only tool that Coding Muse calls explicitly.
- `Tool.Registry` controls availability.
- `Tool.Runner` gates on `requires_approval: :patch_proposal` and `requires_plan_approval: true`. The generated proposal is then approved via `:patch` scope — two distinct gates.
- **Pros**: Clean gating, structured input/output, extensible for PR18, testable in isolation.  
- **Cons**: More initial work; requires tool registration, handler module, runner changes.  
- **Recommendation**: **Primary approach** — aligns with architecture and future PR18 apply flow.

### C. Direct Coding Muse final-output parser

- Conductor extracts PatchProposal from the raw provider response without a tool call.
- No tool gating; approval is based entirely on session state.
- **Pros**: Minimal code change for MVP.  
- **Cons**: Bypasses the entire tool-safety layer; hard to extend; no structured handler.  
- **Recommendation**: **Not recommended** — bypasses too much safety infrastructure.

---

## 16. Decision Points / Questions for User

1. **Command naming**: Accept both `/approve patch proposal` and `/approve patch` as aliases? (Recommended: yes)
2. **PatchProposal tool vs text parser**: Tool-call approach (recommended) or text-parser fallback?
3. **Scope of PR17**: Does PR17 include ONLY the propose/approve/reject flow (no UI changes), or should a minimal LiveView patch-status panel be added?
4. **Multiple proposals**: Allow only one pending proposal per session (recommended) or multiple concurrent proposals?
5. **Patch proposal content**: Should hunks include full diff lines (recommended for review) or only line-number references with a summary?
6. **Approval expiration**: Should patch approvals have a TTL? If so, default? (Recommended: same 24h default as plan approvals)
7. **Pre-proposal scope name**: Use `:patch_proposal` scope (distinct from `:patch`) to gate `patch_propose`? (Recommended: yes — avoids circular dependency where a patch approval is required before a patch exists)
8. **Test scope**: Include property-based tests for PatchProposal roundtrip? (Recommended: defer to future)

---

## 17. Top Recommended Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Patch proposal mechanism | **Tool-call `patch_propose`** (approach B) |
| 2 | Command aliases | Accept both `/approve patch proposal` and `/approve patch` |
| 3 | PR17 scope | Propose + approve/reject flow only. No LiveView patch-status panel; defer to PR roadmap |
| 4 | Concurrent proposals | **One pending proposal per session** — new proposal supersedes old |
| 5 | Diff content | **Full hunk lines** in proposal for review; redacted for events |
| 6 | Approval TTL | **24h default** (same as plan approvals) |
| 7 | Property tests | **Defer** to future PR |
| 8 | PR16 WS integration | **Design events now, implement WS delivery after PR16 merges** — not a blocker |
| 9 | Plan approval → patch proposal/pre-proposal scope | Strict binding: plan_id + plan_version + plan_hash must match. Plan approval alone satisfies neither gate. |
| 10 | Pre-proposal scope name | **`:patch_proposal`** — distinct from `:patch` approval scope, avoiding circular dependency |

---

## Appendix A — Event Specification

```elixir
{:patch_proposal_scope_granted, %{
  session_id: "sess_xxx",
  plan_id: "plan_xxx",
  scope: :patch_proposal,
  granted_by: "user",
  granted_at: "2026-05-04T12:00:00Z"
}}

{:patch_proposal_created, %{
  session_id: "sess_xxx",
  plan_id: "plan_xxx",
  patch_id: "patch_xxx",
  patch_hash: "abc123...",
  files_count: 3,
  hunks_count: 12,
  summary: "Add user authentication module",
  content_ref: %{
    label: "patch_proposal",
    algorithm: "sha256",
    hash: "def456...",
    bytes: 2048
  }
}}

{:patch_approval_requested, %{
  session_id: "sess_xxx",
  plan_id: "plan_xxx",
  patch_id: "patch_xxx",
  patch_hash: "abc123...",
  status: :awaiting_patch_approval
}}

{:patch_approved, %{
  session_id: "sess_xxx",
  plan_id: "plan_xxx",
  patch_id: "patch_xxx",
  patch_hash: "abc123...",
  approved_by: "user",
  approved_at: "2026-05-04T12:00:00Z"
}}

{:patch_rejected, %{
  session_id: "sess_xxx",
  plan_id: "plan_xxx",
  patch_id: "patch_xxx",
  patch_hash: "abc123...",
  reason: "Scope too large, split into smaller patches",
  rejected_by: "user",
  rejected_at: "2026-05-04T12:05:00Z"
}}
```

---

## Appendix B — File Checklist

| File | Action | Lane |
|---|---|---|
| `lib/muse/patch_proposal.ex` | **Create** — struct, parse/format, content_hash, to_map/from_map, redacted_preview | A |
| `lib/muse/approval_gate.ex` | **Modify** — add `:patch_proposal` scope, `require_patch_proposal_scope`, `require_patch_approval`, `approve_patch`, `reject_patch` | B |
| `lib/muse/tool/registry.ex` | **Modify** — remove patch_propose from blocked list, add Spec | C |
| `lib/muse/tools/patch_propose.ex` | **Create** — handler module | C |
| `lib/muse/tool/runner.ex` | **Modify** — gate patch_propose on :patch scope + plan approval | C |
| `lib/muse/command_dispatcher.ex` | **Modify** — add propose_patch, approve_patch, reject_patch, patch_status | D |
| `lib/muse/commands.ex` | **Modify** — add new command registrations | D |
| `lib/muse/session_server.ex` | **Modify** — add scope-grant, approve_patch/reject_patch/patch_status handlers, event emission for both gates | E |
| `lib/muse/conductor.ex` | **Modify** — patch proposal turn routing, event emission | E |
| `lib/muse/session.ex` | **Verify** — :awaiting_patch_approval already defined | E |
| `test/muse/patch_proposal_test.exs` | **Create** — unit tests | F |
| `test/muse/approval_gate_test.exs` | **Modify** — add `:patch_proposal` and `:patch` scope tests | F |
| `test/muse/tool/registry_test.exs` | **Modify** — add patch_propose registration tests | F |
| `test/muse/tool/runner_test.exs` | **Modify** — add patch_propose gating tests for `:patch_proposal` scope | F |
| `test/muse/command_dispatcher_test.exs` | **Modify** — add patch command tests | F |
| `test/muse/m1_read_only_planning_test.exs` | **Modify** — add patch proposal integration tests | F |
| `test/support/muse/patch_proposal_fixtures.ex` | **Create** — fixture batches | F |
| `docs/architecture.md` | **Modify** — add patch proposal flow | G |
| `docs/prompts.md` | **Modify** — add Coding Muse patch proposal prompt | G |
| `docs/testing.md` | **Modify** — add PR17 test docs | G |
| `docs/security.md` | **Modify** — add patch proposal security model | G |

---

*This document is a planning artifact only. No code is delivered. Implementation should be executed by the recommended agents after user approval of the decisions in Section 16–17.*
