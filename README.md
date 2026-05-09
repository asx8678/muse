# Muse

Local Elixir/Phoenix LiveView coding runtime for Muse.

Muse gives you a CLI REPL, TUI, and web interface that all funnel through a
single `Muse.submit/2` API, session runtime, Conductor, tool runner, and LLM
provider layer. It is offline-first with the fake provider by default and can
opt into OpenAI-compatible providers when configured.

> **⚠️ Provider-ready** — `Muse.submit/2` routes through the Conductor which
> delegates to an LLM provider. The fake provider (offline, deterministic) is the
> default. Available providers: `OpenAICompatibleProvider` for OpenAI Chat Completions
> and Responses APIs; `AnthropicProvider` for Anthropic Messages API; OpenRouter and
> Ollama presets via the OpenAI-compatible adapter. Auth/API-key resolution is handled
> by the `Muse.Auth` layer (`Resolver`, `ApiKey`, `BearerCommand`, `CodexCache`,
> `Credential`); use `/auth status` to inspect configuration.

---

## Quick Start

```bash
git clone <repo-url> muse && cd muse
mix deps.get && mix muse
```

You'll see the startup banner, a `muse>` prompt, and (unless you pass
`--no-web`) a web UI at **http://127.0.0.1:4000**.

Type a message at the prompt and press Enter to route it through the session
runtime, Conductor, and default offline fake provider. Type `/quit` to exit.

Run the test suite:

```bash
mix test
```

### Provider configuration

Muse defaults to the offline fake provider and needs no API key:

```bash
MUSE_PROVIDER=fake mix muse
```

Available providers:

| Provider | Env Var | Description |
|---|---|---|
| `fake` | `MUSE_PROVIDER=fake` | Offline, deterministic (default) |
| `openai_compatible` | `MUSE_PROVIDER=openai_compatible` | OpenAI Chat Completions/Responses |
| `openrouter` | `MUSE_PROVIDER=openrouter` | OpenRouter preset |
| `ollama` | `MUSE_PROVIDER=ollama` | Local Ollama (no auth) |
| `anthropic` | `MUSE_PROVIDER=anthropic` | Anthropic Messages API |

The default CLI/LiveView turn path stays on the fake provider unless a non-fake `MUSE_PROVIDER` is set in the environment. When `MUSE_PROVIDER` is set to a non-fake provider (e.g. `openai_compatible`, `openrouter`, `ollama`, `anthropic`), LiveView chat submissions automatically route through the configured provider. In `MIX_ENV=test` and `MIX_ENV=smoke`, the fake provider is always used regardless of environment variables — no network calls are made.

If a non-fake provider is configured but the configuration is invalid (e.g. missing model), an actionable error is shown in the UI instead of a silent fallback to the placeholder response.

For integration code, tests, or lower-level Conductor/SessionServer calls that opt into the real provider, use the environment/app-config contract below and pass the resolved `ProviderConfig` into turn execution; `/auth status` can inspect the same config read-only.

```bash
MUSE_PROVIDER=openai_compatible \
  MUSE_OPENAI_BASE_URL=https://api.openai.com/v1 \
  MUSE_MODEL=gpt-4.1 \
  MUSE_OPENAI_API_KEY=sk-... \
  iex -S mix
```

> The PR13 auth layer (`Muse.Auth`) is implemented: `ApiKey` resolves
> `MUSE_OPENAI_API_KEY` from environment variables; the `Resolver` facade
> dispatches `:api_key`, `:bearer_command`, and `:codex_cache` modes;
> `BearerCommand` executes a configured shell command (with timeout,
> `allow_exec?: false` default, and injectable runner); `CodexCache` reads
> `~/.codex/auth.json` with permission checks; and `/auth status` shows
> read-only redacted status — no shell or Codex reads from `/auth status`.
> The `OpenAICompatibleProvider` injects `Authorization: Bearer …` after building
> the HTTP spec; an explicit `Authorization` header wins and is not overwritten.
>
> The fake provider (default) uses no authentication and requires no env vars.

See [`docs/provider-roadmap.md`](docs/provider-roadmap.md) for the current env/config contract.
Use `/auth status` in the REPL to inspect active auth configuration.

```bash
# Fake provider — no auth, no env vars (default)
MUSE_PROVIDER=fake mix muse

# OpenAI-compatible — auth via MUSE_OPENAI_API_KEY
MUSE_PROVIDER=openai_compatible \
  MUSE_OPENAI_BASE_URL=https://api.openai.com/v1 \
  MUSE_MODEL=gpt-4.1 \
  MUSE_OPENAI_API_KEY=sk-... \
  mix muse

# OpenRouter — access multiple models through one provider
MUSE_PROVIDER=openrouter \
  MUSE_MODEL=anthropic/claude-3.5-sonnet \
  MUSE_OPENROUTER_API_KEY=sk-or-... \
  mix muse

# Ollama — local, no auth required
MUSE_PROVIDER=ollama \
  MUSE_MODEL=llama3.1 \
  mix muse

# Anthropic — Anthropic Messages API
MUSE_PROVIDER=anthropic \
  MUSE_MODEL=claude-sonnet-4-20250514 \
  MUSE_ANTHROPIC_API_KEY=sk-ant-... \
  mix muse

# Per-Muse model pinning via environment
MUSE_PROVIDER=openrouter \
  MUSE_PLANNING_MODEL=anthropic/claude-3-opus \
  MUSE_CODING_MODEL=anthropic/claude-3.5-sonnet \
  MUSE_OPENROUTER_API_KEY=sk-or-... \
  mix muse
```


## Safety & Approval Model

Muse implements a layered safety model that keeps write, shell, and network
actions behind explicit user approval gates. Every execution boundary is
enforced at the runtime level, not at the prompt level.

### Plan lifecycle & approval

1. Planning Muse produces a structured plan with tasks, target files, and risk
   notes.
2. The plan is rendered to the user --- no files are touched, no shell commands
   run, no network calls are made.
3. The user reviews and either `/approve plan` or `/reject plan`.
4. Approval is **content-bound**: the plan’s hash, id, version, session, and
   workspace are validated together. Stale or mismatched approvals are rejected.
5. `/approve plan` records the approval and transitions the session --- it does
   **not** start implementation, write files, or execute code.

### Patch proposal & application

1. After plan approval, Coding Muse can propose patches via `patch_propose`.
2. The diff is displayed to the user; `/approve patch` records the approval
   decision but does **not** modify files by itself.
3. Patch application is a separate explicit step: `/apply patch` applies the
   latest approved patch (or the supplied patch id), creates a Muse Checkpoint
   first, and shows the resulting git diff summary.
4. Rollback is explicit and checkpoint-scoped: `/rollback checkpoint <id>`
   restores the workspace from that checkpoint. The shorter `/rollback` command
   is still reserved for dev hot-reload rollback, not Muse patch rollback.

### Shell & network safety

- Arbitrary shell commands, network calls, and remote execution tools are
  **blocked by default** in the tool registry.
- The tool runner (`Muse.Tool.Runner`) hard-denies dangerous tool names such
  as `shell_command`, `network_call`, `remote_execution`, `write_file`,
  `replace_in_file`, and `delete_file`. `patch_apply` is registered but only
  runs after plan + patch approval context and creates a checkpoint first.
- PR19 adds a preset-only `test_runner` for bounded verification commands such
  as `mix test`, `mix test <test-file>`, `mix format --check-formatted`, and
  `mix compile --warnings-as-errors`; it does not grant arbitrary shell access.
- **PR24** introduces a local execution runner abstraction (`Muse.Execution.LocalRunner`):
  - Local commands execute via argv-vector `Port.open`, never through a shell.
  - Remote execution (`:remote`, `:ssh`, any string target) is explicitly denied.
  - `ApprovalGate` blocks `remote_execution` tools regardless of approval context.
  - Git tools (`git_status`, `git_diff_readonly`, `patch_apply`) use the local runner.
  - Output is capped and redacted; secrets never leak in results or logs.

### Memory, handoff & restoration safety

- **Memory Muse** (PR21) compacts session history into durable memory bundles
  that survive across sessions. Memory is read-only in prompt context --- it
  never mutates workspace files.
- **Handoff** between Muses (e.g., Planning → Coding) is a supervised turn
  transition; the Conductor logs every handoff as an auditable event
  (`:muse_handoff_requested`, `:muse_handoff_completed`).
- **Restoration Muse** (PR21) can inspect session events, checkpoints, git
  status, and diffs, but cannot restore or modify files without approval.
- Every tool call, approval decision, and session transition is recorded in
  the event log for full auditability.

### Workspace path safety

Every file tool passes through a 9-step path validation (`Muse.Workspace.safe_resolve!/2`):
accept relative paths → reject absolute → normalize → resolve symlinks →
confirm inside workspace → enforce permission policy → enforce secret-file
policy → block writes through symlinks → emit audit event.

See [`docs/security.md`](docs/security.md) for the full security model,
[`docs/architecture.md`](docs/architecture.md) for approval flows, and
[`docs/phase4-persistence.md`](docs/phase4-persistence.md) for session persistence,
export/import, memory safety, and workspace profile isolation.

---

## Commands

| Command | What it does |
|---|---|
| `mix muse` | Start REPL + web (default) |
| `mix muse --repl` | Explicit REPL CLI |
| `mix muse --tui` | Full-screen ExRatatui TUI |
| `mix muse --tui --no-web` | TUI without web server |
| `mix muse --verbose` | Debug-level console logging (overrides TUI silence) |
| `mix muse --no-web` | CLI only, no web server |
| `mix muse --web-only` | Web only, no CLI (`--no-cli` is an alias) |
| `mix muse --port 5000` | Web on port 5000 (`-p` shorthand) |
| `mix muse --host 0.0.0.0` | Web on all interfaces |
| `mix muse --workspace /path` | Set workspace (`-w` shorthand) |
| `mix muse --no-watch` | Disable source hot-reload |
| `mix muse --watch` | Enable source hot-reload (on by default in source mode) |
| `mix muse --help` | Print usage (`-h`) |
| `mix muse --version` | Print version and exit (`-v`) |

For built escripts:

| Command | What it does |
|---|---|
| `./muse --help` | Print usage (`-h`) |
| `./muse --version` | Print version (`-v`) |

Flags can be combined: `mix muse --tui --no-web --workspace ~/my_app`.

### Workspace resolution

1. `--workspace PATH` / `-w PATH` — explicit flag wins.
2. `MUSE_WORKSPACE` env var — used if no flag is given.
3. Current working directory — the default fallback.

---

## CLI Commands

Inside the `muse>` REPL:

| Command | Description |
|---|---|
| `/help` | Show available commands |
| `/plan` | Show the active Muse Plan |
| `/plans` | List Muse Plan history for this session |
| `/plan history` | List Muse Plan history for this session |
| `/plan status` | Show active Muse Plan lifecycle and approval audit status |
| `/plan show <id>` | Show a Muse Plan by id |
| `/approve plan` | Approve the active Muse Plan; records approval only and does **not** start implementation |
| `/reject plan` | Reject the active Muse Plan and request a revised plan |
| `/approve patch` | Approve the pending patch proposal; records approval only — no files are written by this command |
| `/reject patch` | Reject the pending patch proposal |
| `/apply patch [patch_id]` | Apply an approved patch with checkpoint protection |
| `/rollback checkpoint <checkpoint_id>` | Roll back a Muse Checkpoint created before patch application |
| `/events` | Print the event log |
| `/workspace` | Print current workspace path |
| `/reload` | Force a dev hot-reload |
| `/rollback` | Roll back to last good code generation |
| `/reload-status` | Show reload generation and last error |
| `/auth status` | Show redacted provider/auth configuration status |
| `/session` | Show Muse session status, active plan, and pending patch |
| `/memory` | Show session memory summary |
| `/memory compact` | Compact session context into safe durable memory |
| `/memory clear` | Clear session memory |
| `/export session` | Copy current session export JSON to clipboard (secrets redacted) |
| `/import session` | Import a session from a JSON export file (commonly `.muse-session`; e.g. `/import session path/to/file.muse-session`) |
| `/workspace create` | Create a workspace profile (e.g. `/workspace create myproject /path/to/root`) |
| `/workspace list` | List all workspace profiles |
| `/workspace switch` | Switch active workspace profile (affects new session persistence paths) |
| `/workspace info` | Show detailed workspace profile and session store info |
| `/handoff <muse_id>` | Request an explicit handoff to another allowed Muse |
| `/checkpoints` | List Muse Checkpoints available for the current session |
| `/restore <checkpoint_id>` | Show a Restoration Muse checkpoint restore request; no files are modified without approval |
| `/quit` | Stop Muse (`:quit` also works) |

Approval commands are lifecycle-only. `/approve plan` prints the plan id,
version, any available approval id/hash, and an explicit "no implementation
started" line. `/reject plan` prints the plan id/version, any available rejection
record, and tells you to ask Planning Muse for a revised plan. `/approve patch`
records the patch approval decision but does **not** apply the patch, create
checkpoints, or modify any files by itself — `/apply patch` is the separate
PR18 application step. `/plan status` includes approval/rejection audit status
and id/hash details when the active plan has them. Approval of a plan does not
start shell commands, arbitrary file writes, remote execution, or network
execution.

---

## Installation

See the [Installation Guide](docs/install.md) for detailed instructions covering:

- **Source/development install** — `git clone && mix deps.get && mix muse` — the stable path for v0.1.0
- **Direct escript download** from GitHub Releases (Linux/macOS) with SHA256 verification — expected for v0.2.0+
- **Mix release** for TUI and native NIF support
- **Homebrew** (planned; see [roadmap](docs/roadmap-v0.2.0.md))
- **Windows** via WSL2
- **Upgrade** instructions for escript, release, and source modes
- **Smoke checks** to verify installation

---

## Building an Escript

Compile a self-contained executable:

```bash
mix escript.build
./muse
```

The escript runs the same as `mix muse` but with one key difference: **source
mode is disabled**, so `Muse.DevReloader` (hot reload) is effectively off even
if `--watch` is passed.  This is intentional — an escript has no source tree
to watch.

All the same flags work: `./muse --no-web --port 3000`.

### Escript TUI limitation

**`./muse --tui` is not supported.** The TUI mode requires the ExRatatui
native NIF (a compiled Rust shared library), which cannot be loaded from
inside a single-file escript archive. If you run `./muse --tui`, Muse prints
a clear error with alternatives and exits nonzero — it does not crash.

For TUI, use `mix muse --tui` (source mode) or a Mix release (see below).

---

## Installing the Escript

```bash
mix escript.install
```

This copies the `muse` escript into `~/.mix/escripts/`. Add that directory to
your shell's `$PATH`:

```bash
# bash
echo 'export PATH="$HOME/.mix/escripts:$PATH"' >> ~/.bashrc
source ~/.bashrc

# zsh
echo 'export PATH="$HOME/.mix/escripts:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Then run `muse` from anywhere:

```bash
muse --workspace ~/projects/my_app
```

---

## Distribution — Mix Release (recommended for TUI)

For production or TUI deployment, build a Mix release instead of an escript.
Mix releases include native NIF libraries and support all modes:

```bash
MIX_ENV=prod mix release
```

Production release startup requires `MUSE_SECRET_KEY_BASE` at runtime. The
release can be built without this value, but every release invocation that
loads runtime config (including `bin/muse_cli`) must set a strong secret of at
least 64 bytes. Generate one locally with `mix phx.gen.secret`, then provide it
through your deployment environment or secret manager — do not commit it to the
repo:

```bash
export MUSE_SECRET_KEY_BASE="$(mix phx.gen.secret)"
```

If `MUSE_SECRET_KEY_BASE` is missing or too short, Muse fails fast before the
production endpoint starts.

The release command creates a self-contained release at `_build/prod/rel/muse/`.
The release includes the ExRatatui native NIF, so **TUI mode works**:

```bash
# Show help
_build/prod/rel/muse/bin/muse_cli --help

# Run TUI
_build/prod/rel/muse/bin/muse_cli --tui --no-web

# Run REPL
_build/prod/rel/muse/bin/muse_cli --repl --no-web

# Run web + CLI
_build/prod/rel/muse/bin/muse_cli
```

`bin/muse_cli` is a convenience wrapper that forwards all arguments to
`Muse.CLI.ReleaseCommand.main/1` via `bin/muse eval`. You can also invoke
the release directly:

```bash
_build/prod/rel/muse/bin/muse eval "Muse.CLI.ReleaseCommand.main(System.argv())" -- --tui --no-web
```

### Tar archive

The release step also generates `_build/prod/muse-0.1.0.tar.gz`. Copy this
to any machine with the same OS/architecture and Erlang/OTP installed, then:

```bash
mkdir -p /opt/muse && tar -xzf muse-0.1.0.tar.gz -C /opt/muse
# Ensure MUSE_SECRET_KEY_BASE is set in the target environment first.
/opt/muse/bin/muse_cli --tui
```

### Release vs. escript vs. source

| Feature | `mix muse` | `mix escript.build` | `mix release` |
|---|---|---|---|
| REPL | ✅ | ✅ | ✅ |
| TUI | ✅ | ❌ NIF can't load | ✅ |
| Web | ✅ | ✅ | ✅ |
| Hot reload | ✅ | ❌ | ❌ |
| Single file | ❌ | ✅ | ❌ |
| Portable tar | ❌ | ❌ | ✅ |

---

## Dev Wrapper

Run the source version of `muse` from any directory without building an
escript. The wrapper preserves your current working directory as the workspace.

```bash
cd ~/projects/muse
./script/install-dev

# Then from any project:
cd ~/projects/my_app
muse           # runs source version, workspace = ~/projects/my_app
```

`script/install-dev` installs to `~/.local/bin/muse` by default; pass a
different path to install elsewhere:

```bash
./script/install-dev /usr/local/bin/muse
```

You can also invoke `bin/muse` directly from the repo checkout — no
installation needed:

```bash
cd ~/projects/muse
./bin/muse --workspace ~/projects/my_app
```

---

## Architecture Overview

```
┌──────────┐    ┌──────────────┐
│  CLI     │    │  Web (LV)    │
│  REPL    │    │  Interface   │
└────┬─────┘    └──────┬───────┘
     │                 │
     └───────┬─────────┘
             ▼
      Muse.submit/2        ← single entry point for all input
             │
             ▼
      SessionRouter
             │
             ▼
      SessionServer        ← per-session GenServer state/persistence
             │
             ▼
      Conductor/TurnRunner ← Muse selection, prompt assembly, tool loop
             │
             ▼
       Muse.State          ← ordered event log (GenServer)
             │
       Muse.PubSub         ← broadcasts every event to subscribers
             │
    ┌────────┴────────┐
    ▼                 ▼
  CLI output      LiveView re-render
```

### Key modules

| Module | Role |
|---|---|
| `Muse.submit/2` | Public API — accepts `(source, text)`, delegates to `SessionRouter` |
| `Muse.SessionRouter` | Starts/looks up per-session `SessionServer` processes |
| `Muse.SessionServer` | Per-session GenServer for state, persistence, approvals, patch/checkpoint/memory state |
| `Muse.Conductor` / `Muse.Conductor.TurnRunner` | Selects Muse profile, assembles prompts, runs provider/tool loop outside the GenServer |
| `Muse.State` | GenServer holding the event log; broadcasts via PubSub |
| `Muse.Event` | Struct — `%{id, source, type, data, timestamp}` |
| `Muse.BootOptions` | Parses CLI flags into a typed struct |
| `Muse.CLI.Repl` | Interactive `muse>` prompt |
| `Muse.CLI.Main` | Escript entrypoint; sets `:source_mode?` |
| `Muse.DevReloader` | Hot-reload watcher with generation tracking & rollback |
| `Muse.SelfHealingQueue` | GenServer holding queued self-healing issues; broadcasts via PubSub |
| `Muse.SelfHealingIssue` | Struct representing a diagnostic queued for next Muse turn |

### Source mode vs. escript mode

- **Source mode** (`mix muse` / dev wrapper): `:source_mode?` is `true`.
  `Muse.DevReloader` is active (when `--watch` is on), polling `lib/` for
  changes, compiling them, and rolling back on failure.

- **Escript mode** (`./muse`): `:source_mode?` is `false`. Hot reload is
  effectively disabled — there's no source tree to watch.

---

## Self-Healing Diagnostics

When backend diagnostics (warnings, errors, criticals) appear, the sidebar card
in the left panel shows a compact summary (count + latest message). Clicking
**details** opens a **diagnostics drawer** overlay with the full list, action
buttons, and status labels.

Each diagnostic in the drawer has an **"Add to next Muse turn"** button.
Clicking it queues the diagnostic for self-healing.  Once queued, the button
changes to a disabled **"Queued for next Muse turn"** label.  Status labels
update through the lifecycle: `In progress`, `Already fixed`, `Self-healing failed`,
`Ignored`.

On the next `Muse.submit/2` call (from the CLI or web), queued self-healing
issues are atomically claimed and attached as an event in the state log.

> **⚠️ Current limitation** — Full autonomous auto-fixing is not enabled.
> `Muse.submit/2` now routes through sessions and the Conductor, and queued
> issues are recorded and attached to the next turn, but diagnostics do not
> trigger an unsupervised repair loop. This remains a **bridge** for explicit,
> approval-gated Muse workflows.

---

## Observability & Telemetry Export

Muse emits structured telemetry events (`:telemetry.execute/3`) for key
lifecycle moments: turn start/stop/exception, provider start/stop/error,
tool start/stop/exception, session created/loaded/ended, and approval
granted/rejected. By default these events are consumed only by internal
handlers (logging, metrics).

**Telemetry export** lets you ship these events to an external sink for
monitoring, debugging, or audit:

| `MUSE_TELEMETRY_EXPORT` | Behavior |
|---|---|
| Unset, blank, `off`, `false`, `0` | No export (default) |
| `stdout` | One JSON object per event, printed to stdout |
| `file` | JSONL appended to `MUSE_TELEMETRY_FILE` path |

```bash
# Stdout export (debugging)
MUSE_TELEMETRY_EXPORT=stdout mix muse

# File export (audit trail)
MUSE_TELEMETRY_EXPORT=file \
  MUSE_TELEMETRY_FILE=/var/log/muse-telemetry.jsonl \
  mix muse
```

Each exported envelope is a JSON object with four top-level keys:
`event`, `timestamp`, `measurements`, `metadata`. All metadata and
measurements pass through defense-in-depth redaction
(`MetadataSanitizer` + `EventPayloadRedactor`) — raw API keys, tokens,
JWTs, and private keys never appear in exported output. File exports
attempt restrictive `0600` permissions; permission failures are non-fatal.
Export handlers swallow all errors so telemetry should never crash the
application.

See [`docs/architecture.md` §9](docs/architecture.md#9-telemetry) for
the full event table and envelope format, and
[`docs/security.md`](docs/security.md) for redaction and file-permission
security notes.

---

## UI

Muse uses a dark-only modern chat-first Muse workspace with calm neutral
panels and a subtle purple accent.  The layout is a full-width single-window
design with a compact top header and a central conversation area.

- **Dark mode only** — no theme toggle. Dark background with high-contrast text.
- **Top header** — compact status chips for backend, watcher, runtime, workspace,
  and diagnostics. When the sidebar is hidden, a context-reopen button appears.
- **Left collapsible sidebar** — context cards for Muse status, workspace info,
  diagnostics summary (with a details button that opens the drawer), recent files,
  and BEAM stats. The sidebar supports three states:
  - *Expanded* (default) — full card layout with labels.
  - *Rail* — narrow icon-only rail that expands on hover/click.
  - *Hidden* — hidden entirely; reopen via the header.
- **Central chat panel** — conversation sourced from `Muse.State` `:user_message`
  and `:assistant_message` events, rendered as chat bubbles with a composer at
  the bottom.
- **Diagnostics drawer** — a slide-in overlay opened from the sidebar (or header
  chip) showing the full diagnostics list with queue, copy, and jump-to-file
  actions. Closing the drawer leaves the sidebar card and header chip visible.

The main area is a conversation sourced from `Muse.State` `:user_message`
and `:assistant_message` events, rendered as chat bubbles. No tab nav, no
separate Backend console, no dev tools panel.

### External WebSocket Channel (Optional)

For non-LiveView clients (CLI integrations, automation tools, IDE extensions),
an optional WebSocket channel is available at `ws://127.0.0.1:4000/socket`.
This channel is **disabled by default** and read-only (no tool/write/shell/network
permissions). See [`docs/architecture.md` §8.5](docs/architecture.md#85-optional-external-phoenix-websocket-channel-pr16)
and [`docs/security.md` §13](docs/security.md#13-external-websocket-channel-security-pr16) for details.

---

## Requirements

- **Elixir** ~> 1.17
- **Erlang/OTP** 27+ (matching Elixir 1.17)
- Install dependencies: `mix deps.get`

---

## Development Workflow

```bash
# Fetch dependencies
mix deps.get

# Run all CI gates locally (format, compile warnings, hex audit, tests)
mix ci

# Run just the test suite (offline by default, no API keys needed)
mix test

# Run a specific test file
mix test test/muse/command_dispatcher_test.exs

# Run the LiveView browser smoke test (HTTP-based, no Playwright required)
./script/liveview-browser-smoke

# Start Muse (REPL + web interface on http://127.0.0.1:4000)
mix muse
```

**CI expectations:**

| Check | Command | CI step |
|---|---|---|
| No formatting violations | `mix format --check-formatted` | ✓ |
| Clean compile with strict warnings | `mix compile --warnings-as-errors` | ✓ |
| No retired Hex packages | `mix hex.audit` | ✓ |
| Tests pass | `mix test` | ✓ |
| LiveView browser smoke | `./script/liveview-browser-smoke` | ✓ |
| Muse-first terminology grep check | No "Active Agent", "Agent Plan", or "Bot" in user-facing surfaces (see [`docs/testing.md`](docs/testing.md#9-product-language-tests)) | manual |

`mix ci` runs the first four gates in one command. The browser smoke test requires a running server and must be run separately via the orchestration script. All CI gates run offline with the fake provider — no API keys, no external network calls. External/network-dependent tests are opt-in via the `@tag :external` mechanism.

GitHub Actions CI runs the full pipeline on every push to `main` and every pull request targeting `main`. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

See [`docs/testing.md`](docs/testing.md) for the full testing strategy.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `mix muse` says "command not found" | Run `mix deps.get` first |
| Web UI not reachable | Check `--port` / `--host` flags; default is `127.0.0.1:4000` |
| `escript.install` puts binary in `~/.mix/escripts` but `muse` isn't on PATH | Add `~/.mix/escripts` to `$PATH` (see *Installing the Escript*) |
| Hot reload not firing | Confirm you're in source mode (`mix muse`, not `./muse`), and `--no-watch` isn't set |
| `/reload` says "DevReloader not available" | Same cause as above — escript mode disables the reloader |
| `./muse --tui` fails with NIF error | Escript cannot load native NIFs — use `mix muse --tui` or build a release (`MIX_ENV=prod mix release`) |
| Provider returns auth error | Run `/auth status` in the REPL; check `MUSE_OPENAI_API_KEY`, `MUSE_OPENROUTER_API_KEY`, or `MUSE_ANTHROPIC_API_KEY` env vars |
| Provider not responding / unknown model | Run `/provider status` in the REPL; verify `MUSE_PROVIDER`, `MUSE_MODEL`, and `MUSE_*_BASE_URL` env vars |
| Session looks stuck or stale | Run `/session` to inspect status, active plan, and pending patch; `/events` to review the event log |
| Need debug-level logging | Start with `mix muse --verbose` for debug console output |
| Telemetry export not producing output | Verify `MUSE_TELEMETRY_EXPORT` is set to `stdout` or `file`; for file mode, also set `MUSE_TELEMETRY_FILE` to a writable path |
| Telemetry export file not created | Check the `MUSE_TELEMETRY_FILE` path exists and is writable; parent directory must exist |
| Can't tell if export is active | Start with `mix muse --verbose`; export attachment status is logged at startup |

---

## License

See [LICENSE](LICENSE) for details.
