# PR09 Lane15 QA / ApprovalGate Contract Audit

Date: 2026-05-05
Branch: `pr09/lane15-qa-contract-audit`
Coordinator: `planning-agent-1a6824`
Reviewer: `elixir-code-critic-3fdfdc`
Baseline: `origin/main` as checked out in the isolated worktree
Issue source: `muse-1ki.1.13` from tracked `issues.jsonl`

> **Final integration update:** This lane15 audit captured the pre-integration baseline. PR09 final integration now adds `%Muse.Approval{}`, `Muse.PlanBinding`, `Muse.ApprovalGate`, pending/approved/rejected approval records in session snapshots, stale content/session/workspace validation, approval request/decision events, recursive secret redaction, display-safe UI summaries, and deny-by-default tool authorization. The findings below are retained as historical QA context; the final status is summarized in the updated checklist.

## Verdict

**Historical verdict:** changes were requested for the full PR09 ApprovalGate contract.

The pre-integration `origin/main` baseline had a useful **plan lifecycle command slice**: `/approve plan` and `/reject plan` were parsed, routed to the active `SessionServer`, transitioned only an awaiting active plan, persisted the updated session snapshot, emitted lifecycle events, and did not start tools, turns, shell commands, patches, or Coding Muse handoff.

Final integration hardens that slice into the PR09 ApprovalGate MVP:

1. **Stale approval prevention is content-bound.** Approval records and bindings include the session id, active plan id, plan version, deterministic plan hash/content hash, and workspace when present.
2. **Approval records and an ApprovalGate facade exist.** Runtime plan approval decisions flow through `Muse.ApprovalGate`; `Tool.Runner` calls the gate facade and remains deny-by-default for patch/write/shell/network/delete/remote/restore scopes.
3. **Approval auditability is stateful.** Pending, approved, and rejected approval records are embedded in plan/session snapshots and emitted through safe `:approval_*` / `:plan_*` events.
4. **Plan/event/persistence redaction is stronger.** Event display/export uses `Muse.EventDisplay`, approval event payloads omit raw plan JSON, and `SessionStore` recursively redacts secret-like strings before disk writes.

## Scope audited

Reviewed current PR09-relevant baseline code and docs on `origin/main`:

- Slash-command registration and dispatcher flow:
  - `lib/muse/commands.ex`
  - `lib/muse/command_dispatcher.ex`
- Session lifecycle transition and persistence:
  - `lib/muse/session_server.ex`
  - `lib/muse/session_router.ex`
  - `lib/muse/session_store.ex`
  - `lib/muse/state.ex`
- Plan creation, identity, versioning, and rendering:
  - `lib/muse/conductor.ex`
  - `lib/muse/plan.ex`
  - `lib/muse/plan_parser.ex`
  - `lib/muse/plan_schema.ex`
  - `lib/muse/plan_history.ex`
- Tool safety / current gate substitute:
  - `lib/muse/tool/registry.ex`
  - `lib/muse/tool/runner.ex`
- Tests covering the baseline:
  - `test/muse/session_server_test.exs`
  - `test/muse/session_router_test.exs`
  - `test/muse/command_dispatcher_test.exs`
  - `test/muse/tool/runner_test.exs`
  - `test/muse/m1_read_only_planning_test.exs`
- Contract docs:
  - `PLAN.md`
  - `docs/architecture.md`
  - `docs/security.md`
  - `docs/testing.md`

This lane was **doc-only** before final integration. The final integration adds the missing stale-approval/content-hash regression tests and runtime model.

## Current baseline positives

### PASS — explicit slash-command entry points exist

`/approve plan` and `/reject plan` are present in the canonical command list.

Evidence:

- `lib/muse/commands.ex:16` registers `/approve plan`.
- `lib/muse/commands.ex:17` registers `/reject plan`.
- `lib/muse/command_dispatcher.ex:106-111` routes both actions to the shared lifecycle dispatcher.
- `lib/muse/command_dispatcher.ex:967-985` rejects extra args, resolves session/source from context, and calls `Muse.SessionRouter.approve_plan/2` or `Muse.SessionRouter.reject_plan/2`.

Why it matters:

- Approval/rejection is explicit and command-based, not inferred from arbitrary natural-language text.
- CLI/TUI/LiveView can share the same parser and dispatcher path.

### PASS — plan lifecycle commands are non-executing

Evidence:

- `lib/muse/session_server.ex:95-100` documents approval as a lifecycle transition only, explicitly not starting turn execution, shell commands, file writes, or patch application.
- `lib/muse/session_server.ex:640-653` handles lifecycle commands without starting a `TurnRunner`.
- `lib/muse/session_server.ex:660-687` transitions the plan, emits events, appends to in-memory session events, and persists a session snapshot; it does not call conductor/tool/shell/patch code.
- `test/muse/m1_read_only_planning_test.exs` completion-gate coverage asserts `/approve plan` and `/reject plan` do not start turns, tools, patches, shell, or Coding Muse handoff.

Why it matters:

- The M1 safety invariant remains intact after plan approval: approval does not yet mean implementation.

### PASS — no active plan, non-awaiting plan, and running-turn cases are blocked

Evidence:

- `lib/muse/session_server.ex:642-650` returns `{:error, :turn_running}` or `{:error, :no_active_plan}`.
- `lib/muse/session_server.ex:658-660` refuses plans whose status is not `:awaiting_approval`.
- `lib/muse/command_dispatcher.ex:1000-1015` formats safe user-facing errors for running turns, missing plans, and non-awaiting plans.
- `test/muse/session_server_test.exs:1075-1124` covers no-active-plan, running-turn, already-approved, and already-rejected cases.

Why it matters:

- Repeated approvals/rejections cannot repeatedly mutate an already terminal plan.
- A plan cannot be approved while another model/tool turn is actively running in that session.

### PASS / current-scope — dangerous tool names remain blocked

Evidence:

- `lib/muse/tool/registry.ex:46-55` hard-denies known dangerous tool names including `write_file`, `replace_in_file`, `delete_file`, `patch_apply`, `patch_propose`, `shell_command`, `network_call`, and `remote_execution`.
- `lib/muse/tool/registry.ex:57-75` blocks destructive-looking unknown tool-name shapes such as write/patch/shell/network/remote/http/curl tokens.
- `lib/muse/tool/runner.ex:84-91` checks blocked tools, registration, Muse role allowlists, approval, required args, and workspace before execution.
- `lib/muse/tool/runner.ex` delegates tool authorization to `Muse.ApprovalGate.authorize_tool/2`; PR09 still blocks approval-scoped tool categories by default.
- `test/muse/tool/runner_test.exs` covers blocked dangerous names, unknown destructive-looking names, role allowlists, required args, workspace safety, and event redaction.

Why it matters:

- Current main is still safe for M1 read-only planning because plan approval does not unlock execution tools.
- Future write/shell/network tools must not be added by merely flipping `requires_approval` or registry metadata; they need explicit non-plan approval categories first.

### PASS / partial — lifecycle event payloads are redacted at the event boundary

Evidence:

- `lib/muse/session_server.ex` emits approval/plan lifecycle event data with plan id, version, approval id, plan/content hash, status, and task count; plan approval/rejection events do not include raw objectives or raw plan JSON.
- `lib/muse/session_server.ex` redacts every session event payload via `Muse.Prompt.Redactor.redact_term/1` before `Event.new/4` and `State.append/1`.

Why it matters:

- If a plan objective contains a recognizable secret pattern, the event payload should be redacted before broadcast and in-memory event storage.

Residual risk:

- Snapshot persistence now recursively redacts secret-like strings before disk writes, but future new persistence files must continue using `SessionStore` or equivalent redaction boundaries.

## Acceptance checklist for PR09 final gate

Legend: `PASS` = final integration satisfies the lane-level expectation; `PARTIAL` = useful behavior exists but not enough for PR09; `MISSING` = not implemented; `OOS` = out of PR09 scope but must remain blocked.

| Status | Acceptance item | Current evidence / required action |
|---|---|---|
| PASS | `/approve plan` and `/reject plan` are explicit commands | Registered in `lib/muse/commands.ex:16-17`; dispatched in `lib/muse/command_dispatcher.ex:106-111`. |
| PASS | Extra args are rejected for current bare commands | `lib/muse/command_dispatcher.ex:967-970`; tests cover usage errors. |
| PASS | Missing session / no active plan fails safely | `SessionRouter` returns `:not_found`; dispatcher maps it to “no Muse Plan is awaiting approval.” |
| PASS | Already approved/rejected plans cannot be approved/rejected again | `lib/muse/session_server.ex:658-660`; tests cover non-awaiting plans. |
| PASS | Approval/rejection is lifecycle-only and does not execute tools/patch/shell | `lib/muse/session_server.ex:95-100`, `640-687`; M1 completion-gate tests cover no execution/handoff. |
| PASS | Running turn blocks approval/rejection | `lib/muse/session_server.ex:642-645`; tests cover running-turn refusal. |
| PASS | Approved/rejected plan status is persisted in session snapshot | `lib/muse/session_server.ex:825-840`; tests assert persisted status. |
| PASS | Lifecycle events are emitted and redacted | `emit_session_event/5` redacts and appends to `Muse.State`; UI/export/search display uses `Muse.EventDisplay.safe_data/1`. |
| PASS | Current read-only gate blocks write/shell/network/remote tools | Registry/runner block lists work; `Tool.Runner` delegates authorization to `Muse.ApprovalGate.authorize_tool/2`, which denies PR09 execution categories by default. |
| PASS | `%Muse.Approval{}` record with id, kind, scope, status, session, plan id/version, workspace, approver, timestamps | `lib/muse/approval.ex` provides the canonical model and JSON-safe normalization. |
| PASS | `Muse.ApprovalGate` facade called by plan lifecycle and tool paths | `SessionServer` calls `ApprovalGate` for plan decisions; `Tool.Runner` calls `authorize_tool/2` for all registered specs. |
| PASS | Stale plan approval rejection based on displayed plan id/version/content hash/workspace | `Muse.PlanBinding` + `ApprovalGate.validate_approval/3` reject session/workspace/content/version mismatches. |
| PASS | Stateful approval audit trail | Approval records are persisted in session snapshots and embedded in plans; append-only `approvals.jsonl` can be a future enhancement but is not required for PR09 MVP. |
| PASS | Approval records survive restart and are queryable by CLI/TUI/LiveView | Snapshot restore normalizes approvals and recaptures legacy pending bindings; CLI/TUI/LiveView display safe approval summaries. |
| PASS | Plan approval does not grant patch/shell/write/network until later explicit gates exist | Tests cover that approved plan context does not unlock destructive tool names or tool scopes. |
| OOS | Patch proposal/apply, checkpoints, test runner, remote execution | Must remain blocked until PR17/18/19/24. Do not implement in PR09. |

## Findings and recommended fixes

### Finding 1 — High — stale approval prevention is not content/version bound (resolved in final integration)

Evidence:

- `lib/muse/command_dispatcher.ex:967-976` accepts bare `/approve plan` or `/reject plan`, resolves only `session_id` and `source`, and forwards the action to the router.
- `lib/muse/session_server.ex:695-718` resolves whichever plan is currently active from `active_plan_id` / `state.plan`.
- `lib/muse/session_server.ex:658-660` rejects only when the resolved plan status is not `:awaiting_approval`.
- `lib/muse/conductor.ex:654-665` increments plan versions when new plans are created, but approval never verifies that the user is approving the same plan version that was displayed.
- `docs/architecture.md:917-930` says plan approvals should bind to `session_id`, `plan_id`, `plan_version`, `workspace`, `approved_by`, `approved_at`, and scope, with old approvals invalidated when a version changes.
- `docs/architecture.md:2299-2305` says natural-language approval is valid only when the plan version matches the displayed plan.

Why it matters:

A user can see plan A, another turn can create/replace active plan B, and a stale `/approve plan` command can approve B because the command carries no displayed plan identity. This is especially risky once LiveView/TUI buttons, natural-language “go ahead,” or delayed CLI command submission enter the flow. It also leaves no way to reject a stale approval attempt deterministically.

Suggested fix:

- Add a first-class `Muse.Approval` struct and an `ApprovalGate` API for plan lifecycle operations.
- Bind plan approval requests to at least:
  - `session_id`
  - `workspace`
  - `plan_id`
  - `plan_version`
  - a stable content hash of the plan fields shown to the user
  - `requested_at` / `expires_at` or a monotonic request sequence
  - `requested_by` / `approved_by` source metadata
- Render a displayed approval token or require `/approve plan <plan_id>` plus version/hash, while preserving bare `/approve plan` only if the session has exactly one current pending approval and the last displayed request still matches.
- On mismatch, return a clear stale error and leave the active plan unchanged.

Regression tests to add with the fix:

- User sees plan v1, plan v2 becomes active, stale v1 approval token is rejected, v2 remains `:awaiting_approval`.
- Same `plan_id` with incremented `version` rejects stale version approval.
- Bare `/approve plan` rejects if more than one pending approval exists or if there is no recorded displayed approval request.
- Concurrent duplicate approvals produce exactly one success and one stale/non-awaiting error, with a single approval record.

### Finding 2 — High — no ApprovalGate / Approval model existed yet (resolved in final integration)

Evidence:

- Historical docs said runtime enforcement was only `Muse.Tool.Registry` + `Muse.Tool.Runner`; final integration now adds `Muse.ApprovalGate`.
- `lib/muse/tool/runner.ex` still blocks approval-scoped tool categories in PR09, but it now does so through the gate facade.
- `lib/muse/tool/registry.ex` continues using a hard block list for dangerous names, which remains acceptable for M1/PR09 read-only planning.

Why it matters:

PR09’s bead explicitly names “Approval struct, ApprovalGate, `/approve plan`, `/reject plan`, and stale approval prevention.” Final integration implements the command transition slice and the gate abstraction. Later lanes that add `patch_propose`, `patch_apply`, shell/test, network, or remote tools must add explicit non-plan approval categories instead of relying on plan approval.

Suggested fix:

- Introduce a small but real `Muse.Approval` struct and `Muse.ApprovalGate` module before any write/shell/network tools are made executable.
- Make `Tool.Runner` call `ApprovalGate.check_tool/2` for every tool call, even read-only tools, so the audit path is uniform. Initial policy can return `:allow` for read-only specs and `{:deny, :approval_required}` / `{:deny, :blocked}` for write/shell/network/remote specs.
- Keep existing registry/role/workspace checks; the gate should not replace path safety or tool registration.
- Keep tests proving approval-scoped specs cannot execute without a matching grant and cannot execute with a stale/mismatched grant.

### Finding 3 — High — approval audit trail was in-memory and snapshot-only (resolved for PR09 MVP via persisted snapshots)

Evidence:

- `lib/muse/session_server.ex:671-687` emits lifecycle events, appends them to `state.events`, and persists a session snapshot.
- `lib/muse/session_server.ex:948-950` appends emitted events to `Muse.State` only.
- `lib/muse/state.ex:1-15` documents `Muse.State` as a bounded in-memory event log capped at 1,000 events.
- `lib/muse/session_store.ex:132-149` has an `append_event/3` API for `events.jsonl`, but the audited lifecycle path does not call it.
- `lib/muse/session_server.ex:825-840` persists final plan/session state, not an append-only approval record.

Why it matters:

Auditable approval should survive process restarts and event-log truncation. A snapshot saying “plan is approved” is not enough to answer who/what approved it, what exact plan hash/version was displayed, whether it was stale, or whether the approval was later superseded.

Suggested fix:

- Persist lifecycle events to session `events.jsonl` or, preferably, append structured approval records to `approvals.jsonl`.
- Store immutable approval records with id, kind, session/workspace, plan id/version/hash, status, source, created/approved/rejected timestamps, and reason.
- Keep `Muse.State` as a broadcast/cache layer, not the source of audit truth.
- Add restart tests: approve a plan, stop/restart the session server, verify the approval record and plan status reload accurately.

### Finding 4 — High — valid plan text could leak secrets into rendered output and session snapshots (resolved in final integration)

Evidence:

- `lib/muse/session_server.ex:736-743` includes plan objective in lifecycle event data, but `emit_session_event/5` redacts event payloads at `lib/muse/session_server.ex:926-948`.
- `lib/muse/conductor.ex:616-625` uses `safe_objective_summary/1` for the `:plan_created` event, but `lib/muse/conductor.ex:617-618` also emits `Plan.render(plan)` as user-visible assistant text.
- `lib/muse/session_server.ex:825-840` persists `Plan.to_map(state.plan)` and every plan in `state.plans` through `SessionStore.save_session/2`.
- `lib/muse/session_store.ex:36-41` and `260-264` redact values by sensitive **key** names, not arbitrary secret-like values embedded in normal fields such as `objective`, `summary`, task descriptions, risks, or validation text.
- `lib/muse/plan_schema.ex` validates shape and sanitizes metadata, but does not redact normal text fields.

Why it matters:

Even with read-only tool path restrictions, the model or user can put a secret-like string into a valid plan field. That string can be rendered to the user and stored under `.muse/sessions/.../session.json`. The MVP security contract says secrets should not appear in events, logs, prompt previews, crash text, or provider debug output; auth docs also warn against storing tokens under workspace `.muse/`. Plan snapshots are part of that same safety boundary.

Suggested fix:

- Decide the canonical boundary: either plans must never contain raw secrets, or persisted/rendered plan views must use a redacted projection.
- At minimum, apply `Muse.Prompt.Redactor.redact_term/1` to plan maps before persistence and to `Plan.render/1` output before user-facing events.
- Prefer storing a sanitized plan plus, if absolutely necessary, a separate internal raw plan only outside workspace storage and never in events/logs/UI.
- Add tests with a syntactically valid plan containing `API_KEY=sk-...` in objective, task description, risks, and validation; assert no raw secret appears in rendered assistant text, lifecycle events, `session.json`, `events.jsonl`, or approval records.

### Finding 5 — Medium — approved-plan behavior must not unlock Coding Muse; final integration preserves deny-by-default behavior

Evidence:

- `lib/muse/conductor.ex:107-124` always selects Planning Muse, even after statuses outside the explicit planning set, with a comment saying this remains until plan-approval flow is implemented.
- `lib/muse/tool/registry.ex:46-55` blocks patch/write/shell/network tools by name.
- PR09’s acceptance says approved plan transition is recorded while file writes, shell commands, and patch work remain blocked until later gates exist.

Why it matters:

This is safe today, but it will become a merge-risk hotspot when a later lane tries to make approved plans enable Coding Muse or patch proposal. If that lane lands before a central gate, approved plan status may be confused with permission to write or run shell commands.

Suggested fix:

- Keep “approved plan” as a prerequisite, not a permission grant.
- Require subsequent patch/shell/network approvals to bind to the approved plan id/version/hash.
- Add tests that an approved plan alone still cannot run `patch_propose`, `patch_apply`, `write_file`, `shell_command`, `network_call`, or `remote_execution`.

## Redaction-focused audit notes

Current good behavior:

- Session event payloads pass through `Redactor.redact_term/1` before `Event.new/4` and `State.append/1`.
- Tool runner output and event summaries are capped/redacted before broadcast.
- Invalid plan-like output tests already assert raw invalid JSON and embedded secret strings do not remain in events.

Remaining redaction risks:

1. **Rendered valid plans are not guaranteed redacted.** `Plan.render/1` emits objective/tasks/risks/permissions directly.
2. **Plan snapshots are not value-redacted.** `SessionStore.save_session/2` scrubs by key name; ordinary plan fields can still carry token-like values.
3. **Approval events include objective by design.** Event redaction should catch many patterns, but the audit record should ideally use `plan_hash` and a short redacted title/summary rather than the full objective.
4. **Future approval records must be sanitized at construction time.** Do not rely only on event or JSON storage redaction after the record is created.

High-priority redaction regression tests:

- Valid plan with `API_KEY=sk-test-approval-secret` in objective/task/risk/validation renders and persists only redacted values.
- `/approve plan` and `/reject plan` lifecycle events do not contain raw secrets from plan fields.
- Approval records redact source/reason/metadata fields and never write raw bearer/API/Codex tokens to `.muse`.
- Provider error or tool-call args containing approval tokens/secrets are redacted before event/log output.

## Stale-approval-focused audit notes

Current good behavior:

- A plan must be active and `:awaiting_approval` to transition.
- Running turns block lifecycle commands.
- Already approved/rejected plans are rejected without adding events.

Remaining stale risks:

1. **Bare command ambiguity:** `/approve plan` has no plan id/version/hash/token argument.
2. **Displayed-plan mismatch:** There is no persisted record of which plan version/hash the user saw before approving.
3. **Same-id replacement:** `Conductor` can increment plan versions, and storage can replace `plans[plan.id]`; approval checks status only.
4. **Multi-surface latency:** A LiveView button, TUI action, or CLI command copied from old output can approve the currently active plan, not necessarily the displayed one.
5. **Restart ambiguity:** After restart, only the active plan snapshot is restored; there is no pending approval request record with expiry/display hash.

High-priority stale regression tests:

- Old displayed approval token for v1 rejects after v2 replaces active plan.
- Same `plan_id`, higher `version` rejects approval with old version/hash.
- Concurrent `/approve plan` calls produce one approval and one stale/non-awaiting error.
- Natural-language “proceed” remains non-mutating until a displayed, unambiguous, non-stale pending approval exists.
- `/reject plan` uses the same stale-binding protections as `/approve plan`.

## Likely lane integration conflict points

1. `lib/muse/session_server.ex`
   - Existing lifecycle transition, persistence, and event logic is concentrated here.
   - ApprovalGate integration will likely touch `handle_plan_lifecycle_command/3`, `transition_active_plan/5`, event data, and snapshot persistence.

2. `lib/muse/command_dispatcher.ex` and `lib/muse/commands.ex`
   - Any move from bare `/approve plan` to token/id/version-bound approval will touch parsing, usage errors, help text, autocomplete, and dispatcher tests.

3. `lib/muse/conductor.ex`
   - Plan id/version generation and future Coding Muse selection/handoff logic are here.
   - Do not let “plan approved” automatically imply “write permission granted.”

4. `lib/muse/tool/runner.ex` and `lib/muse/tool/registry.ex`
   - The PR09 gate now plugs into the validation chain while preserving current block-list and workspace/path safety behavior.
   - Avoid adding write/shell/network handlers until the later non-plan approval category tests are green.

5. `lib/muse/session_store.ex`
   - Snapshot persistence now carries approval records and bindings; durable `approvals.jsonl` could be a future enhancement.
   - Be careful not to regress current atomic snapshot, recursive redaction, and corrupt-line handling.

6. Docs and test files
   - `docs/security.md` and `docs/architecture.md` describe the final PR09 ApprovalGate MVP and deny-by-default boundary.
   - Tests in `session_server_test.exs`, `command_dispatcher_test.exs`, `m1_read_only_planning_test.exs`, and `tool/runner_test.exs` assert the integrated UX/signature behavior.

## High-priority final validation before PR09 merge

Minimum focused commands after code changes:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/muse/session_server_test.exs \
  test/muse/session_router_test.exs \
  test/muse/command_dispatcher_test.exs \
  test/muse/commands_test.exs \
  test/muse/tool/runner_test.exs \
  test/muse/m1_read_only_planning_test.exs
```

Recommended full gate before merge:

```bash
mix test
```

High-priority scenario coverage to verify:

- Approve awaiting plan: state becomes `:idle`, plan status becomes `:approved`, approval record persists, no turn/tool/patch/shell/handoff starts.
- Reject awaiting plan: state becomes `:idle`, plan status becomes `:rejected`, rejection record persists, no execution starts.
- No active plan / missing session / already approved / already rejected / running turn: safe errors, no state corruption, no events/records beyond expected denial audit.
- Stale plan id/version/content hash: denial, unchanged current plan, clear user-facing stale message.
- Durable audit: restart session after approval/rejection and verify approval record, plan status, and history render correctly.
- Redaction: valid plan and approval metadata containing secret-like strings never leak to rendered text, events, session snapshots, approval records, logs, or diagnostics.
- Tool safety after approved plan: `write_file`, `replace_in_file`, `delete_file`, `patch_propose`, `patch_apply`, `shell_command`, `network_call`, and `remote_execution` remain blocked until their own later gates exist.

## Out-of-scope reminders for PR09

Do not implement or silently enable these in PR09:

- Patch proposal/apply execution (`patch_propose`, `patch_apply`) beyond blocked/gated placeholders.
- File write tools or destructive file operations.
- Shell/test command execution.
- Network calls or remote execution.
- Checkpoint creation/rollback.
- Autonomous Coding Muse handoff after plan approval.
- Natural-language approval unless it is strictly bound to a non-stale displayed approval request and is explicitly covered by tests.
- Live provider/network tests in the default suite.

PR09 should leave the runtime in a state where an approved plan is an auditable prerequisite for future implementation, not a grant to mutate the workspace.

## Recommendation

Accept the existing lifecycle command slice as a useful foundation, but do **not** mark the full ApprovalGate contract complete until the project has:

1. A real `Muse.Approval` model.
2. A `Muse.ApprovalGate` facade in the tool/lifecycle path.
3. Content/version/workspace-bound stale approval rejection.
4. Durable approval audit records.
5. Redacted plan/approval persistence.
6. Regression tests covering stale, redaction, restart, concurrency, and no-execution guarantees.
