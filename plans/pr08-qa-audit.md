# PR08 Lane10 QA / Contract Audit

Date: 2026-05-04
Branch: `pr08/lane10-qa-contract-audit`
Coordinator: `planning-agent-1a6824`
Reviewer: `elixir-code-critic-d38bd6`

> **Post-integration note:** This PR08 QA audit is retained as historical contract evidence. Its ApprovalGate residual blocker described PR08, when content-bound approval policy was future work; after PR09 integration, use the current PR09 docs/code for ApprovalGate status while preserving PR08's no-implementation-handoff safety boundary.

## Scope audited

Reviewed the current PR08 state on `origin/main` for the Planning Muse MVP contract:

- Planning Muse selection, read-only tool exposure, and plan finalization in `Muse.Conductor` and `Muse.Conductor.ToolLoop`.
- Structured plan parsing/validation in `Muse.PlanParser`, `Muse.PlanSchema`, and `%Muse.Plan{}` normalization/rendering.
- Session lifecycle persistence and plan approval/rejection command paths through `Muse.SessionServer`, `Muse.SessionStore`, and command dispatcher tests.
- Tool runner guardrails and event redaction in `Muse.Tool.Runner`, `Muse.Tool.Result`, and session-owned tool loop events.
- Workspace safety and docs/security claims around approval gating, write/shell tools, and secret redaction.

## Issues fixed in this lane

1. **Raw structured plan JSON could remain in user-visible assistant delta events.**
   - Impact: final rendered plan text hid JSON, but streamed `:assistant_delta` event specs could still contain raw JSON.
   - Fix: planning finalization now removes assistant deltas/messages from the turn event specs before emitting the rendered plan message. Invalid plan fallback similarly replaces raw assistant events with a safe message.
   - Regression coverage: `test/muse/conductor_planning_test.exs` asserts no assistant deltas for rendered/fenced/invalid plan outputs.

2. **Plans without a model-supplied id were not guaranteed to be persisted under a concrete active plan id.**
   - Impact: `%Muse.Plan{id: nil}` could leave `active_plan_id` unset and make the plan inaccessible through `/plan`/history even though the session entered `:awaiting_plan_approval`.
   - Fix: conductor plan finalization now fills missing `id`, `session_id`, and `created_by` from the session/turn/muse before transitioning to `:awaiting_approval`.
   - Regression coverage: `test/muse/m1_read_only_planning_test.exs` verifies generated `active_plan_id`, in-memory plan map, and persisted session store entry.

3. **Fenced structured JSON from the Planning Muse was not accepted by conductor finalization.**
   - Impact: `PlanParser` could parse fenced JSON when requested, but conductor finalization used strict parsing.
   - Fix: conductor plan parse/repair paths call `PlanParser.parse/2` with `fenced: true`.
   - Regression coverage: conductor contract test for fenced JSON verifies rendered output and no raw JSON deltas.

4. **Risk list item types were not validated against the declared schema.**
   - Impact: a non-string `risks` entry could pass schema validation and later crash rendering paths that expect binaries.
   - Fix: `Muse.PlanSchema` now rejects non-string risk entries.
   - Regression coverage: `test/muse/plan_schema_test.exs` covers non-string risk entries.

5. **Secret-like provider tool names / tool args could survive intermediate result or event summaries.**
   - Impact: event payload redaction protected emitted events, but `Muse.Tool.Result` and tool-loop `args_summary` did not consistently redact at construction/summary boundaries.
   - Fix: `Muse.Tool.Result` redacts tool names, errors, and safe summaries; `Muse.Conductor.ToolLoop` redacts args summaries.
   - Regression coverage: runner tests cover secret-like unknown tool names and args summaries.

6. **Provider-requested write/shell tools needed an explicit workspace mutation contract test.**
   - Impact: existing positive tests covered read-only tool use, but did not prove malicious provider write/shell tool calls were blocked and non-mutating.
   - Fix: added an M1 read-only planning test that scripts `write_file` and `shell_command` tool calls, verifies blocked events, and snapshots workspace paths/hashes before and after.

## Residual blockers / proposed fixes

### Blocker A — documentation overstates the implemented approval-gate boundary

Follow-up bead: `muse-1ki.1.18`

Evidence:

- `docs/security.md` states that `Muse.ApprovalGate` enforces every tool call and that no tool executes without passing through the approval gate.
- Current PR08 code enforces the M1 read-only contract through tool registry allow/block lists and runner checks. There is no dedicated `Muse.ApprovalGate` module in the audited PR08 code.
- PR08 can still be accepted as a read-only Planning Muse MVP, but the docs claim a stronger future PR09 approval architecture than exists today.

Risk:

- A future implementer or reviewer may assume content-bound approval checks exist for all tool paths when the current implementation only provides coarse read-only/block-list enforcement.

Proposed fix:

- In PR08 docs, label the `ApprovalGate` material as PR09/future architecture, or add a minimal `Muse.ApprovalGate` facade that the tool runner calls before registry execution.
- In PR09, make approval binding explicit and test stale plan/patch/command approvals against content hashes and workspace/session identity.

## Residual risks to track outside this lane

- The current blocked-tool list is name based. That is sufficient for the present read-only registry but should evolve into positive capability metadata enforced by a single approval gate before new write/shell/network tools are added.
- `Plan.render/1` still assumes callers provide a normalized `%Muse.Plan{}`. This lane tightened the LLM schema path, but persisted legacy malformed plans could still warrant a defensive renderer hardening pass.
- Planning docs describe future patch/test/shell approval flows that are intentionally outside PR08; they should not be treated as available until PR09+ implementation lands.

## Contract status after lane fixes

- Planning Muse is selected for new planning turns and remains read-only: covered by existing and added M1 tests.
- Provider write/shell tool calls are blocked and cannot mutate workspace: covered by added M1 malicious-tool test.
- Structured plan JSON parses to `%Muse.Plan{}` and rendered output hides raw JSON: covered by conductor and parser tests, with added event-delta coverage.
- Invalid plan output is safe and does not crash `SessionServer`: covered by conductor and M1 invalid-plan tests.
- Plan approval/rejection transitions are deterministic and non-mutating: covered by existing completion-gate tests.
- No dynamic atoms from LLM JSON/tool names/statuses: reviewed `String.to_existing_atom` usage and schema normalization paths; no new dynamic atom creation introduced.
- Secret-like strings in model output/tool args/errors are redacted from events/errors: covered by existing redaction tests and new runner/invalid-plan coverage.
