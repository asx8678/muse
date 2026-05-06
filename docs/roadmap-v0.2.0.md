# Muse Runtime v0.2.0 Roadmap

> **Objective:** Post-v0 hardening, polish, and foundation after the safe v0.1.0 release.
> **Companion docs:** [README](../README.md) · [PLAN.md](../PLAN.md) · [Architecture](architecture.md) · [Security](security.md) · [Testing](testing.md) · [Providers](provider-roadmap.md)

## Safety Invariants (Never Relaxed)

- **Fake provider remains the default test provider** — no real provider calls in `mix test`
- **Remote execution remains denied by default** — Runner.Policy denies `:remote`, `:ssh`, string targets
- **Secrets never appear** in prompts, logs, events, or provider debug output
- **All approval gates remain enforced** — no bypass of plan/patch/approval gating
- **Workspace/file safety is never weakened** — symlink awareness, path traversal blocking, secret redaction

## Phases

| # | Phase | Epic | Priority | Status | Dependencies |
|---|-------|------|----------|--------|-------------|
| 1 | Release/distribution and CI polish | `muse-6jz` | P1 | Open | v0.2.0 epic |
| 2 | LiveView/TUI/CLI UX and browser QA hardening | `muse-w23` | P2 | Open | v0.2.0 epic |
| 3 | Provider/model routing UX and resilience | `muse-3bh` | P2 | Open | v0.2.0 epic |
| 4 | Persistent memory/session and multi-workspace foundations | `muse-9sr` | P2 | Open | v0.2.0 epic |
| 5 | Remote execution approval design spike | `muse-pr5` | P3 | Open | v0.2.0 epic |
| 6 | Observability, docs, and release readiness | `muse-4qh` | P2 | Open | Phases 1–4 |

### Phase 1 — Release/distribution and CI polish
Package artifacts with checksums, install docs for all platforms, CI/CD release automation. No secrets in CI.

Delivered:
- `--version`/`-v` boot flag prints `muse <version>` and exits 0 without starting runtime children
- `script/build-release-artifacts` builds escript + Mix release tarball, copies to `dist/`, generates SHA256SUMS
- `.github/workflows/release.yml` — triggered on `v*.*.*` tags or `workflow_dispatch`, builds artifacts, uploads to GitHub Release using least-privilege `contents: write` permission
- `docs/install.md` covers source, escript download (Linux/macOS), Mix release (TUI), Homebrew planned, WSL2 for Windows, and upgrade pathways
- Release pipeline is secret-minimal: uses default `GITHUB_TOKEN`, no API keys or provider secrets

### Phase 2 — LiveView/TUI/CLI UX and browser QA hardening
Browser QA suite (QA Kitten/Playwright), command discoverability, accessibility review, session panel polish.

Delivered:
- **CLI help**: `--help` / `-h` / `help` prints usage with all flags and key interface commands
- **CLI version**: `--version` / `-v` prints `muse <version>` and exits without starting runtime
- **Help documents version flags**: `--help` output explicitly lists `--version, -v` option
- **Accessibility hardening**:
  - Chat panel has `role="region"`, `aria-label`, `role="log"`, `aria-live="polite"`
  - Chat composer has visible label, concise placeholder text
  - Prompt chips have descriptive `aria-label` attributes
  - Toast container has `role="status"`, `aria-live`, `aria-label`
  - Context panel has `role="complementary"` and session status uses `role="status"` and `role="alert"`
  - Screen-reader-only CSS utility class (`.sr-only`) added
- **Session panel polish**:
  - Session status card shows status, active Muse, plan, patch, turn with clear labels
  - ARIA labels indicate pending patches with `role="alert"` for visibility
- **TUI help**:
  - Help popup (`?` from MAIN focus) shows complete key reference including tab shortcuts
  - Settings tab displays key bindings, workspace, web URL, session status
  - Footer shows context-sensitive hints for INPUT/MAIN modes
- **Discoverability tests**:
  - LiveView tests for accessibility markers and command hints
  - TUI tests for help popup, settings tab key bindings, `/help` command output
  - CLI tests for `--help`, `-h`, `--version`, `-v` handling
- **Docs updated**: README documents `--version` and `-v`, escript usage notes

Not yet implemented (deferred to follow-up issues):
- Full WCAG 2.1 AA audit (manual testing required)

Delivered (follow-up `muse-3pq`):
- **Real-browser LiveView smoke with Playwright**: `script/liveview-browser-smoke-playwright` starts Muse with fake provider on a non-default port, waits for HTTP readiness, runs HTTP smoke assertions, then runs Playwright headless browser tests. Browser checks: no console.error/pageerror/unhandledrejection, LiveView WebSocket connects, command/help discoverability in DOM, keyboard Tab reaches message composer input, session/context panel ARIA markers, no visible secrets/tokens in page text, ARIA landmarks and live regions. Prerequisites: `npm install && npm run browser:install`. Default `mix test` unchanged. See `docs/testing.md` §11.7.

Delivered (follow-up `muse-po4`):
- **Executable LiveView browser smoke**: `script/liveview-browser-smoke` starts Muse with fake provider on a non-default port, waits for HTTP readiness, and runs `mix muse.smoke` assertions against the running server. Checks: page load, accessibility markers, command discoverability, session/context panel, no visible secrets, keyboard focus indicators. Non-interactive, suitable for CI. Default `mix test` unchanged. Real-browser console-error detection remains opt-in Playwright (see `docs/testing.md` §11).

### Phase 3 — Provider/model routing UX and resilience
Provider health/status commands, actionable error messages, safe retry/backoff, model listing/config validation. External tests opt-in only; fake remains default.

### Phase 4 — Persistent memory/session and multi-workspace foundations
Durable local session store, retention policy, export/import, trust boundaries between workspaces, secret-safe migration, workspace profiles/switching.

### Phase 5 — Remote execution approval design spike
**Design only.** Threat model, approval model, audit events, runner contract extension. Remote execution remains denied by default throughout v0.2.0.

### Phase 6 — Observability, docs, and release readiness
Telemetry/event export, troubleshooting docs, docs refresh, release readiness checklist: tag v0.2.0, release notes, verify all gates.

## Non-Goals

- No new Muse roles or specialist profiles
- No remote execution implementation (design spike only)
- No cloud sync or SaaS infrastructure
- No major UI redesign
- No breaking changes to public API (`Muse.submit/2`)
- No MCP server/ecosystem integration
- No evaluation harness or cost tracking
- No autonomous shell loops or browser automation

## Quality Gates

Before v0.2.0 release:
- [ ] All phase acceptance criteria met
- [ ] `mix test` passes (fake provider only)
- [ ] `mix format --check-formatted` passes
- [ ] `mix compile --warnings-as-errors` passes
- [ ] Browser QA suite passes
- [ ] Install pathway verified
- [ ] No secrets leaked anywhere in output/logs/export
- [ ] Remote execution still denied by default

## Release Criteria

- [ ] Tag v0.2.0 (annotated/signed)
- [ ] Release notes published on GitHub
- [ ] Escript artifact with SHA256 checksum published
- [ ] Install docs updated for new release
- [ ] All docs refreshed to reflect v0.2.0 changes

## Next Issue to Start

Begin with **Phase 1** (`muse-6jz`): Release/distribution and CI polish — package artifacts, install docs, CI/CD automation.
