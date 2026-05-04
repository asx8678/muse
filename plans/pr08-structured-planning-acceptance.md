# PR08 Structured Planning Acceptance Scout

Date: 2026-05-04  
Branch: `pr08/lane01-acceptance-scout`  
Coordinator: `planning-agent-1a6824`  
Scout: `code-puppy-59af78`  
Scope: acceptance and gap analysis for `muse-1ki.1.12` / PR08 only; code changes are intentionally out of scope.

## 1. Bead and branch status

| Item | Observed state |
|---|---|
| PR08 bead | `muse-1ki.1.12` is `CLOSED` |
| Owner / assignee | `asx8678` / `asx8678` |
| Claim action | Not claimed: bead is already closed and owned/assigned |
| Parent bead | `muse-1ki.1` is open; M1 Read-Only Planning Muse |
| Top-level bead | `muse-1ki` is open; Muse Universal Runtime v0 |
| Local worktree | Created from `origin/main` because the shared checkout had a dirty `.beads/issues.jsonl` on another lane |
| PR08 closure rule | Do not close/reopen `muse-1ki.1.12` from this lane |

This document describes the acceptance contract that PR08 should satisfy after final integration. It also separates what is already present on `origin/main` from fixes that appear to exist on other PR08 lane branches but are not part of this scout branch.

## 2. Exact PR08 acceptance contract

The bead acceptance criterion is:

> Planning Muse produces a validated structured Muse Plan; plan/tasks are persisted and shown by `/plan`; invalid plans fail safely; the session enters `:awaiting_plan_approval` with no implementation handoff.

For integration, treat that as the following concrete contract.

| ID | Acceptance criterion | Required observable signal |
|---|---|---|
| AC-01 | Planning Muse is selected for new pre-approval code-change turns. | `Muse.Conductor.select_muse/2` returns `:planning` for `:idle`, `:running`, `:planning`, and `:awaiting_plan_approval` sessions; no Coding Muse selection occurs before plan approval. |
| AC-02 | Planning Muse receives only read-only/interactive tools before approval. | Provider request tool schemas for `:planning` include `list_files`, `read_file`, `repo_search`, `git_status`, `git_diff_readonly`, `ask_user_question`, `list_muses`, and `list_skills`; no write, shell, patch, network, delete, or remote tools are exposed. |
| AC-03 | Runtime guardrails block provider-requested unsafe tools even if the model asks for them. | Tool calls such as `write_file`, `replace_in_file`, `delete_file`, `patch_propose`, `patch_apply`, `shell_command`, `network_call`, and `remote_execution` cannot mutate the workspace and produce safe blocked/error events. |
| AC-04 | The structured plan schema is explicit and local. | `Muse.PlanSchema.schema/0` describes the accepted JSON shape; `validate/1` enforces required fields and types without trusting provider-side schema validation. |
| AC-05 | A valid plan has a non-empty objective and at least one task. | Parser/schema reject missing, empty, or non-string `objective`; reject missing, empty, or non-list `tasks`; reject non-map task items. |
| AC-06 | Every task has displayable work details. | Parser/schema reject tasks missing non-empty string `title` and `description`; task booleans default to `false` and are persisted as booleans. |
| AC-07 | Optional structured fields are safe and normalized. | Lists such as `risks`, `validation`, `inspected_files`, `likely_changed_files`, `files_expected`, `commands_expected`, task `target_files`, task `files`, task `tools`, and task `dependencies` are lists of the expected primitive type when present; unknown keys do not create atoms. |
| AC-08 | The parser accepts realistic model plan output. | Strict JSON is accepted; fenced JSON and ordinary prose-wrapped JSON are accepted or extracted by a documented option used by the Conductor path; parse failures return `{:error, [safe_message]}` without raising. |
| AC-09 | Invalid plan output fails safely. | Invalid JSON/schema output does not crash `SessionServer`, does not store a plan, returns a safe user message, emits safe event payloads, and leaves the session in a non-approval state such as `:idle`. |
| AC-10 | Repair behavior is bounded. | At most one repair attempt is made for plan-like invalid output; repair prompts contain safe, redacted parse errors; repair success follows the same finalization path as first-pass success. |
| AC-11 | Successful plan finalization assigns runtime ownership. | If the model omits `id`, `session_id`, or creator fields, the runtime fills deterministic/safe values before persistence; `active_plan_id` is concrete and non-nil. |
| AC-12 | Successful plan finalization transitions lifecycle state. | Plan status becomes `:awaiting_approval`; session status becomes `:awaiting_plan_approval`; a `:plan_created` event and `:session_status_changed` event are emitted with safe metadata. |
| AC-13 | User-visible output is rendered plan text, not raw JSON. | Return text and user-visible assistant events contain `Planning Muse prepared a plan.`, `Objective:`, task list, risks if present, and `/approve plan` / `/reject plan` guidance; raw JSON is not exposed in user events. |
| AC-14 | Plan persistence survives session restart. | `SessionServer.status/1` exposes `plan`, `plans`, and `active_plan_id`; `SessionStore` can persist and restore the active plan and plan map with statuses intact. |
| AC-15 | `/plan` shows the active Muse Plan. | `Muse.Commands.parse/1` recognizes `/plan`; `Muse.CommandDispatcher.dispatch/3` renders the active plan from context or `SessionRouter.status/1` without starting a missing session. |
| AC-16 | Plan history/status commands are read-only if included in PR08 integration. | `/plans`, `/plan history`, `/plan status`, and `/plan show <id>` only query/render state; they do not emit new turn/tool events or mutate workspace/session state. |
| AC-17 | The Planning Muse stops at approval. | After plan creation there is no Coding Muse handoff, patch proposal/application, write tool, shell/test execution, network call, or remote execution. |
| AC-18 | Tests and docs define the same contract. | Unit, contract, and M1 E2E tests cover valid/invalid/fenced/prose plan output, read-only tool-loop planning, persistence/commands, and unsafe tool attempts; docs do not claim stronger runtime approval features than implemented. |

## 3. Current state on `origin/main`

| Area | Current state | Evidence |
|---|---|---|
| Plan model | Implemented. `%Muse.Plan{}` includes lifecycle statuses, timestamps, tasks, risks, list fields, serialization, and rendering. | `lib/muse/plan.ex`, `test/muse/plan_test.exs` |
| Task model | Implemented. `%Muse.Task{}` supports status, target files, tool metadata, dependencies, validation, `requires_write?`, and `requires_shell?`. | `lib/muse/task.ex`, `test/muse/task_test.exs` |
| Schema | Minimal validation exists for objective, task list, task title/description, task booleans, and `risks` as a list. | `lib/muse/plan_schema.ex`, `test/muse/plan_schema_test.exs` |
| Parser | Strict JSON parser exists; optional `fenced: true` extraction exists only when explicitly passed; repair prompt helper exists. | `lib/muse/plan_parser.ex`, `test/muse/plan_parser_test.exs` |
| Prompt profile | Planning Muse profile exists with read-only tools and `output_schema: Muse.Plan`, but the prompt is very short and does not include the JSON schema/output contract. | `lib/muse/muse_registry.ex`, `lib/muse/prompt/assembler.ex` |
| Model request | `ModelPreparer` can pass `response_format`, but the assembled bundle currently leaves it unset by default. | `lib/muse/prompt/model_preparer.ex`, `lib/muse/prompt/assembler.ex` |
| Conductor plan finalization | Planning Muse output is parsed as strict JSON; valid plan output is rendered, `:plan_created` is emitted, session becomes `:awaiting_plan_approval`; invalid plan-like output attempts repair. | `lib/muse/conductor.ex`, `test/muse/conductor_planning_test.exs` |
| Session persistence | SessionServer stores `plan`, `plans`, `active_plan_id` and persists a session snapshot when a plan exists; restore path rebuilds plans. | `lib/muse/session_server.ex`, `lib/muse/session_store.ex`, `test/muse/session_server_test.exs` |
| Slash commands | `/plan`, `/plans`, `/plan history`, `/plan status`, `/plan show`, `/approve plan`, and `/reject plan` parse/dispatch paths exist. | `lib/muse/commands.ex`, `lib/muse/command_dispatcher.ex`, `test/muse/command_dispatcher_test.exs` |
| Read-only tools | Registry exposes read-only tools for Planning Muse and blocks several dangerous names; ToolRunner enforces registered/allowed/approval checks. | `lib/muse/tool/registry.ex`, `lib/muse/tool/runner.ex` |
| M1 E2E coverage | Inline fake provider batches cover read-only planning, persistence, `/plan` family, approval/rejection lifecycle-only behavior, and workspace unchanged assertions. | `test/muse/m1_read_only_planning_test.exs` |
| Fixture coverage | Provider fixture docs mention fake-provider planning fixtures, but `origin/main` has only OpenAI/Chat Completions fixtures. | `docs/testing.md`, `test/fixtures/` |
| Docs | PLAN/architecture/prompts/testing/security describe the target architecture. Security docs currently overstate `Muse.ApprovalGate` runtime enforcement for this codebase. | `PLAN.md`, `docs/architecture.md`, `docs/prompts.md`, `docs/testing.md`, `docs/security.md` |

## 4. Blockers and gaps

These are ordered by acceptance risk, not by how annoying they are. Sadly, some bugs are both.

| Gap | Priority | Evidence | Impact | Suggested lane owner |
|---|---:|---|---|---|
| G-01: plans without model-supplied ids can produce nil `active_plan_id`. | P0 | `Muse.PlanSchema.schema/0` does not require `id`; docs examples omit it. `Muse.Conductor.finalize_as_plan/6` only transitions the parsed plan. `Muse.SessionServer` stores `Map.put(state.plans, plan.id, plan)` and sets `active_plan_id: plan.id`. | A valid model plan can enter `:awaiting_plan_approval` while history lookup and active plan id are broken. `/plans` can lose the plan because nil ids are ignored by `PlanHistory`. | Lane05 + Lane10 |
| G-02: Conductor parser path is stricter than realistic LLM output. | P0 | `Muse.PlanParser.parse/2` can extract fenced JSON only with `fenced: true`; Conductor calls `PlanParser.parse(assistant_text)` without options. Current parser on `origin/main` has no `extract: :auto` or prose extraction despite PR08 bead notes referencing that work. | Fenced/prose-wrapped structured JSON can fail finalization or trigger repair unnecessarily. | Lane03 + Lane05 |
| G-03: raw plan JSON can leak through user-visible stream events. | P0 | `finalize_as_plan/6` removes old `:assistant_message` specs and `running -> idle` status specs, but not prior `:assistant_delta` specs. `safe_invalid_plan_result/2` changes `assistant_text` but does not scrub `event_specs`. | Final return text is rendered, but event consumers can still see raw structured JSON or invalid JSON. | Lane05 + Lane10 |
| G-04: prompt/preparer does not force structured JSON output. | P0 | Planning profile prompt is a single high-level sentence; `Prompt.Assembler` does not inject `PlanSchema.schema/0`; `Bundle.response_format` remains nil; `ModelPreparer` only forwards an existing response format. | Real providers may return prose plans that the Conductor cannot parse; current green tests rely heavily on scripted fake JSON. | Lane04 |
| G-05: schema validation is too permissive for declared structured fields. | P1 | `PlanSchema.validate/1` checks `risks` is a list but not that entries are strings; optional plan lists and task lists such as `target_files`, `files`, `tools`, `dependencies`, and `validation` are not type-checked. | Malformed plans can persist and later crash rendering, history, or future approval/execution logic. | Lane02 + Lane10 |
| G-06: invalid-plan failure contract lacks clean observability and redaction. | P1 | Repair prompt uses raw parse errors; invalid fallback does not replace unsafe event specs with a clean `plan_validation_failed` / safe assistant event contract. | Users and integrations get inconsistent signals; raw invalid content can leak through events; debugging invalid model behavior is harder. | Lane03 + Lane05 + Lane10 |
| G-07: read-only enforcement is split and docs overclaim `ApprovalGate`. | P1 | There is no `Muse.ApprovalGate` module on `origin/main`; `docs/security.md` says every tool path checks it. `patch_propose` is not in the current blocked-name list, so a provider attempt becomes an unknown-tool failure rather than an explicit pre-approval block. | PR08 read-only behavior can still be acceptable, but the documented security boundary is stronger than the implementation. | Lane06 + Lane09; full gate is PR09 |
| G-08: documented fake-provider fixtures are missing from `origin/main`. | P1 | `docs/testing.md` lists `test/fixtures/fake_provider/planning_flow.jsonl`; `test/fixtures/` currently lacks `fake_provider/`. M1 tests use inline batches. | E2E planning behavior is harder to reuse across providers/CI and docs are inaccurate until Lane08 lands. | Lane08 |
| G-09: rendered plan output omits much of the structured plan. | P1 | `Plan.render/1` displays header, objective, task titles, risks, and footer only. It omits descriptions, inspected files, likely changed files, validation, recommended Muse, dependencies, and write/shell flags. | Users may be asked to approve without enough structured detail to judge scope and risk. | Lane02 + Lane07 + Lane09 |
| G-10: branch integration overlaps are real. | P2 | Remote lanes modify the same files: `plan_parser.ex`, `plan_schema.ex`, `conductor.ex`, `conductor/tool_loop.ex`, `tool/result.ex`, `session_server.ex`, `command_dispatcher.ex`, and M1 tests. | A naive merge can regress one lane while making another green. Plan finalization, event scrubbing, parser extraction, and guardrails must be verified together. | Coordinator + Lane10 |

## 5. Lane responsibility map

Observed branch state from this workspace:

| Lane | Branch | Responsibility | Integration expectation |
|---|---|---|---|
| Lane01 | `pr08/lane01-acceptance-scout` | Acceptance contract, current-state audit, blocker/gap map, integration checklist. | This document only; no code changes. |
| Lane02 | `pr08/lane02-plan-model-schema` | `%Muse.Plan{}`, `%Muse.Task{}`, `Muse.PlanSchema`, model/render contract. | Ensure schema enforces all declared structured fields and renderer shows enough approval context. Local branch observed at `origin/main` in this checkout. |
| Lane03 | `origin/pr08/lane03-plan-parser-normalizer` | Parser hardening, fixtures, fenced/prose extraction, safe errors. | Merge or port `extract: :auto`, fenced/prose fixtures, redacted errors, and parser tests. |
| Lane04 | `pr08/lane04-planning-prompt-preparer` | Planning Muse prompt and provider request shape for structured output. | Add exact JSON schema/output instructions and/or response format plumbing. Local branch observed at `origin/main` in this checkout. |
| Lane05 | `origin/pr08/lane05-conductor-planning-flow` | Conductor finalization, repair path, plan-created events, session transition. | Ensure plan ids/session ids are assigned, fenced/prose parsing is used, and raw JSON deltas/messages are removed. |
| Lane06 | `origin/pr08/lane06-readonly-guardrails-security` | Read-only tool guardrails, malicious tool attempts, workspace safety, redaction. | Explicitly block unsafe provider tool calls and prove zero workspace mutation. Keep PR09 ApprovalGate claims out of PR08 unless implemented. |
| Lane07 | `origin/pr08/lane07-session-cli-plan-lifecycle` | Session persistence, `/plan` command family, approve/reject lifecycle-only flow. | Ensure read-only commands do not start sessions/turns and restored plan history works with generated plan ids. |
| Lane08 | `origin/pr08/lane08-fake-provider-fixtures-e2e` | Deterministic fake-provider planning fixtures and fixture contract tests. | Integrate `test/fixtures/fake_provider/*` and make docs/testing match real fixture paths. |
| Lane09 | `pr08/lane09-docs-contract` | README/docs/security/prompts/testing alignment. | Fix `ApprovalGate` overclaims or clearly mark them PR09/future. Local branch observed at `origin/main` in this checkout. |
| Lane10 | `origin/pr08/lane10-qa-contract-audit` | Cross-lane QA audit and regression coverage. | Merge/port audit fixes for event scrubbing, generated plan ids, fenced parsing, risk validation, and redaction. |

## 6. Final integration checklist

Use this as a gate list for the final PR08 integration branch. It is intentionally table-based rather than a task-tracking checklist; beads remain the source of task state.

| Gate | Required pass condition |
|---|---|
| Source control | Start from fresh `origin/main`; integrate PR08 lane branches intentionally; do not merge to `main` directly from a lane. |
| Branch overlap | Manually review conflicts in `lib/muse/plan_parser.ex`, `lib/muse/plan_schema.ex`, `lib/muse/conductor.ex`, `lib/muse/conductor/tool_loop.ex`, `lib/muse/tool/result.ex`, `lib/muse/session_server.ex`, `lib/muse/command_dispatcher.ex`, and M1 tests. |
| Parser contract | Valid strict JSON, fenced JSON, and prose-wrapped JSON all parse in the Conductor path; invalid output returns safe errors; no exceptions leak. |
| Plan identity | Every successful plan has concrete `id`, `session_id`, `version`, `status: :awaiting_approval`, and `created_by`/metadata sufficient for later approval. |
| Event safety | No user-visible `:assistant_delta` or `:assistant_message` event contains raw structured JSON after finalization or invalid-plan fallback. |
| Persistence | `SessionServer.status/1` exposes `plan`, `plans`, and non-nil `active_plan_id`; `SessionStore.load_session/1` restores them after restart. |
| Commands | `/plan`, `/plans`, `/plan history`, `/plan status`, `/plan show <id>` render from context/router without mutating session state or workspace. |
| Read-only safety | Scripted model attempts for write/shell/network/remote/patch tools are blocked/fail safely and do not alter workspace paths or file hashes. |
| No implementation handoff | Plan creation ends in `:awaiting_plan_approval`; no Coding Muse selection, patch proposal/apply, shell/test execution, network, or remote events occur. |
| Docs alignment | README, `docs/architecture.md`, `docs/prompts.md`, `docs/testing.md`, and `docs/security.md` describe exactly what PR08 implements and mark PR09+ ApprovalGate/patch/test behavior as future when not implemented. |
| Targeted tests | Run plan/task/schema/parser tests, conductor planning tests, session/command tests, tool guardrail tests, and M1 read-only planning E2E tests. |
| Full suite | Run `mix test` after targeted suites pass. |
| Formatting/static checks | Run `mix format --check-formatted` and `git diff --check`. |
| Beads | Keep `muse-1ki.1.12` status consistent with coordinator guidance; do not close/reopen PR08 from lane branches. |

Suggested command bundle for final integration:

```bash
mix format --check-formatted
mix test test/muse/plan_test.exs test/muse/task_test.exs test/muse/plan_schema_test.exs test/muse/plan_parser_test.exs
mix test test/muse/conductor_planning_test.exs test/muse/m1_read_only_planning_test.exs
mix test test/muse/session_server_test.exs test/muse/command_dispatcher_test.exs
mix test test/muse/tool/runner_test.exs test/muse/conductor/tool_loop_test.exs test/muse/workspace_safety_test.exs
mix test
git diff --check
```

## 7. Out of scope for PR08

| Item | Reason |
|---|---|
| Full `Muse.ApprovalGate` content-hash/stale-approval implementation | PR09 scope. PR08 may expose lifecycle commands, but content-bound approval enforcement is not required unless explicitly pulled forward. |
| Coding Muse implementation handoff | PR08 must stop before implementation. Coding Muse activation belongs after plan approval in later PRs. |
| Patch proposal/apply/checkpoint/rollback | PR17/PR18 scope. PR08 should not produce or apply patches. |
| Shell/test command approval and `test_runner` execution | Later approval/test phases. PR08 must not run arbitrary shell/test commands. |
| Real-provider structured-output guarantees | Provider/Auth/streaming PRs are later. PR08 should work with fake provider and local parser contracts. |
| Remote execution or network actions | Later milestone; explicitly blocked for PR08. |
| Large module refactors purely for line count | Several files exceed 600 lines, but refactoring them is not required for this acceptance scout and should only happen when it improves cohesion. |
| Dedicated append-only `plans.jsonl` migration | Architecture mentions it, but PR08 acceptance can be satisfied by safe session snapshot persistence if docs/tests say so. If `plans.jsonl` is required, make it an explicit follow-up. |

## 8. Scout conclusion

`origin/main` contains a substantial PR08 skeleton: Plan/Task structs, schema/parser, Conductor finalization, session persistence, slash commands, and M1-style tests are present. The remaining acceptance risk is not that PR08 is empty; it is that the integrated contract is split across branches and has several edge-case holes around realistic model output, runtime-generated plan identity, raw event leakage, schema strictness, and docs that overclaim ApprovalGate behavior.

The highest-confidence integration path is to merge or port Lane03, Lane05, Lane06, Lane07, Lane08, and Lane10 deliberately, then use Lane04/Lane09 to close the prompt/docs contract gap before final QA. Do not treat PR08 as done until generated-id plans, fenced/prose parsing, raw-event scrubbing, invalid-output safety, and malicious tool attempts are covered in one integrated test run.
