# Muse — Minimal Core Setup Plan

## Window Management System Plan

MVP floating-window shell for the Muse LiveView UI.

### Phases

| # | Phase | Scope |
|---|-------|-------|
| 1 | Icon dock + window shell | Header icon bar; `open_windows` / `active_window` assigns; `toggle_window` / `close_window` / `focus_window` events; safe window-name allowlist |
| 2 | Draggable JS hook | `DraggableWindow` LiveView hook in `app.js`; pointer-event drag by title-bar; localStorage position persistence |
| 3 | BEAM stats window | `Muse.BeamStats.snapshot/0`; Statistics window rendering memory / process / scheduler info |
| 4 | Reload / recent-files window | Enhance `Muse.DevReloader` status with `recent_files` list; `scan_file_stats/1` helper for line-count tracking; per-file `modified_count` + `lines_added` |
| 5 | Agent registry + tree window | `Muse.AgentRegistry` GenServer with register/update/unregister/snapshot/subscribe; PubSub broadcast; Agents window with idle/unavailable UI |
| 6 | Settings / universal-agent placeholders | Settings window shell; Universal Agent window placeholder |
| 7 | CSS | `.icon-dock`, `.dock-icon`, `.managed-window`, `.window-title-bar`, `.window-body`, stats / file / agent-tree classes; floating fixed position; high z-index |
| 8 | Tests + QA | `Muse.BeamStatsTest`, `Muse.AgentRegistryTest`, DevReloader recent-files tests, HomeLive window-interaction tests, JS hook source checks, `mix format && mix test` |

### Constraints
- All windows gracefully handle missing GenServers (DevReloader, AgentRegistry).
- No real agent/tool activity — UI shows unavailable/idle.
- Preserve existing IDs: `workspace`, `diagnostics-badge`, `diagnostics-popup`, `events`, `reload-status`.
- Dark-only, subtle purple accent.

---

## Overview

Muse is a minimal Elixir CLI coding-agent foundation. This milestone creates the
boot infrastructure, CLI REPL, optional local web UI, workspace management,
shared in-memory event state, placeholder agent responses, and a basic
development hot-code watcher with rollback.

No real AI, no shell execution, no file editing, no persistence. Just the
skeleton that breathes.

---

## Product Identity

| Item              | Value           |
|-------------------|-----------------|
| Product name      | Muse            |
| Executable        | `muse`          |
| OTP app           | `:muse`         |
| Core module       | `Muse`          |
| Web namespace     | `MuseWeb`       |
| CLI prompt        | `muse>`         |

---

## Project Structure

```
muse/
├── mix.exs
├── README.md
├── bin/
│   └── muse                  # optional dev wrapper script
├── config/
│   ├── config.exs
│   └── dev.exs
├── assets/
│   ├── js/
│   │   └── app.js
│   └── css/
│       └── app.css
├── lib/
│   ├── muse.ex               # Public API: Muse.submit/2
│   ├── muse/
│   │   ├── application.ex    # OTP app callback + supervisor
│   │   ├── argv.ex           # Boot args helper
│   │   ├── boot_options.ex   # CLI flag parsing
│   │   ├── workspace.ex      # Workspace root + path resolution
│   │   ├── event.ex          # Event struct
│   │   ├── state.ex          # GenServer: shared event state + PubSub
│   │   ├── health.ex         # Smoke checks for dev reloader
│   │   ├── dev_reloader.ex   # Development hot-code watcher + rollback
│   │   └── cli/
│   │       ├── main.ex       # Escript entrypoint
│   │       └── repl.ex       # CLI REPL loop
│   ├── muse_web.ex           # Web module helpers
│   ├── muse_web/
│   │   ├── endpoint.ex       # Phoenix endpoint (Bandit adapter)
│   │   ├── router.ex         # Minimal router
│   │   └── live/
│   │       └── home_live.ex  # Home LiveView
│   └── mix/
│       └── tasks/
│           └── muse.ex       # mix muse task
└── test/
    ├── test_helper.exs
    ├── muse/
    │   ├── boot_options_test.exs
    │   ├── workspace_test.exs
    │   ├── event_test.exs
    │   ├── state_test.exs
    │   ├── health_test.exs
    │   ├── dev_reloader_test.exs
    │   └── muse_test.exs     # Muse.submit/2 tests
    └── muse_web/
        └── live/
            └── home_live_test.exs
```

---

## Dependencies

```elixir
defp deps do
  [
    {:phoenix, "~> 1.8"},
    {:phoenix_live_view, "~> 1.1"},
    {:phoenix_html, "~> 4.3"},
    {:phoenix_pubsub, "~> 2.2"},
    {:phoenix_live_reload, "~> 1.6", only: :dev},
    {:bandit, "~> 1.0"},
    {:jason, "~> 1.4"},
    {:esbuild, "~> 0.9", runtime: Mix.env() == :dev}
  ]
end
```

No Ecto. No database. No Tailwind. Plain CSS only.

---

## Default Boot Options

```elixir
%{
  cli?: true,
  web?: true,
  host: "127.0.0.1",
  port: 4000,
  workspace: nil,          # resolved at parse time to absolute path
  watch?: true,            # true when source_mode? == true, false otherwise
  help?: false
}
```

### Flag Behavior

| Flag                | Effect                                    |
|---------------------|-------------------------------------------|
| (none)              | cli?: true, web?: true                    |
| `--no-web`          | cli?: true, web?: false                   |
| `--web-only`        | cli?: false, web?: true                   |
| `--no-cli`          | cli?: false, web?: true (alias for --web-only) |
| `--port PORT`       | port: PORT                                |
| `--host HOST`       | host: HOST                                |
| `--workspace PATH`  | workspace: absolute path                  |
| `--watch`           | watch?: true (override)                   |
| `--no-watch`        | watch?: false                             |
| `--help`            | help?: true, print usage and exit         |

Invalid flags → clear error + exit code 1.

---

## Implementation Steps (Ordered)

### Step 1 — Scaffold the app

**Goal:** `mix new muse --sup` + working `mix compile`.

**Actions:**
1. Run `mix new muse --sup`
2. Edit `mix.exs`:
   - Set elixir version to `~> 1.17`
   - Set version to `0.1.0`
   - Add all deps listed above
   - Add escript config: `[main_module: Muse.CLI.Main, name: "muse"]`
   - Add `elixirc_paths: elixirc_paths(Mix.env())` to include `lib`
3. Create `config/config.exs` with minimal Phoenix endpoint config:
   - `adapter: Bandit.PhoenixAdapter`
   - `secret_key_base` (dev-only placeholder)
   - `pubsub_server: Muse.PubSub`
   - `live_view` signing salt
   - `render_errors` config if Phoenix requires it
4. Create `config/dev.exs` with dev overrides:
   - `http: [ip: {127,0,0,1}, port: 4000]`
   - `check_origin: false`
   - `code_reloader: true`
   - `debug_errors: true`
5. Verify `mix deps.get && mix compile` passes

**Acceptance:** `mix compile` succeeds with zero warnings (or only known dep warnings).

---

### Step 2 — Boot options + Argv

**Goal:** Parse CLI flags into a typed struct; provide reusable argv access.

**Files to create:**
- `lib/muse/argv.ex`
- `lib/muse/boot_options.ex`

**Design:**

```elixir
# lib/muse/argv.ex
defmodule Muse.Argv do
  def get do
    Application.get_env(:muse, :boot_args, System.argv())
  end
end
```

```elixir
# lib/muse/boot_options.ex
defmodule Muse.BootOptions do
  defstruct cli?: true, web?: true, host: "127.0.0.1",
            port: 4000, workspace: nil, watch?: true, help?: false

  def parse!(argv) do
    # Use OptionParser with strict opts
    # Resolve workspace: --workspace > MUSE_WORKSPACE env > File.cwd!()
    # Determine watch?: if source_mode? is false, default watch? to false
    # Return %__MODULE__{...} or raise on invalid args
  end
end
```

**Key behaviors:**
- `--web-only` sets `cli?: false, web?: true`
- `--no-web` sets `cli?: true, web?: false`
- `--no-cli` is an alias for `--web-only`
- `--workspace` resolves to absolute path immediately
- `watch?` defaults to true but only makes sense when `source_mode?` is true
  (we'll handle the final default in Application, not in BootOptions)
- Invalid flags → `Mix.raise()` or `IO.puts(:stderr, ...) + System.halt(1)`

**Tests to create:**
- `test/muse/boot_options_test.exs`
  - default → cli?: true, web?: true
  - --no-web → cli?: true, web?: false
  - --web-only → cli?: false, web?: true
  - --no-cli → cli?: false, web?: true
  - --port 4100 → port: 4100
  - --workspace /tmp/foo → workspace: "/tmp/foo"
  - --no-watch → watch?: false
  - --help → help?: true
  - invalid flag → raises/errors

**Acceptance:** All boot_options tests pass. `Muse.BootOptions.parse!([])` returns defaults.

---

### Step 3 — Workspace module

**Goal:** Store workspace root once at boot; provide safe path resolution.

**File to create:** `lib/muse/workspace.ex`

**Design:**

```elixir
defmodule Muse.Workspace do
  use Agent

  def start_link(opts) do
    root = Keyword.fetch!(opts, :root) |> Path.expand()
    Agent.start_link(fn -> root end, name: __MODULE__)
  end

  def root, do: Agent.get(__MODULE__, & &1)

  def resolve!(path) do
    root = root()
    resolved = Path.expand(path, root)
    if String.starts_with?(resolved, root <> "/") or resolved == root do
      resolved
    else
      raise ArgumentError, "path #{inspect(path)} escapes workspace #{inspect(root)}"
    end
  end
end
```

**Key behaviors:**
- `root/0` always returns absolute path
- `resolve!/1` with relative path → joins to root, returns absolute
- `resolve!/1` with absolute path inside root → allowed
- `resolve!/1` with `../outside` → raises `ArgumentError`

**Tests to create:**
- `test/muse/workspace_test.exs`
  - root is absolute
  - relative "lib/foo.ex" resolves inside root
  - absolute path inside root is accepted
  - `../outside` is rejected (raises)

**Acceptance:** All workspace tests pass. Path escape is blocked.

---

### Step 4 — Event + State

**Goal:** Define the event struct and shared GenServer state with PubSub broadcasting.

**Files to create:**
- `lib/muse/event.ex`
- `lib/muse/state.ex`

**Event design:**

```elixir
defmodule Muse.Event do
  defstruct [:id, :timestamp, :source, :type, :data]

  def new(source, type, data) do
    %__MODULE__{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      source: source,
      type: type,
      data: data
    }
  end

  defp generate_id, do: System.unique_integer([:positive])
end
```

**State design:**

```elixir
defmodule Muse.State do
  use GenServer

  @topic "muse:events"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def events, do: GenServer.call(__MODULE__, :events)
  def append(event), do: GenServer.call(__MODULE__, {:append, event})
  def subscribe, do: Phoenix.PubSub.subscribe(Muse.PubSub, @topic)

  # GenServer callbacks
  def init(_opts), do: {:ok, %{events: []}}

  def handle_call(:get, _from, state), do: {:reply, state, state}
  def handle_call(:events, _from, state), do: {:reply, state.events, state}

  def handle_call({:append, event}, _from, state) do
    new_state = %{state | events: state.events ++ [event]}
    Phoenix.PubSub.broadcast(Muse.PubSub, @topic, {:muse_event, event})
    {:reply, :ok, new_state}
  end
end
```

**Key behaviors:**
- `Muse.State.subscribe()` hides the topic string from consumers
- Events are appended in order (oldest first)
- Each append broadcasts `{:muse_event, event}` on PubSub

**Tests to create:**
- `test/muse/event_test.exs`
  - `new/3` creates struct with all fields
- `test/muse/state_test.exs`
  - initial events are empty
  - `append/1` stores event
  - `append/1` broadcasts PubSub message
  - `subscribe/0` receives broadcast

**Acceptance:** Event struct is well-formed. State stores and broadcasts correctly.

---

### Step 5 — Muse.submit/2 (Public API)

**Goal:** Single entry point for both CLI and web to submit text.

**File to modify:** `lib/muse.ex`

**Design:**

```elixir
defmodule Muse do
  def submit(source, text) do
    user_event = Muse.Event.new(source, :user_message, %{text: text})
    Muse.State.append(user_event)

    assistant_text = "Placeholder response: received #{inspect(text)}"
    assistant_event = Muse.Event.new(:muse, :assistant_message, %{text: assistant_text})
    Muse.State.append(assistant_event)

    {:ok, assistant_text}
  end
end
```

**Tests to create:**
- `test/muse/muse_test.exs`
  - `submit/2` appends user event
  - `submit/2` appends assistant placeholder event
  - `submit/2` returns `{:ok, "Placeholder response: received \"hello\""}`

**Acceptance:** `Muse.submit(:cli, "hello")` → stored events + placeholder response.

---

### Step 6 — CLI REPL

**Goal:** Interactive `muse>` prompt with command handling and error resilience.

**File to create:** `lib/muse/cli/repl.ex`

**Design:**

```elixir
defmodule Muse.CLI.Repl do
  def start_link(opts) do
    # Spawn a process that runs the REPL loop
    # NOT a GenServer — IO.gets is blocking
    pid = spawn_link(fn -> loop(opts) end)
    {:ok, pid}
  end

  defp loop(opts) do
    case IO.gets("muse> ") do
      :eof -> shutdown()
      {:error, _} -> shutdown()
      nil -> shutdown()
      input ->
        input = String.trim(input)
        handle_input(input, opts)
        loop(opts)
    end
  end

  defp handle_input(input, _opts) do
    try do
      case input do
        "" -> :ok
        "/help" -> print_help()
        "/events" -> print_events()
        "/workspace" -> print_workspace()
        "/reload" -> Muse.DevReloader.reload()
        "/rollback" -> Muse.DevReloader.rollback()
        "/reload-status" -> print_reload_status()
        "/quit" -> shutdown()
        ":quit" -> shutdown()
        text -> Muse.submit(:cli, text) |> print_response()
      end
    rescue
      e ->
        IO.puts("[error] #{inspect(e)}")
        # Attempt rollback if dev reloader is active
        try do
          if function_exported?(Muse.DevReloader, :rollback, 0) do
            Muse.DevReloader.rollback()
          end
        rescue
          _ -> :ok
        end
    end
  end

  defp print_response({:ok, text}), do: IO.puts("assistant> #{text}")
  defp print_response({:error, text}), do: IO.puts("[error] #{text}")

  defp print_help do
    IO.puts("""
    Commands:
      /help          Show this help
      /events        Print event log
      /workspace     Print current workspace
      /reload        Force dev reload
      /rollback      Roll back to last good generation
      /reload-status Show reload generation and last error
      /quit          Stop Muse
      :quit          Stop Muse
    """)
  end

  defp print_events do
    Muse.State.events()
    |> Enum.each(fn event -> IO.puts("[#{event.source}] #{inspect(event.data)}") end)
  end

  defp print_workspace do
    IO.puts("Workspace: #{Muse.Workspace.root()}")
  end

  defp print_reload_status do
    status = Muse.DevReloader.status()
    IO.puts("Generation: #{status.generation}")
    if status.last_error, do: IO.puts("Last error: #{inspect(status.last_error)}")
    if status.last_reload_at, do: IO.puts("Last reload: #{status.last_reload_at}")
  end

  defp shutdown do
    IO.puts("Goodbye!")
    System.halt(0)
  end
end
```

**Key behaviors:**
- EOF/nil → clean shutdown, no crash, no restart loop
- Errors in input handling → print error, attempt rollback, continue prompt
- Both `/quit` and `:quit` exit
- Normal text → `Muse.submit(:cli, text)`

**Tests to create:**
- `test/muse/cli/repl_test.exs`
  - Harder to test IO loops; focus on unit-testing the helper functions
  - Or test via integration: start app with `--no-web`, feed input, check output

**Acceptance:** `mix muse --no-web` shows `muse>` prompt. Commands work. Crashes don't kill the app.

---

### Step 7 — Dev Reloader + Health Check

**Goal:** Poll for source changes, compile, smoke-check, rollback on failure.

**Files to create:**
- `lib/muse/health.ex`
- `lib/muse/dev_reloader.ex`

**Health check design:**

```elixir
defmodule Muse.Health do
  def check! do
    # Raise if any check fails; return :ok if all pass
    checks = [
      fn -> File.dir?(Muse.Workspace.root()) end,
      fn -> Process.alive?(Process.whereis(Muse.State)) end,
      fn -> is_list(Muse.State.events()) end,
      fn -> Muse.BootOptions.parse!([]) end,
      fn -> function_exported?(Muse, :submit, 2) end
    ]

    Enum.each(checks, fn check ->
      unless check.(), do: raise "Health check failed"
    end)

    :ok
  end
end
```

**Dev reloader design:**

```elixir
defmodule Muse.DevReloader do
  use GenServer

  @poll_interval 1000
  @debounce_ms 300
  @watch_patterns ~w(lib/muse.ex lib/muse/**/*.ex lib/muse_web/**/*.ex)
  @exclude_patterns ~w(lib/muse/dev_reloader.ex lib/muse/application.ex)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def reload, do: GenServer.call(__MODULE__, :force_reload)
  def rollback, do: GenServer.call(__MODULE__, :rollback)

  def init(opts) do
    schedule_poll()
    {:ok, %{
      generation: 0,
      last_good_snapshot: nil,
      last_error: nil,
      last_reload_at: nil,
      pending_changes: nil,
      mtimes: scan_mtimes()
    }}
  end

  # ... handle_call, handle_info for polling, debounce, reload, rollback
end
```

**Key behaviors:**
- Poll every 1000ms for changed `lib/**/*.ex` files (exclude `_build`, `deps`, `assets`, `test`)
- Debounce 300ms before acting on changes
- Exclude `dev_reloader.ex` and `application.ex` from auto-reload
- Before loading new code: snapshot current Muse.*/MuseWeb.* module object code
- On changed files: compile → `Muse.Health.check!()`
- Success: increment generation, store snapshot as rollback target, broadcast success event
- Failure: restore previous snapshot, store error, broadcast failure event, keep running
- `/rollback` CLI command: restore last good snapshot manually
- `status()` returns current generation, last error, last reload time

**Dev reloader events:**
- `:reload_success` → `%{generation, files}`
- `:reload_failed` → `%{error, files}`
- `:rollback_success` → `%{generation}`

**Tests to create:**
- `test/muse/health_test.exs`
  - `check!/0` returns `:ok` when everything is healthy
  - `check!/0` raises when a check fails (e.g., State is dead)
- `test/muse/dev_reloader_test.exs`
  - `status/0` returns generation
  - `reload/0` handles compile success
  - `reload/0` handles compile failure without killing app
  - `rollback/0` restores previous generation
  - Health check failure triggers rollback

**Acceptance:** `mix muse` starts with `Hot reload: enabled`. Editing a watched `.ex` file triggers reload. Compile failure keeps old code. `/rollback` works. `/reload-status` shows info.

---

### Step 8 — Minimal Web UI

**Goal:** Phoenix + LiveView page showing workspace, events, input form, reload status.

**Files to create:**
- `lib/muse_web.ex`
- `lib/muse_web/endpoint.ex`
- `lib/muse_web/router.ex`
- `lib/muse_web/live/home_live.ex`
- `assets/js/app.js`
- `assets/css/app.css`

**Endpoint design:**

```elixir
defmodule MuseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :muse

  socket "/live", Phoenix.LiveView.Socket
  plug Plug.Static, at: "/", from: :muse, gzip: false, only: ~w(assets)

  plug Plug.Session,
    store: :cookie,
    key: "_muse_key",
    signing_salt: "dev-salt"

  plug MuseWeb.Router
end
```

**Router design:**

```elixir
defmodule MuseWeb.Router do
  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", MuseWeb do
    pipe_through :browser
    live "/", HomeLive
  end
end
```

**HomeLive design:**

```elixir
defmodule MuseWeb.HomeLive do
  use MuseWeb, :live_view

  def mount(_params, _session, socket) do
    state = Muse.State.get()
    if connected?(socket), do: Muse.State.subscribe()
    {:ok, assign(socket, state: state, input: "")}
  end

  def handle_event("submit", %{"text" => text}, socket) do
    try do
      Muse.submit(:web, text)
      {:noreply, assign(socket, input: "")}
    rescue
      e ->
        {:noreply, put_flash(socket, :error, inspect(e))}
    end
  end

  def handle_info({:muse_event, event}, socket) do
    state = Muse.State.get()
    {:noreply, assign(socket, state: state)}
  end

  def render(assigns) do
    # Minimal HEEx template:
    # - workspace root
    # - event list
    # - text input + submit button
    # - reload status
  end
end
```

**Assets:**
- `assets/js/app.js` — minimal Phoenix LiveView socket connect
- `assets/css/app.css` — minimal plain CSS, no Tailwind

**Tests to create:**
- `test/muse_web/live/home_live_test.exs`
  - LiveView renders workspace
  - LiveView renders existing events
  - Form submit appends events

**Acceptance:** `mix muse --web-only` starts `http://127.0.0.1:4000`. Page shows workspace, events, input form, reload status. Submitting calls `Muse.submit(:web, text)`.

---

### Step 9 — Wire CLI + Web Together

**Goal:** Default `mix muse` starts both. Events are shared.

**This is already wired by the architecture** — both CLI and web call `Muse.submit/2`, which goes through `Muse.State`, which broadcasts via PubSub. The CLI subscribes through `/events`, and the LiveView subscribes on mount.

**Verification:**
1. Start `mix muse`
2. Type in CLI `muse> hello` → see response in CLI
3. Open browser `http://127.0.0.1:4000` → see events from CLI input
4. Submit from web → see events in CLI `/events`
5. Confirm startup banner:
   ```
   Muse started
   Workspace: /absolute/path
   CLI: enabled
   Web: http://127.0.0.1:4000
   Hot reload: enabled
   ```

**Acceptance:** Events flow bidirectionally. Startup banner is correct.

---

### Step 10 — Escript Entrypoint + Mix Task

**Goal:** `mix escript.build && ./muse --no-web` works. `mix muse` works.

**Files to create/modify:**
- `lib/muse/cli/main.ex`
- `lib/mix/tasks/muse.ex`

**Escript entrypoint:**

```elixir
defmodule Muse.CLI.Main do
  def main(args) do
    Application.put_env(:muse, :boot_args, args)
    Application.put_env(:muse, :source_mode?, false)
    {:ok, _apps} = Application.ensure_all_started(:muse)
    Process.sleep(:infinity)
  end
end
```

**Mix task:**

```elixir
defmodule Mix.Tasks.Muse do
  use Mix.Task

  @shortdoc "Start Muse coding agent"

  def run(args) do
    Application.put_env(:muse, :boot_args, args)
    Application.put_env(:muse, :source_mode?, true)
    {:ok, _apps} = Application.ensure_all_started(:muse)
    Process.sleep(:infinity)
  end
end
```

**mix.exs escript config:**

```elixir
defp escript do
  [main_module: Muse.CLI.Main, name: "muse"]
end
```

**Acceptance:** `mix muse` starts CLI + web. `mix escript.build && ./muse --no-web` starts CLI only.

---

### Step 11 — Application Supervisor Wiring

**Goal:** `Muse.Application` reads boot options, starts correct children, prints banner.

**File to modify:** `lib/muse/application.ex`

**Supervisor children:**

```elixir
def start(_type, _args) do
  argv = Muse.Argv.get()
  opts = Muse.BootOptions.parse!(argv)

  if opts.help?, do: print_help_and_exit()

  children = base_children(opts) ++
             maybe_cli_child(opts) ++
             maybe_web_child(opts) ++
             maybe_dev_reloader_child(opts)

  print_banner(opts)

  Supervisor.start_link(children, strategy: :one_for_one, name: Muse.Supervisor)
end

defp base_children(opts) do
  [
    {Task.Supervisor, name: Muse.TaskSupervisor},
    {Phoenix.PubSub, name: Muse.PubSub},
    {Muse.Workspace, root: opts.workspace},
    Muse.State
  ]
end

defp maybe_cli_child(%{cli?: true} = opts), do: [{Muse.CLI.Repl, opts}]
defp maybe_cli_child(_), do: []

defp maybe_web_child(%{web?: true} = opts) do
  [{MuseWeb.Endpoint, server: true, http: [ip: {127,0,0,1}, port: opts.port]}]
end
defp maybe_web_child(_), do: []

defp maybe_dev_reloader_child(%{watch?: true} = opts) do
  if Application.get_env(:muse, :source_mode?, false) do
    [{Muse.DevReloader, opts}]
  else
    []
  end
end
defp maybe_dev_reloader_child(_), do: []
```

**Banner:**

```
Muse started
Workspace: /absolute/path
CLI: enabled
Web: http://127.0.0.1:4000
Hot reload: enabled
```

Variations:
- CLI only: `Web: disabled`
- Web only: `CLI: disabled`
- No watch: `Hot reload: disabled`

**Acceptance:** Startup banner matches mode. Correct children start. Workspace is captured once.

---

### Step 12 — Optional Dev Wrapper + Install Script

**Goal:** Developer can run `muse` from any project directory, executing the source version.

**Files to create:**
- `bin/muse` (template, not the actual installed wrapper)
- `script/install-dev` (generates installed wrapper)

**install-dev script:**

```bash
#!/usr/bin/env sh
set -eu

MUSE_SRC="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$HOME/.local/bin/muse}"

cat > "$TARGET" <<WRAPPER
#!/usr/bin/env sh
set -eu
export MUSE_WORKSPACE="\${MUSE_WORKSPACE:-\$(pwd)}"
cd "$MUSE_SRC"
exec mix muse \$@
WRAPPER

chmod +x "$TARGET"
echo "Installed muse dev wrapper → $TARGET"
```

**README should document:**
```bash
cd ~/projects/muse
./script/install-dev

# Then from any project:
cd ~/projects/my_app
muse           # runs source version, workspace = ~/projects/my_app
```

**Acceptance:** `script/install-dev` creates a working `muse` wrapper that preserves the user's cwd as workspace.

---

### Step 13 — README

**Goal:** Document everything a new user needs.

**Sections:**
1. What is Muse?
2. Quick Start
   - `mix deps.get && mix muse`
3. Commands
   - `mix muse`, `mix muse --no-web`, `mix muse --web-only`, etc.
4. CLI Commands
   - `/help`, `/events`, `/workspace`, `/reload`, `/rollback`, `/reload-status`, `/quit`
5. Building escript
   - `mix escript.build && ./muse`
6. Installing escript
   - `mix escript.install` + add `~/.mix/escripts` to `$PATH`
7. Dev wrapper
   - `./script/install-dev`
8. Architecture overview
   - CLI and Web both call `Muse.submit/2`
   - Shared state via `Muse.State` + PubSub
   - Dev reloader for source-mode hot reload

**Acceptance:** A new developer can read the README and get running in under 5 minutes.

---

## Test Summary

| Module            | Key Tests                                              |
|-------------------|--------------------------------------------------------|
| BootOptions       | defaults, --no-web, --web-only, --no-cli, --port, --workspace, --no-watch, --help, invalid |
| Workspace         | root is absolute, resolve inside, resolve outside raises |
| Event             | new/3 creates struct with all fields                  |
| State             | initial empty, append stores, append broadcasts        |
| Muse (submit/2)   | appends user event, appends assistant event, returns text |
| Health            | check! returns :ok when healthy, raises on failure     |
| DevReloader       | status, reload success, reload failure, rollback       |
| HomeLive          | renders workspace, renders events, submit appends     |

---

## Definition of Done

- [ ] `mix muse` starts CLI + web
- [ ] `mix muse --no-web` starts CLI only
- [ ] `mix muse --web-only` starts web only
- [ ] `mix muse --port 4100` starts web on port 4100
- [ ] `mix muse --workspace /tmp/example` uses /tmp/example
- [ ] `mix muse --no-watch` disables dev reloader
- [ ] `mix escript.build && ./muse --no-web` works
- [ ] CLI prompt shows `muse>`
- [ ] Startup banner shows workspace, CLI status, web status, hot reload status
- [ ] CLI and web share same in-memory events
- [ ] Editing a watched source file triggers hot reload
- [ ] Compile failure → old code keeps running
- [ ] Health check failure → rollback
- [ ] No real AI required; placeholder response is sufficient
- [ ] All tests pass: `mix test`

---

## Risks & Mitigations

| Risk                                   | Mitigation                                        |
|----------------------------------------|---------------------------------------------------|
| Dev reloader breaks itself             | Exclude its own module + Application from auto-reload |
| CLI REPL IO.gets blocks GenServer      | Use spawn_link, not GenServer, for the REPL loop  |
| Escript can't include Phoenix assets   | For escript mode, serve minimal inline HTML       |
| PubSub not started before State        | Order supervisor children: PubSub before State    |
| Workspace race on boot                 | Capture workspace before starting supervisor      |
| Hot reload misses process state changes| Document limitation; appup/relup is future scope  |

---

## Implementation Order (Priority)

```
Step 1  → Scaffold
Step 2  → Boot options + Argv
Step 3  → Workspace
Step 4  → Event + State
Step 5  → Muse.submit/2
Step 6  → CLI REPL
Step 7  → Dev Reloader + Health
Step 8  → Web UI
Step 9  → Wire CLI + Web
Step 10 → Escript + Mix Task
Step 11 → Application Supervisor Wiring (iterate with steps 6-10)
Step 12 → Dev Wrapper + Install Script
Step 13 → README
```

> **Note:** Step 11 (Application wiring) is logically intertwined with steps 6-10.
> In practice, you'll build it incrementally: start with base children in Step 1,
> then add CLI child in Step 6, web child in Step 8, reloader child in Step 7.
> Step 11 represents the final polished version of the Application module.
