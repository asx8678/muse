# LiveView WCAG 2.1 AA Accessibility Audit Report

| Field | Value |
|---|---|
| **Issue** | muse-1rq |
| **Coordinator** | planning-agent-b5a7cf |
| **Audited URL** | http://localhost:4102 |
| **Date** | 2026-05-06 |
| **Auditor** | QA Kitten (automated browser/ARIA tooling) |
| **Verdict** | **PASS WITH CONCERNS** |

## Limitations

This is a point-in-time structural audit from 2026-05-06. Several recommended follow-up bugs were later closed under `muse-1rq`, but this report remains historical evidence of what was found on that date. Verify the current LiveView markup and behavior with the screen-reader checklist before treating any finding as still open or fully resolved.

This audit was performed using browser DevTools, ARIA inspection tooling, keyboard navigation, and contrast measurement. **No actual OS-level screen reader (VoiceOver, NVDA, JAWS, Narrator) was used.** ARIA markup and keyboard patterns were verified structurally, but the lived assistive-technology experience — including announcement order, interruption behavior, and virtual cursor navigation — remains unvalidated. A screen-reader audit is still required per muse-1rq acceptance criteria.

> **📋 Screen-reader audit checklist available at** \
> [`docs/audits/liveview-screen-reader-audit-checklist.md`](./liveview-screen-reader-audit-checklist.md) \
> A human-executable runbook with VoiceOver/NVDA commands, per-area checks, and a pass/fail recording template.

## Browser & Viewports

- Chromium (Playwright-headed) — desktop viewport (1280×720 default)
- Viewports spot-checked: 1280×720, 390×844 (mobile), 320×568 (narrow)

## Findings

| # | Severity | WCAG Criterion | Finding | Evidence | Remediation |
|---|----------|---------------|---------|----------|-------------|
| 1 | **High** | 2.4.3 Focus Order (A), 2.4.7 Focus Visible (AA) | Diagnostics drawer focus management broken | Overlay opens but focus remains on trigger/background; obscured controls stay in tab order before drawer controls | Decide modal vs non-modal drawer. If modal: move focus into drawer on open, trap focus within, restore focus on close, make background inert (`aria-hidden` + `inert`). If non-modal: ensure drawer controls appear in correct DOM order, no obscured controls in between. Support Escape to close. |
| 2 | **Medium** | 1.3.1 Info & Relationships (A), 2.4.1 Bypass Blocks (A) | Duplicate `<main>` landmarks | Outer `#muse-shell` and inner `.main-layout` both exposed as `main` landmark | Ensure exactly one `<main>` landmark per page. Rename one to `<section aria-labelledby=…>` or similar. |
| 3 | **Medium** | 2.4.1 Bypass Blocks (A) | No rendered skip/bypass link | CSS class exists but no visible or sr-only skip link rendered to conversation/composer | Render a skip link as first focusable element: "Skip to main content" → `#conversation` or composer. |
| 4 | **Medium** | 4.1.2 Name/Role/Value (A), 1.3.1 Info & Relationships (A) | Over-broad / nested live regions | `role=log` contains `role=status`; diagnostics drawer entire content has `aria-live=polite`; nested announcements may cause redundant or suppressed speech | Use concise, targeted live regions. Avoid nesting `role=status` inside `role=log`. Scope `aria-live` to specific announcement spans rather than entire drawer. Verify toast nesting is not inside other live regions. |
| 5 | **Medium** | 1.4.10 Reflow (AA), 1.4.4 Resize Text (AA) | Narrow/mobile composer reflow concerns | At 320/390 px the composer area is crowded; sidebar/rail controls are hidden without alternative access; 200% zoom not validated | Ensure all controls reachable at 320 px and 200% zoom. Provide alternative access to hidden sidebar/rail controls (hamburger, expandable, etc.). Validate 200% zoom. |
| 6 | **Low-Medium** | 1.4.3 Contrast (AA) | Textarea placeholder contrast ~4.38:1 | Measured via DevTools color picker against background; target ≥ 4.5:1 for AA | Darken placeholder color or lighten background to achieve ≥ 4.5:1 ratio. |
| 7 | **Low** | 1.3.2 Meaningful Sequence (A) | Heading/landmark reading order could be improved | Some heading levels skip or landmarks are not in optimal reading order for screen readers | Ensure heading hierarchy is sequential (h1→h2→h3) and landmark order matches visual/content order. |

## What Passed

- ✅ Desktop visible controls reachable in computed tab order
- ✅ Focus indicators visible and distinguishable
- ✅ Control accessible names mostly good
- ✅ No visible secrets or sensitive data in DOM text
- ✅ Visible text mostly passed contrast checks
- ✅ Rail emoji buttons and close controls had accessible names
- ✅ Keyboard-only navigation possible for primary flows (excluding drawer focus issue)

## Recommended Follow-Up Issues

| Priority | Title | Follows Finding |
|----------|-------|----------------|
| P2 (High) | Accessibility: fix diagnostics drawer focus management | #1 |
| P2 | Accessibility: fix duplicate main landmarks and add skip links | #2, #3 |
| P3 | Accessibility: simplify LiveView live-region semantics | #4 |
| P3 | Accessibility: improve textarea placeholder contrast | #6 |
| P3 | Accessibility: improve narrow/mobile composer reflow and sidebar access | #5 |
| P1 | Accessibility: perform OS screen-reader audit (VoiceOver/NVDA) | Limitation |

## Artifacts & Cleanup

- QA server (PID 52258, log `/tmp/muse-smoke-4102.log`) stopped and log removed.
- No persistent artifacts remain from this audit.
