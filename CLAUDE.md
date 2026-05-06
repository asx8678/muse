# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
# Fetch dependencies
mix deps.get

# Run test suite (offline by default, no API keys needed)
mix test

# Run a specific test file
mix test test/muse/command_dispatcher_test.exs

# Check formatting
mix format --check-formatted

# Compile with strict warnings
mix compile --warnings-as-errors

# Start Muse (REPL + web)
mix muse
```

## Architecture Overview

A single `Muse.submit/2` API feeds into a GenServer event log (`Muse.State`)
broadcast via PubSub to CLI REPL and LiveView web interfaces. The Conductor
orchestrates turns: it selects a Muse profile (Planning, Coding, Memory,
Restoration), assembles a layered prompt (core invariants → mode policy →
Muse profile → workspace rules → memory → plan state → history), runs the
LLM provider, and manages the tool-call loop (read-only tools only in PR09;
write/shell/network tools blocked).

**Muse profiles:**
- **Planning Muse** — Reads the repo, produces structured plans for user
  approval. Tools: `list_files`, `read_file`, `repo_search`, `git_status`,
  `git_diff_readonly`, `ask_user_question`.
- **Coding Muse** — Proposes patches after plan approval (PR17).
- **Memory Muse** (PR21) — Compacts session history into durable memory.
- **Restoration Muse** (PR21) — Recovers state from checkpoints and memory.

**Approval lifecycle:** `/approve plan` / `/reject plan` (lifecycle-only),
`/approve patch` / `/reject patch` (PR17, lifecycle-only). Patch apply with
checkpoint/rollback is future scope (PR18).

**Provider model:** Fake provider (offline, deterministic) is the default.
OpenAI-compatible provider is available via env vars. Auth handled by
`Muse.Auth` layer (ApiKey, BearerCommand, CodexCache). `/auth status` shows
redacted config.

See `docs/README.md` for full documentation index.

## Conventions & Patterns

- **Muse-first terminology**: Use "Muse Plan" not "Agent Plan", "Planning
  Muse" not "Planning Agent", "Active Muse" not "Active Agent", "Patch
  Proposal" not "Bot Patch". See `docs/testing.md §8` for grep check.
- **Tabs over spaces** in Elixir code (`.ex`, `.exs`).
- **Single-API entry point**: All user input flows through `Muse.submit/2`.
- **Offline-first testing**: `mix test` never calls live providers.
  External-dependent tests use `@tag :external`.
- **Everything is an event**: State changes, tool calls, approvals, and errors
  are recorded as `Muse.Event` structs broadcast via PubSub.
- **Security at the runtime level**: Path safety, secret denylist, and tool
  blocking are enforced by `Muse.Workspace.safe_resolve!/2` and
  `Muse.Tool.Runner`, not by prompt text.
