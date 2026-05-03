# Muse Runtime Docs

This directory contains the detailed Muse Universal Runtime planning documents. Start with [../PLAN.md](../PLAN.md) for the executive summary.

| Document | Purpose |
|---|---|
| [architecture.md](architecture.md) | Runtime architecture, process model, data models, module map, tools, Conductor, CLI/TUI/LiveView, telemetry, approvals, patch/checkpoint/rollback. |
| [prompts.md](prompts.md) | Muse profiles, role prompts, core runtime prompt, and project-rules loading behavior. |
| [provider-roadmap.md](provider-roadmap.md) | Fake-provider-first provider roadmap, provider configuration, OpenAI-compatible mappings, transports, and auth. |
| [testing.md](testing.md) | Offline-first testing strategy, provider contracts, fixtures, integration/safety/product-language tests, first fake-provider demo. |
| [security.md](security.md) | MVP security checklist, workspace safety, secret denylist, redaction, approval/security rules. |

## Canonical ownership

- **architecture.md** — Runtime process architecture, module map, data models, normalized event types, Conductor behavior, tool system, streaming API, telemetry, approvals, patch/checkpoint/rollback behavior.
- **prompts.md** — Muse profiles, prompt templates, Muse role behavior, and project-rules loading behavior.
- **provider-roadmap.md** — Provider sequencing, fake-provider behavior, provider configuration, OpenAI-compatible wire mapping, transports, and auth roadmap.
- **testing.md** — Testing strategy and acceptance checks. Provider/event assertions reference the canonical normalized event types in architecture.md.
- **security.md** — Workspace safety, secret handling, redaction, approval/security rules, and MVP security checklist.
