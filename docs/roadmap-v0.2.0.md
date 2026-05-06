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
