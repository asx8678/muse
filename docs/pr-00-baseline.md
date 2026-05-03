# PR 00 — Baseline Verification & Naming Cleanup

> **Parent:** [`PLAN.md`](../PLAN.md) · **PR:** 00 · **Status:** Complete

---

## Baseline Quality Gates

All commands run from project root (`/Users/adam2/projects/muse`).

| # | Command | Exit Code | Result |
|---|---|---|---|
| 1 | `mix format --check-formatted` | 0 | All files formatted |
| 2 | `mix compile --warnings-as-errors` | 0 | Clean compilation, no warnings |
| 3 | `mix test` | 0 | 858 tests, 0 failures |

---

## Product-Language Audit

### User-facing replacements

| Old (visible) | New (visible) | Surfaces |
|---|---|---|
| `Agents` | `Muses` | TUI tab label, LiveView tab label, sidebar rail, sidebar card title |
| `Agent registry` | `Muse registry` | `/muses` command output, LiveView agents panel empty state |
| `Agent runtime` | `Muse runtime` | `/runtime` output, connect/disconnect toasts, button titles, aria-labels, status bar label |
| `Add to next agent turn` | `Add to next Muse turn` | Diagnostics drawer button |
| `Queued for next agent turn` | `Queued for next Muse turn` | Diagnostics drawer disabled button |
| `Muse CLI Coding Agent` | `Muse CLI Coding Muse` | Logo `alt` text |
| `/agents` | `/muses` | Slash-command display and help text |
| `/open agents` | `/open muses` | Slash-command display and help text |
| `Open Agents` | `Open Muses` | Command palette label |
| `Help me connect the agent runtime` | `Help me connect the Muse runtime` | Empty-chat prompt chip |
| `Connect universal agent runtime` / `Register first agent` | Muse-first setup copy | Legacy dev sidebar/setup checklist |
| `coding-agent foundation` | `coding-runtime foundation` | README subtitle and public moduledocs |
| `agent workspace` | `Muse workspace` | README UI section |
| `agent status` | `Muse status` | `/muses` help description |
| `Agent tree and runtime status` | `Muse tree and runtime status` | LiveView agents panel description |
| `Universal agent runtime` | `Muse Runtime` | LiveView runtime card title |
| `Universal agent` | `Muse` | Status bar label |
| `agent actions` | `Muse actions` | Events panel description |
| `manages agents` | `manages Muses` | Events panel description |
| `No agents registered` | `No Muses registered` | LiveView empty state |
| `next agent/development turn` | `next Muse turn` | Moduledocs (SelfHealingIssue, SelfHealingQueue) |
| `until a real agent is wired in` | `until a real coding Muse is wired in` | README current-limitation note |

### Legacy aliases preserved

- `/agents` still parses to `:agents` action (backward-compatible, not shown in help)
- `/open agents` still parses to `:open_agents` action (backward-compatible, not shown in help)

### Internal identifiers kept (not user-facing)

These remain unchanged because they are implementation details, not user-visible labels:

- Module names: `Muse.AgentRegistry`, `Muse.AgentRuntime`
- Data keys: `agent_snapshot`, `agent_runtime`, `agents` (map/list fields)
- CSS classes: `agent-*` (e.g., `agent-runtime-card`, `agent-entry`, `agent-status`)
- Phoenix event names: `connect_agent_runtime`, `disconnect_agent_runtime`, `retry_agent_runtime`, `set_agent_runtime_endpoint`
- PubSub messages: `:muse_agent_registry_updated`, `:muse_agent_runtime_updated`
- Process names: `Muse.AgentRegistry`, `Muse.AgentRuntime`
- Internal tab key: `"agents"` (used as map key in TUI state, LiveView tab routing)
- Backend function names: `safe_agent_*`, `safe_subscribe_agent_*`
- Anti-examples in PLAN.md §5 and docs/testing.md (they list what *not* to use)

---

## Grep Audit Commands

To reproduce the product-language audit:

```bash
# Check for remaining "Agent/agent" in user-facing quoted strings
grep -rn '"[Aa]gent' lib/ test/ README.md | \
  grep -v 'agent_runtime\|agent_snapshot\|agent_registry\|agent_count\|agent_name\|agent_status\|agent_entry\|agent_header\|agent_detail\|agent_progress\|agent_indent\|agent-child\|connect_agent\|disconnect_agent\|retry_agent\|register_agent\|unregister_agent\|update_agent\|AgentRegistry\|AgentRuntime\|\.exs:\|class="agent\|id="agent\|phx-click=".*agent\|for="agent\|name="agent\|Backend.safe_'

# Expected: only internal identifiers remain (tab keys, CSS interpolation, etc.)
```
