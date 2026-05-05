# PR09 lane14 — UI/TUI/LiveView approval status audit

Coordinator: `planning-agent-1a6824`
Implementer: `code-puppy-d908f0`
Branch: `pr09/lane14-ui-status-audit`

## Scope audited

Checked the UI-facing paths that display, search, export, or stream Muse Plan approval lifecycle events:

- LiveView home/session chat rendering via `MuseWeb.HomeLive` + `Muse.EventStream.chat_messages/1`.
- LiveView Events tab formatting/search/export via `MuseWeb.EventFormatter`.
- TUI Events tab rendering/search via `Muse.CLI.Tui`.
- CLI command output/export paths via `Muse.CommandDispatcher`.
- Event creation and plan lifecycle event emission through `Muse.SessionServer` and `Muse.Event`.
- Plan lifecycle command parser/dispatcher wording for `/approve plan` and `/reject plan`.

## Findings

### Approval events existed, but UI status visibility was incomplete

`SessionServer` already emits `:plan_created`, `:plan_approved`, and `:plan_rejected` events with safe summary fields such as plan id, version, task count, and objective for creation. The Events tab and `/events` command could display these generic events, but the LiveView/session chat projection ignored plan lifecycle events because `EventStream.chat_messages/1` only projected user/assistant message event types.

### Approval wording was slightly risky

`/approve plan` returned:

> The approved plan is ready for implementation.

That was true-ish but dangerously easy to read as “approval starts implementation.” Approval currently transitions plan/session state only; it does not start a runner or implementation turn. The UI copy now says approval records the plan decision only and implementation still requires a later explicit gate.

### Raw plan JSON/secrets needed one shared display boundary

Multiple UI paths had local `inspect(data)` fallbacks. Existing plan lifecycle events do not intentionally include raw plan JSON, and planning-turn raw assistant JSON is already omitted when a valid plan is produced, but local fallbacks make future payload drift too easy. A shared display-safe boundary is less cursed than hoping every UI path remembers to redact.

## Implemented changes

### Shared display-safe event helper

Added `Muse.EventDisplay`:

- Redacts event payload secrets using `Muse.Prompt.Redactor`.
- Suppresses raw structured plan JSON strings with a placeholder pointing users to `/plan` or `/plan show <id>`.
- Replaces nested `%Muse.Plan{}` structs or plan-shaped maps with compact summaries:
  - `plan_id`
  - `version`
  - `status`
  - `objective`
  - `task_count`
- Provides lifecycle summaries for:
  - `:plan_created`
  - `:plan_approved`
  - `:plan_rejected`
- Makes approval caveat explicit:
  - “Approval records the plan decision only; implementation still requires a later explicit gate.”

### LiveView/session event stream visibility

Updated `Muse.EventStream.chat_messages/1` to project plan lifecycle events into `:system` chat messages while continuing to suppress internal/sensitive events.

Added light CSS for `.chat-message-system` so system status events are visually distinct in the LiveView session chat instead of looking like a malformed puppy sneezed into the DOM.

### Web Events tab/export/search

Updated `MuseWeb.EventFormatter` to use `Muse.EventDisplay` for:

- event row display text;
- search text; and
- JSON/export maps.

Plan lifecycle event badges now get visible accent/success styling, with `:plan_approved` treated as success-ish.

### TUI Events tab/search

Updated `Muse.CLI.Tui` event rendering/search to use the shared display-safe summaries instead of local ad-hoc map formatting.

### CLI command output/export

Updated `Muse.CommandDispatcher` to use shared display-safe event summaries for:

- `/events` output;
- event search; and
- event export maps.

Updated `/approve plan` success copy so it does not imply approval starts implementation.

## Safety notes

- No plan lifecycle command now starts implementation; tests assert `active_turn_id == nil` and `runner_pid == nil` after approve/reject.
- Plan lifecycle event summaries expose only status/id/version/task count/objective summary, not raw plan JSON.
- UI-facing event JSON export is sanitized before JSON conversion.
- Internal/sensitive events remain excluded from chat projection.

## Validation

Ran targeted UI/event tests and compile checks with the isolated worktree using the main workspace dependency cache:

```bash
MIX_DEPS_PATH=/Users/adam2/projects/muse/deps mix test \
  test/muse/event_stream_test.exs \
  test/muse/event_test.exs \
  test/muse/event_display_test.exs \
  test/muse/command_dispatcher_test.exs \
  test/muse_web/event_formatter_test.exs \
  test/muse/cli/tui_test.exs

MIX_DEPS_PATH=/Users/adam2/projects/muse/deps mix compile --warnings-as-errors
mix format
git diff --check
```

## Remaining risks / follow-up ideas

- `Muse.CommandDispatcher` and `Muse.CLI.Tui` were already over 1k lines before this lane. Splitting them would be healthy, but doing that in an approval-status audit lane would be scope creep wearing a fake mustache.
- `SessionServer` persists session events separately from global `Muse.State`; this lane sanitizes UI/export/display boundaries rather than changing persisted event semantics.
- `EventStream.chat_messages/1` preserves its existing grouped turn ordering and appends system lifecycle messages after user/assistant messages for a turn. That matches current plan-created ordering, but a future richer timeline renderer may want fully interleaved chronological rows.
