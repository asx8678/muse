# Muse Runtime — Documentation

Documentation directory for the Muse Universal Runtime. Start with [../README.md](../README.md) for quick-start/onboarding, or [../PLAN.md](../PLAN.md) for the executive roadmap.

## Document index

| Document | Purpose |
|---|---|
| [architecture.md](architecture.md) | Runtime architecture, process model, data models, module map, tools, Conductor, CLI/TUI/LiveView, telemetry, approvals, patch/checkpoint/rollback. |
| [prompts.md](prompts.md) | Muse profiles, role prompts, core runtime prompt, and project-rules loading behavior. |
| [provider-roadmap.md](provider-roadmap.md) | Fake-provider-first provider roadmap, provider configuration, OpenAI-compatible mappings, transports, and auth. |
| [testing.md](testing.md) | Offline-first testing strategy, provider contracts, fixtures, integration/safety/product-language tests, first fake-provider demo. |
| [security.md](security.md) | MVP security checklist, workspace safety, secret denylist, redaction, approval/security rules. |
| [phase4-persistence.md](phase4-persistence.md) | Phase 4 session persistence, export/import, retention, memory safety, workspace profile isolation. |

## Recommended reading paths

### 🆕 New users

1. [../README.md](../README.md) — Quick start, run modes, provider setup
2. [architecture.md](architecture.md) — High-level architecture §1–§4
3. [provider-roadmap.md](provider-roadmap.md) — Provider setup deep-dive §3–§5
4. [testing.md](testing.md) — Offline-first testing strategy and demo flow §1, §10

### 🔑 Provider setup

1. [provider-roadmap.md](provider-roadmap.md) — Full provider config reference, env vars, wire mappings, transports
2. [../README.md#provider-configuration](../README.md#provider-configuration) — Quick-start provider env vars
3. [security.md](security.md) — Auth security rules §11, redaction rules §4

### 🛡️ Safety & security reviewers

1. [security.md](security.md) — Full security model: MVP checklist, workspace path policy, secret denylist, redaction, approval lifecycle
2. [phase4-persistence.md](phase4-persistence.md) — Session persistence, memory validation, export/import safety, workspace isolation
3. [architecture.md](architecture.md) — Approval flows §11, tool system §6, plan lifecycle §0
4. [../README.md#safety--approval-model](../README.md#safety--approval-model) — High-level safety overview

### 👩‍💻 Contributors

1. [../README.md#development-workflow](../README.md#development-workflow) — Build, test, format, compile gates
2. [testing.md](testing.md) — Testing strategy, provider contract tests, safety tests
3. [architecture.md](architecture.md) — Module map §4, data models §3, Conductor §7
4. [phase4-persistence.md](phase4-persistence.md) — Session persistence, memory safety, export/import, workspace profiles
5. [prompts.md](prompts.md) — Prompt assembly system, Muse profiles, project rules
6. [../README.md#architecture-overview](../README.md#architecture-overview) — Runtime architecture diagram

### 🗺️ PR roadmap & context

1. [../PLAN.md](../PLAN.md) — Executive summary and full PR roadmap
2. [provider-roadmap.md](provider-roadmap.md) — Provider sequencing (PR03 → PR11–15 → PR23)
3. [architecture.md](architecture.md) — PR09/PR17/PR18/PR19/PR21 boundaries documented inline
4. [security.md](security.md) — MVP checklist and current/future safety gates

## Canonical ownership

| Document | Canonical for |
|---|---|
| [architecture.md](architecture.md) | Runtime process architecture, module map, data models, normalized event types, Conductor behavior, tool system, streaming API, telemetry, approvals, patch/checkpoint/rollback behavior. |
| [prompts.md](prompts.md) | Muse profiles, prompt templates, Muse role behavior, and project-rules loading behavior. |
| [provider-roadmap.md](provider-roadmap.md) | Provider sequencing, fake-provider behavior, provider configuration, OpenAI-compatible wire mapping, transports, and auth roadmap. |
| [testing.md](testing.md) | Testing strategy and acceptance checks. Provider/event assertions reference the canonical normalized event types in architecture.md. |
| [security.md](security.md) | Workspace safety, secret handling, redaction, approval/security rules, and MVP security checklist. |
| [phase4-persistence.md](phase4-persistence.md) | Session persistence, export/import, retention, memory validation, and workspace profile boundaries. |
