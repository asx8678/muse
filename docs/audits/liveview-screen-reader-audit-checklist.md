# LiveView Screen-Reader Audit Checklist

> **Audit Issue:** [muse-1rq](../beads-db/issues/muse-1rq.md)
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
- [ ] Latest stable version of **Google Chrome** or **Mozilla Firefox** (see matrix below)
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
| **VoiceOver** | macOS 14+ | Safari          | Native integration; required for bleed-through testing |
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

> Alternatively, use `./script/liveview-browser-smoke` which auto-starts on port 4101.  
> However, for manual screen-reader work, a persistent server (above) is preferred.

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
- [ ] `Tab` order is logical: skip link → composer → send button → context/sidebar controls → status card → (drawer trigger / other)
- [ ] No **keyboard traps**: You can `Tab` through the entire page without getting stuck
- [ ] `Shift+Tab` reverses navigation correctly
- [ ] All interactive elements are reachable via keyboard alone

### Interactive Elements

- [ ] **Chat composer** (`<textarea>`): receives focus, typing works, Enter submits (or Cmd+Enter / Ctrl+Enter depending on config)
- [ ] **Send button**: reachable and activatable via `Enter` / `Space`
- [ ] **Context sidebar collapse/expand**: reachable and toggles state
- [ ] **Diagnostics drawer trigger**: reachable; `Enter`/`Space` opens drawer
- [ ] **Diagnostics drawer close/back**: reachable while drawer is open; `Escape` closes drawer
- [ ] **Toast dismiss button**: reachable (if not auto-dismissed) and activatable
- [ ] **Session status card**: focusable elements within (if any) are reachable
- [ ] **Patch proposal panel** (when visible): accept/reject buttons reachable and activatable

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
- [ ] Chat panel is a `region` with an `aria-label` like "Chat conversation"
- [ ] Context / sidebar is `role="complementary"` with an `aria-label` like "Workspace context"
- [ ] Toast container is `role="status"` with `aria-live="polite"`
- [ ] Session status card is `role="region"` or within a landmark
- [ ] Diagnostics drawer (when open) has `role="dialog"` with `aria-label` / `aria-labelledby`
- [ ] Patch proposal panel (when visible) has `role="region"` with `aria-label`
- [ ] No duplicate landmark roles caused by wrapping/inner elements (see finding #2 in audit report)
- [ ] VoiceOver Rotor → Landmarks lists all distinct landmarks clearly
- [ ] NVDA: `D` navigation cycles through landmarks in a logical order

**Expected landmarks (VoiceOver Rotor, NVDA `D`):**
1. "banner" or site header (if any)
2. "main" — the primary content region
3. "Chat conversation" region (or inside main)
4. "Workspace context" complementary
5. "Status" live region for toasts
6. "Session Status" region (or within complementary)
7. "Diagnostics dialog" (when open)

### 6.3 Chat Composer (WCAG 1.3.1, 2.4.6, 4.1.2)

- [ ] `<textarea>` has an associated `<label>` or `aria-label`
- [ ] Label clearly describes purpose, e.g., "Message input" or "Chat message"
- [ ] Placeholder text provides additional hint (e.g., "Type a message… /help for commands")
- [ ] `role="form"` on the composer form element
- [ ] Send button has an accessible name (e.g., "Send" or "Send message")
- [ ] Screen reader announces label + role + state when focused
- [ ] Textarea placeholder contrast meets AA (≥4.5:1) — existing finding #6

**Expected announcements (VoiceOver focus on textarea):**
- "Message input, text area, insert text for chat, /help for commands"
- "Enter text to send to Muse"

**Expected announcements (NVDA browse mode on textarea):**
- "Message input, edit, /help for commands"
- Form landmark is navigable

### 6.4 Message Log / Live Region (WCAG 4.1.2, 4.1.3)

- [ ] Message container has `role="log"` with `aria-live="polite"` and `aria-label="Chat conversation"`
- [ ] New messages are announced automatically (or via `aria-live` region `polite` updates)
- [ ] Announcements do not interrupt current focus/speech (i.e., use `polite` not `assertive`)
- [ ] No nested `role="status"` inside `role="log"` (see finding #4)
- [ ] Each message has clear accessible name/label if interactive
- [ ] With screen reader: type a message, send it → the message is announced without focus being moved
- [ ] Message timestamps (if present) are not overly verbose

**Expected behavior:**
- VoiceOver: "You said: [message text]" announced as live region update
- NVDA: "[message text]" announced while remaining in browse mode

### 6.5 Context / Sidebar Controls (WCAG 1.3.2, 2.4.3)

- [ ] Sidebar toggle/collapse button has accessible name: "Collapse sidebar" / "Expand sidebar"
- [ ] State is communicated: `aria-expanded="true|false"`
- [ ] Sidebar content navigable when expanded
- [ ] With screen reader: navigate to toggle → hear "Workspace context, complementary, [heading/text]" → activate toggle → sidebar collapse is announced
- [ ] When sidebar is collapsed/hidden, its content is not in tab order
- [ ] Sidebar controls are not announced as "dimmed" or "unavailable" unless visually disabled

**Expected announcements (VoiceOver Rotor → Landmarks → "Workspace context"):**
- "Workspace context, complementary"
- Inside: "Workspace, heading level 2"
- "Session status, region"

### 6.6 Diagnostics Drawer (WCAG 2.4.3, 2.4.7, 4.1.2)

> Existing finding #1 (HIGH): Drawer focus management is broken. Test carefully.

- [ ] Drawer trigger button has accessible name: "Open diagnostics" or "Diagnostics"
- [ ] When drawer opens, focus moves **into** the drawer (NOT remaining on trigger)
- [ ] Focus is trapped within drawer while open (Tab cycles inside, not behind)
- [ ] Background content is `aria-hidden="true"` and/or `inert` while drawer is open
- [ ] Drawer close button has accessible name: "Close diagnostics" or "Close"
- [ ] `Escape` key closes the drawer
- [ ] When drawer closes, focus returns to the trigger
- [ ] Drawer has `role="dialog"` with `aria-modal="true"` (if modal) or appropriate landmark
- [ ] With screen reader: activate trigger → hear announcement like "Diagnostics dialog, currently open" → navigate inside → all drawer content is readable
- [ ] NVDA: browse mode should work inside drawer; focus mode for interactive elements
- [ ] Announcement of live regions inside drawer should not bleed to background

**Expected announcements (VoiceOver):**
- Trigger: "Diagnostics, button"
- On open: "Diagnostics dialog, [content summary], you are currently in a dialog"
- Close button: "Close, button"

### 6.7 Patch Proposal Panel (WCAG 2.4.3, 4.1.2) — Visible only when a patch is proposed

- [ ] Panel has clear accessible role: `role="region"` with `aria-label="Patch proposal"`
- [ ] Approve and Reject buttons have distinct accessible names
- [ ] Keyboard navigation reaches panel in logical order (after the message prompting it)
- [ ] With screen reader: panel is discoverable through landmark navigation
- [ ] Status is clear: "Awaiting approval" or similar

**Expected announcements:**
- "Patch proposal, region"
- "Approve, button" / "Reject, button"

### 6.8 Session Status Card (WCAG 1.3.1, 4.1.2)

- [ ] Card is within a landmark with label (e.g., "Session status")
- [ ] Session status text ("active", "idle", etc.) is readable by screen reader
- [ ] If status changes dynamically, consider `aria-live="polite"` on the status region
- [ ] Workspace name and session ID (if displayed) are descriptive

**Expected announcements:**
- "Session status, region"
- "Status: active"
- "Workspace: [name]"

### 6.9 Toast / Error Announcements (WCAG 4.1.3, 4.1.2)

- [ ] Toast container is `role="status"` with `aria-live="polite"`
- [ ] Toasts are announced without moving focus
- [ ] Toast content is concise and meaningful
- [ ] Dismissible toasts have a close button with accessible name
- [ ] Error toasts do not use `aria-live="assertive"` unless truly urgent
- [ ] With screen reader: trigger a toast → hear announcement like "Error: [message]" while remaining in current context
- [ ] Multiple simultaneous toasts: announcements are not overly verbose (deduplication or summarization if needed)

**Expected announcements:**
- "Error: Could not connect to provider. Please try again."
- "Close notification, button" (if dismissible)

### 6.10 Skip-Link Rendering (WCAG 2.4.1)

> Existing finding #3: skip link may not be rendered. Verify status.

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
3. Update muse-1rq status
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

File a new beads issue for **every FAIL** of Medium severity or above using:

```bash
bd create --title="a11y: {specific issue}" --description="WCAG SC {ref}: {description of problem}

Found during screen-reader audit (muse-1rq).
Screen reader: {VoiceOver/NVDA/...}
Browser: {Safari/Chrome/Firefox/...}

Steps to reproduce:
1. {step}
2. {step}
3. {step}

Expected: {what should happen}
Actual: {what actually happens}

Severity: {Critical/High/Medium}" --type=bug --priority={0-4}
```

Then note the dependency:

```bash
bd dep add {new-issue} muse-1rq
```

For Low severity items, either file a bug or add to a tracking issue. Use judgment.

Do **not** close `muse-1rq` until all Critical/High issues found are filed, and the overall audit record is complete.

---

## 10. Responsive / Mobile Checks

If a mobile viewport or OS-level zoom is feasible with the screen reader:

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

*This checklist was prepared under [muse-ur4](beads-issues/../beads-db/issues/muse-ur4.md). The actual audit is tracked under [muse-1rq](beads-issues/../beads-db/issues/muse-1rq.md). See the [WCAG 2.1 AA audit report](./liveview-wcag-2.1-aa-2026-05-06.md) for structural ARIA findings.*
