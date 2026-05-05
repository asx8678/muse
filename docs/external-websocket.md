# Muse External WebSocket Client Contract

> **Companion docs:** [Architecture](architecture.md) · [Security](security.md)
>
> **PR16 scope:** Optional Phoenix channel for non-LiveView external clients. LiveView already streams through Phoenix; this channel serves CLI integrations, third-party UIs, and automation clients.

---

## 1. Overview

The external WebSocket channel (`MuseWeb.SessionChannel`) provides real-time event streaming for clients that cannot use Phoenix LiveView. It subscribes to `Muse.State` and forwards **only** visibility-filtered, redacted events to connected clients.

**Key properties:**

- Read-only event stream — clients observe, they do not control the runtime
- No tool/write/shell permissions are granted to WebSocket clients
- Events are filtered by visibility before leaving the server
- Payloads pass through `Muse.EventDisplay.safe_data/1` and JSON-safe conversion before serialization
- Channel process subscribes to `Muse.State` and forwards matching events
- External WS is **disabled by default**; opt-in via config or env var

**Boundaries:**

| Concern | Client Responsibility | Server Responsibility |
|---|---|---|
| Reconnect / backoff | Client | — |
| Event ordering (seq) | Client (reorder by `seq`) | Server sends monotonic `seq` |
| Deduplication | Client | Server assigns unique `id` per event |
| Secret redaction | — | Server redacts before sending |
| Visibility filtering | — | Server drops `:debug` / `:internal` / `:sensitive` |
| Replay after disconnect | Client (reconnect triggers replay) | Server replays from `Muse.State` up to `replay_limit` |
| Approval decisions | Client sends via `/approve` CLI or LiveView | Channel is read-only |

---

## 2. Connection

### Endpoint

The WebSocket endpoint is mounted at `/socket` in `MuseWeb.Endpoint`.

```text
ws://127.0.0.1:4000/socket/websocket
wss://127.0.0.1:4000/socket/websocket   # TLS in production
```

> **Security requirement:** The web server binds to `127.0.0.1` by default. External exposure requires explicit configuration and authentication.

### Enable/Disable

The external WebSocket channel is **disabled by default**.

- Enable in config: `config :muse, :external_ws, enabled: true`
- Enable in production: `MUSE_EXTERNAL_WS=true` environment variable (accepted values: `true`, `1`, `yes`, `on`)
- Test environment: enabled by default for test coverage

When disabled, `MuseWeb.UserSocket.connect/3` rejects all connections.

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
Server → Client:  phx_reply  ref  {"status": "ok", "response": {}}
```

On successful join, the server:
1. Subscribes the channel process to `Muse.State` events
2. Pushes a replay of existing events for this session (up to `replay_limit`)
3. Begins forwarding real-time events matching the session and visibility filter

### Session ID Validation

Session IDs are validated on join:
- Must be non-empty
- Must not be `.` or `..`
- Must not contain `/`, `\`, or NUL characters
- Invalid session IDs result in `{:error, %{reason: "invalid_session_id"}}`

### Error Replies

| Reason | Condition |
|---|---|
| `"invalid_session_id"` | Empty, path-traversal, or invalid session ID |
| `"invalid_topic"` | Not a `session:<id>` topic |
| `:error` (socket connect) | External WS is disabled |

---

## 4. JSON Envelope Specification

Every event pushed to the client uses this envelope:

```json
{
  "id": 9001,
  "type": "assistant_delta",
  "timestamp": "2025-05-27T14:32:01.456Z",
  "session_id": "sess_a1b2c3",
  "turn_id": "turn_f7e8d9",
  "seq": 17,
  "source": "planning_muse",
  "visibility": "user",
  "payload": {},
  "muse_id": "planning_muse"
}
```

| Field | Type | Description |
|---|---|---|
| `id` | integer | Monotonically-increasing event ID |
| `type` | string | Event type (see §5) |
| `timestamp` | ISO 8601 | UTC timestamp |
| `session_id` | string | Session this event belongs to — always matches the joined topic |
| `turn_id` | string \| omitted | Turn identifier, omitted if nil |
| `seq` | integer \| omitted | Session-local monotonic sequence number |
| `source` | string | Event source (e.g., `"planning_muse"`, `"conductor"`, `"cli"`) |
| `visibility` | string \| omitted | Always `"user"` for external clients; omitted if nil |
| `payload` | object | Event-specific data (redacted) |
| `muse_id` | string \| omitted | Muse profile identifier, omitted if nil |

> **Invariant:** The `visibility` field is always `"user"` on the external channel when present. If any other value appears, it is a server bug.

---

## 5. Delivered Event Types

Only events with `visibility: :user` or nil-visibility events on the explicit allowlist are forwarded. The following event types are delivered to external clients:

| Event Type | Typical Source | Payload Summary |
|---|---|---|
| `user_message` | `cli`, `liveview` | `{text}` |
| `assistant_delta` | `planning_muse`, `coding_muse` | `{text}` (streaming chunk) |
| `assistant_message` | `planning_muse`, `coding_muse` | `{text, streamed?}` |
| `plan_created` | `planning_muse` | `{objective, task_count, ...}` (summary, not raw plan) |
| `plan_approved` | `approval_gate` | `{plan_id, ...}` |
| `plan_rejected` | `approval_gate` | `{plan_id, ...}` |
| `approval_requested` | `approval_gate` | `{kind, id, ...}` |
| `approval_approved` | `approval_gate` | `{kind, id, ...}` |
| `approval_rejected` | `approval_gate` | `{kind, id, ...}` |
| `turn_completed` | `conductor` | `{status, ...}` |
| `turn_failed` | `conductor` | `{status, ...}` |
| `session_status_changed` | various | `{status}` |

---

## 6. Negative Contract — What Is Never Delivered

The following categories of events are **never** forwarded to external WebSocket clients. This is enforced server-side in `MuseWeb.ExternalEventFilter`.

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
| `provider_request` | Contains model config, headers |
| `provider_response` | Raw provider output |
| `provider_error` | May leak API error details |
| `tool_result` | May contain file contents |
| `prompt_assembled` | Contains full assembled prompt |
| `session_persisted` | Internal persistence event |
| `self_healing_*` | Internal repair events |

### 6.3 No Permissions Granted

The external WebSocket channel is **strictly read-only**. Connecting does **not** grant:

- ❌ Tool execution permissions
- ❌ Approval authority
- ❌ Session control (cannot create/destroy sessions or modify state)
- ❌ Shell command execution
- ❌ Network access

---

## 7. Replay

When a client joins a session, the server pushes a replay of existing events for that session (up to `replay_limit`, default 100). The replay event uses the same `"muse_event"` push event and same envelope format as live events.

```json
{
  "events": [...]
}
```

Replay is bounded by `MuseWeb.ExternalSocketConfig.replay_limit/0` and applies the same visibility and redaction rules as live forwarding.

---

## 8. Connection Examples

### Phoenix JS Client

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", {});
socket.connect();

const channel = socket.channel("session:sess_a1b2c3", {});
channel.join()
  .receive("ok", () => console.log("Joined session"))
  .receive("error", (resp) => console.error("Join failed:", resp.reason));

channel.on("muse_event", (event) => {
  console.log(`[${event.type}] ${event.payload?.text || ""}`);
});

channel.on("events_cleared", () => {
  console.log("Events cleared");
});
```

### cURL / wscat Quick Test

```bash
wscat -c ws://127.0.0.1:4000/socket/websocket

# Join a session (Phoenix protocol array: [join_ref, ref, topic, event, payload])
["1", "1", "session:sess_a1b2c3", "phx_join", {}]
```

---

## Appendix A: Event Type Quick Reference

| Event Type | Typical Source | Payload Summary |
|---|---|---|
| `assistant_delta` | `planning_muse`, `coding_muse` | `{text}` |
| `assistant_message` | `planning_muse`, `coding_muse` | `{text, streamed?}` |
| `user_message` | `cli`, `liveview` | `{text}` |
| `plan_created` | `planning_muse` | `{objective, task_count, ...}` |
| `plan_approved` | `approval_gate` | `{plan_id, ...}` |
| `plan_rejected` | `approval_gate` | `{plan_id, ...}` |
| `approval_requested` | `approval_gate` | `{kind, id, ...}` |
| `approval_approved` | `approval_gate` | `{kind, id, ...}` |
| `approval_rejected` | `approval_gate` | `{kind, id, ...}` |
| `turn_completed` | `conductor` | `{status, ...}` |
| `turn_failed` | `conductor` | `{status, ...}` |

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
