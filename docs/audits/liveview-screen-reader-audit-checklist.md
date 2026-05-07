# LiveView Screen-Reader Audit Checklist

> **Audit Issue:** `muse-1rq` (`bd show muse-1rq`)
> **Checklist created:** 2026-05-06 (muse-ur4)
> **Auditor:** _fill in your name/role_
> **Date executed:** _fill in audit date_
>
> **⚠️ IMPORTANT:** This checklist prepares the audit but does **not** satisfy `muse-1rq` acceptance criteria. Actual assistive-technology testing results must be recorded and reviewed before that issue can close.

## Table of Contents

1. [Prerequisites & Environment Setup](#1-prerequisites--environment-setup)
2. [Recommended Browser / OS / Screen-Reader Matrix](#2-recommended-browser--os--screen-reader-matrix)
3. [App Startup & Route](#3-app-startup--route)
4. [Keyboard-Only Baseline Checks](#4-keyboard-only-baseline-checks)
5. [Screen-Reader Quick Reference](#5-screen-reader-quick-reference)
6. [Audit Areas — Detailed Checks](#6-audit-areas--detailed-checks)
7. [Pass / Fail Recording Template](#7-pass--fail-recording-template)
8. [Severity Guidance](#8-severity-guidance)
9. [When to File Follow-Up Beads Issues](#9-when-to-file-follow-up-beads-issues)
10. [Responsive / Mobile Checks](#10-responsive--mobile-checks)

---

## 1. Prerequisites & Environment Setup

### Required Hardware / Software

- [ ] **macOS 14+** (for VoiceOver) **or** **Windows 10/11** (for NVDA / JAWS)
- [ ] Latest stable browser appropriate for the selected screen reader: **Safari** or **Chrome** for VoiceOver, **Firefox** or **Chrome** for NVDA, **Edge** for Narrator (see matrix below)
- [ ] **VoiceOver** (macOS, built-in) **or** **NVDA** (Windows, free: <https://www.nvaccess.org/>) — at least one must be installed and working
- [ ] **Optional but recommended:** JAWS (paid) or Narrator (Windows built-in) for cross-reader validation
- [ ] Elixir/OTP 26+ installed (`elixir --version`)
- [ ] Node.js 18+ (for Playwright smoke if needed, but not required for this manual audit)

### Environment Checks

- [ ] Screen reader is enabled and producing speech output (e.g., VoiceOver: `Cmd+F5`; NVDA: `Ctrl+Alt+N`)
- [ ] Volume is audible / headphones connected (privacy for speech output)
- [ ] No other TTS or voiceover utility is conflicting
- [ ] Browser zoom set to **100%** (reset before testing reflow/zoom)
- [ ] Browser in **full-screen or maximized** for desktop checks
- [ ] Font size: OS default

### Local Repo

- [ ] Repository checked out at `main` (or the current target branch for `muse-1rq`)
- [ ] `mix deps.get` run successfully
- [ ] `npm install` (for LiveView asset bundling if applicable)

---

## 2. Recommended Browser / OS / Screen-Reader Matrix

| Screen Reader | OS        | Best Browser    | Notes                                  |
|---------------|-----------|-----------------|----------------------------------------|
| **VoiceOver** | macOS 14+ | Safari          | Native integration; best primary macOS combination |
| VoiceOver     | macOS 14+ | Chrome          | Different rendering engine; useful for comparison |
| **NVDA**      | Windows   | Firefox         | Most popular free SR; close-to-real-world |
| NVDA          | Windows   | Chrome          | Also widely used                        |
| JAWS          | Windows   | Chrome / Firefox | Paid; enterprise standard               |
| Narrator      | Windows   | Edge            | Built-in; good baseline                 |

**Minimum**: VoiceOver + Safari (macOS) **or** NVDA + Firefox (Windows).  
**Recommended**: At least two SR/browser combinations from different engines.

---

## 3. App Startup & Route

### Start Muse with Fake Provider

```bash
# From the project root:
MIX_ENV=smoke MUSE_PROVIDER=fake mix muse --web-only --host 127.0.0.1 --port 4102 --no-watch
```

> `./script/liveview-browser-smoke` is useful as a non-manual smoke check: it auto-starts on port 4101 by default, runs assertions, and tears the server down.  
> For manual screen-reader work, use the persistent server command above.

### URL

```
http://127.0.0.1:4102
```

### Verify Server Is Running

- [ ] Browser loads the page (no blank/error page)
- [ ] The chat composer textarea is reachable
- [ ] No JavaScript console errors (DevTools → Console)

---

## 4. Keyboard-Only Baseline Checks

> Perform these **with the screen reader off** first, then repeat with screen reader on.

### Tab / Focus Navigation

- [ ] `Tab` from page load moves focus to **skip link** (if rendered) → Enter activates it, moving focus to main chat panel
- [ ] `Tab` order is logical for the current DOM: skip link → header controls (mobile/context toggle, diagnostics chip if present) → context/sidebar controls and session card → chat panel prompt chips/history → composer → send button → overlays when visible
- [ ] No **keyboard traps**: You can `Tab` through the entire page without getting stuck
- [ ] `Shift+Tab` reverses navigation correctly
- [ ] All interactive elements are reachable via keyboard alone

### Interactive Elements

- [ ] **Chat composer** (`<textarea>`): receives focus, typing works, `Enter` submits, and `Shift+Enter` inserts a newline
- [ ] **Send button**: reachable and activatable via `Enter` / `Space`
- [ ] **Context sidebar controls**: mobile "Toggle context sidebar", rail "Expand sidebar", "Collapse to rail", and "Hide sidebar" controls are reachable where rendered and communicate state clearly enough for the current viewport
- [ ] **Diagnostics drawer trigger**: reachable; `Enter`/`Space` opens drawer
- [ ] **Diagnostics drawer close/back**: reachable while drawer is open; `Escape` closes drawer
- [ ] **Toast dismiss button**: reachable (if not auto-dismissed) and activatable
- [ ] **Session status card**: focusable elements within (if any) are reachable
- [ ] **Patch proposal panel** (when visible): dismiss button and command guidance are reachable; approval/rejection via `/approve patch` and `/reject patch` remains discoverable through the composer

### Focus Indicators

- [ ] Focus ring/outline visible on every focused element (WCAG 2.4.7)
- [ ] Focus indicators have sufficient contrast against their background

---

## 5. Screen-Reader Quick Reference

### VoiceOver (macOS) — Key Commands

| Action | Command |
|--------|---------|
| Enable/disable | `Cmd+F5` |
| Read next element | `VO+Right Arrow` |
| Read previous element | `VO+Left Arrow` |
| Read entire page | `VO+A` |
| Interact with an element | `VO+Shift+Down Arrow` |
| Stop interacting | `VO+Shift+Up Arrow` |
| Navigate by headings | `VO+Cmd+H` (next), `VO+Cmd+Shift+H` (previous) |
| Navigate by landmarks | `VO+U` → Rotor → Landmarks |
| Navigate by links | `VO+U` → Rotor → Links |
| Navigate by form controls | `VO+U` → Rotor → Form Controls |
| Activate element | `VO+Space` |
| Read next item in rotor | `VO+U` → Right/Left Arrow to change category |
| Read page title | `VO+Shift+T` |
| Read current focused element | `VO+Shift+F` |
| Open Rotor | `VO+U` |

> `VO` = `Ctrl+Option` on macOS.

### NVDA (Windows) — Key Commands

| Action | Command |
|--------|---------|
| Enable/disable | `Ctrl+Alt+N` |
| Read next element | `Down Arrow` (browse mode) |
| Read previous element | `Up Arrow` (browse mode) |
| Read entire page | `NVDA+Down Arrow` (say all) |
| Navigate by headings | `H` (next), `Shift+H` (previous) |
| Navigate by landmarks | `D` (next), `Shift+D` (previous) |
| Navigate by form fields | `F` (next), `Shift+F` (previous) |
| Navigate by buttons | `B` (next), `Shift+B` (previous) |
| Navigate by links | `K` (next), `Shift+K` (previous) |
| Toggle browse/focus mode | `NVDA+Space` |
| Activate element | `Enter` |
| Read page title | `NVDA+T` |
| List elements dialog | `NVDA+F7` |
| Read current line | `NVDA+Up Arrow` |

> `NVDA` key is typically `Insert` (default) or `Caps Lock` (configurable).

### Common Landmark Navigation

| Landmark | VoiceOver Rotor      | NVDA Browse Mode |
|----------|----------------------|------------------|
| `main`   | Landmarks → "main"  | `D` → "main"    |
| `region` | Landmarks → region  | `D` → region    |
| `complementary` | Landmarks → complementary | `D` → complementary |
| `form`   | Form Controls        | `F` → form      |
| `log`    | (may auto-announce) | (live region)   |
| `status` | (may auto-announce) | (live region)   |

---

## 6. Audit Areas — Detailed Checks

### 6.1 Skip Link & Bypass Block (WCAG 2.4.1)

- [ ] A **skip link** is the first focusable element on the page
- [ ] Skip link label is clear: "Skip to main content" or similar
- [ ] Activating skip link moves focus to the chat panel / main region
- [ ] Skip link is visible on focus (not hidden unless focused)
- [ ] With screen reader: navigate forward from top of page → skip link is announced before any other content
- [ ] VoiceOver Rotor → Landmarks → "main" is present
- [ ] NVDA: press `D` → "main" landmark is navigable

**Expected announcements:**
- VoiceOver: "Skip to main content, link, [you are currently on a link]" (when focused)
- NVDA: "Skip to main content, link" (browse mode)

### 6.2 Landmarks & Regions (WCAG 1.3.1, 4.1.2)

- [ ] Exactly **one** `role="main"` or `<main>` landmark per page
- [ ] Chat panel is a `region` with an `aria-label` like "Muse conversation"; its scroll area is a `log` named "Conversation history"
- [ ] Context / sidebar is `role="complementary"` with an `aria-label` like "Workspace context and session status"
- [ ] Toast notifications are exposed consistently with current markup: the container is labelled "Notifications" and individual toasts use `role="alert"`; record whether that assertive behavior is appropriate for the toast type
- [ ] Session status card is understandable within the complementary landmark; the current status row exposes a concise `role="status"` name such as "Session status: Idle"
- [ ] Diagnostics drawer (when open) has `role="dialog"` with `aria-label` / `aria-labelledby`
- [ ] Patch proposal panel (when visible) has `role="region"` with `aria-label`
- [ ] No duplicate landmark roles caused by wrapping/inner elements; historical finding #2 was addressed in `muse-1rq.2`, so verify no regression
- [ ] VoiceOver Rotor → Landmarks lists all distinct landmarks clearly
- [ ] NVDA: `D` navigation cycles through landmarks in a logical order

**Expected landmarks (VoiceOver Rotor, NVDA `D`):**
1. "banner" or site header (if any)
2. "main" — the primary content region
3. "Muse conversation" region (inside main)
4. "Workspace context and session status" complementary
5. "Conversation history" log (may be exposed as a live region rather than a rotor landmark)
6. Toast alerts as notifications when present (not necessarily a landmark)
7. "Diagnostics" dialog (when open)

### 6.3 Chat Composer (WCAG 1.3.1, 2.4.6, 4.1.2)

- [ ] `<textarea>` has an associated `<label>` or `aria-label` (current markup: `aria-label="Message to Muse"`)
- [ ] Label clearly describes purpose, e.g., "Message to Muse", "Message input", or "Chat message"
- [ ] Placeholder text provides additional hint (current markup: "Ask Muse anything, or type /help...")
- [ ] `role="form"` on the composer form element
- [ ] Send button has an accessible name (e.g., "Send" or "Send message")
- [ ] Screen reader announces label + role + state when focused
- [ ] Textarea placeholder contrast meets AA (≥4.5:1); historical finding #6 was addressed in `muse-1rq.4`, so verify no regression

**Expected announcements (VoiceOver focus on textarea):**
- "Message to Muse, text area" plus placeholder/hint text
- "Ask Muse anything, or type /help..."

**Expected announcements (NVDA browse mode on textarea):**
- "Message to Muse, edit, multi-line" plus placeholder/hint text
- Form landmark is navigable

### 6.4 Message Log / Live Region (WCAG 4.1.2, 4.1.3)

- [ ] Message container has `role="log"` with `aria-live="polite"` and `aria-label="Conversation history"`
- [ ] New messages are announced automatically (or via `aria-live` region `polite` updates)
- [ ] Announcements do not interrupt current focus/speech (i.e., use `polite` not `assertive`)
- [ ] No nested `role="status"` inside `role="log"`; historical finding #4 was addressed in `muse-1rq.3`, so verify no regression
- [ ] Each message has clear accessible name/label if interactive
- [ ] With screen reader: type a message, send it → the message is announced without focus being moved
- [ ] Message timestamps (if present) are not overly verbose

**Expected behavior:**
- VoiceOver: new user/assistant message text is announced as a polite live-region update, with the visible speaker label (for example "you" or "muse") available when browsing history
- NVDA: new message text is announced without moving focus away from the composer/current control

### 6.5 Context / Sidebar Controls (WCAG 1.3.2, 2.4.3)

- [ ] Sidebar controls have accessible names matching the current UI: "Toggle context sidebar" (mobile/header), "Expand sidebar" (rail), "Collapse to rail", and "Hide sidebar"
- [ ] State is communicated where applicable: the mobile/header toggle exposes `aria-expanded="true|false"`; rail/desktop controls should still be understandable from their names
- [ ] Sidebar content navigable when expanded
- [ ] With screen reader: navigate to the complementary landmark → hear "Workspace context and session status, complementary"; activate sidebar controls and verify the resulting expanded/rail/hidden state is clear
- [ ] When sidebar is collapsed/hidden, its content is not in tab order
- [ ] Sidebar controls are not announced as "dimmed" or "unavailable" unless visually disabled

**Expected announcements (VoiceOver Rotor → Landmarks → "Workspace context and session status"):**
- "Workspace context and session status, complementary"
- Inside: "Context" and mini-card headings such as "session", "workspace", "diagnostics"
- Current session row: "Session status: Idle" / "Session status: Running" (or equivalent current state)

### 6.6 Diagnostics Drawer (WCAG 2.4.3, 2.4.7, 4.1.2)

> Historical finding #1 (HIGH) reported broken drawer focus management. Follow-up `muse-1rq.1` is closed; verify the current modal/focus-trap behavior manually and file a regression if it fails.

- [ ] Drawer trigger button has an accessible name derived from the current diagnostics chip/details control (for example "diagnostics … issue(s)" or "open details")
- [ ] When drawer opens, focus moves **into** the drawer (NOT remaining on trigger)
- [ ] Focus is trapped within drawer while open (Tab cycles inside, not behind)
- [ ] Background content is `aria-hidden="true"` and/or `inert` while drawer is open
- [ ] Drawer close/minimize button has an accessible name (current markup: "Minimize diagnostics panel")
- [ ] `Escape` key closes the drawer
- [ ] When drawer closes, focus returns to the trigger
- [ ] Drawer has `role="dialog"` with `aria-modal="true"` (if modal) or appropriate landmark
- [ ] With screen reader: activate trigger → hear announcement like "Diagnostics, dialog" → navigate inside → all drawer content and action buttons are readable
- [ ] NVDA: browse mode should work inside drawer; focus mode for interactive elements
- [ ] Announcement of live regions inside drawer should not bleed to background

**Expected announcements (VoiceOver):**
- Trigger: "diagnostics, [n] issue(s), button" or "open details, button"
- On open: "Diagnostics, dialog" / "Diagnostics, heading/text" followed by drawer content
- Close button: "Minimize diagnostics panel, button"

### 6.7 Patch Proposal Panel (WCAG 2.4.3, 4.1.2) — Visible only when a patch is proposed

- [ ] Panel has clear accessible role: `role="region"` with an `aria-label` like "Patch proposal awaiting approval"
- [ ] Dismiss button has a distinct accessible name (current markup: "Dismiss patch proposal")
- [ ] Approval/rejection instructions are readable: `/approve patch` and `/reject patch`; if approve/reject buttons are added later, each must have a distinct accessible name
- [ ] Keyboard navigation reaches panel in a logical order for an overlay rendered after main content
- [ ] With screen reader: panel is discoverable through region navigation or sequential reading
- [ ] Status is clear: "awaiting approval" or similar

**Expected announcements:**
- "Patch proposal awaiting approval, region"
- "Dismiss patch proposal, button"
- Text guidance for `/approve patch` and `/reject patch`

### 6.8 Session Status Card (WCAG 1.3.1, 4.1.2)

- [ ] Card is within the "Workspace context and session status" complementary landmark and has a meaningful card label (current mini-card label: "Session status")
- [ ] Session status text ("Idle", "Running", "Plan awaiting approval", etc.) is readable by screen reader
- [ ] The current status row's `role="status"` announcement is concise and does not create excessive repeated speech
- [ ] Active Muse, plan, patch, and turn rows (when present) have descriptive names

**Expected announcements:**
- "Session status: Idle" / "Session status: Running" (or equivalent current state)
- "Active Muse: [name]" when present
- "Patch awaiting approval" when present

### 6.9 Toast / Error Announcements (WCAG 4.1.3, 4.1.2)

- [ ] Toast container is labelled "Notifications" and individual toasts expose the intended live-region behavior (current markup: each toast uses `role="alert"`)
- [ ] Toasts are announced without moving focus
- [ ] Toast content is concise and meaningful
- [ ] Dismissible toasts have a close button with accessible name (current pattern: "Dismiss {type} notification: {message}")
- [ ] Assertive `role="alert"` announcements are reserved for error/urgent toasts; if routine/success toasts interrupt speech, file a follow-up to use a polite status pattern for those cases
- [ ] With screen reader: trigger a toast → hear announcement like "Error: [message]" while remaining in current context
- [ ] Multiple simultaneous toasts: announcements are not overly verbose (deduplication or summarization if needed)

**Expected announcements:**
- "Error: Could not connect to provider. Please try again."
- "Dismiss error notification: Could not connect to provider. Please try again., button" (or equivalent current toast type/message)

### 6.10 Skip-Link Rendering (WCAG 2.4.1)

> Historical finding #3 reported a missing skip link. Follow-up `muse-1rq.2` is closed; verify the current rendered skip link has not regressed.

- [ ] A rendered skip link exists in the HTML (not just CSS class)
- [ ] Skip link is target of `href="#main-content"` or similar
- [ ] Target element (`id`) exists and contains chat panel
- [ ] Skip link is visible on focus (at minimum visible programmatically for screen reader users)

---

## 7. Pass / Fail Recording Template

For each check, record:

| Check ID | Area | Criterion | Result (PASS/FAIL/NA) | Notes | SR Used |
|----------|------|-----------|----------------------|-------|---------|
| SL-1 | Skip Link | 2.4.1 | | | |
| LM-1 | Landmarks | 1.3.1 | | | |
| LM-2 | Landmarks | 4.1.2 | | | |
| CC-1 | Composer | 1.3.1 | | | |
| CC-2 | Composer | 4.1.2 | | | |
| ML-1 | Message Log | 4.1.2 | | | |
| ML-2 | Message Log | 4.1.3 | | | |
| SC-1 | Sidebar | 1.3.2 | | | |
| SC-2 | Sidebar | 2.4.3 | | | |
| DD-1 | Diagnostics Drawer | 2.4.3 | | | |
| DD-2 | Diagnostics Drawer | 2.4.7 | | | |
| DD-3 | Diagnostics Drawer | 4.1.2 | | | |
| PP-1 | Patch Proposal | 2.4.3 | | | |
| PP-2 | Patch Proposal | 4.1.2 | | | |
| SS-1 | Session Status | 1.3.1 | | | |
| TE-1 | Toast/Errors | 4.1.3 | | | |
| KB-1 | Keyboard Baseline | 2.1.1 | | | |
| KB-2 | Keyboard Baseline | 2.4.7 | | | |

### Template Row (copy for each area/component)

```markdown
| {check-id} | {area} | {wcag-ref} | PASS/FAIL/NA | {observations} | {VoiceOver/NVDA/..} |
```

### Summary Section

After completing checks, fill in:

```markdown
## Audit Summary

**Auditor:** {name}
**Date:** {date}
**Screen Reader(s) used:** {list}
**Browser(s) used:** {list}

### Overall Verdict

| Category | Count |
|----------|-------|
| ✅ Pass | {n} |
| ❌ Fail | {n} |
| ⚠️ NA   | {n} |

### Critical / High Findings

1. {Finding} — {severity}
2. {Finding} — {severity}

### Notes / Observations

{free text}

### Recommended Next Steps

1. File follow-up issues for each FAIL (see §9 below)
2. Re-test after fixes
3. Update `muse-1rq` with the audit summary; do not close it until results are reviewed and accepted
```

---

## 8. Severity Guidance

| Severity | Criteria | Example |
|----------|----------|---------|
| **Critical** | Complete barrier: user cannot accomplish a primary task | Send button unreachable by keyboard; focus trap prevents page exit |
| **High** | Major usability barrier with screen reader | Dialog content not announced; skip link missing; focus not moved into drawer |
| **Medium** | Annoying but workable: extra steps needed, awkward announcements | Nested live regions causing redundant speech; heading level skip |
| **Low** | Minor polish issue, doesn't significantly block use | Slightly low placeholder contrast; non-ideal reading order |
| **Info** | Observation, not a violation | Could improve: alternative label wording suggestion |

**Rule of thumb:** If you cannot complete a task with the screen reader, it's at least **High**. If you can but it's confusing or verbose, it's **Medium**.

---

## 9. When to File Follow-Up Beads Issues

File a new child beads issue for **every FAIL** of Medium severity or above using:

```bash
bd create --parent muse-1rq --title="a11y: {specific issue}" --description="WCAG SC {ref}: {description of problem}

Found during screen-reader audit (muse-1rq).
Screen reader: {VoiceOver/NVDA/...}
Browser: {Safari/Chrome/Firefox/...}

Steps to reproduce:
1. {step}
2. {step}
3. {step}

Expected: {what should happen}
Actual: {what actually happens}

Severity: {Critical/High/Medium}" --type=bug --priority={0-4} --labels=a11y,wcag
```

Use the priority scale from `bd prime`: P0/P1 for Critical, P2 for High, P3 for Medium unless the coordinator sets a different priority. Prefer `--parent muse-1rq` so findings are grouped under the audit. Do **not** add dependency edges unless the coordinator explicitly wants a bug to block the audit; if blocking is required, the direction is `bd dep add muse-1rq {new-issue}` (the audit depends on the bug), not the reverse.

For Low severity items, either file a bug or add to a tracking issue. Use judgment.

Do **not** close `muse-1rq` until all Critical/High issues found are filed, the overall audit record is complete, and the coordinator/human accepts the screen-reader results.

---

## 10. Responsive / Mobile Checks

If a mobile viewport or OS-level zoom is feasible with the screen reader, verify the fixes from `muse-1rq.5` did not regress:

### Narrow Viewport (320–390 px CSS width)

- [ ] All controls reachable at 320 px width (WCAG 1.4.10 Reflow)
- [ ] Sidebar/rail controls have alternative access (hamburger menu, expandable)
- [ ] Composer textarea is usable at narrow widths
- [ ] Send button is not hidden off-screen

### 200% Zoom (WCAG 1.4.4 Resize Text)

- [ ] No horizontal scrolling required at 200% zoom
- [ ] Text does not clip or overflow containers
- [ ] Composer and send button remain visible
- [ ] Screen reader navigation still works (content not reflowed off-screen)

### Mobile Screen Reader

If testing on iOS (VoiceOver on iPhone/iPad):

- [ ] Touch exploration reaches all controls
- [ ] Rotor navigation (headings, links, form controls) works
- [ ] Live region announcements work on VoiceOver on iOS / Safari
- [ ] Double-tap activates controls correctly

---

## Audit Checklist Completion

**This section must be filled before considering the audit complete.**

- [ ] All checks in §4 (Keyboard Baseline) executed with screen reader off
- [ ] All checks in §6.1–6.10 executed with at least one screen reader
- [ ] Pass/fail table (§7) fully filled
- [ ] All FAILs of Medium+ severity filed as beads issues (§9)
- [ ] Severity ratings applied consistently (§8)
- [ ] This checklist document was used as the audit runbook
- [ ] `muse-1rq` issue updated with audit summary and a link to this checklist
- [ ] **`muse-1rq` is NOT closed** — it remains IN_PROGRESS until screen-reader testing results are reviewed and accepted

---

*This checklist was prepared under `muse-ur4`. The actual audit is tracked under `muse-1rq`. See the [WCAG 2.1 AA audit report](./liveview-wcag-2.1-aa-2026-05-06.md) for structural ARIA findings.*
