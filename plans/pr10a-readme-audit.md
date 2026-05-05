# PR10a README/CLI Docs Audit — Lane 06

**Branch:** `pr10a/lane06-readme-cli-docs`
**Commit:** `9eb462f` — docs: README/CLI wording cleanup after PR09
**Status:** Changes committed and pushed

---

## Findings

### 1. Opening paragraph — `Muse.submit/2` scope was ambiguous

**Before:** "both funnel through a single `Muse.submit/2` API"
**After:** "both funnel user messages through a single `Muse.submit/2` API"
**Added:** Note that slash commands dispatch separately through `Muse.CommandDispatcher`

Rationale: The original wording implied ALL input (including slash commands) flows
through `Muse.submit/2`. In reality, `Muse.submit/2` handles user messages only;
slash commands are parsed by `Muse.Commands` and dispatched via
`Muse.CommandDispatcher.dispatch/3`.

### 2. Architecture diagram annotation was misleading

**Before:** `Muse.submit/2 ← single entry point for all input`
**After:** `Muse.submit/2 ← single entry point for user messages`

Same rationale as #1 — consistent with the opening paragraph fix.

### 3. `/approve plan` and `/reject plan` — no implication of implementation

The `/approve plan` table entry already said "records approval only and does **not**
start implementation" — this was correct and was NOT changed.

However, the paragraph below the CLI Commands table previously said:
> "Approval of a plan does not start Coding Muse, shell commands, file writes,
> patch application, or network execution."

**After:**
> "Plan approval records the decision only — it does not trigger implementation,
> patch application, shell commands, file writes, or network execution.
> Implementation and patch-approval gates are separate roadmap items."

Changes:
- Removed "Coding Muse" — avoids implying a specific agent exists that could be
  started (the term is internal to `Muse.ApprovalAudit` output, not user-facing)
- Restructured as a positive statement ("records the decision only") followed by
  explicit enumeration of what it does NOT trigger
- Added roadmap note about separate implementation/patch-approval gates

### 4. CLI table descriptions didn't match `Muse.Commands` module

| Command | Before (README) | After (matches code) |
|---|---|---|
| `/events` | Print the event log | Show event summary |
| `/workspace` | Print current workspace path | Show workspace info |
| `/reload` | Force a dev hot-reload | Force dev reload |
| `/rollback` | Roll back to last good code generation | Roll back to last good generation |
| `/reload-status` | Show reload generation and last error | Show reload/watcher status |

### 5. `/auth status` was missing from CLI Commands table

The `/auth status` command exists in `Muse.Commands` and is mentioned elsewhere in
the README (provider/auth sections) but was not listed in the CLI Commands table.
Added it.

### 6. Key modules table — `Muse.submit/2` return type was vague

**Before:** `returns {:ok, response}`
**After:** `returns {:ok, String.t()}`

Matches the actual `@spec submit(atom(), String.t()) :: {:ok, String.t()}` in
`lib/muse.ex`.

---

## Items NOT changed (with rationale)

- **`/approve plan` table description** — already says "records approval only and
  does **not** start implementation". Sufficient for a table cell; detailed
  semantics are in the paragraph below.
- **`/reject plan` table description** — "Reject the active Muse Plan and request
  a revised plan" does not imply any implementation, patching, shell/network, or
  writes. No change needed.
- **`/reject plan` paragraph** — changed "ask Planning Muse" to "request" for
  consistency (the code's `Plan` footer says "Ask Planning Muse" but the README
  should be implementation-neutral).

---

## Validation

- `git diff --check` — clean (no whitespace errors)
- `grep README.md for Coding Muse` — 0 occurrences (removed)
- `grep README.md for approve` — only in proper contexts
- `grep README.md for implementation` — correctly positioned
- `grep README.md for patch` — correctly positioned
- `grep README.md for Muse.submit` — consistent across all references

---

## Risks

- **Low**: Removing "Coding Muse" from the README paragraph diverges slightly from
  `Muse.ApprovalAudit` internal messages which still say "no Coding Muse turn".
  This is intentional — the README is user-facing and should not name a specific
  agent that may not exist yet. The audit messages are internal/developer-facing.
- **Low**: Adding "Implementation and patch-approval gates are separate roadmap
  items" is a forward-looking statement. If these gates are never implemented,
  this note may become stale. Consider tracking with a bead for future cleanup.
