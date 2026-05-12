# Weft — Bidirectional Agent Tool Bridge

**Status:** Planning  
**Target:** Muse v0.3.0  
**Owner:** asx8678  
**Source:** tidewave_app (Rust/Tauri desktop app, Dashbit/Apache 2.0)

---

## Executive Summary

Weft ports battle-tested agent-to-tool patterns from the companion desktop app (`tidewave`) into Muse, extending the existing `/socket` WebSocket from **read-only event streaming** to a **full bidirectional tool proxy layer**.

Named "Weft" after the horizontal threads in weaving — connecting agent capabilities together. The warp threads are Muse's existing session and conductor architecture; the weft threads are the new channels that let external agents control local tools (browser, files, shell, downloads) through a single WebSocket connection.

## Current State

Muse's external WebSocket at `/socket/websocket` is read-only. Clients can join `session:<id>` topics and receive events ( deltas, tool calls, patch previews). They cannot:

- Send tool calls back to Muse
- Proxy HTTP through Muse
- Watch files or spawn interactive terminals
- Bridge MCP (Model Context Protocol) messages to a browser

Weft closes these gaps by adding Phoenix-style interactive channels alongside the existing read-only session channel.

## Goals

1. **Zero regression:** All 3600+ existing tests pass unchanged
2. **Opt-in by config:** Every new channel is disabled by default
3. **Battle-tested patterns:** Direct ports from tidewave, not reinventions
4. **Unit-testable:** Fake WS transport tests channel handlers without a browser
5. **Secure:** Same token model as external WS; localhost-origin gates where appropriate

## Non-Goals

- Replacing Muse's internal tool loop — Weft is an *external* bridge
- Adding a new transport protocol — Phoenix V2 JSON array format already works
- Real-time collaboration between multiple human users
- Native binary packaging of Muse itself

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│           External Client                │
│  (Browser extension / ACP agent / CLI)   │
└─────────────┬───────────────────────────┘
              │ Phoenix V2 WS
              ▼
┌─────────────────────────────────────────┐
│    MuseWeb.Endpoint /socket/websocket   │
│         (existing, read-only)             │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│      Muse.Weft.Connection (new)         │
│   - heartbeat, dispatch_join, cleanup   │
│   - manages channel tasks + panics      │
└─────────────┬───────────────────────────┘
              │
    ┌─────────┼─────────┬─────────┬────────┐
    ▼         ▼         ▼         ▼        ▼
 session:*  mcp:*     watch:*  terminal:*  exec:*
 (existing)  (new)     (new)    (new)     (new)
```

### Module Namespace

All new code lives under `Muse.Weft.*`:

| Module | Purpose |
|--------|---------|
| `Muse.Weft.Connection` | WS handler, dispatch, heartbeat, cleanup |
| `Muse.Weft.Sender` | `ChannelSender` — wraps push API with topic/join_ref |
| `Muse.Weft.Dispatch` | `dispatch_join/4`, `reply_init/3` |
| `Muse.Weft.Behaviour` | Channel handler behaviour (init callback) |
| `Muse.Weft.Channels.McpChannel` | MCP reverse proxy WS channel |
| `Muse.Weft.Endpoints.McpClientHandler` | HTTP POST bridge for MCP |
| `Muse.Weft.Proxy.Http` | Smart HTTP proxy |
| `Muse.Weft.Proxy.Download` | Download + extract service |
| `Muse.Weft.Channels.WatchChannel` | File system watching |
| `Muse.Weft.Channels.TerminalChannel` | PTY shell over WS |
| `Muse.Weft.ProcessGroup` | Process tree cleanup (Unix/Windows) |

---

## Epic Breakdown

### P0 — Foundation & MCP (Must-have for v0.3.0)

#### Epic 1: Channel Dispatch & Interactive WS (`muse-weft.1`)

Port the core channel abstraction from tidewave-core:

- **Channel dispatch** (`connection.rs`): `dispatch_join/4` routes by topic prefix (`mcp:*`, `watch:*`, `terminal:*`, `exec:*`). Unknown topics get `phx_reply` error.
- **InitResult** (`phoenix.rs`): `Done` → `phx_close`, `Error` → `phx_reply` error, `Shutdown` → `phx_error` (triggers client rejoin).
- **ChannelSender** (`ws/mod.rs`): wraps an `UnboundedSender` with `topic` and `join_ref`, providing a clean `push(event, payload)` API.
- **Connection handler** (`connection.rs`): unit-testable WS handler that spawns channel tasks, detects panics via `JoinSet`, handles heartbeats, and cleans up on disconnect.
- **Fake WS transport** (`tests/common/mod.rs`): `(out_tx, out_rx, in_tx, in_rx)` mpsc pairs simulate a WebSocket for unit tests. Helpers: `send_phoenix_msg/2`, `recv_phoenix_msg/1`, `wait_for_event/3`, `wait_for_reply/2`.

**Key files in Muse:**
- `lib/muse/weft/dispatch.ex`
- `lib/muse/weft/connection.ex`
- `lib/muse/weft/sender.ex`
- `lib/muse/weft/behaviour.ex`
- `test/support/weft/fake_ws_transport.ex`

#### Epic 2: MCP Reverse Proxy Bridge (`muse-weft.2`)

Port the MCP reverse proxy from `tidewave-core/src/ws/mcp.rs`.

MCP (Model Context Protocol) is a JSON-RPC 2.0 protocol for tool discovery and invocation. Muse tools that need browser access (e.g., `browser_eval`, `screenshot`) can delegate to a browser extension via this bridge.

**Flow:**
1. Browser joins `mcp:<session_id>` WS channel.
2. Browser registers as the MCP server for that session.
3. Muse tool (or ACP agent) sends JSON-RPC to `POST /socket/mcp-remote-client?sessionId=<id>`.
4. HTTP handler looks up the session's `ChannelSender`, pushes the message to the browser.
5. Browser replies via WS `mcp_message` event; reply is routed back to the HTTP caller via oneshot channel.

**State:**
- `McpChannelState.sessions` — `DashMap<String, ChannelSender>` (session registry)
- `McpChannelState.awaiting_answers` — `DashMap<(session_id, id), oneshot::Sender<Value>>` (pending requests)

**Error cases:**
- Missing session → JSON-RPC error response with code `-32000`, message "Browser is not connected"
- Malformed JSON → HTTP 400
- Notification (no `id`) → HTTP 202 Accepted, no body
- Response channel closed → HTTP 500

**Key files in Muse:**
- `lib/muse/weft/channels/mcp_channel.ex`
- `lib/muse/weft/endpoints/mcp_client_handler.ex`

### P1 — Proxy & Interactive Channels (Should-have for v0.3.0)

#### Epic 3: HTTP Proxy & Download Service (`muse-weft.3`)

Port from `tidewave-core/src/http_handlers.rs`.

**HTTP Proxy:**
- `POST /proxy?url=<target>`
- Forwards method, headers, body
- Auto-retries `*.localhost` → `127.0.0.1` on connection failure
- Detects TLS cert errors (`NotValidForName`, `InvalidCertificate`, `ConnectionRefused`) and returns typed `X-Weft-Error` headers instead of raw connection errors
- Uses `Req` library

**Download Service:**
- `GET /download?key=<key>&url=<url>&extract=<path>`
- Concurrent download sharing: one download, N subscribers (broadcast channel)
- Progress streaming as NDJSON
- Extraction: `tar.gz`, `tgz`, `zip` with path traversal protection
- Temp file cleanup on crash
- Unix permission preservation

**Key files in Muse:**
- `lib/muse/weft/proxy/http.ex`
- `lib/muse/weft/proxy/download.ex`

#### Epic 4: File Watching & Interactive Channels (`muse-weft.4`)

**File Watching** (`tidewave-core/src/ws/watch.rs`):
- Topic: `watch:<ref>`
- Uses Elixir `FileSystem` library (wraps `fs` NIF)
- Broadcast channel: one underlying watcher, N subscribers
- Path normalization
- Rename coalescing (`From` + `To` → `Renamed` event)
- Native + poll fallback

**PTY Terminal** (`tidewave-core/src/ws/terminal.rs`):
- Topic: `terminal:<ref>`
- Interactive PTY shell via Elixir `Port` or `:ssh`
- Events: `input`, `output`, `resize`
- One PTY per join, cleaned up on disconnect

**Key files in Muse:**
- `lib/muse/weft/channels/watch_channel.ex`
- `lib/muse/weft/channels/terminal_channel.ex`

### P2 — Process Execution Hardening (Could-have for v0.3.0)

#### Epic 5: Process Execution Hardening (`muse-weft.5`)

Port from `tidewave-core/src/command.rs`.

**Process Group Management:**
- Ensure `LocalRunner` creates process groups on Unix (`process_group(0)`)
- Kill/cancel terminates the child process tree (`kill(-pid, SIGKILL)`)
- Windows: job object support (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) prevents orphan processes

**AppImage Environment Cleanup:**
- Detect `APPIMAGE` env var
- Strip 20+ injected env vars: `APPDIR`, `LD_LIBRARY_PATH`, `GTK_*`, `QT_PLUGIN_PATH`, etc.
- Filter AppImage mount paths from `PATH` and `XDG_DATA_DIRS`

**Key files in Muse:**
- `lib/muse/weft/process_group.ex`
- Patches to `lib/muse/execution/local_runner.ex`

---

## Source Analysis: tidewave_app

### File Inventory

| File | Size | Purpose |
|------|------|---------|
| `tidewave-core/src/ws/connection.rs` | 10.3 KB | WS handler, dispatch, channel lifecycle |
| `tidewave-core/src/ws/mod.rs` | 3.6 KB | `ChannelSender`, `WsState` |
| `tidewave-core/src/ws/mcp.rs` | 8.1 KB | MCP reverse proxy channel + HTTP bridge |
| `tidewave-core/src/ws/watch.rs` | 19.4 KB | File watching with rename coalescing |
| `tidewave-core/src/ws/terminal.rs` | 9.4 KB | PTY shell over WS |
| `tidewave-core/src/ws/acp.rs` | 92.4 KB | ACP proxy (out of scope for Weft v1) |
| `tidewave-core/src/ws/upload.rs` | 3.3 KB | File upload (out of scope for Weft v1) |
| `tidewave-core/src/http_handlers.rs` | 37.9 KB | Proxy + download handlers |
| `tidewave-core/src/command.rs` | 10.3 KB | Process group + AppImage cleanup |
| `tidewave-core/src/phoenix.rs` | 9.3 KB | `PhxMessage`, `InitResult`, wire format |
| `tidewave-core/tests/common/mod.rs` | ~2 KB | Fake WS transport helpers |

### Key Patterns to Port

1. **Phoenix V2 wire format** — JSON array `[join_ref, ref, topic, event, payload]`. Already used by Muse's read-only WS; Weft extends it to interactive events.
2. **Channel as async task** — Each `phx_join` spawns a channel handler task. Dropping the incoming sender signals cleanup. Panics detected via `JoinSet`.
3. **State-per-feature** — `WsState` is a struct of feature states (`watch`, `acp`, `mcp`). Each feature manages its own concurrent state (e.g., `DashMap` for sessions).
4. **Oneshot request/response** — MCP bridge uses `tokio::sync::oneshot` to match HTTP POST requests with WS replies from the browser.
5. **Broadcast downloads** — One download task, N waiting HTTP requests, progress streamed as NDJSON.

### Patterns to Adapt (Rust → Elixir)

| Rust Pattern | Elixir Equivalent |
|--------------|-------------------|
| `tokio::sync::mpsc::unbounded_channel` | `Phoenix.PubSub` or plain `GenServer` cast |
| `DashMap<String, ChannelSender>` | `Registry` or `:ets` table |
| `tokio::sync::oneshot` | `Task` + `Agent` or `GenServer.call` |
| `JoinSet` (panic detection) | `Task` + `Process.monitor` or `Task.yield_many` |
| `tokio::spawn` | `Task.Supervisor.start_child` |
| `process_group(0)` | `Port.open` with `{:group, 0}` or `System.cmd` with `[:group, 0]` |
| Windows job object | `Muse.Weft.ProcessGroup` (conditional compilation) |

---

## Testing Strategy

### Fake WS Transport

The fake transport is the linchpin of unit-testability. It creates two pairs of mpsc channels:

```elixir
{out_tx, out_rx} = Channel.pair()   # → channel handler sees this as ws_receiver
{in_tx, in_rx} = Channel.pair()     # → test sends messages here, reads replies from out_rx
```

A test can:
1. `send_phoenix_msg(fake, phx_join)`
2. `wait_for_reply(fake)` → asserts `ok_reply`
3. `send_phoenix_msg(fake, event)`
4. `wait_for_event(fake, "mcp_message", 5000)`

### End-to-End Smoke Tests

- MCP: Start a fake browser WS client → HTTP POST → assert JSON-RPC response round-trip
- Proxy: `POST /proxy?url=http://localhost:4001` → assert forwarded response
- Download: `GET /download?key=test&url=<fixture>&extract=/tmp/out` → assert extracted files
- Watch: Join `watch:test` → touch file → assert `modified` event
- Terminal: Join `terminal:test` → send `input` → assert `output` event

### Regression Guard

- All existing 3600+ tests must pass unchanged before any Weft epic closes
- New channels are gated by config (`config :muse, :weft, enabled_channels: [...]`)
- Default config: `enabled_channels: []` (all new channels disabled)

---

## Security Model

1. **Token auth:** External WS already requires a token. New channels inherit this.
2. **Localhost gate:** HTTP proxy and download endpoints require `localhost` origin or token auth.
3. **Path traversal:** Download extraction validates archive entries. Watch channel normalizes paths.
4. **No shell interpolation:** Process execution uses argv-vector, same as existing `LocalRunner`.
5. **Opt-in:** All new channels disabled by default. Admin must explicitly enable.
6. **Session isolation:** MCP sessions are keyed by `session_id`; no cross-session leakage.

---

## Rollout Plan

### Phase 0: Foundation (Week 1)
- `muse-weft.1.1` — Fake WS transport
- `muse-weft.1.2` — Channel dispatch, InitResult, ChannelSender
- Merge foundation into main; all tests pass

### Phase 1: MCP Bridge (Week 2)
- `muse-weft.2.1` — MCP channel + session registry
- `muse-weft.2.2` — HTTP POST bridge
- End-to-end smoke with fake browser client

### Phase 2: Proxy & Interactive (Week 3–4)
- `muse-weft.3` — HTTP proxy + download
- `muse-weft.4` — File watching + terminal
- Each epic is independent after foundation

### Phase 3: Hardening (Week 5, optional)
- `muse-weft.5` — Process group + AppImage cleanup
- Patch existing `LocalRunner`

---

## BD Issues

| ID | Title | Priority | Type |
|----|-------|----------|------|
| `muse-weft` | Weft — Bidirectional Agent Tool Bridge | P1 | Epic |
| `muse-weft.1` | Foundation — Channel Dispatch & Interactive WS | P1 | Epic |
| `muse-weft.1.1` | Fake WebSocket transport for channel unit tests | P1 | Task |
| `muse-weft.1.2` | Channel dispatch abstraction | P1 | Task |
| `muse-weft.2` | MCP Reverse Proxy Bridge | P1 | Epic |
| `muse-weft.2.1` | MCP channel init & session registry | P1 | Task |
| `muse-weft.2.2` | HTTP POST handler for MCP remote client requests | P1 | Task |
| `muse-weft.3` | HTTP Proxy & Download Service | P2 | Epic |
| `muse-weft.4` | File Watching & Interactive Channels | P2 | Epic |
| `muse-weft.5` | Process Execution Hardening | P3 | Epic |

---

## Appendix: Phoenix V2 Wire Format Cheat Sheet

Client → Server (join):
```json
["1", "1", "mcp:session-123", "phx_join", {}]
```

Server → Client (ok reply):
```json
["1", "1", "mcp:session-123", "phx_reply", {"status": "ok", "response": {}}]
```

Server → Client (push event):
```json
["1", null, "mcp:session-123", "mcp_message", {"jsonrpc": "2.0", "id": 1, "result": {}}]
```

Heartbeat:
```json
[null, "3", "phoenix", "heartbeat", {}]
[null, "3", "phoenix", "phx_reply", {"status": "ok", "response": {}}]
```
