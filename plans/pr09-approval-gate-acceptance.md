# PR09 ApprovalGate Acceptance Scout (lane01)

- Coordinator: `planning-agent-1a6824`
- Scout: `light-puppy-2b6239`
- Branch baseline: `origin/main` checked out as `pr09/lane01-acceptance-scout`
- Workspace: `/Users/adam2/projects/muse`
- Date: 2026-05-05

## 1) Goal of this scout

Define **exact acceptance criteria** for a **full PR09 ApprovalGate MVP** (beyond lifecycle-only `/approve plan` and `/reject plan`), document current behavior on `origin/main`, identify gaps/blockers, and provide a 15-lane execution map + integration checklist.

---

## 2) Exact acceptance criteria for PR09 full ApprovalGate MVP

PR09 is accepted only when **all** items below are true.

### A. Approval domain model

1. `Muse.Approval` exists as a runtime struct/module (not docs-only), with typed fields for:
   - identity (`id`, `session_id`, `kind`, `status`),
   - plan binding (`plan_id`, `plan_version`, `workspace`),
   - content binding (`content_fingerprint` or equivalent canonical hash field),
   - actor/timing (`requested_by`, `approved_by`, `created_at`, `approved_at`, `rejected_at`, `expires_at`),
   - metadata (`metadata` map).
2. `Muse.Approval` provides validated constructors/transitions and map serialization/deserialization for persistence.
3. Approval statuses are explicit and auditable (`:pending | :approved | :rejected | :expired` or equivalent) with invalid transitions rejected.

### B. ApprovalGate runtime policy

4. `Muse.ApprovalGate` exists and is the single runtime policy point for approval decisions.
5. ApprovalGate validates active plan binding tuple before granting:
   - `session_id`,
   - `plan_id`,
   - `plan_version`,
   - `workspace`,
   - canonical content fingerprint.
6. If any binding component mismatches current active plan/session state, decision is **deny with stale reason** (`:stale_approval` or equivalent typed reason).
7. ApprovalGate decisions return structured values (not string-only) suitable for tests, CLI formatting, and telemetry.

### C. Session + plan lifecycle integration

8. `/approve plan` and `/reject plan` flow through ApprovalGate (not direct status mutation only).
9. Approving a plan both:
   - transitions plan lifecycle to `:approved`, and
   - stores an approval record bound to that exact approved plan content.
10. Rejecting a plan stores a rejected approval/audit record (or equivalent explicit rejection event payload) with actor + timestamp.
11. Session state includes approvals in-memory and persisted snapshot; restore path rehydrates approvals safely.

### D. Stale-approval prevention

12. Any plan change that affects version/content invalidates prior approval for execution intent.
13. Attempted use of stale approval yields deterministic denial and emits auditable event(s).
14. Tests cover stale by at least:
    - changed `plan_version`,
    - changed plan content hash with same plan id,
    - workspace/session mismatch.

### E. Tool-gating alignment (MVP boundary-safe)

15. `Muse.Tool.Runner` integrates with ApprovalGate for tools marked `requires_approval: true`.
16. For PR09 scope, unsupported write/shell/network execution paths remain safely denied, but now denied via explicit gate/policy reason instead of generic hardcoded block text.
17. Dangerous blocked-name behavior remains intact as hard deny fallback.

### F. Observability + docs + tests

18. Runtime emits approval telemetry/events for grant/reject/deny-stale with sanitized metadata.
19. Existing telemetry declaration functions are either wired or removed; no dead approval telemetry API surface remains.
20. Docs (`PLAN.md`, `docs/architecture.md`, `docs/security.md`, `docs/testing.md`) clearly separate implemented PR09 behavior vs future PR17/18/19/24 work.
21. Test suite includes unit + integration coverage for Approval struct, ApprovalGate policy, session persistence/rehydration, CLI lifecycle behavior, and stale prevention.
22. `mix test` for touched suites passes; no regression in existing plan lifecycle behavior.

---

## 3) Current state on `origin/main` (evidence snapshot)

### Implemented now

- Plan lifecycle commands exist and are non-executing:
  - `Muse.SessionRouter.approve_plan/2` + `reject_plan/2` route to SessionServer (`lib/muse/session_router.ex:71-101`).
  - SessionServer lifecycle transitions + events implemented (`lib/muse/session_server.ex:642-744`).
  - Dispatcher UX responses implemented (`lib/muse/command_dispatcher.ex:988-1020`).
  - Slash commands exposed (`lib/muse/commands.ex:16-17`).
- Plan lifecycle persistence exists for active plan/plans/status (`lib/muse/session_server.ex:825-847`).
- Tool surface is still read-only + blocked dangerous names (`lib/muse/tool/registry.ex:46-75`; `test/muse/tool/runner_test.exs:35-100`).

### Missing for full PR09

- No `Muse.Approval` module in `lib/` (fixed-string grep found none).
- No `Muse.ApprovalGate` module in `lib/` (fixed-string grep found none).
- Approval lifecycle path mutates plan directly, not content-bound approval records (`lib/muse/session_server.ex:658-690`).
- No stale approval checks against content hash/version/workspace/session.
- Session snapshots persist plan data only; no approvals collection persisted (`lib/muse/session_server.ex:825-847`).
- Turn session builder does not project approvals into `%Muse.Session{}` (`lib/muse/session_server.ex:307-317`).
- Telemetry defines approval events, but no runtime emission sites found outside declaration (`lib/muse/telemetry.ex:247-285`).
- Conductor always returns Planning Muse (Coding Muse handoff not active) (`lib/muse/conductor.ex:119-125`).
- Tool runner `requires_approval` remains hardcoded blocked message pending ApprovalGate (`lib/muse/tool/runner.ex:180-184`).
- Docs explicitly note ApprovalGate not yet implemented (`docs/security.md:199-201`, `docs/architecture.md:949-963`).

---

## 4) Blockers / gap list (top 12)

1. **No runtime approval entity** (`Muse.Approval`) to represent auditable grants/denials.
2. **No runtime gate/policy module** (`Muse.ApprovalGate`) to centralize decisions.
3. **No content fingerprint binding** for approvals, so stale approval cannot be detected.
4. **No persisted approval ledger** in session snapshot/load path.
5. **Lifecycle approval bypasses policy** by directly transitioning plan status.
6. **No stale denial reason taxonomy** (typed errors) for CLI/tests/telemetry.
7. **Approval telemetry is dead declaration** (declared, not emitted).
8. **Tool `requires_approval` path is generic blocked-only** (not gate-aware).
9. **Conductor never selects Coding Muse**, so approved plan has no execution-stage handoff semantics.
10. **Session struct has `approvals` field but not integrated** into runtime turn construction/persistence.
11. **Test coverage stops at lifecycle transitions**; no stale-content/workspace mismatch coverage.
12. **Tracking mismatch**: `muse-1ki.1.13` closed while key PR09 roadmap expectations remain unimplemented.

---

## 5) 15-lane responsibility map

> Goal: parallelize PR09 hardening while keeping scope narrow and merge-safe.

| Lane | Responsibility | Primary outputs |
|---|---|---|
| lane01 | Acceptance scout + integration checklist (this doc) | `plans/pr09-approval-gate-acceptance.md`, integration criteria |
| lane02 | `Muse.Approval` domain struct/model | module + transitions + serialization tests |
| lane03 | `Muse.ApprovalGate` decision engine | policy API + stale/mismatch denial reasons |
| lane04 | Canonical plan fingerprinting + binding helpers | deterministic hash utility + tests |
| lane05 | Session persistence/rehydration for approvals | snapshot schema updates + restore tests |
| lane06 | SessionServer + SessionRouter policy integration | lifecycle commands route through gate, structured errors |
| lane07 | CLI approval UX polish (already delivered once) | command messaging/error polish validation against new reasons |
| lane08 | Telemetry/event instrumentation for gate decisions | grant/reject/deny events + sanitizer coverage |
| lane09 | Conductor/active-muse gating semantics | approved-plan handoff readiness checks (no PR17/18 execution) |
| lane10 | Tool Runner gate hook for `requires_approval` | gate-aware deny path + blocked fallback invariants |
| lane11 | Docs alignment | PLAN/security/architecture/testing updates to match runtime |
| lane12 | Unit test lane | Approval + ApprovalGate + fingerprint edge cases |
| lane13 | Integration/regression lane | end-to-end lifecycle + stale invalidation + persistence roundtrip |
| lane14 | QA acceptance scripts | deterministic manual/automated acceptance scenarios |
| lane15 | Final hardening + release integration | merge order, changelog, risk signoff, final acceptance report |

---

## 6) Final integration checklist (must pass before PR09 signoff)

1. All 15 lane branches merged into PR09 integration branch without unresolved conflicts.
2. `Muse.Approval` + `Muse.ApprovalGate` present in `lib/` with docs/spec/tests.
3. Approval decisions are content-bound and stale-safe.
4. `/approve plan` and `/reject plan` produce both lifecycle outcomes and approval audit records.
5. Session persistence stores/restores approvals and active binding context.
6. Tool runner consults ApprovalGate for `requires_approval` decisions.
7. Blocked dangerous-name safeguards remain unchanged and tested.
8. Telemetry + event stream include approval outcomes with sanitized metadata.
9. CLI strings reflect typed errors (`stale`, `mismatch`, `no_active_plan`, etc.) consistently.
10. `mix format`/lint/tests for touched areas pass.
11. `git diff --check` clean.
12. Beads issues updated to reflect real completion state (no premature closure).

---

## 7) Out-of-scope for this PR09 acceptance target

Unless explicit gating placeholders are needed, the following are **not** part of PR09 full ApprovalGate MVP:

1. Full patch proposal/apply runtime implementation (PR17/PR18).
2. Actual shell-command execution workflows (PR19 scope).
3. Actual network-call approval/execution workflows (PR24 scope).
4. Remote execution capabilities.

Allowed in PR09: placeholder policy hooks + explicit denied outcomes that prepare future PRs without enabling execution.

---

## 8) Beads tracking status

- Existing issue `muse-1ki.1.13` is CLOSED with lifecycle-only implementation.
- Follow-up issue created (left OPEN, not closed):
  - `muse-rc8` — **PR09 full ApprovalGate hardening integration**.

This follow-up issue should be the umbrella tracker for lanes 02-15 completion evidence.
