# PR 17 — Coding Muse Patch Proposal & Approval Lifecycle (Plan/Contract Artifact)

## 1. Title & Status

| Field | Value |
|---|---|
| **PR** | 17 |
| **Title** | Coding Muse patch proposal and approval lifecycle |
| **Bead** | `muse-1ki.3.1` |
| **Lane** | 01 — Plan/contract artifact |
| **Branch** | `pr17/lane01-contract-plan` |
| **Status** | 🟡 Planning (Lane 01 in progress) |
| **Owner** | asx8678 |

## 2. Executive Summary

PR17 implements the **patch proposal and approval lifecycle**: the user-facing workflow where Coding Muse prepares a concrete diff, the system displays it, and the user approves or rejects it via a structured `/approve patch` or `/reject patch` command.

**Critical boundary:** PR17 records the lifecycle decision only — it never applies files, creates checkpoints, or runs patch apply. Those behaviors belong to PR18.

PR17 closes the gap between "plan approved" (PR09) and "patch applied" (PR18). After PR17, the user can inspect a proposed patch and explicitly approve or reject it, with a full audit trail and content-bound integrity check.

## 3. Objective & Acceptance Criteria

**Objective:** When Coding Muse produces a patch proposal (via `patch_propose` tool call within a turn), the system captures a content-bound patch artifact, renders the diff for user review, and provides `/approve patch` / `/reject patch` commands that record a lifecycle decision — without applying any changes to disk.

**Acceptance criteria (derived from bead `muse-1ki.3.1`):**

1. Coding Muse can produce a patch proposal within a turn and have it rendered as a reviewable diff.
2. A patch proposal is parseable/formattable with a stable content hash (same design as `PlanBinding.content_hash/1`).
3. The proposed diff is displayed to the user with affected file paths.
4. The session enters `:awaiting_patch_approval` state after a patch is proposed.
5. `/approve patch` records approval with content-bound integrity check; it never applies files/checkpoints.
6. `/reject patch` records rejection with reason; the session returns to idle.
7. No file is modified, checkpoint created, or tool executed by the approval command itself.
8. Patch lifecycle events are emitted for audit.

## 4. Non-Goals (Explicit Out-of-Scope for PR17)

The following behaviors are **explicitly deferred to PR18**:

| Behavior | PR | Rationale |
|---|---|---|
| `patch_apply` tool execution | PR18 | Actual file write + checkpoint |
| Checkpoint creation before/after apply | PR18 | Requires `checkpoint_create` tool |
| Rollback/revert of applied patches | PR18 | Requires checkpoint restore |
| `test_runner` tool execution | PR19 (tentative) | Requires safe test sandbox |
| Shell command approval flow | PR19+ | Separate lifecycle |
| Automatic Coding Muse handoff on plan approval | PR17 | Handoff is a routing concern, not lifecycle |
| Patch conflict detection against HEAD | PR18 | Requires `git apply --check` |

**Design principle for `/approve patch`:** The command records a `%Muse.Approval{}` with `kind: :patch`, `status: :approved`, and a content-bound `patch_hash`. It must not invoke `patch_apply`, write files, create checkpoints, or switch active Muse. It is a pure lifecycle command, exactly parallel to `/approve plan`.

## 5. Current Code Anchors

### 5.1 `Muse.MuseRegistry` (`lib/muse/muse_registry.ex`)
- Coding Muse profile exists with `response_mode: :patch`, `permissions.write: :approval_required`, `can_write?: true`.
- Tool list includes `patch_propose`, `patch_apply`, `test_runner` (all currently blocked by Tool.Registry).
- `Conductor.select_muse/2` currently returns Planning Muse only; Coding Muse is defined but not yet selected by routing logic.

### 5.2 `Muse.Tool.Registry` (`lib/muse/tool/registry.ex`)
- `patch_propose` and `patch_apply` are explicitly listed in `@blocked_tool_names`.
- PR17 will need to unblock `patch_propose` (for Coding Muse only, after plan approval) while keeping `patch_apply` blocked for PR18.

### 5.3 `Muse.Tool.Runner` (`lib/muse/tool/runner.ex`)
- Runs tools with validation including permission checks via `Muse.ApprovalGate`.
- Emits `:tool_call_started`, `:tool_call_completed`, `:tool_call_failed`, `:tool_call_blocked`.
- PR17 requires the runner to accept `patch_propose` from Coding Muse when the session has an approved plan.

### 5.4 `Muse.Approval` (`lib/muse/approval.ex`)
- Already has `:patch_id`, `:patch_hash` fields and `:patch` kind with `kind_map` entries for `"patch"`, `"patch_apply"`, `"patch_propose"`.
- The struct is ready for patch approval records; no structural changes needed.

### 5.5 `Muse.ApprovalGate` (`lib/muse/approval_gate.ex`)
- Already has `:patch` in `@denied_scopes` and `@approval_scoped_tool_permissions`.
- `allowed?/2` returns `{:error, {:scope_denied, :patch}}` for patch scope.
- Scope normalization maps `"patch"`, `"patch_apply"`, `"patch_propose"` → `:patch`.
- PR17 will add `request_patch_approval/3`, `approve_patch/4`, `reject_patch/4` functions parallel to the existing plan approval API, plus a patch-specific `allowed?/2` path.

### 5.6 `Muse.PlanBinding` (`lib/muse/plan_binding.ex`)
- Deterministic content hashing pattern for plans. PR17 will create an analogous `PatchBinding` module (or extend `PlanBinding` to be `ContentBinding`) for computing stable content hashes over patch diffs.

### 5.7 `Muse.ApprovalAudit` (`lib/muse/approval_audit.ex`)
- Read-only rendering helpers for plan approval/rejection messages.
- PR17 will add `patch_approval_message/1` and `patch_rejection_message/1` with explicit "no files written" disclaimer.

### 5.8 `Muse.Commands` (`lib/muse/commands.ex`)
- Current commands include `/approve plan`, `/reject plan`.
- PR17 will add `/approve patch` (→ `:approve_patch`), `/reject patch` (→ `:reject_patch`).

### 5.9 `Muse.CommandDispatcher` (`lib/muse/command_dispatcher.ex`)
- Current `dispatch(:approve_plan, ...)` and `dispatch(:reject_plan, ...)` delegate to `dispatch_plan_lifecycle_command/3`.
- PR17 will add parallel `dispatch(:approve_patch, ...)` and `dispatch(:reject_patch, ...)` handlers that delegate to `dispatch_patch_lifecycle_command/3`.

### 5.10 `Muse.SessionServer` (`lib/muse/session_server.ex`)
- Initi state includes `:plan`, `:plans`, `:approvals`, `:approval_binding`, `:active_approval`.
- `approve_plan/2` and `reject_plan/2` delegate to `handle_plan_lifecycle_command/3` → `transition_active_plan/5`.
- PR17 will add `:patch`, `:patches`, `:patch_approval_binding` to init state, plus `approve_patch/2`, `reject_patch/2` API and `handle_patch_lifecycle_command/3`.

### 5.11 `Muse.SessionRouter` (`lib/muse/session_router.ex`)
- Routes approve/reject to SessionServer by session_id.
- PR17 will add `approve_patch/2` and `reject_patch/2`.

### 5.12 `Muse.State` / `Muse.Event` (unchanged)
- Event struct is already adequate. No structural changes needed.

### 5.13 `Muse.EventDisplay` (`lib/muse/event_display.ex`)
- Has `plan_lifecycle_summary/2` for `:plan_created`, `:plan_approved`, `:plan_rejected`, `:approval_requested`.
- PR17 will add patch lifecycle summary handlers.

### 5.14 `MuseWeb.ConsoleCommand` (`lib/muse_web/console_command.ex`)
- Builds context and delegates to `CommandDispatcher`.
- `apply_effects/2` handles `{:refresh, :events}` etc.
- PR17 will add `{:refresh, :patch}` effect if needed, or reuse `{:refresh, :events}`.

### 5.15 `docs/architecture.md`
- §10.1 already describes patch proposal display format.
- §10.2 describes patch apply policy (PR18).
- §11 describes PR17/PR18 as future approval flows.

### 5.16 `docs/security.md`
- §1 security checklist includes "Patch apply blocks secret file paths" (PR18).
- §6 plan approval lifecycle security (PR09).

## 6. Product Contract

### 6.1 What it is

A user-visible patch proposal and approval lifecycle that:

1. **Coding Muse produces a patch** — Within a turn after plan approval, Coding Muse calls `patch_propose` with a unified diff. The tool validates the diff (paths inside workspace, no binaries, size cap), computes a content hash, and returns a `patch_id`.
2. **Patch is displayed** — The system renders the diff with affected file paths and instructions for `/approve patch` or `/reject patch`.
3. **Session enters `:awaiting_patch_approval`** — The session state transitions from `:running` or `:idle` to `:awaiting_patch_approval` after the patch is stored.
4. **User runs `/approve patch`** — The command validates that a patch is pending, checks content hash integrity, records a `%Muse.Approval{}` with `kind: :patch, status: :approved`, emits patch lifecycle events, and returns the session to `:idle`. **No files are written.**
5. **User runs `/reject patch`** — The command records rejection with reason, emits events, returns to `:idle`. The patch artifact remains in session history for audit.
6. **Audit trail** — All lifecycle decisions are captured as events with session_id, patch_id, patch_hash, actor, and timestamp.

### 6.2 What it is NOT

- **Not a file writer** — `/approve patch` does not invoke `patch_apply`, `write_file`, or any disk mutation.
- **Not a checkpoint creator** — No checkpoint is created by approval.
- **Not a test runner** — No tests are run by approval.
- **Not a Coding Muse handoff trigger** — Approval does not automatically start a Coding Muse turn.
- **Not a substitute for plan approval** — A plan must be approved first before a patch can be proposed or approved. Patch approval does not imply or override plan approval.

### 6.3 Configuration

No new configuration is required for PR17. The existing profile/tool infrastructure in `Muse.MuseRegistry` and `Muse.Tool.Registry` controls availability.

| Config | Effect |
|---|---|
| `:coding` profile tools include `patch_propose` | Enables patch proposal (already configured) |
| `patch_propose` unblocked in `Tool.Registry` for Coding Muse after plan approval | PR17 scope |
| `patch_apply` remains blocked in `Tool.Registry` | PR17 keeps this blocked (PR18 unblocks) |

## 7. Session State Transitions

### 7.1 New session statuses

PR17 introduces `:awaiting_patch_approval` to the session status lifecycle alongside the existing `:awaiting_plan_approval`.

```
:idle → :planning → :awaiting_plan_approval → :idle (or :running)
  ↓ (user submits to Coding Muse after plan approval)
:running (Coding Muse turn) → :awaiting_patch_approval
  ↓ (/approve patch)
:idle (patch approved, no files changed)
  ↓ (/reject patch)
:idle (patch rejected)
```

### 7.2 Session state fields (additions to `SessionServer.init/1`)

```elixir
# Add to init state:
patch: nil,                            # Current pending %Patch{} struct
patches: %{},                          # %{patch_id => %Patch{}}
patch_approval_binding: nil,           # Binding captured at proposal time
active_patch_approval: nil,            # Current %Approval{} for this patch
```

### 7.3 Patch struct (`Muse.Patch`, new module)

```elixir
defmodule Muse.Patch do
  defstruct [
    :id,               # "patch_<uuid>"
    :session_id,
    :turn_id,
    :plan_id,
    :plan_version,
    :diff,             # Unified diff text (capped)
    :diff_hash,        # SHA-256 of normalized diff content
    :affected_files,   # [String.t()] — file paths extracted from diff headers
    :status,           # :proposed | :approved | :rejected | :stale | :applied
    :byte_size,
    :created_at,
    :approved_at,
    :rejected_at,
    :applied_at,       # PR18
    metadata: %{}
  ]
end
```

### 7.4 Patch status lifecycle

```
:proposed → :approved → (PR18: → :applied)
         ↘ :rejected
         ↘ :stale (if superseded by another patch)
```

## 8. Command UX

### 8.1 New slash commands

| Command | Action atom | Description |
|---|---|---|
| `/approve patch` | `:approve_patch` | Approve the pending patch proposal (records decision only; no files written) |
| `/reject patch` | `:reject_patch` | Reject the pending patch proposal |

Both commands take no arguments. They operate on the single pending patch proposal for the current session.

### 8.2 Status output (patch section in `/plan status`)

When a patch is pending, `/plan status` appends:

```
Patch status:
- Patch id: patch_a1b2c3
- Status: proposed
- Diff hash: sha256:a1b2c3d4e5f6
- Affected files:
  - lib/muse/commands.ex
  - lib/muse/command_dispatcher.ex
- Created at: 2026-06-01T12:00:00Z
- Approve with: /approve patch
- Reject with: /reject patch
- Note: /approve patch records approval only; file changes require a subsequent step.
```

### 8.3 `/approve patch` output

```
Patch approved.

- Patch id: patch_a1b2c3
- Diff hash: sha256:a1b2c3d4e5f6
- Status: approved
- No files were written: approval recorded the patch only; no files were modified,
  no checkpoints were created, no tools were executed.
- Next: patch apply is a separate step (available in a future release).
```

### 8.4 `/reject patch` output

```
Patch rejected.

- Patch id: patch_a1b2c3
- Status: rejected
- No files were written: rejection recorded the decision only; the workspace
  is unchanged.
- Next: ask Coding Muse for a revised patch, or switch back to Planning Muse.
```

## 9. Event Taxonomy Additions

### 9.1 New event types

| Event type | Source | Visibility | Data payload |
|---|---|---|---|
| `:patch_proposed` | `:conductor` / `:coding_muse` | `:user` | `%{patch_id, plan_id, plan_version, diff_hash, affected_files, byte_size}` |
| `:patch_approval_requested` | `:conductor` | `:user` | `%{patch_id, plan_id, approval_binding}` |
| `:patch_approved` | `:session` | `:user` | `%{patch_id, plan_id, diff_hash, approved_by}` |
| `:patch_rejected` | `:session` | `:user` | `%{patch_id, plan_id, diff_hash, rejected_by, reason}` |
| `:patch_stale` | `:session` | `:user` | `%{patch_id, superseded_by, reason}` |

### 9.2 Events that must NOT be added in PR17

| Event | Reason |
|---|---|
| `:patch_applied` | PR18 — actual file write |
| `:patch_apply_failed` | PR18 — apply error |
| `:checkpoint_created` | PR18 |
| `:checkpoint_restored` | PR18 |

### 9.3 Event registration

These events should be added to the lifecycle event sets in:

- `Muse.EventDisplay` — add `patch_lifecycle_summary/2` handlers for the new types (parallel to `plan_lifecycle_summary/2`)
- `Muse.EventStream` — add patch lifecycle types to the lifecycle event allowlist for external forwarding

## 10. Module & Data Structure Summary

### 10.1 New modules

| Module | Purpose | Lane |
|---|---|---|
| `Muse.Patch` | Patch struct — diff, hash, metadata | Lane 02 |
| `Muse.PatchBinding` | Stable content hash for patches (analogous to `PlanBinding`) | Lane 02 |
| `Muse.PatchApprovalRequest` | Safe approval-request metadata builder (analogous to `PlanApprovalRequest`) | Lane 02 |
| `Muse.PatchApprovalAudit` | Read-only rendering helpers (or extend `ApprovalAudit`) | Lane 03 |

### 10.2 Existing modules to modify

| Module | Change | Lane |
|---|---|---|
| `Muse.ApprovalGate` | Add `request_patch_approval/3`, `approve_patch/4`, `reject_patch/4`, patch binding validation | Lane 02 |
| `Muse.Commands` | Add `/approve patch` and `/reject patch` to slash command table | Lane 03 |
| `Muse.CommandDispatcher` | Add `dispatch(:approve_patch, ...)`, `dispatch(:reject_patch, ...)` → `dispatch_patch_lifecycle_command/3` | Lane 03 |
| `Muse.SessionServer` | Add patch state fields, `approve_patch/2`, `reject_patch/2`, `handle_patch_lifecycle_command/3` | Lane 04 |
| `Muse.SessionRouter` | Add `approve_patch/2`, `reject_patch/2` | Lane 04 |
| `Muse.ApprovalAudit` | Add `patch_approval_message/1`, `patch_rejection_message/1` | Lane 03 |
| `Muse.Tool.Registry` | Unblock `patch_propose` for Coding Muse when session has approved plan | Lane 05 |
| `Muse.Conductor` | Update `select_muse/2` to return Coding Muse when session has approved plan and user requests patch | Lane 05 |
| `Muse.EventDisplay` | Add patch lifecycle summary handlers | Lane 06 |
| `Muse.EventStream` | Add patch types to lifecycle allowlist | Lane 06 |

### 10.3 Test files to create

| Test file | Scope | Lane |
|---|---|---|
| `test/muse/patch_test.exs` | Patch struct, status transitions, field validation | Lane 07 |
| `test/muse/patch_binding_test.exs` | Content hash stability, deterministic hashing | Lane 07 |
| `test/muse/patch_approval_request_test.exs` | Build/attach/get helpers | Lane 07 |
| `test/muse/approval_gate_patch_test.exs` | Patch approval/rejection validation, binding checks | Lane 07 |
| `test/muse/command_dispatcher_patch_test.exs` | `/approve patch`, `/reject patch` dispatching | Lane 07 |
| `test/muse/session_server_patch_test.exs` | Patch lifecycle in session server | Lane 07 |
| `test/muse/session_router_patch_test.exs` | Router-level patch lifecycle | Lane 07 |
| `test/muse/approval_audit_patch_test.exs` | Audit message rendering | Lane 07 |

## 11. Integration Sequence

### 11.1 Conversation flow (end-to-end)

```
User: "Add a /version command to the CLI."
  ↓
Planning Muse inspects workspace with list_files, read_file, git_status, etc.
  ↓
Planning Muse produces structured plan → session enters :awaiting_plan_approval
  ↓
User: "/approve plan"
  ↓
Plan approved → session returns to :idle
  ↓
User asks Coding Muse to implement (or automatic handoff in later PR)
  ↓
Coding Muse reads relevant files, prepares a diff
  ↓
Coding Muse calls patch_propose → patch artifact created → session enters :awaiting_patch_approval
  ↓
System displays: "Coding Muse proposed a patch. Diff:\n<diff>\nApprove with /approve patch"
  ↓
User: "/approve patch"
  ↓
Patch approved (event emitted, no files changed) → session returns to :idle
  ↓
[PR18: User runs patch apply flow to write files]
```

### 11.2 Lane dependency graph

```
Lane 02 (Patch struct + binding) ──► Lane 03 (Command UX: /approve patch /reject patch)
                                          │
                                          ▼
                                  Lane 04 (SessionServer patch lifecycle)
                                          │
                                          ▼
                                  Lane 05 (Tool unblocking + Muse routing)
                                          │
                                          ▼
                                  Lane 06 (Events: taxonomy + display)
                                          │
                                          ▼
                                  Lane 07 (Tests)
                                          │
                                          ▼
                                  Lane 08 (QA / Security review)
                                          │
                                          ▼
                                  Lane 09 (Merge / integration)
                                          │
                                          ▼
                                  Lane 10 (Docs: architecture, security, README)
```

### 11.3 Implementation order rationale

1. **Lane 02 (structs/binding) first** — Pure data definitions with no runtime dependencies. `Muse.Patch`, `Muse.PatchBinding` can be developed and tested independently.
2. **Lane 03 (command UX) next** — `/approve patch` and `/reject patch` can be wired into the dispatcher as stubs that return "not yet implemented" messages initially, then filled in.
3. **Lane 04 (session server lifecycle)** — Core logic for record/replay patch lifecycle. Requires Lane 02 structs and Lane 03 dispatcher hooks.
4. **Lane 05 (tool unblocking + routing)** — Unblock `patch_propose` for Coding Muse, update Conductor routing so Coding Muse is selectable after plan approval.
5. **Lane 06 (events)** — Wire event emissions into the lifecycle, update display/stream modules.
6. **Lane 07 (tests)** — Comprehensive test files for all new functionality.
7. **Lane 08 (QA)** — Manual testing, edge case audit, security review.
8. **Lane 09 (merge)** — Resolve conflicts, coordinate across lanes.
9. **Lane 10 (docs)** — Update architecture doc §10.1, §11; security doc; README.

## 12. Security Invariants

### 12.1 `/approve patch` must not write files

This is the **cardinal rule** of PR17. The command:
- Must only record a `%Muse.Approval{kind: :patch, status: :approved}`.
- Must not call `patch_apply`, `write_file`, `replace_in_file`, `delete_file`, `shell_command`, or any tool handler.
- Must not create checkpoints.
- Must not switch active Muse or start a turn.
- Must include the explicit disclaimer: "No files were written."

### 12.2 Content-bound integrity

Every patch approval is bound to a specific diff hash computed by `Muse.PatchBinding.content_hash/1`. The binding captures:
- `session_id` — session that produced the patch
- `plan_id` + `plan_version` — plan the patch implements
- `patch_id` — unique patch identifier
- `patch_hash` — SHA-256 of canonicalized diff content

Stale/binding-mismatched approvals are rejected (parallel to `ApprovalGate.validate_approval/2`).

### 12.3 Patch proposal safety

`patch_propose` must validate:
- Workspace-relative paths only (absolute paths rejected)
- No path traversal outside workspace
- No modification of secret files (per `Muse.Workspace` denylist)
- Patch size is capped (recommended: 100 KB for MVP)
- Binary patches are rejected in v1
- Unified diff format only
- Affected files exist (optional — new files allowed)

### 12.4 Read-only enforcement for Planning Muse

`patch_propose` remains blocked for Planning Muse. Only Coding Muse may call it, and only after plan approval.

### 12.5 Data that must never leak in patch events

- Raw file contents (diff is a summary of changes, not full file contents)
- Provider API keys, tokens, or secrets
- Session credentials or auth material
- Raw plan JSON (already redacted by `EventDisplay`)

### 12.6 Actor tracking

All patch lifecycle events and approval records include the actor (user identity or `:system`) for auditability.

## 13. Diff Display Contract

### 13.1 Display format (from `docs/architecture.md` §10.1)

```
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

### 13.2 Diff rendering behavior

- Diff is rendered as-is from `patch_propose` output (unified format).
- Diff text is capped at 50 KB for display (full patch stored in session).
- Affected file paths are extracted from diff headers (`--- a/...`, `+++ b/...`).
- Binary files are displayed as "Binary file: <path>" with no diff content.
- The rendering happens through the Conductor's assistant text output (or a dedicated patch display effect).

## 14. Integration Checklist (Lanes 02–10)

| # | Item | Lane | Status |
|---|---|---|---|
| 1 | `Muse.Patch` struct defined with all fields and status transitions | 02 | ☐ |
| 2 | `Muse.PatchBinding.content_hash/1` with deterministic SHA-256 | 02 | ☐ |
| 3 | `Muse.PatchApprovalRequest.build/1`, `attach/1`, `get/1`, `render_binding/2` | 02 | ☐ |
| 4 | `/approve patch` and `/reject patch` registered in `Muse.Commands` | 03 | ☐ |
| 5 | `dispatch(:approve_patch, ...)` and `dispatch(:reject_patch, ...)` in `CommandDispatcher` | 03 | ☐ |
| 6 | `ApprovalAudit.patch_approval_message/1` and `patch_rejection_message/1` | 03 | ☐ |
| 7 | `SessionServer.approve_patch/2` and `reject_patch/2` API | 04 | ☐ |
| 8 | `SessionServer.handle_patch_lifecycle_command/3` implementation | 04 | ☐ |
| 9 | Patch state fields in `SessionServer.init/1` | 04 | ☐ |
| 10 | `SessionRouter.approve_patch/2` and `reject_patch/2` | 04 | ☐ |
| 11 | `ApprovalGate.request_patch_approval/3` | 04 | ☐ |
| 12 | `ApprovalGate.approve_patch/4` and `reject_patch/4` | 04 | ☐ |
| 13 | `ApprovalGate.allowed?/2` supporting `:patch` scope | 04 | ☐ |
| 14 | Unblock `patch_propose` in `Tool.Registry` for Coding Muse after plan approval | 05 | ☐ |
| 15 | `Conductor.select_muse/2` returns Coding Muse when applicable | 05 | ☐ |
| 16 | `Conductor` handles patch proposal output (extracts patch from tool result) | 05 | ☐ |
| 17 | `:patch_proposed`, `:patch_approval_requested`, `:patch_approved`, `:patch_rejected` events emitted | 06 | ☐ |
| 18 | `EventDisplay.patch_lifecycle_summary/2` handlers | 06 | ☐ |
| 19 | `EventStream` allowlist includes patch lifecycle types | 06 | ☐ |
| 20 | All test files created and passing | 07 | ☐ |
| 21 | QA security audit: verify `/approve patch` does not write files | 08 | ☐ |
| 22 | QA edge case audit: stale binding, missing patch, concurrent patches | 08 | ☐ |
| 23 | Merge conflicts resolved, all lanes integrated | 09 | ☐ |
| 24 | `docs/architecture.md` §10.1, §11 updated | 10 | ☐ |
| 25 | `docs/security.md` patch approval section updated | 10 | ☐ |
| 26 | `README.md` or `PLAN.md` updated with PR17 status | 10 | ☐ |
| 27 | All acceptance criteria met (see §3) | 10 | ☐ |

## 15. Merge / Integration Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Race with concurrent PR on `commands.ex` or `command_dispatcher.ex` | Medium | Merge conflict | Coordinate with other PR authors; plan lanes to merge in dependency order |
| Race with PR18 (patch apply) touching same state fields | High | Major conflict | Define clear state field ownership: PR17 adds patch state, PR18 adds checkpoint state. Document shared fields. |
| `/approve patch` accidentally triggers file write | Low | Critical | Code review gate in Lane 08; explicit test that no tools are called; stub `patch_apply` runner to raise if invoked |
| `Conductor.select_muse/2` change breaks existing plan flow | Medium | Major | Keep `select_muse/2` backward-compatible; use explicit handoff, not automatic routing |
| Content hash algorithm changes between plan binding and patch binding | Low | Medium | Use same `PlanBinding` approach; document algorithm choice (SHA-256, deterministic serialization) |
| Existing `Approval` struct `:patch_id`/`:patch_hash` fields conflict with PR17 semantics | Low | Low | Fields already defined and match PR17 intent; no rename needed |
| LiveView shows partial or missing patch state | Medium | Medium | Add patch state to LiveView assigns; handle `:awaiting_patch_approval` status in `HomeLive` |
| External WebSocket channel (PR16) emits new patch events without allowlist update | Low | Low | Patch lifecycle events are `:user` visibility; they pass existing filtering rules. No change needed. |

## 16. Detailed Lane Descriptions

### Lane 02 — Patch struct + binding (pure data layer)

**Modules to create:**
- `lib/muse/patch.ex` — `%Muse.Patch{}` struct
- `lib/muse/patch_binding.ex` — `Muse.PatchBinding.content_hash/1`, `approval_binding/2`
- `lib/muse/patch_approval_request.ex` — `build/1`, `attach/2`, `get/1`, `render_binding/2`

**Key decisions:**
- Patch IDs use `"patch_<uuid>"` format (distinct from `"plan_<n>"` plan IDs)
- Content hash follows same algorithm as `PlanBinding`: sort keys deterministically, exclude timestamps/status/metadata, SHA-256
- Patch struct does **not** embed full event history; only the diff text, hash, and metadata

**Agent:** Code-Puppy

### Lane 03 — Command UX (dispatcher + messages)

**Files to modify:**
- `lib/muse/commands.ex` — add `/approve patch` and `/reject patch` entries
- `lib/muse/command_dispatcher.ex` — add `dispatch(:approve_patch, ...)` and `dispatch(:reject_patch, ...)` delegating to `dispatch_patch_lifecycle_command/3`
- `lib/muse/approval_audit.ex` — add `patch_approval_message/1`, `patch_rejection_message/1`

**Key decisions:**
- `dispatch_patch_lifecycle_command/3` follows the exact pattern of `dispatch_plan_lifecycle_command/3`
- Messages explicitly state "no files were written"
- No args expected for `/approve patch` or `/reject patch`

**Agent:** Code-Puppy

### Lane 04 — Session lifecycle (core logic)

**Files to modify:**
- `lib/muse/session_server.ex` — init state adds `:patch`, `:patches`, `:patch_approval_binding`, `:active_patch_approval`; add `approve_patch/2`, `reject_patch/2`, `handle_patch_lifecycle_command/3`
- `lib/muse/session_router.ex` — add `approve_patch/2`, `reject_patch/2`
- `lib/muse/approval_gate.ex` — add `request_patch_approval/3`, `approve_patch/4`, `reject_patch/4`, binding validation

**Key decisions:**
- Patch lifecycle uses `ApprovalGate` pattern identically to plan lifecycle
- `ApprovalGate.allowed?(:patch, ...)` returns `:ok` only when a valid patch approval exists
- Session status `:awaiting_patch_approval` is added to `Muse.Session` status type

**Agent:** Code-Puppy

### Lane 05 — Tool unblocking + Muse routing

**Files to modify:**
- `lib/muse/tool/registry.ex` — conditionally unblock `patch_propose` for Coding Muse with approved plan
- `lib/muse/tool/runner.ex` — allow `patch_propose` through approval gates for Coding Muse
- `lib/muse/conductor.ex` — update `select_muse/2` to return Coding Muse when session has an approved plan and user's turn context implies implementation

**Key decisions:**
- `patch_propose` is unblocked only when: calling muse is `:coding`, session has `:approved` plan
- `patch_apply` remains blocked (deferred to PR18)
- Muse selection is explicit: user message to Coding Muse triggers handoff, not automatic routing

**Agent:** Code-Puppy

### Lane 06 — Events (taxonomy + display)

**Files to modify:**
- `lib/muse/event_display.ex` — add `patch_lifecycle_summary/2` for `:patch_proposed`, `:patch_approved`, `:patch_rejected`
- `lib/muse/event_stream.ex` — add patch lifecycle types to lifecycle allowlist for external forwarding (PR16)

**Key decisions:**
- Patch events are `:user` visibility — always forwarded by external WS
- `summary/1` for patch events includes patch_id, status, affected file count

**Agent:** Code-Puppy

### Lane 07 — Tests

**Test files to create** (see §10.3 for full list): 8 new test files covering struct, binding, approval gate, command dispatch, session lifecycle, router, audit messages, and event display.

**Test patterns to follow:** existing `test/muse/plan_binding_test.exs`, `test/muse/approval_gate_test.exs`, `test/muse/session_server_test.exs`.

**Agent:** Code-Puppy

### Lane 08 — QA / Security Review

**Scope:**
1. Manual testing: propose patch, approve, reject, verify no files changed
2. Edge case audit: stale bindings, missing session, missing plan, invalid diff hash
3. Security review: confirm `/approve patch` does not write files, invoke tools, or create checkpoints
4. Confirm `patch_propose` validation: binary rejection, size cap, path traversal prevention
5. Confirm Planning Muse cannot call `patch_propose`

**Agent:** qa-kitten

### Lane 09 — Merge / Integration

- Merge lanes in dependency order (02 → 03 → 04 → 05 → 06 → 07 → 08)
- Resolve any conflicts with concurrent PRs
- Verify end-to-end: propose → display → approve → no files written
- Verify existing plan lifecycle still works unchanged

**Agent:** planning-agent

### Lane 10 — Docs

**Files to update:**
- `docs/architecture.md`:
  - §10.1: Update patch proposal policy to reference PR17 patch struct, binding, and approval
  - §11: Mark patch approval flow as PR17 implemented; reference PR18 for apply
- `docs/security.md`:
  - §1: Add checklist item for "Patch approval does not write files"
  - Add §X: Patch approval security invariants
- `README.md` / `PLAN.md`: Update PR status

**Agent:** asx8678 or Code-Puppy

## 17. Files to Create (Complete List)

| # | File | Lane |
|---|---|---|
| 1 | `lib/muse/patch.ex` | 02 |
| 2 | `lib/muse/patch_binding.ex` | 02 |
| 3 | `lib/muse/patch_approval_request.ex` | 02 |
| 4 | `test/muse/patch_test.exs` | 07 |
| 5 | `test/muse/patch_binding_test.exs` | 07 |
| 6 | `test/muse/patch_approval_request_test.exs` | 07 |
| 7 | `test/muse/approval_gate_patch_test.exs` | 07 |
| 8 | `test/muse/command_dispatcher_patch_test.exs` | 07 |
| 9 | `test/muse/session_server_patch_test.exs` | 07 |
| 10 | `test/muse/session_router_patch_test.exs` | 07 |
| 11 | `test/muse/approval_audit_patch_test.exs` | 07 |

## 18. Files to Modify (Complete List)

| # | File | Change summary | Lane |
|---|---|---|---|
| 1 | `lib/muse/approval_gate.ex` | Add patch approval/rejection API + validation | 04 |
| 2 | `lib/muse/commands.ex` | Add `/approve patch`, `/reject patch` | 03 |
| 3 | `lib/muse/command_dispatcher.ex` | Add `dispatch(:approve_patch)`, `dispatch(:reject_patch)` | 03 |
| 4 | `lib/muse/session_server.ex` | Patch state, patch lifecycle handlers | 04 |
| 5 | `lib/muse/session_router.ex` | `approve_patch/2`, `reject_patch/2` | 04 |
| 6 | `lib/muse/approval_audit.ex` | `patch_approval_message/1`, `patch_rejection_message/1` | 03 |
| 7 | `lib/muse/tool/registry.ex` | Unblock `patch_propose` conditionally | 05 |
| 8 | `lib/muse/tool/runner.ex` | Allow `patch_propose` through approval gates | 05 |
| 9 | `lib/muse/conductor.ex` | Update `select_muse/2` for Coding Muse | 05 |
| 10 | `lib/muse/event_display.ex` | Patch lifecycle summary handlers | 06 |
| 11 | `lib/muse/event_stream.ex` | Patch lifecycle allowlist additions | 06 |
| 12 | `docs/architecture.md` | §10.1, §11 updates | 10 |
| 13 | `docs/security.md` | Patch approval security invariants | 10 |

## 19. Acceptance Checklist

| # | Item | Status |
|---|---|---|
| 1 | `Muse.Patch` struct defined with all required fields | ☐ |
| 2 | `PatchBinding.content_hash/1` produces stable deterministic hash | ☐ |
| 3 | `patch_propose` available to Coding Muse after plan approval | ☐ |
| 4 | Proposed patch is displayed with diff, file list, and instructions | ☐ |
| 5 | Session enters `:awaiting_patch_approval` after patch proposed | ☐ |
| 6 | `/approve patch` validates content binding and records approval | ☐ |
| 7 | `/reject patch` records rejection with reason | ☐ |
| 8 | `/approve patch` does NOT write files, create checkpoints, or run tools | ☐ |
| 9 | `/reject patch` does NOT write files, create checkpoints, or run tools | ☐ |
| 10 | Patch lifecycle events emitted for all transitions | ☐ |
| 11 | Events include `:user` visibility with safe summaries | ☐ |
| 12 | Stale/patch-mismatched approvals are rejected | ☐ |
| 13 | Planning Muse cannot call `patch_propose` | ☐ |
| 14 | Binary patches rejected in v1 | ☐ |
| 15 | Patch size capped at 100 KB | ☐ |
| 16 | Path traversal rejected | ☐ |
| 17 | Secret files blocked from patch modification | ☐ |
| 18 | Existing plan lifecycle continues working unchanged | ☐ |
| 19 | All 8 test files pass | ☐ |
| 20 | QA security audit confirms no file writes from approval | ☐ |

## 20. Comparison: Plan Approval vs. Patch Approval

| Dimension | Plan Approval (PR09) | Patch Approval (PR17) |
|---|---|---|
| Artifact | `%Muse.Plan{}` — structured JSON | `%Muse.Patch{}` — unified diff |
| Content binding | `PlanBinding.content_hash/1` | `PatchBinding.content_hash/1` |
| Approval kind | `Approval.kind == :plan` | `Approval.kind == :patch` |
| Commands | `/approve plan`, `/reject plan` | `/approve patch`, `/reject patch` |
| Gate module | `ApprovalGate.approve_plan/4` | `ApprovalGate.approve_patch/4` |
| Session status | `:awaiting_plan_approval` | `:awaiting_patch_approval` |
| Post-approval action | None (plan approved) | None (patch approved; PR18 applies) |
| Precondition | Session exists, plan present | Plan approved, patch proposed |
| Does it write files? | **Never** | **Never** |
| Does it start turns? | **Never** | **Never** |
| Audit events | `:plan_created`, `:plan_approved`, `:plan_rejected` | `:patch_proposed`, `:patch_approved`, `:patch_rejected` |

---

*Lane 01 contract artifact — created 2026-06-01 as part of PR17. Branch: `pr17/lane01-contract-plan`. Bead: `muse-1ki.3.1`.*
