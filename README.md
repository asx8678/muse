# Muse

Minimal Elixir/Phoenix LiveView coding-agent foundation.

Muse gives you a CLI REPL and a web interface that both funnel through a
single `Muse.submit/2` API — so adding real AI behavior later is a one-module
change.

> **⚠️ Placeholder AI** — `Muse.submit/2` currently returns a canned
> `"Placeholder response: received …"` string.  No real LLM integration exists
> yet.  Everything else (CLI, web, state, hot reload) is fully functional.

---

## Quick Start

```bash
git clone <repo-url> muse && cd muse
mix deps.get && mix muse
```

You'll see the startup banner, a `muse>` prompt, and (unless you pass
`--no-web`) a web UI at **http://127.0.0.1:4000**.

Type anything at the prompt and press Enter to get the placeholder response.
Type `/quit` to exit.

Run the test suite:

```bash
mix test
```

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
| `/events` | Print the event log |
| `/workspace` | Print current workspace path |
| `/reload` | Force a dev hot-reload |
| `/rollback` | Roll back to last good code generation |
| `/reload-status` | Show reload generation and last error |
| `/quit` | Stop Muse (`:quit` also works) |

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

This creates a self-contained release at `_build/prod/rel/muse/`. The release
includes the ExRatatui native NIF, so **TUI mode works**:

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
| `Muse.submit/2` | Public API — accepts `(source, text)`, returns `{:ok, response}` |
| `Muse.State` | GenServer holding the event log; broadcasts via PubSub |
| `Muse.Event` | Struct — `%{id, source, type, data, timestamp}` |
| `Muse.BootOptions` | Parses CLI flags into a typed struct |
| `Muse.CLI.Repl` | Interactive `muse>` prompt |
| `Muse.CLI.Main` | Escript entrypoint; sets `:source_mode?` |
| `Muse.DevReloader` | Hot-reload watcher with generation tracking & rollback |
| `Muse.SelfHealingQueue` | GenServer holding queued self-healing issues; broadcasts via PubSub |
| `Muse.SelfHealingIssue` | Struct representing a diagnostic queued for next agent turn |

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

Each diagnostic in the drawer has an **"Add to next agent turn"** button.
Clicking it queues the diagnostic for self-healing.  Once queued, the button
changes to a disabled **"Queued for next agent turn"** label.  Status labels
update through the lifecycle: `In progress`, `Already fixed`, `Self-healing failed`,
`Ignored`.

On the next `Muse.submit/2` call (from the CLI or web), queued self-healing
issues are atomically claimed and attached as an event in the state log.

> **⚠️ Current limitation** — Full auto-fixing requires a real coding-agent
> integration.  Currently, `Muse.submit/2` is still a placeholder; queued
> issues are recorded and attached to the next turn, but no automatic
> resolution happens.  This is a **bridge** until a real agent is wired in.

---

## UI

Muse uses a dark-only modern chat-first agent workspace with calm neutral
panels and a subtle purple accent.  The layout is a full-width single-window
design with a compact top header and a central conversation area.

- **Dark mode only** — no theme toggle. Dark background with high-contrast text.
- **Top header** — compact status chips for backend, watcher, runtime, workspace,
  and diagnostics. When the sidebar is hidden, a context-reopen button appears.
- **Left collapsible sidebar** — context cards for agent status, workspace info,
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

---

## Requirements

- **Elixir** ~> 1.17
- **Erlang/OTP** 27+ (matching Elixir 1.17)
- Install dependencies: `mix deps.get`

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

---

## License

See [LICENSE](LICENSE) for details.
