# PR10a — Docs/roadmap wording cleanup (tracking + acceptance)

- **Coordinator:** `planning-agent-1a6824`
- **Lane agent:** `light-puppy-f9588e` (Light Puppy)
- **Bead:** `muse-bzi`
- **Branch:** `pr10a/lane01-tracking-acceptance`
- **Baseline:** `origin/main`
- **Status:** Tracking + acceptance definition. Do NOT merge to main.
- **Date:** 2026-05-05

## 1) Objective

Create a tracking plan and acceptance criteria for **docs/roadmap wording cleanup after PR09**. PR09 (Approval Gate) and PR10 (Plan management/history commands) shipped lifecycle-only, non-executing plan approval. Several docs contain wording that reads as if execution-gated behavior (Coding Muse handoff, patch apply, shell, network, writes) is already active.

This is a **non-code** acceptance/tracking lane. No code edits, no broad docs rewrites — just a plan for what needs to be cleaned up and how to validate.

---

## 2) Known stale wording findings (from final PR09 QA)

### A. PLAN.md:76 — "Coding Muse will prepare a patch"

**File:** `PLAN.md`
**Lines:** ~73–80 (second product experience example block)

```text
muse> approve plan

Muse Conductor:
Plan approved. Coding Muse will prepare a patch.

Coding Muse:
I found the command handler and test files. Here is the proposed diff.

Apply this patch? [y/N]
```

**Problem:** This example reads as current behavior. Approval in PR09/PR10 is lifecycle-only and non-executing — it does not hand off to Coding Muse, propose patches, or apply patches. The example describes a future post-implementation-gate experience (PR17/PR18+).

**What should be clarified:** The example should be labelled as a future/roadmap product experience, or replaced with an example that reflects current lifecycle-only behavior, with a note that Coding Muse handoff, patch propose, and patch apply are future roadmap gates.

---

### B. docs/architecture.md:1095 — `lib/muse.ex` overclaims

**File:** `docs/architecture.md`
**Line:** 1095 (Module Map → Public API section)

```text
lib/muse.ex                  Public API. Delegates submit/resume/approve to SessionServer.
```

**Problem:** `lib/muse.ex` only defines `Muse.submit/2`. There is no `resume` or `approve` function in that module. The module map should accurately reflect the current public API surface.

**What should be clarified:** The description should say `submit/2` only, or be expanded to note which functions actually exist vs. roadmap. The `resume` and `approve` delegation claims are stale or refer to router-level dispatch, not the `Muse` module itself.

---

### C. General risk: docs implying `/approve plan` starts implementation

Several docs accurately include disclaimers that PR09 is lifecycle-only and non-executing (e.g., `docs/security.md:273`, `docs/prompts.md:48`, `docs/architecture.md:949`), but the risk remains that:

- A casual reader sees PLAN.md:76 and assumes the product experience is already built.
- A new contributor could interpret the module map at architecture.md:1095 as implying `Muse.approve/2` exists.
- Any doc that shows the `/approve plan` UX without clear "roadmap / not yet implemented" labelling could confuse.

**Target safeguard:** All `/approve plan` UX examples in docs that include Coding Muse handoff, patch propose, patch apply, shell execution, network calls, or file writes should be clearly marked as **future/roadmap** behavior, not current PR09/PR10.

---

## 3) Target docs for review

| Doc | Sections of concern | Risk |
|-----|-------------------|------|
| `PLAN.md` | Line 73–80 (second product experience) | Implies execution handoff is live |
| `docs/architecture.md` | Line 1095 (module map), lines 2171–2200 (Coding Muse UX example), lines 2293–2319 (approval UX) | Overclaims API surface; UX examples may imply execution |
| `docs/prompts.md` | Lines 98, 125, 304–337 (Coding Muse profile + prompt) | Profile description says "implements approved plans" — accurate as roadmap but could be clearer that handoff is gated |
| `docs/security.md` | Lines 241, 273 | Already has good disclaimers — verify consistency |
| `docs/testing.md` | Lines 123–132, 150, 216–218 | Verify no implication that `/approve plan` triggers execution |
| `docs/provider-roadmap.md` | Lines 53, 76–77 | Mostly accurate (roadmap-labelled) — verify consistency |

---

## 4) Acceptance checklist (for PR10a cleanup itself)

- [ ] **A1:** `plans/pr10a-doc-roadmap-cleanup.md` exists with objective, known findings, target docs, non-goals, validation plan.
- [ ] **A2:** At minimum, the three known stale items above (PLAN.md:76, architecture.md:1095, general risk of implied execution handoff) are documented with file:line references.
- [ ] **A3:** The 6 target docs are identified with specific sections of concern.
- [ ] **A4:** Non-goals section documents what is explicitly out of scope.
- [ ] **A5:** Validation plan documents how cleanup will be verified (`git diff --check`, manual review of each target line, no code changes).
- [ ] **A6:** Integration checklist covers commit/push to branch, no merge to main.
- [ ] **A7:** Bead (`muse-bzi`) is OPEN with dependency on `muse-1ki.1.13` (PR09).
- [ ] **A8:** Branch `pr10a/lane01-tracking-acceptance` is pushed to remote.

---

## 5) Non-goals

The following are **explicitly out of scope** for PR10a (this plan doc and the tracking lane):

1. **No code edits.** No changes to `lib/`, `test/`, or any `.ex`/`.exs` files.
2. **No broad docs rewrites.** Targeted edits only — each change must be justified by a specific stale-wording finding.
3. **No implementation of Coding Muse handoff, patch propose, patch apply, shell/network gates, or any other execution workflow.** Those are PR17/PR18/PR19/PR24 scope.
4. **No full doc audit.** Only the 6 target docs listed above, focused on the known stale items.
5. **No merge to `main`.** This branch exists for tracking only.
6. **No changes to beads beyond the issue created here.** The bead `muse-bzi` tracks this cleanup; it is not a general roadmap tracker.

---

## 6) Validation plan

| Step | Check | Method |
|------|-------|--------|
| V1 | No whitespace errors | `git diff --check` |
| V2 | No code files changed | `git diff --stat` — only `plans/pr10a-doc-roadmap-cleanup.md` and optionally `.beads/` files |
| V3 | Bead `muse-bzi` exists and is OPEN | `bd show muse-bzi` |
| V4 | Branch is on `pr10a/lane01-tracking-acceptance` | `git branch --show-current` |
| V5 | Dependency on PR09 is set | `bd show muse-bzi` shows depends-on `muse-1ki.1.13` |
| V6 | All three known findings documented | Manual review of sections 2A/2B/2C |
| V7 | Remote branch pushed | `git push --dry-run` or `git log origin/pr10a/lane01-tracking-acceptance..HEAD` |

---

## 7) Integration checklist

- [ ] 1. Branch `pr10a/lane01-tracking-acceptance` created from `origin/main`.
- [ ] 2. Bead `muse-bzi` created and OPEN (not closed).
- [ ] 3. `plans/pr10a-doc-roadmap-cleanup.md` committed to branch.
- [ ] 4. `git diff --check` clean.
- [ ] 5. Only changed files: `plans/pr10a-doc-roadmap-cleanup.md` (new), plus any `.beads/` changes from bead create.
- [ ] 6. Branch pushed to remote.
- [ ] 7. Bead status: OPEN, claimed, on branch `pr10a/lane01-tracking-acceptance`.
- [ ] 8. No merge to main.
- [ ] 9. Final report generated.
