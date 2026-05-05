# PR 16 — Optional External WebSocket Channel (Implementation Plan)

## 1. Title & Status

| Field | Value |
|---|---|
| **PR** | 16 |
| **Title** | Optional external WebSocket channel for non-LiveView clients |
| **Bead** | `muse-1ki.2.6` |
| **Lane** | 01 — Plan/contract artifact |
| **Branch** | `pr16/lane01-contract` |
| **Status** | ✅ Implemented (all lanes merged). Doc updated to match actual implementation. |
| **Owner** | asx8678 |

## 2. Objective & Acceptance Criteria

**Objective:** Add an optional Phoenix WebSocket channel so that non-LiveView clients (custom UIs, CI dashboards, external tools) can subscribe to filtered, structured Muse events over a raw Phoenix WebSocket connection without requiring a LiveView session.

**Acceptance criteria (from bead `muse-1ki.2.6`):**

1. Non-LiveView clients can subscribe to filtered structured events through an optional WebSocket channel.
2. Event filtering protects sensitive data — no `:internal` or `:sensitive` visibility events leak to external clients.
3. LiveView remains fully supported and unaffected.
4. No unauthorized provider/auth/session details are exposed.
5. The external socket is localhost-only by default and disabled without explicit configuration.

## 3. Non-Goals

- **No auth/authentication layer** — PR16 does not add API keys, bearer tokens, or client authentication. The channel is only accessible on localhost. If external/public access is needed later, a separate authenticated design and PR is required.
- **No global/debug topic** — PR16 ships session-scoped topics only (`session:<session_id>`). A future dev-only `debug:events` topic is deferred.
- **No LiveView replacement** — LiveView (at `/live`) remains the primary real-time UI. The external WebSocket channel is an optional supplement for non-LiveView clients.
- **No changes to Muse.State, Muse.Event, Muse.EventStream, or Muse.EventDisplay** — these modules are already correct for this purpose.
- **No new dependencies** — Phoenix WebSockets (`Phoenix.Socket`) ships with the framework; no additional hex packages needed.

## 4. Current Code Anchors

### 4.1 `Muse.State` (`lib/muse/state.ex`)
- Global GenServer with ordered bounded event log (default max 1,000 events).
- Broadcasts `{:muse_event, %Muse.Event{}}` on `Muse.PubSub` topic `"muse:events"`.
- Broadcasts `{:muse_events_cleared}` when the log is cleared.
- `Muse.State.subscribe/0` hides the internal topic string from callers.
- Used by LiveView (`HomeLive`) and CLI (`StreamPrinter`).

### 4.2 `Muse.Event` (`lib/muse/event.ex`)
- Immutable event struct with required fields: `id`, `timestamp`, `source`, `type`, `data`.
- Optional metadata: `session_id`, `turn_id`, `seq`, `parent_id`, `visibility`, `muse_id`.
- Visibility enum: `:user | :debug | :internal | :sensitive`.
- `Event.new/3` (backward-compatible, no metadata) and `Event.new/4` (with keyword overrides).

### 4.3 `Muse.EventStream` (`lib/muse/event_stream.ex`)
- Central subscription/replay/chat derivation.
- `replay/2` options filter by `session_id` and `visibility`.
- `chat_messages/1` excludes `:internal` and `:sensitive` events.
- Handles `:assistant_delta` streaming deduplication.

### 4.4 `Muse.EventDisplay` (`lib/muse/event_display.ex`)
- `safe_data/1` — redacts secrets via `Muse.Prompt.Redactor` and replaces raw `%Plan{}` structs with safe summary maps; suppresses raw structured plan JSON strings.
- `safe_text/1` — redacts text and suppresses inline plan JSON.
- `summary/1` — returns a concise, context-aware summary for an event.

### 4.5 `MuseWeb.Endpoint` (`lib/muse_web/endpoint.ex`)
- Current socket: LiveView only at `/live`.
- `socket("/live", Phoenix.LiveView.Socket, ...)`.
- PR16 will add `socket("/socket", MuseWeb.UserSocket, ...)`.

### 4.6 `MuseWeb.EventFormatter` (`lib/muse_web/event_formatter.ex`)
- `event_to_map/1` — converts `%Muse.Event{}` to a map with safe data via `Muse.EventDisplay.safe_data/1` + `MuseWeb.ExportJSON.json_safe/1`. Omits nil metadata fields.
- `format_event_json/1` — wraps `event_to_map` in Jason.encode.
- Baseline for external serialization (reuse this exact pattern).

### 4.7 `MuseWeb.ExportJSON` (`lib/muse_web/export_json.ex`)
- Recursive JSON-safe conversion for atoms, tuples, DateTime, structs, maps, lists; fallback to `inspect`.
- `json_safe/1` handles all edge cases.
- `json_key/1` converts any key to string.

### 4.8 LiveView (`lib/muse_web/live/home_live.ex`)
- Subscribes to `Muse.State` when connected.
- Receives `{:muse_event, %Muse.Event{}}` and `{:muse_events_cleared}`.
- **PR16 must not modify, remove, or degrade LiveView support.**

### 4.9 Router (`lib/muse_web/router.ex`)
- Simple browser pipeline with a single `live_session` for `/`.
- No API/JSON routes. PR16 does not change the router.

### 4.10 Docs references
- `docs/architecture.md` §8.5 — existing design intent for external WebSocket channel.
- `docs/security.md` — checklist item: "External WebSocket channel does not forward internal/sensitive events."
- `docs/provider-roadmap.md` — "External Phoenix WebSocket channel remains future/PR16 scope."

## 5. Product Contract

### 5.1 What it is

A lightweight, optional Phoenix WebSocket channel at endpoint `/socket` (separate from the existing LiveView socket at `/live`) that allows non-LiveView clients to:

1. Open a WebSocket connection to `ws://127.0.0.1:4000/socket` (or `wss://` in production).
2. Join a topic `session:<session_id>` to receive real-time events for a specific session.
3. Receive JSON-encoded events matching the envelope defined in §7.
4. Receive filtered events only — `:internal` and `:sensitive` visibility events are rejected; only `:user` and explicitly allowlisted lifecycle events are forwarded.

### 5.2 What it is NOT

- Not a replacement for LiveView.
- Not authenticated (local-only by default).
- Not a public WebSocket API.
- Not a general-purpose event bus — session-scoped only.

### 5.3 Configuration

The external WebSocket channel is **disabled by default**. It is enabled only when an explicit configuration flag is set:

```elixir
# config/config.exs (or dev/prod config)
config :muse, :external_ws, enabled: false

# To enable:
config :muse, :external_ws, enabled: true
```

When disabled:
- The socket is still mounted (to avoid confusing `:via` errors).
- The socket's `connect/3` callback returns `:error` for all connections.
- No channel processes are started, no resources consumed.

This guard allows the code to ship merged without risk and be activated by configuration only.

### 5.3.1 Dev-only debug topic (deferred)

A future dev-only `debug:events` topic (all events, all visibilities, local-only) is explicitly **not part of PR16**. It may be added in a follow-up PR under a `config :muse, :external_ws, enable_debug_topic: true` guard, but only if:

- The config is gated behind `Mix.env() == :dev`.
- All events still pass through `Muse.EventDisplay.safe_data/1` redaction.
- The config defaults to `false`.

## 6. Topic Contract

### 6.1 Topic format

| Topic pattern | Scope | PR16? |
|---|---|---|
| `session:<session_id>` | Events for a specific session | ✅ Ship |
| `debug:events` | All events (dev-only) | ❌ Defer |

### 6.2 `session:<session_id>` behavior

- Client joins `session:<session_id>` where `session_id` matches the session they care about.
- Channel process subscribes to `Muse.State`.
- For each incoming `{:muse_event, %Muse.Event{event}}`:
  - If `event.session_id == subscribed_session_id`, evaluate filtering rules (§8).
  - Otherwise, silently drop.
- For `{:muse_events_cleared}`: optionally forward as an empty notice (exact design choice for implementation lanes).
- Client can join multiple session topics on the same socket.

### 6.3 Why no public global/debug topic in PR16

- A global topic (`debug:events`) would expose all sessions' events to any connected client. Without auth, this is a data-leak risk even on localhost (other local processes can connect).
- If added later, it must be gated behind explicit dev config and apply the same redaction/filtering rules. Recommend PR 16.x or PR 17 for this.

## 7. Event Envelope & Serialization Contract

### 7.1 Wire format

All messages are JSON-encoded Phoenix WebSocket push messages with the standard Phoenix envelope:

```json
{
  "id": 123,
  "type": "assistant_delta",
  "source": "planning_muse",
  "timestamp": "2026-05-03T18:49:07Z",
  "session_id": "sess_123",
  "turn_id": "turn_abc",
  "seq": 17,
  "visibility": "user",
  "muse_id": "planning",
  "payload": {"text": "..."}
}
```

> **Note:** The Phoenix push event name is `"muse_event"` — it is the channel event name, not a field
> inside the envelope. Replay batch uses the same push event with `%{"events" => [...]}`.

### 7.2 Serialization rules

| Field | Type | Notes |
|---|---|---|
| `id` | integer | `event.id` |
| `type` | string | `Atom.to_string(event.type)` |
| `source` | string | `Atom.to_string(event.source)` |
| `timestamp` | string (ISO8601) | `DateTime.to_iso8601(event.timestamp)` |
| `session_id` | string \| omitted | Omitted if nil |
| `turn_id` | string \| omitted | Omitted if nil |
| `seq` | integer \| omitted | Omitted if nil |
| `visibility` | string \| omitted | `Atom.to_string(event.visibility)`; omitted if nil |
| `muse_id` | string \| omitted | Omitted if nil |
| `payload` | object | `event.data \|> Muse.EventDisplay.safe_data() \|> external_json_safe()` |

### 7.3 Implementation strategy

Serialization and filtering are combined in `MuseWeb.ExternalEventFilter.to_external_map/2`.
This module:
- Validates session ID and checks visibility before building the envelope.
- Converts atoms to strings; omits nil metadata fields.
- Applies `safe_data` then `external_json_safe` (depth-limited, struct-suppressing
  JSON safety) to the `payload` field.
- Returns `{:ok, envelope}` or `{:error, reason}`.

The originally planned `MuseWeb.ExternalEventSerializer` module was not created;
`ExternalEventFilter` absorbed both roles (filter + serialize).

### 7.4 `events_cleared` push

When the event log is cleared, the channel pushes:

```json
channel.push("events_cleared", {})
```

The push event name is `"events_cleared"` and the payload is empty (`%{}`).
No session ID or internal state details are included.

## 8. Filtering & Redaction Contract

### 8.1 Session matching

Forward an event **only if** `event.session_id == subscribed_session_id`.

If `event.session_id` is `nil` (legacy event created with `Event.new/3`), it is **not forwarded** on any session topic.

### 8.2 Visibility-based filtering

| Visibility | Forward? | Notes |
|---|---|---|
| `:user` | ✅ Yes | Always forwarded (if session matches) |
| `:debug` | ❌ No | Rejected by default. Not forwarded as ordinary event. A lifecycle event with `:debug` visibility may pass only if its type is in the explicit safe lifecycle allowlist (§8.3) AND its data passes redaction. |
| `:internal` | ❌ No | Rejected — always rejected, even for allowlisted types. |
| `:sensitive` | ❌ No | Rejected — always rejected, even for allowlisted types. |
| `nil` (unset) | ❌ No | Rejected by default. May pass only if the event type is in the explicit safe lifecycle allowlist (§8.3) AND its data passes redaction. |

**Rationale — why ordinary `:debug` events are not forwarded in PR16:** The `session:<session_id>` topic is intended for non-LiveView clients who need structured, safe, application-level event data. Ordinary `:debug` events (trace-level internal diagnostics, ad-hoc instrumentation) are not designed for external consumption. A dev-only `debug:events` topic (with the same `safe_data` redaction) is deferred to a future PR behind an explicit local/dev config guard. Lifecycle events carrying `:debug` or `nil` visibility that are proven safe and pass redaction may still be forwarded via the allowlist (§8.3).

### 8.3 Type-based lifecycle allowlist

The allowlist is the **only exception** to the `:user`-only forwarding rule. An event with `:debug`, `nil`, or unknown visibility may still be forwarded if (a) its type is in the explicit safe lifecycle allowlist below, (b) its visibility is NOT `:internal` or `:sensitive` (those are always rejected regardless of type), and (c) its data passes `Muse.EventDisplay.safe_data/1` redaction.

Events with `:user` visibility are always forwarded when session matches — they do not need to be in this allowlist.

| Type | Notes |
|---|---|
| `:plan_created` | Safe summary via `EventDisplay.summary/1` |
| `:plan_approved` | Safe summary |
| `:plan_rejected` | Safe summary |
| `:approval_requested` | Safe summary |
| `:approval_approved` | Safe summary |
| `:approval_rejected` | Safe summary |
| `:session_started` | (If data payload proven safe) |
| `:session_completed` | (If data payload proven safe) |
| `:session_failed` | (If data payload proven safe) |
| `:turn_started` | (If data payload proven safe) |
| `:turn_completed` | (If data payload proven safe) |
| `:turn_failed` | (If data payload proven safe) |

**Recommendation for PR16:** Ship with the first six (plan/approval lifecycle). Add session/turn lifecycle events in a follow-up lane once their data payloads have been audited and proven safe.

### 8.4 Data redaction

All event data **must** pass through `Muse.EventDisplay.safe_data/1` before serialization. This ensures:

- Secrets (`api_key`, `token`, `secret`, etc.) are redacted via `Muse.Prompt.Redactor`.
- Raw `%Plan{}` structs are replaced with safe summary maps (id, version, status, objective, task_count).
- Raw structured plan JSON strings are replaced with `"[structured plan JSON omitted; use /plan or /plan show <id> for the rendered plan]"`.
- The exported data never contains provider keys, Authorization headers, Codex cache contents, raw prompts/hidden prompts, session secrets, cookie/session signing salts, or raw plan task/objective details beyond what `safe_data` allows.

### 8.5 Recommended filter implementation pattern

```elixir
# Pseudocode for the channel's handle_info
def handle_info({:muse_event, %Event{} = event}, socket) do
  session_id = socket.assigns.session_id

  if event.session_id == session_id && visible_to_external?(event) do
    case MuseWeb.ExternalEventFilter.to_external_map(event, session_id: session_id) do
      {:ok, envelope} -> push(socket, "muse_event", envelope)
      {:error, _reason} -> :ok
    end
  end

  {:noreply, socket}
end

defp visible_to_external?(%Event{visibility: visibility, type: type}) do
  cond do
    # :internal and :sensitive are ALWAYS rejected, even for allowlisted types
    visibility in [:internal, :sensitive] ->
      false

    # :user is always forwarded (when session matches)
    visibility == :user ->
      true

    # :debug, nil, and unknown visibility pass ONLY if type is allowlisted
    type in @allowlisted_lifecycle_types ->
      true

    # Everything else (ordinary :debug events, unknown types) is dropped
    true ->
      false
  end
end
```

**Suggested helper module:** `MuseWeb.ExternalEventFilter` with:
- `visible_to_external?(event)` — centralizes the visibility + allowlist logic.
- `allowlisted_lifecycle_types()` — returns the current allowlist.

## 9. Auth & Security Posture

### 9.1 Localhost-by-default

- The web server binds to `127.0.0.1` by default (`Muse.BootOptions` default host).
- The external WebSocket channel is accessible only at `ws://127.0.0.1:4000/socket`.
- No external access is possible unless the user explicitly starts with `--host 0.0.0.0` or equivalent.

### 9.2 Optional-by-default (config guard)

- The channel is disabled by default (`config :muse, :external_ws, enabled: false`).
- When disabled, `MuseWeb.UserSocket.connect/3` returns `:error`.
- No channel processes start; no resources consumed; no socket-level handlers run beyond the reject.

### 9.3 No auth in PR16

- PR16 does NOT add API keys, bearer tokens, or any authentication mechanism.
- If external/public access is needed in the future, a separate PR must add:
  - An authentication layer (API keys, OAuth, or similar).
  - Rate limiting.
  - Audit logging.
  - A security review.

### 9.4 Data that must NEVER be exposed

The following categories of data are **never** forwarded to external WebSocket clients:

- Provider API keys/tokens (redacted by `Muse.Prompt.Redactor`).
- Authorization headers or bearer tokens.
- Codex cache contents.
- Raw prompt/hidden prompt text.
- Session secrets (e.g., cookie signing salt `"dev-salt"`).
- Raw structured plan JSON (replaced by safe summaries, §8.4).
- Events with `visibility: :sensitive` or `visibility: :internal`.

### 9.5 Startup banner

- The startup banner (`Muse.StartupBanner`) should indicate whether the external WebSocket channel is enabled/disabled, e.g.:
  - `ws=127.0.0.1:4000/socket` when enabled.
  - No WS line when disabled.

## 10. Implementation Plan for Downstream Lanes

### 10.1 Files to create

| # | File | Purpose | Lane |
|---|---|---|---|
| 1 | `lib/muse_web/channels/user_socket.ex` | Phoenix WebSocket socket module; connects at `/socket`; calls `MuseWeb.UserSocket` | Lane 02 |
| 2 | `lib/muse_web/channels/session_channel.ex` | Channel process for `session:<session_id>` topic; subscribes to Muse.State; filters and forwards events | Lane 03 |
| 3 | `lib/muse_web/external_event_filter.ex` | Pure helper: visibility filtering **and** envelope serialization (`to_external_map/2`) | Lane 04 |
| 4 | `lib/muse_web/external_socket_config.ex` | Runtime config: `enabled?/0`, `replay_limit/0`, env var resolution | Lane 02 |

### 10.2 Files to modify

| # | File | Change | Lane |
|---|---|---|---|
| 1 | `lib/muse_web/endpoint.ex` | Add `socket("/socket", MuseWeb.UserSocket, ...)` next to existing LiveView socket | Lane 02 |
| 2 | `config/config.exs` (or relevant) | Add `config :muse, :external_ws, enabled: false` | Lane 02 |
| 3 | `lib/muse/application.ex` | Possibly map CLI `--ws` or `--external-ws` flag to config; otherwise minimal | Lane 05 |
| 4 | `lib/muse/startup_banner.ex` | Show WS URL when enabled | Lane 05 |

### 10.3 Files to create (tests)

| # | File | Purpose | Lane |
|---|---|---|---|
| 1 | `test/muse_web/channels/user_socket_test.exs` | Socket `connect/3` tests: allowed when enabled, rejected when disabled | Lane 06 |
| 2 | `test/muse_web/channels/session_channel_test.exs` | Channel `join/3` and `handle_info` tests: session matching, filtering, redaction, deny internal/sensitive | Lane 06 |
| 3 | `test/muse_web/external_event_filter_test.exs` | Filter + serializer unit tests: every visibility value, allowlist types, nil edge cases, envelope shape | Lane 06 |
| 4 | `test/muse_web/external_event_security_test.exs` | Security boundary: redaction, secret suppression, struct omission, session ID validation | Lane 06 |
| 5 | `test/muse_web/external_socket_config_test.exs` | Config defaults: enabled/disabled, env var truthy values, replay_limit | Lane 06 |

### 10.4 Lane breakdown

| Lane | Description | Owner (suggested) |
|---|---|---|
| **01** | ✅ Plan/contract artifact (this document) | asx8678 |
| **02** | Endpoint/socket wiring: `user_socket.ex`, `endpoint.ex` socket registration, config guard | Code-Puppy |
| **03** | Channel process: `session_channel.ex` — join, subscribe to Muse.State, filter/forward | Code-Puppy |
| **04** | Filter + serializer helper: `ExternalEventFilter` (combined) | Code-Puppy |
| **05** | Integration: startup banner, boot flag, config wiring | Code-Puppy |
| **06** | Tests: all four test files, integration tests | Code-Puppy |
| **07** | Docs: update `docs/architecture.md` §8.5, `docs/security.md` checklist, `docs/provider-roadmap.md` | Code-Puppy |
| **08** | QA/security review: manual testing, edge case audit, redaction audit | qa-kitten |
| **09** | Merge/integration: resolve conflicts, coordinate all lanes | planning-agent |
| **10** | Post-merge docs & announcement | asx8678 |

## 11. Tests Matrix

| Test file | Scope | Key assertions |
|---|---|---|
| `test/muse_web/channels/user_socket_test.exs` | Socket connect | Connect succeeds when enabled; `:error` when disabled; socket params correct |
| `test/muse_web/channels/session_channel_test.exs` | Channel join & handle_info | Join `session:<id>` OK; join mismatched topic returns `{:error, ...}`; `handle_info({:muse_event, ...})` forwards matching session events; drops non-matching session; drops `:internal`; drops `:sensitive`; forwards `:user`; drops ordinary `:debug` event (not allowlisted); forwards allowlisted lifecycle type with `:debug`/nil visibility; drops nil-visibility non-allowlisted; respects allowlist |
| `test/muse_web/external_event_filter_test.exs` | Filtering + serialization | `:user` → true; `:debug` with non-allowlisted type → false; `:debug` with allowlisted lifecycle type → true; `:internal` → false (even if allowlisted); `:sensitive` → false (even if allowlisted); `nil` → false for ordinary types, true for allowlisted lifecycle types; each allowlisted type returns true for `:user`, and also for `:debug`/nil only when data proven safe; envelope shape (string keys, `payload` field, nil omission) |
| `test/muse_web/external_event_security_test.exs` | Security boundary | Redaction, secret suppression, struct omission, nested event omission, session ID validation, provider/auth/debug denial |
| `test/muse_web/external_socket_config_test.exs` | Config defaults | enabled/disabled, env var truthy values, replay_limit |

## 12. Docs Matrix

| Doc file | Update needed |
|---|---|
| `docs/architecture.md` §8.5 | Replace placeholder "Create later" with final module names, socket path, topic contract, envelope shape (from §7), filtering rules (from §8), config guard flag |
| `docs/security.md` | Check off checklist item: "External WebSocket channel does not forward internal/sensitive events" once verified |
| `docs/provider-roadmap.md` | Update "External Phoenix WebSocket channel remains future/PR16 scope" to reference PR16 as implemented |
| `README.md` | Optionally add a section under "Web UI" noting the external WebSocket endpoint for non-LiveView clients |

## 13. Merge & Integration Strategy for Other 9 Lanes

### 13.1 Lane ordering

The lanes **must** be implemented and merged in dependency order:

```
Lane 02 (socket wiring) ──► Lane 04 (serializer/filter) ──► Lane 03 (channel)
                                                              │
                                                              ▼
                                                      Lane 05 (integration)
                                                              │
                                                              ▼
                                                      Lane 06 (tests)
                                                              │
                                                              ▼
                                                      Lane 07 (docs)
                                                              │
                                                              ▼
                                                      Lane 08 (QA/review)
                                                              │
                                                              ▼
                                                      Lane 09 (merge)
                                                              │
                                                              ▼
                                                      Lane 10 (announce)
```

**Why Lane 04 before Lane 03?** The channel process (`session_channel.ex`) imports serializer and filter. Those helpers must exist first (or be stubbed/inline initially and extracted). The recommended approach: implement helpers as pure functions first, then the channel uses them.

### 13.2 Branch strategy

- All implementation lanes branch from `origin/main`.
- Lane 01 (this artifact) merges first to provide the contract.
- Each downstream lane creates a feature branch: `pr16/lane02-socket-wiring`, `pr16/lane03-channel`, etc.
- Lanes merge into `main` sequentially.
- If parallel lanes are needed (e.g., Lane 04 helpers and Lane 02 socket wiring are independent), they can branch from `main` and merge in any order before Lane 03.

### 13.3 Suggested ownership

| Lane | Agent/Persona | Notes |
|---|---|---|
| 01 (plan) | planning-agent / asx8678 | ✅ Complete |
| 02 (socket wiring) | Code-Puppy | Simple ~30-line file + 2-line endpoint change |
| 03 (channel) | Code-Puppy | Core logic; moderate complexity |
| 04 (helpers) | Code-Puppy | Pure functions; easily tested; high value |
| 05 (integration) | Code-Puppy | Config wiring, banner tweak |
| 06 (tests) | Code-Puppy | Comprehensive; reuse existing test patterns |
| 07 (docs) | Code-Puppy | Lightweight updates |
| 08 (QA/security) | qa-kitten | Manual testing + redaction audit |
| 09 (merge) | planning-agent | Conflict resolution, coordination |
| 10 (announce) | asx8678 | Post-merge communication |

### 13.4 Risk areas

- **Race with concurrent PRs that touch `endpoint.ex`**: If another PR adds socket registrations, coordinate with Lane 02 to avoid conflicts.
- **LiveView regression**: Lane 03 must not change any LiveView-related code. The channel is a separate process tree.
- **Config flag naming**: Config key is `config :muse, :external_ws, enabled:` — do not diverge.

## 14. Acceptance Checklist

| # | Item | Status |
|---|---|---|
| 1 | Socket `/socket` registered in endpoint, guarded by config | ☐ |
| 2 | `UserSocket.connect/3` rejects when disabled, accepts when enabled | ☐ |
| 3 | `session:<session_id>` topic joinable | ☐ |
| 4 | Channel subscribes to `Muse.State` and receives events | ☐ |
| 5 | Session matching: only events with matching `session_id` forwarded | ☐ |
| 6 | Visibility filtering: `:user` forwarded; `:debug` ordinary events dropped (lifecycle allowlist types with `:debug` may pass); `:internal` and `:sensitive` always dropped | ☐ |
| 7 | `nil`/unknown visibility: dropped by default; forwarded only if type is in explicit safe lifecycle allowlist AND data passes redaction | ☐ |
| 8 | Allowlist includes plan/approval lifecycle types (6 types minimum) | ☐ |
| 9 | All event data passes through `Muse.EventDisplay.safe_data/1` | ☐ |
| 10 | JSON serialization matches envelope contract (§7) | ☐ |
| 11 | Nil metadata fields omitted from JSON | ☐ |
| 12 | Summary field present in each forwarded event | ☐ |
| 13 | LiveView continues to work without changes | ☐ |
| 14 | No provider keys, tokens, secrets exposed | ☐ |
| 15 | No raw plan JSON in forwarded data | ☐ |
| 16 | Channel disabled by default; opt-in via config flag | ☐ |
| 17 | All four test files pass | ☐ |
| 18 | Docs updated (architecture, security checklist, roadmap) | ☐ |
| 19 | QA security audit: manual verify no sensitive data leaks | ☐ |
| 20 | Merge conflicts resolved, all lanes integrated cleanly | ☐ |

---

*Lane 01 contract artifact — created 2026-05-03 as part of PR16. Branch: `pr16/lane01-contract`. Bead: `muse-1ki.2.6`.*
