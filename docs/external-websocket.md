# Muse External WebSocket Client Contract

> **Companion docs:** [Architecture](architecture.md) · [Security](security.md) · [Executive Summary](../PLAN.md)
>
> **PR16 scope:** Optional Phoenix channel for non-LiveView external clients. LiveView already streams through Phoenix; this channel serves CLI integrations, third-party UIs, and automation clients.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Connection & Authentication](#2-connection--authentication)
3. [Channel Topics & Joining](#3-channel-topics--joining)
4. [JSON Envelope Specification](#4-json-envelope-specification)
5. [Delivered Event Types](#5-delivered-event-types)
6. [Negative Contract — What Is Never Delivered](#6-negative-contract--what-is-never-delivered)
7. [Sample Filters & Replay](#7-sample-filters--replay)
8. [Connection Examples](#8-connection-examples)
9. [Integration Checklist for PR16 Merge](#9-integration-checklist-for-pr16-merge)

---

## 1. Overview

The external WebSocket channel (`MuseWeb.SessionChannel`) provides real-time event streaming for clients that cannot use Phoenix LiveView. It subscribes to `Muse.PubSub` and forwards **only** visibility-filtered, redacted events to connected clients.

**Key properties:**

- Read-only event stream — clients observe, they do not control the runtime
- No tool/write/shell permissions are granted to WebSocket clients
- Events are filtered by visibility before leaving the server
- Payloads pass through `Muse.EventPayloadRedactor` before serialization
- Channel process subscribes to `Muse.State` and forwards matching events

**Boundaries:**

| Concern | Client Responsibility | Server Responsibility |
|---|---|---|
| Reconnect / backoff | Client | — |
| Event ordering (seq) | Client (reorder by `seq`) | Server sends monotonic `seq` |
| Deduplication | Client | Server assigns unique `id` per event |
| Secret redaction | — | Server redacts before sending |
| Visibility filtering | — | Server drops `:debug` / `:internal` / `:sensitive` |
| Replay after disconnect | Client (request via `replay` push) | Server serves from `Muse.State` |
| Approval decisions | Client sends via `/approve` CLI or LiveView | Channel is read-only |

---

## 2. Connection & Authentication

### Endpoint

The WebSocket endpoint is mounted at `/socket` in `MuseWeb.Endpoint`.

```text
ws://127.0.0.1:4000/socket/websocket
wss://127.0.0.1:4000/socket/websocket   # TLS in production
```

> **Security requirement (see [security.md](security.md) §1):** The web server binds to `127.0.0.1` by default. External exposure requires explicit configuration and authentication.

### Authentication

PR16 ships with localhost-only access by default. When exposed externally:

1. **Token-based** — pass a token in `params` on connect:
   ```json
   {"token": "muse_ws_<hex>"}
   ```
   The server validates the token against a configured allowlist. Tokens are not API keys — they are short-lived WebSocket-specific credentials.

2. **No token = reject** — unauthenticated connections are rejected when auth is configured.

### Connect Parameters

```json
{
  "token": "muse_ws_abc123",
  "session_id": "sess_a1b2c3",
  "filters": {
    "visibility": ["user"],
    "types": ["assistant_delta", "plan_created", "plan_approved", "turn_completed"]
  }
}
```

| Parameter | Required | Description |
|---|---|---|
| `token` | Conditional | Auth token (required when auth is enabled) |
| `session_id` | No | Default session to subscribe to on connect |
| `filters` | No | Pre-join event type filter (see §7) |

---

## 3. Channel Topics & Joining

### Topic Format

```text
session:<session_id>
```

Clients join a specific session's channel to receive events for that session.

### Join Flow

```
Client → Server:  phx_join  "session:sess_a1b2c3"  {}
Server → Client:  phx_reply  ref  {"status": "ok", "response": {"session_id": "sess_a1b2c3", "last_seq": 42}}
```

On successful join, the server:
1. Subscribes the channel process to `Muse.PubSub` for `Muse.State` events
2. Returns the current `last_seq` so the client can request replay from that point
3. Begins forwarding real-time events matching the session and visibility filter

### Join Reply Envelope

```json
{
  "status": "ok",
  "response": {
    "session_id": "sess_a1b2c3",
    "last_seq": 42,
    "muse_ids": ["planning_muse", "coding_muse"],
    "session_status": "idle"
  }
}
```

### Error Replies

| Status | Reason |
|---|---|
| `error` | `session_not_found` — session does not exist |
| `error` | `unauthorized` — token missing or invalid |
| `error` | `rate_limited` — too many join attempts |

---

## 4. JSON Envelope Specification

Every event pushed to the client uses this envelope:

```json
{
  "type": "<event_type>",
  "id": 9001,
  "timestamp": "2025-05-27T14:32:01.456Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 17,
  "source": "planning_muse",
  "muse_id": "planning_muse",
  "visibility": "user",
  "payload": {}
}
```

| Field | Type | Description |
|---|---|---|
| `type` | string | Event type (see §5) |
| `id` | integer | Monotonically-increasing event ID (unique within node) |
| `timestamp` | ISO 8601 | UTC timestamp |
| `session_id` | string \| null | Session this event belongs to |
| `turn_id` | string \| null | Turn this event belongs to |
| `seq` | integer \| null | Session-local monotonic sequence number |
| `source` | string | Event source atom (e.g. `"planning_muse"`, `"conductor"`) |
| `muse_id` | string \| null | Muse profile that produced this event |
| `visibility` | string | Always `"user"` for external clients |
| `payload` | object | Type-specific payload (see §5 for schemas) |

> **Invariant:** The `visibility` field is always `"user"` on the external channel. If any other value appears, it is a server bug.

---

## 5. Delivered Event Types

Only events with `visibility: :user` are forwarded. The following event types are delivered to external clients:

### 5.1 `assistant_delta` — Streaming Text Chunk

Emitted during streaming model responses. Clients concatenate deltas by `seq` order within a `turn_id`.

```json
{
  "type": "assistant_delta",
  "id": 9010,
  "timestamp": "2025-05-27T14:32:02.100Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 18,
  "source": "planning_muse",
  "muse_id": "planning_muse",
  "visibility": "user",
  "payload": {
    "text": "I'll inspect the CLI command structure",
    "streamed": true
  }
}
```

### 5.2 `assistant_message` — Final Assistant Message

Emitted when a complete assistant message is ready. When `streamed: true`, the full text was already sent as deltas; the final message is informational.

```json
{
  "type": "assistant_message",
  "id": 9015,
  "timestamp": "2025-05-27T14:32:05.500Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 22,
  "source": "planning_muse",
  "muse_id": "planning_muse",
  "visibility": "user",
  "payload": {
    "text": "I'll inspect the CLI command structure, find the project version source, create an implementation plan, and wait for approval before changes.",
    "streamed": true
  }
}
```

### 5.3 `user_message` — User Input Echo

Emitted when the user submits input to the session.

```json
{
  "type": "user_message",
  "id": 9005,
  "timestamp": "2025-05-27T14:32:00.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 15,
  "source": "cli",
  "muse_id": null,
  "visibility": "user",
  "payload": {
    "text": "add a /version command"
  }
}
```

### 5.4 `plan_created` — Plan Produced by Planning Muse

Emitted when the Planning Muse produces a structured plan. The full plan body is not included — use the `/plan` CLI command or LiveView for details.

```json
{
  "type": "plan_created",
  "id": 9020,
  "timestamp": "2025-05-27T14:32:10.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 25,
  "source": "planning_muse",
  "muse_id": "planning_muse",
  "visibility": "user",
  "payload": {
    "plan_id": "plan_c4d5e6",
    "objective": "Add a /version command",
    "task_count": 5,
    "summary": "Locate CLI routing, add /version handler, source version from mix.exs, add tests, run verification."
  }
}
```

### 5.5 `plan_approved` — Plan Approved by User

Emitted when the user approves a plan. **Important:** Plan approval records a decision only; it does not start implementation.

```json
{
  "type": "plan_approved",
  "id": 9030,
  "timestamp": "2025-05-27T14:32:30.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 30,
  "source": "approval_gate",
  "muse_id": null,
  "visibility": "user",
  "payload": {
    "plan_id": "plan_c4d5e6",
    "plan_version": 1,
    "approved_by": "user",
    "note": "Plan approved; implementation requires separate patch-proposal gate."
  }
}
```

### 5.6 `plan_rejected` — Plan Rejected by User

```json
{
  "type": "plan_rejected",
  "id": 9030,
  "timestamp": "2025-05-27T14:32:30.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 30,
  "source": "approval_gate",
  "muse_id": null,
  "visibility": "user",
  "payload": {
    "plan_id": "plan_c4d5e6",
    "rejected_by": "user",
    "note": "Plan rejected; Planning Muse may revise."
  }
}
```

### 5.7 `approval_requested` — Approval Gate Activated

Emitted when the runtime enters `:awaiting_approval` state.

```json
{
  "type": "approval_requested",
  "id": 9025,
  "timestamp": "2025-05-27T14:32:12.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 27,
  "source": "approval_gate",
  "muse_id": null,
  "visibility": "user",
  "payload": {
    "kind": "plan",
    "id": "approval_x1y2z3",
    "plan_id": "plan_c4d5e6",
    "note": "Awaiting plan approval."
  }
}
```

### 5.8 `approval_approved` / `approval_rejected` — Approval Decision Recorded

```json
{
  "type": "approval_approved",
  "id": 9035,
  "timestamp": "2025-05-27T14:32:35.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 32,
  "source": "approval_gate",
  "muse_id": null,
  "visibility": "user",
  "payload": {
    "kind": "plan",
    "id": "approval_x1y2z3",
    "plan_id": "plan_c4d5e6"
  }
}
```

### 5.9 `turn_completed` — Turn Finished

Emitted when a turn reaches `:completed` status.

```json
{
  "type": "turn_completed",
  "id": 9040,
  "timestamp": "2025-05-27T14:32:40.000Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 35,
  "source": "conductor",
  "muse_id": null,
  "visibility": "user",
  "payload": {
    "status": "completed",
    "streamed": true,
    "tool_call_count": 3,
    "duration_ms": 4250
  }
}
```

---

## 6. Negative Contract — What Is Never Delivered

The following categories of events are **never** forwarded to external WebSocket clients. This is enforced server-side in the channel; it is not merely a client-side filter.

### 6.1 Never-Delivered Visibility Levels

| Visibility | Meaning | Delivered? |
|---|---|---|
| `:user` | Safe for all surfaces | ✅ Yes |
| `:debug` | Event/debug log only | ❌ **Never** |
| `:internal` | Persisted but not shown | ❌ **Never** |
| `:sensitive` | Should not be stored unredacted | ❌ **Never** |

### 6.2 Never-Delivered Event Types

These event types are internal-only and must never appear on the external channel:

| Event Type | Why It's Internal |
|---|---|
| `provider_request` | Contains model config, headers, potentially API endpoints |
| `provider_response` | Raw provider output, may include unredacted tool schemas |
| `provider_error` | May leak API error details, auth failure reasons |
| `tool_result` | May contain file contents from secret paths |
| `prompt_assembled` | Contains full assembled prompt including hidden layers |
| `session_persisted` | Internal persistence event |
| `checkpoint_created` | Internal checkpoint event |
| `self_healing_*` | Internal repair events |

### 6.3 Never-Delivered Data Fields

Even within delivered event types, these fields are **stripped** before serialization:

| Field | Reason |
|---|---|
| `api_key` | Secret credential |
| `authorization` / `bearer` | Auth headers |
| `provider_config` | Model config with potentially sensitive endpoints |
| `raw_provider_output` | Unprocessed provider JSON |
| `prompt_layers` | Full prompt assembly (hidden layers must stay hidden) |
| `tool_spec` | Internal tool specification details |

### 6.4 No Permissions Granted

The external WebSocket channel is **strictly read-only**. Connecting to it does **not** grant:

- ❌ Tool execution permissions (no `write`, `shell`, `network`, `delete`)
- ❌ Approval authority (approvals come from CLI `/approve` or LiveView only)
- ❌ Session control (cannot create/destroy sessions or modify state)
- ❌ Patch apply capability
- ❌ Shell command execution
- ❌ Network access

The `ApprovalGate.denied_scopes` (`:patch`, `:write`, `:shell`, `:shell_command`, `:network`, `:delete`, `:restore`, `:restore_checkpoint`, `:remote_execution`) are never granted to WebSocket clients.

### 6.5 Negative Test Cases

These payloads must **never** appear on the external channel. If they do, it's a security bug:

```json
// ❌ NEVER: Internal provider debug event with auth header
// (Raw form before redaction — server must drop the entire event)
{
  "type": "provider_error",
  "visibility": "debug",
  "payload": {
    "error": "Authorization: Bearer [CREDENTIAL — would be redacted if stored]",
    "status": 401
  }
}

// ❌ NEVER: Sensitive visibility event with raw prompt
// (Entire event is dropped by visibility filter, never reaches channel)
{
  "type": "prompt_assembled",
  "visibility": "sensitive",
  "payload": {
    "system_prompt": "[FULL HIDDEN PROMPT — internal only]",
    "api_key": "[CREDENTIAL — would be redacted if stored]"
  }
}

// ❌ NEVER: Internal tool result containing file content from a secret path
// (Visibility :internal blocks forwarding; secret paths are workspace-blocked)
{
  "type": "tool_result",
  "visibility": "internal",
  "payload": {
    "tool": "read_file",
    "path": ".env",
    "content": "[SECRET FILE CONTENT — blocked by workspace policy]"
  }
}

// ❌ NEVER: Self-healing internal event
// (Visibility :internal blocks forwarding)
{
  "type": "self_healing_attempt",
  "visibility": "internal",
  "payload": {
    "issue_id": "beads-123",
    "repair_action": "restart_turn"
  }
}
```

---

## 7. Sample Filters & Replay

### 7.1 Join-Time Filters

Clients can pre-filter events when joining a channel:

```json
// Only stream text deltas and plan lifecycle
{
  "filters": {
    "types": ["assistant_delta", "plan_created", "plan_approved", "plan_rejected"]
  }
}
```

```json
// Only plan approval lifecycle events
{
  "filters": {
    "types": ["plan_created", "plan_approved", "plan_rejected", "approval_requested", "approval_approved", "approval_rejected"]
  }
}
```

```json
// Minimal: only turn completion (heartbeat for automation)
{
  "filters": {
    "types": ["turn_completed"]
  }
}
```

> **Visibility filter is server-enforced.** Clients cannot override the visibility filter — `:debug`, `:internal`, and `:sensitive` events are always dropped regardless of client filters.

### 7.2 Replay After Reconnect

When a client reconnects, it can request replay of missed events using the `replay` push message:

```
Client → Server:  push  "replay"  {"after_seq": 42}
Server → Client:  push  "replay_result"  {"events": [...], "count": 8, "has_more": false}
```

**Replay semantics:**

- Events are replayed from `Muse.State` (bounded to `max_events`, default 1000)
- Only events with `visibility: :user` are included in replay
- Client-side `types` filter from join is applied to replay results
- `after_seq: 0` replays all available events (useful for initial state hydration)
- If `has_more: true`, the client may paginate by calling again with the last received `seq`

### 7.3 Replay Example

```javascript
// Client reconnects and requests events missed since seq 42
channel.push("replay", { after_seq: 42 })
  .receive("ok", (resp) => {
    if (resp.has_more) {
      const lastSeq = resp.events[resp.events.length - 1].seq;
      channel.push("replay", { after_seq: lastSeq });
    }
    resp.events.forEach(processEvent);
  });
```

### 7.4 Chat Message Derivation

For clients that want a chat-like view (similar to CLI/TUI/LiveView), apply the same derivation logic as `Muse.EventStream.chat_messages/1`:

1. Filter to `@chat_event_types`: `user_message`, `assistant_delta`, `assistant_message`, `plan_created`, `plan_approved`, `plan_rejected`, `approval_requested`, `approval_approved`, `approval_rejected`
2. Group by `turn_id` (preserve order of first appearance)
3. Within each turn, sort by `seq`
4. For assistant content: if deltas were streamed (`streamed: true`), concatenate deltas and suppress the final `assistant_message` duplicate
5. Render plan/approval events as system messages with concise summaries

---

## 8. Connection Examples

### 8.1 Phoenix JS Client (Recommended)

```javascript
import { Socket } from "phoenix";

// Connect to the Muse WebSocket
const socket = new Socket("/socket", {
  params: {
    token: "muse_ws_abc123",         // required when auth is enabled
    session_id: "sess_a1b2c3",        // optional: auto-join this session
    filters: {
      types: ["assistant_delta", "plan_created", "plan_approved",
              "plan_rejected", "turn_completed"]
    }
  }
});

socket.connect();

// Join a session channel
const channel = socket.channel("session:sess_a1b2c3", {});

channel.join()
  .receive("ok", (resp) => {
    console.log(`Joined session ${resp.session_id}, last_seq: ${resp.last_seq}`);

    // Replay missed events if reconnecting
    if (resp.last_seq > myLastSeenSeq) {
      channel.push("replay", { after_seq: myLastSeenSeq });
    }
  })
  .receive("error", (resp) => {
    console.error("Join failed:", resp.reason);
  });

// Listen for streaming assistant deltas
let currentTurnText = "";
let currentTurnId = null;

channel.on("assistant_delta", (event) => {
  if (event.turn_id !== currentTurnId) {
    currentTurnText = "";
    currentTurnId = event.turn_id;
  }
  currentTurnText += event.payload.text;
  renderStreamingText(currentTurnText);
});

// Listen for final assistant message
channel.on("assistant_message", (event) => {
  if (!event.payload.streamed) {
    renderFinalMessage(event.payload.text);
  }
  // If streamed, deltas already rendered — suppress duplicate
});

// Listen for plan lifecycle events
channel.on("plan_created", (event) => {
  renderPlanNotification({
    planId: event.payload.plan_id,
    objective: event.payload.objective,
    taskCount: event.payload.task_count
  });
});

channel.on("approval_requested", (event) => {
  renderApprovalPrompt({
    kind: event.payload.kind,
    planId: event.payload.plan_id,
    note: event.payload.note
  });
});

channel.on("plan_approved", (event) => {
  renderPlanStatus("approved", event.payload);
});

channel.on("plan_rejected", (event) => {
  renderPlanStatus("rejected", event.payload);
});

// Listen for turn completion
channel.on("turn_completed", (event) => {
  renderTurnSummary({
    status: event.payload.status,
    durationMs: event.payload.duration_ms,
    toolCallCount: event.payload.tool_call_count
  });
});

// Handle replay responses
channel.on("replay_result", (resp) => {
  resp.events.forEach(processEvent);
  if (resp.has_more) {
    const lastSeq = resp.events[resp.events.length - 1].seq;
    channel.push("replay", { after_seq: lastSeq });
  }
});

// Graceful disconnect
function disconnect() {
  channel.leave();
  socket.disconnect();
}
```

### 8.2 Raw WebSocket Client (No Phoenix Library)

For environments without the Phoenix JS client (Python, Go, etc.), use the raw WebSocket protocol:

```python
import json
import websocket

# Phoenix socket protocol messages
PHX_JOIN = "phx_join"
PHX_REPLY = "phx_reply"
PHX_PUSH = "phx_push"

class MuseWSClient:
    def __init__(self, base_url="ws://127.0.0.1:4000"):
        self.url = f"{base_url}/socket/websocket"
        self.msg_ref = 0
        self.ws = None

    def connect(self):
        self.ws = websocket.WebSocketApp(
            self.url,
            on_message=self._on_message,
            on_error=lambda ws, e: print(f"WS error: {e}"),
            on_close=lambda ws, c, m: print(f"WS closed: {c} {m}")
        )
        # Phoenix sends heartbeat; set ping_interval for keepalive

    def join_session(self, session_id, filters=None):
        topic = f"session:{session_id}"
        payload = {"filters": filters} if filters else {}
        self._send(topic, PHX_JOIN, payload)

    def replay(self, session_id, after_seq=0):
        topic = f"session:{session_id}"
        self._send(topic, "phx_push", {"event": "replay", "payload": {"after_seq": after_seq}})

    def _send(self, topic, event, payload):
        self.msg_ref += 1
        msg = [None, str(self.msg_ref), topic, event, payload]
        self.ws.send(json.dumps(msg))

    def _on_message(self, ws, raw):
        msg = json.loads(raw)
        # Phoenix array format: [join_ref, ref, topic, event, payload]
        _, ref, topic, event, payload = msg

        if event == PHX_REPLY:
            status = payload.get("status")
            if status == "ok":
                print(f"Join OK: session={payload['response']['session_id']}")
            elif status == "error":
                print(f"Join error: {payload['response']}")
        elif event == "assistant_delta":
            self._handle_delta(payload)
        elif event == "plan_created":
            self._handle_plan_created(payload)
        elif event == "turn_completed":
            self._handle_turn_completed(payload)
        # ... handle other event types

    def _handle_delta(self, event):
        print(f"[streaming] {event['payload']['text']}", end="", flush=True)

    def _handle_plan_created(self, event):
        p = event["payload"]
        print(f"\n📋 Plan created: {p['objective']} ({p['task_count']} tasks)")

    def _handle_turn_completed(self, event):
        p = event["payload"]
        print(f"\n✅ Turn completed in {p['duration_ms']}ms")


# Usage
client = MuseWSClient()
client.connect()
client.join_session("sess_a1b2c3", filters={"types": ["assistant_delta", "plan_created", "turn_completed"]})
```

### 8.3 cURL / wscat Quick Test

```bash
# Connect with wscat
wscat -c ws://127.0.0.1:4000/socket/websocket

# Join a session (Phoenix protocol array: [join_ref, ref, topic, event, payload])
["1", "1", "session:sess_a1b2c3", "phx_join", {}]

# Request replay from seq 0
["2", "2", "session:sess_a1b2c3", "phx_push", {"event": "replay", "payload": {"after_seq": 0}}]
```

---

## 9. Integration Checklist for PR16 Merge

This checklist tracks the remaining work to complete the external WebSocket channel feature. Items marked with 🔒 are security-critical and must pass before merge.

### 9.1 Server-Side Implementation

- [ ] Create `lib/muse_web/channels/user_socket.ex` — Phoenix socket module
- [ ] Create `lib/muse_web/channels/session_channel.ex` — Session channel with PubSub subscription
- [ ] Mount socket `/socket` in `MuseWeb.Endpoint`
- [ ] Implement visibility filter: only `:user` events forwarded to clients
- [ ] 🔒 Apply `Muse.EventPayloadRedactor.redact/1` to all payloads before push
- [ ] 🔒 Strip internal data fields (`provider_config`, `prompt_layers`, `raw_provider_output`, `tool_spec`) from payloads
- [ ] Implement `replay` push handler using `Muse.State.events()` + `EventStream.replay/1`
- [ ] Apply client-side `types` filter to both live events and replay results
- [ ] Implement join reply with `last_seq`, `muse_ids`, `session_status`
- [ ] 🔒 Reject unauthenticated connections when auth is configured
- [ ] 🔒 Bind web server to `127.0.0.1` by default (verify existing config)
- [ ] Add channel tests: join, event forwarding, visibility filter, replay
- [ ] Add security tests: verify `:debug`/`:internal`/`:sensitive` events never reach client
- [ ] Add security tests: verify secret patterns never appear in client payloads
- [ ] Add security tests: verify no tool/write/shell permissions from WebSocket

### 9.2 Client-Side Contract Tests

- [ ] Create `test/fixtures/external_ws/` directory with sample event JSON fixtures
- [ ] Add fixture for `assistant_delta` envelope
- [ ] Add fixture for `assistant_message` envelope (streamed and non-streamed)
- [ ] Add fixture for `user_message` envelope
- [ ] Add fixture for `plan_created` envelope
- [ ] Add fixture for `plan_approved` / `plan_rejected` envelopes
- [ ] Add fixture for `approval_requested` / `approval_approved` / `approval_rejected` envelopes
- [ ] Add fixture for `turn_completed` envelope
- [ ] Add negative fixture: `provider_error` (must be filtered)
- [ ] Add negative fixture: `prompt_assembled` with `:sensitive` visibility (must be filtered)
- [ ] Add negative fixture: `tool_result` from secret path (must be filtered/redacted)
- [ ] Contract test: every delivered event matches the envelope spec in §4
- [ ] Contract test: every negative fixture is correctly filtered/redacted

### 9.3 Documentation & Integration

- [ ] Update `docs/architecture.md` §8.5 with implementation details
- [ ] Update `docs/security.md` §1 checklist: "External WebSocket channel does not forward internal/sensitive events"
- [ ] Update `PLAN.md` PR16 row with completion status
- [ ] Add `priv/static/js/muse-ws-client.js` (optional: minimal reference client)
- [ ] Verify LiveView still works (regression: endpoint changes must not break LiveView socket)

### 9.4 Pre-Merge Quality Gates

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test` — all existing + new tests pass
- [ ] 🔒 `grep -rE '\bsk-[a-zA-Z0-9_-]{8,}\b' docs/external-websocket.md` — no real API key patterns in examples
- [ ] 🔒 `grep -riE 'password=|secret=|credential=' docs/external-websocket.md` — no real secret values in examples
- [ ] No `:debug`, `:internal`, or `:sensitive` visibility in any example payload
- [ ] No `provider_request`, `provider_response`, `provider_error`, `tool_result`, or `prompt_assembled` in any positive example

---

## Appendix A: Event Type Quick Reference

| Event Type | Typical Source | Payload Summary |
|---|---|---|
| `assistant_delta` | `planning_muse`, `coding_muse` | `{text, streamed}` |
| `assistant_message` | `planning_muse`, `coding_muse` | `{text, streamed}` |
| `user_message` | `cli`, `liveview` | `{text}` |
| `plan_created` | `planning_muse` | `{plan_id, objective, task_count, summary}` |
| `plan_approved` | `approval_gate` | `{plan_id, plan_version, approved_by, note}` |
| `plan_rejected` | `approval_gate` | `{plan_id, rejected_by, note}` |
| `approval_requested` | `approval_gate` | `{kind, id, plan_id, note}` |
| `approval_approved` | `approval_gate` | `{kind, id, plan_id}` |
| `approval_rejected` | `approval_gate` | `{kind, id, plan_id}` |
| `turn_completed` | `conductor` | `{status, streamed, tool_call_count, duration_ms}` |

## Appendix B: Plan Approval Lifecycle Sequence

```text
1. User submits:           user_message
2. Planning Muse starts:   assistant_delta (streaming)
3. Planning Muse done:     assistant_message (streamed: true)
4. Plan produced:          plan_created
5. Approval gate active:   approval_requested
   ┌─ User approves:       plan_approved + approval_approved
   └─ User rejects:        plan_rejected + approval_rejected
6. Turn finishes:          turn_completed
```
