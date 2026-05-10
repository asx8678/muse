# Ultimate Muse Fix Instructions for Planning Agent

## Purpose

This document combines `fix.md` and `fix2.md` into a single implementation-ready remediation brief for the `muse-main` Elixir/Phoenix LiveView application. It is intended to be handed to a planning or coding agent that will create the actual patches.

The source audits found three broad classes of work:

1. **P0 security and correctness fixes** that prevent unauthorized control/event access, caller hangs, active-turn corruption, and blocked LiveView sessions.
2. **P1 reliability and performance fixes** that harden process execution, tool input handling, filesystem behavior, persistence, repository scanning, event rendering, session memory retention, JSONL I/O, and model/tool-loop costs.
3. **P2/P3 maintainability, CI, and configuration fixes** that make future changes safer and deployments less fragile.

The implementation should preserve existing user-facing behavior unless the plan explicitly calls for safer behavior. Where behavior must change, prefer small, explicit states such as `:turn_in_progress`, `:submit_timeout`, `:unauthorized`, or `:persistence_failed` over silent failure or process crashes.

---

## Non-Negotiable Planning Rules

A planning agent should follow these rules while converting this document into patches:

- **Implement in priority order.** P0 fixes must land before P1/P2/P3 work unless a lower-priority change is a direct prerequisite for a P0 patch.
- **Do not merge security-sensitive exposure fixes with large refactors.** Authentication, authorization, loopback enforcement, secret handling, and child-process hardening should be reviewable in small patches.
- **Preserve the session turn lifecycle.** Any change to `SessionServer` must include tests for active-turn state, stale task results, cancellation, failure, completion, and persistence side effects.
- **Bound memory everywhere long-lived state accumulates.** Global state, per-session events, command history, toasts, stream buffers, JSONL imports/exports, and tool-model payloads must have explicit limits.
- **Prefer streaming and incremental updates over full recomputation.** This applies to LiveView PubSub handling, event grouping, JSONL reads, repository search, and provider deltas.
- **Never leak secrets to child processes by default.** Child command environments must be allowlisted, not inherited wholesale.
- **Do not let LLM/tool input crash handlers.** Validate schemas and replace bang filesystem calls with safe result handling.
- **Every patch must include tests or a documented reason tests are impossible.** For this codebase, most items are testable with ExUnit and focused unit tests.
- **Canonical conflict rule:** if an appendix section conflicts with the integrated plan below, follow the integrated plan. The appendices preserve original audit detail and code sketches.

---

## Implementation Phases

### Phase 0 — Preparation and Safety Harness

Before making invasive changes, add or verify the minimum test harness needed to prove fixes:

- Ensure ExUnit can run targeted tests for `SessionServer`, `SessionStore`, `EventStream`, tool modules, and LiveView event handling.
- Add a small set of fake LLM provider and fake tool-runner modules for deterministic tests.
- Add helpers for building sessions, turns, tool calls, and synthetic event streams.
- Add regression tests before modifying high-risk lifecycle behavior where feasible.
- Capture a rough baseline for a large synthetic event stream, large JSONL file, and large repository traversal. Exact benchmarks are optional, but the agent should be able to confirm that new implementations do not perform obviously worse.

Recommended baseline checks:

- `EventStream.chat_messages/1` on 1,000, 5,000, and 20,000 synthetic events.
- `SessionStore.load_*` behavior on a JSONL file with many lines and at least one invalid line.
- `repo_search` stops after `max_results` instead of walking an entire synthetic tree.
- `SessionServer` rejects or handles a second submit while the first turn is active.

---

## Canonical Priority Backlog

### T0-01 — Authenticate and authorize the optional external WebSocket

**Priority:** P0  
**Primary files:**

- `lib/muse_web/channels/user_socket.ex`
- `lib/muse_web/channels/session_channel.ex`
- `lib/muse_web/external_socket_config.ex`
- `config/config.exs`
- `config/runtime.exs`

**Problem:** The optional external WebSocket accepts clients once enabled, and channel joins are authorized only by topic/session-id shape. If the endpoint is bound broadly, proxied, tunneled, or exposed accidentally, external clients can subscribe to sensitive session event streams.

**Required changes:**

1. Add `MuseWeb.ExternalSocketAuth` or equivalent.
2. Authenticate a caller in `UserSocket.connect/3` with a token supplied in params or a documented header/param mechanism supported by Phoenix sockets.
3. Store only token hashes in application config. Do not store raw token values except transiently in runtime config generation.
4. Use constant-time comparison through `Plug.Crypto.secure_compare/2` when comparing hashes.
5. Assign an external principal to the socket, including token id, scopes, and allowed sessions.
6. Authorize `SessionChannel.join/3` against the assigned principal and requested `session_id`.
7. Fail closed in production if the external WebSocket is enabled without a valid token.
8. Keep event filtering intact; authentication is additive, not a replacement for sanitization.

**Acceptance criteria:**

- External WebSocket disabled: connection fails.
- External WebSocket enabled without token config in production: app fails fast at startup.
- Invalid or too-short token: connection fails.
- Valid token but unauthorized session: channel join fails.
- Valid token and authorized session: channel join succeeds.
- Socket id should be stable enough for observability but must not expose the raw token.

**Tests to add:**

- `UserSocket.connect/3` rejects missing/invalid token.
- `UserSocket.connect/3` accepts valid token hash.
- `SessionChannel.join/3` rejects unauthorized sessions.
- `SessionChannel.join/3` accepts authorized sessions.
- Runtime config validation requires a token when external socket is enabled.

---

### T0-02 — Add browser LiveView access control or enforce loopback-only access

**Priority:** P0  
**Primary files:**

- `lib/muse_web/router.ex`
- `lib/muse_web/endpoint.ex`
- `config/*.exs`

**Problem:** The browser LiveView is a local coding-agent control surface. If it is accidentally reachable from outside the local machine, a remote user may be able to submit prompts, trigger tool activity, see workflow state, or control approvals.

**Required changes:**

1. Enforce loopback-only binding for local/dev usage or add explicit browser authentication.
2. In production, require a secret/session auth mechanism unless the deployment is explicitly configured for trusted loopback only.
3. Make unsafe combinations fail closed, especially `0.0.0.0` plus no browser auth.
4. Add configuration flags that are environment-specific and auditable.
5. Avoid relying on obscurity or default ports for protection.

**Acceptance criteria:**

- Default local dev remains convenient on loopback.
- Browser UI cannot be reached remotely by accident.
- Production config requires either explicit auth or explicit loopback-only binding.
- Misconfiguration produces a clear error message.

**Tests to add:**

- Router/plug rejects unauthorized browser LiveView access.
- Runtime config validation rejects unsafe deployment config.
- Authorized local/browser session still mounts normally.

---

### T0-03 — Prevent concurrent submissions from corrupting active turn state

**Priority:** P0  
**Primary files:**

- `lib/muse/session_server.ex`
- Callers of `Muse.submit/3`, `SessionRouter.submit/4`, or equivalent public submit APIs

**Problem:** The current `SessionServer` path can start a new turn while another is active. A second submit can overwrite `from`, `runner_pid`, `runner_task`, and `active_turn_id`. The first caller can block indefinitely, and stale task results can be ignored without useful diagnostics.

**Required behavior:** Start with a **single-flight reject policy**. While a turn is active, new submissions should return `{:error, :turn_in_progress}`. Do not add queueing unless product requirements explicitly demand it.

**Required changes:**

1. Replace infinite submit calls with a finite, configurable timeout.
2. Add `turn_active?/1` to check `runner_task`, `runner_pid`, `active_turn_id`, and/or `status`.
3. Guard all submit handlers. If a turn is active, emit an internal `:submit_rejected` event and return `{:error, :turn_in_progress}`.
4. Refactor startup into a shared `start_turn/5` function used by both sync and async APIs.
5. Make stale task results and stale `:DOWN` messages observable through structured logging.
6. Ensure `clear_turn_state/1` clears all active-turn fields consistently.

**Acceptance criteria:**

- A second submit during an active turn does not mutate `active_turn_id`.
- The first caller still receives the correct reply when its turn completes.
- A second submit receives `{:error, :turn_in_progress}` quickly.
- No caller waits forever because of overwritten `from` state.
- Stale task results are logged and ignored without mutating active state.

**Tests to add:**

- Reject second submit while a turn is running.
- Do not overwrite active turn id on second submit.
- Do not overwrite original caller.
- Original caller receives a reply when the first turn completes.
- Stale task result does not mutate active state.
- Submit returns `{:error, :submit_timeout}` when caller timeout is reached.

---

### T0-04 — Make LiveView submit non-blocking

**Priority:** P0  
**Primary files:**

- `lib/muse_web/live/home_live.ex`
- `lib/muse/session_server.ex`
- `lib/muse/session_router.ex`
- `lib/muse.ex`

**Problem:** The LiveView submit handler currently waits for the whole LLM/tool turn to finish. This blocks the LiveView process, delays UI updates, and can prevent cancellation or approval interactions during long turns.

**Required changes:**

1. Add an explicit non-blocking submit API such as `SessionServer.submit_async/4`, `SessionRouter.submit_async/4`, and/or `Muse.start_submit/3`.
2. The async API should start a turn and immediately return `{:ok, turn_id}` or `{:error, :turn_in_progress}`.
3. The synchronous submit API may remain for CLI/TUI paths, but it must use finite timeouts and the same single-flight guard.
4. `HomeLive.handle_event("submit", ...)` must use the async API and rely on PubSub/session events for progress and completion.
5. UI assigns such as `submitting?` and `active_turn_id` should update immediately.
6. Completion/failure/cancel events must clear the submitting state.

**Acceptance criteria:**

- Browser submit returns immediately after turn startup.
- LiveView remains able to process PubSub events, cancel clicks, approval clicks, and diagnostics while a turn runs.
- UI shows a durable running/busy state.
- UI clears running state on `:turn_completed`, `:turn_failed`, or `:turn_cancelled`.
- Turn-in-progress submission shows a clear warning instead of blocking or starting another turn.

**Tests to add:**

- Submit event returns immediately after starting a turn.
- UI assigns `submitting?` while a turn is active.
- Submit button/input is disabled or shows busy state while running.
- `turn_completed` clears `submitting?`.
- `turn_failed` clears `submitting?` and shows durable error feedback.

---

### T0-05 — Convert provider “streaming” from buffered replay to true live event emission

**Priority:** P0/P1 bridge; implement immediately after T0-04  
**Primary files:**

- `lib/muse/conductor.ex`
- `lib/muse/conductor/tool_loop.ex`
- `lib/muse/session_server.ex`
- `lib/muse/turn_runner.ex` or equivalent runner startup path

**Problem:** Provider events are currently buffered in the process dictionary and converted/emitted only after the provider call completes. This defeats token streaming and creates avoidable memory buildup.

**Required changes:**

1. Stop using the process dictionary as a streaming buffer for provider deltas.
2. Pass an `emit_event_fn` or equivalent callback from `SessionServer`/`TurnRunner` into `Conductor` and `ToolLoop`.
3. Emit converted `%Muse.LLM.Event{}` deltas immediately as provider callbacks arrive.
4. `SessionServer` should handle messages such as `{:turn_event_spec, turn_id, spec}` and append/publish only when the event belongs to the current active turn.
5. Prevent duplicate events: once deltas are emitted live, do not replay the same buffered deltas at provider completion.
6. Keep cancellation semantics safe. If cancellation is requested, late provider events should be ignored or marked stale.

**Acceptance criteria:**

- First assistant delta reaches PubSub before provider completion.
- LiveView can render streaming text while provider call is still active.
- Provider completion does not duplicate already-emitted deltas.
- Stale deltas from old turn ids are ignored.
- Tool-loop provider calls use the same streaming approach.

**Tests to add:**

- Fake provider emits several deltas and delays final response; PubSub receives deltas before final response.
- Completion event does not duplicate delta events.
- Stale `turn_id` event specs are ignored.
- Tool-loop stream emits deltas live.

---

### T1-06 — Harden child process environments and stop leaking secrets

**Priority:** P1  
**Primary files:**

- `lib/muse/execution/local_runner.ex`
- `lib/muse/execution/command.ex`
- `lib/muse/tools/test_runner.ex`

**Problem:** Child commands may inherit the BEAM environment, including provider keys, GitHub tokens, cloud credentials, `MUSE_*` secrets, and proxy values. Redacting output is not enough because arbitrary project code can read and exfiltrate inherited environment variables.

**Required changes:**

1. Replace inherited environment behavior with an allowlisted environment.
2. Include only safe variables necessary for local tool execution, such as `PATH`, `HOME`, `LANG`, and explicitly configured project-safe variables.
3. Add denylist filtering as defense-in-depth for common secret patterns.
4. Ensure `test_runner.safe_env/0` does not start from unrestricted `System.get_env()`.
5. Redact command environment values from logs and events.

**Acceptance criteria:**

- Child commands do not receive provider API keys or unrelated secrets by default.
- Tests can still run with required safe environment values.
- Users can explicitly allow additional environment variables if needed.
- Logs never expose secret values.

**Tests to add:**

- A fake secret in parent env is not visible to child command.
- Allowed env var is visible to child command.
- Denylisted env var is removed even if requested accidentally.
- Logs/events do not include secret values.

---

### T1-07 — Terminate full process trees on timeout

**Priority:** P1  
**Primary files:**

- `lib/muse/execution/local_runner.ex`
- `lib/muse/execution/runner.ex`

**Problem:** Timeout handling can close/kill the immediate port process while child/grandchild processes survive. Tests, builds, or arbitrary shell commands can continue consuming CPU, memory, disk, or network after the application believes they timed out.

**Required changes:**

1. Start commands in a process group where supported.
2. On timeout, terminate the whole process group best-effort.
3. Fall back safely on platforms where process-group cleanup is unavailable.
4. Document platform limitations.
5. Emit structured timeout diagnostics.

**Acceptance criteria:**

- A command that spawns a long-lived child does not leave that child alive after timeout on supported platforms.
- Timeout cleanup is observable in logs/events.
- Unsupported platforms fail gracefully with documented behavior.

**Tests to add:**

- Command spawning a child is fully terminated on timeout where supported.
- Timeout result includes clear reason.
- Cleanup path does not crash if process already exited.

---

### T1-08 — Route checkpoint git metadata through the hardened runner

**Priority:** P1  
**Primary files:**

- `lib/muse/checkpoint/store.ex`
- Hardened execution runner from T1-06/T1-07

**Problem:** Direct `System.cmd/3` calls bypass environment redaction, timeout handling, logging, and process-tree cleanup. Git metadata commands should use the same execution safety path as other commands.

**Required changes:**

1. Replace direct `System.cmd/3` git metadata calls with the hardened runner.
2. Use finite timeouts.
3. Use sanitized environment.
4. Redact output in logs.
5. Handle command failures explicitly.

**Acceptance criteria:**

- Git metadata retrieval cannot hang indefinitely.
- Git calls inherit only allowed env vars.
- Failures are returned or logged explicitly without crashing normal checkpoint flow.

**Tests to add:**

- Git command timeout is handled.
- Git command failure produces safe fallback metadata.
- No secret env is passed to git command.

---

### T1-09 — Bound bearer command stdout

**Priority:** P1  
**Primary files:**

- `lib/muse/auth/bearer_command.ex`

**Problem:** Credential helper commands can produce unbounded stdout, causing memory pressure during authentication/credential resolution.

**Required changes:**

1. Replace unbounded `System.cmd/3` capture with bounded command execution.
2. Limit stdout bytes accepted for bearer tokens.
3. Fail if command output exceeds the configured maximum.
4. Trim expected output and validate token shape/length.
5. Apply timeout and secret-safe environment.

**Acceptance criteria:**

- A bearer command producing huge output cannot exhaust memory.
- Timeout returns a clear error.
- Secret output is not logged.
- Valid small token output still works.

**Tests to add:**

- Huge stdout is rejected/truncated safely.
- Timeout returns explicit error.
- Valid token output succeeds.

---

### T1-10 — Add strict tool input validation and replace bang filesystem calls

**Priority:** P1  
**Primary files:**

- `lib/muse/tool/runner.ex`
- `lib/muse/tool/registry.ex`
- Tool modules under `lib/muse/tools/`

**Problem:** Tool calls originate from an LLM or external orchestration and can be malformed. Bang filesystem calls or loose validation can crash handlers or produce unsafe behavior.

**Required changes:**

1. Define schemas or validation functions for every tool input.
2. Validate tool name, argument map shape, required fields, field types, path constraints, max lengths, max results, and optional values.
3. Return structured tool errors instead of raising.
4. Replace `File.*!`, `Path.*` assumptions, and other bang operations where user/tool input is involved.
5. Ensure invalid tool calls produce bounded, model-safe error messages.

**Acceptance criteria:**

- Malformed LLM tool calls do not crash the runner.
- Unknown tool names return clear errors.
- Invalid paths are rejected before filesystem access.
- Tool errors are safe to display and safe to send back to the model.

**Tests to add:**

- Unknown tool is rejected.
- Missing required argument is rejected.
- Wrong argument type is rejected.
- Invalid path traversal is rejected.
- Filesystem permission errors do not crash.

---

### T1-11 — Validate UTF-8 and binary handling in file tools

**Priority:** P1  
**Primary files:**

- `lib/muse/tools/read_file.ex`
- `lib/muse/tools/repo_search.ex`
- Other file/text tools as applicable

**Problem:** Some file tools apply `String.*` functions to file content that may be invalid UTF-8 or binary. This can raise exceptions or split multibyte characters incorrectly.

**Required changes:**

1. Detect binary files and invalid UTF-8 before string operations.
2. Return a clear `:binary_file` or `:invalid_utf8` tool error when text processing is not safe.
3. Avoid slicing binaries in the middle of multibyte characters when truncating text.
4. For search tools, skip invalid/binary files unless the tool explicitly supports binary scanning.

**Acceptance criteria:**

- Reading invalid UTF-8 does not crash.
- Searching invalid UTF-8 does not crash.
- Binary files are skipped or rejected with explicit reason.
- Text truncation respects valid UTF-8 boundaries.

**Tests to add:**

- `read_file` rejects invalid UTF-8 without crashing.
- `read_file` does not split multibyte boundary.
- `repo_search` skips invalid UTF-8 files without crashing.
- `repo_search` skips binary files with NUL bytes.

---

### T1-12 — Handle persistence failures explicitly

**Priority:** P1  
**Primary files:**

- `lib/muse/session_server.ex`
- `lib/muse/session_store.ex`

**Problem:** Some persistence writes are pattern-matched as `:ok`, while other failures are silently ignored. Auditability and recovery depend on session snapshots, patch proposals, approvals, and event storage.

**Required changes:**

1. Replace `:ok = ...` persistence calls with helpers such as `persist_patch/2` and `persist_session_snapshot/2`.
2. Log sanitized persistence errors with operation and session id.
3. Emit internal `:persistence_failed` events.
4. Preserve in-memory state when disk writes fail.
5. Make UI or diagnostics able to show durable persistence warnings.

**Acceptance criteria:**

- Disk write failure does not crash `SessionServer` unless explicitly unrecoverable.
- Failure is logged and emitted as a sanitized diagnostic event.
- In-memory state remains consistent.
- Patches/session snapshots do not silently disappear without warning.

**Tests to add:**

- `append_patch` failure does not crash `SessionServer`.
- `append_patch` failure emits `persistence_failed` event.
- `save_session` failure is logged and visible.
- In-memory state remains consistent after persistence failure.

---

### T1-13 — Stream repository search instead of materializing full file lists

**Priority:** P1  
**Primary files:**

- `lib/muse/tools/repo_search.ex`

**Problem:** Repository search currently materializes file lists and uses repeated list concatenation. This defeats early termination and wastes CPU/memory on large repositories.

**Required changes:**

1. Replace recursive eager traversal with a lazy stream/resource walker.
2. Apply file-pattern filtering lazily.
3. Stop walking as soon as `max_results` is reached.
4. Search each file only up to remaining match capacity.
5. Accumulate in reverse and reverse once instead of repeated `++`.
6. Skip inaccessible directories safely.
7. Preserve symlink/path safety rules.

**Acceptance criteria:**

- Search stops after `max_results`.
- Search does not materialize the entire tree before finding first results.
- Inaccessible directories do not crash.
- Large repository memory use is bounded.

**Tests to add:**

- Stops scanning after `max_results`.
- Does not materialize entire tree before first result.
- Handles inaccessible directories without crashing.
- Does not use repeated result concatenation.

---

### T1-14 — Bound per-session events, command history, streaming buffers, and toasts

**Priority:** P1  
**Primary files:**

- `lib/muse/session_server.ex`
- `lib/muse_web/live/home_live.ex`
- `lib/muse/state.ex`

**Problem:** Global state has some bounding, but per-session events and several UI collections can grow indefinitely or be appended with expensive list operations. Long sessions and streaming deltas can accumulate memory and increase render cost.

**Required changes:**

1. Add explicit caps for per-session events, command history, toasts, and streaming buffers.
2. Prefer queue-based or newest-first storage for append-heavy collections.
3. Avoid `existing ++ new_items` on long-lived lists.
4. Drop oldest events first when caps are exceeded.
5. Clear streaming buffers on completion/failure/cancel.
6. Consider LiveView streams for high-frequency event/delta lists.

**Acceptance criteria:**

- Per-session events have a documented cap.
- Oldest events are dropped first.
- Command history is capped and deduplicated.
- Toasts are capped.
- Streaming buffers are cleared after terminal turn events.

**Tests to add:**

- Per-session events are capped.
- Oldest events are dropped first.
- Command history is capped and deduplicated.
- Toasts are capped.
- Streaming buffers are cleared on turn completion/failure/cancel.

---

### T1-15 — Replace whole-log UI recomputation and O(n²) event grouping

**Priority:** P1  
**Primary files:**

- `lib/muse/event_stream.ex`
- `lib/muse/state.ex`
- `lib/muse_web/live/home_live.ex`

**Problem:** Every PubSub event causes the LiveView to fetch and rederive the entire global state. `EventStream.group_by_turn_preserving_order/1` groups by repeatedly filtering the full list for each turn, creating O(n²) behavior. Streaming will amplify this path dramatically.

**Required changes:**

1. Replace O(n²) grouping with a single-pass grouping algorithm.
2. Avoid `Muse.State.get()` on every `{:muse_event, event}`. Use the event already delivered over PubSub to update local assigns incrementally.
3. Store precomputed `chat_messages` in assigns if that is the rendering unit.
4. For the first patch, recalculating `chat_messages` from a bounded local event list is acceptable; the follow-up should update only the affected turn/message.
5. Avoid full `Enum.reverse`, `Enum.filter`, `Enum.group_by`, `Enum.sort_by`, and `Enum.flat_map` chains on every delta when possible.

**Acceptance criteria:**

- `group_by_turn_preserving_order/1` is O(n).
- LiveView event handler does not synchronously fetch full global state on every PubSub event.
- Streaming deltas do not cause quadratic CPU usage.
- Render behavior remains functionally equivalent.

**Tests to add:**

- Grouping preserves original turn order.
- Nil-turn events preserve expected behavior.
- Chat message derivation output matches old implementation for representative fixtures.
- Synthetic large event list completes within a reasonable time.
- LiveView handles PubSub event by updating local assigns.

---

### T1-16 — Optimize `SessionServer` event memory and list-copying hotspots

**Priority:** P1  
**Primary files:**

- `lib/muse/session_server.ex`

**Problem:** `SessionServer` stores a long-lived `events` list and repeatedly appends with `++`, copying historical lists. It also computes `length(state.events)` in status paths. Long sessions will grow heap usage and GC pauses.

**Required changes:**

1. Store per-session events in a bounded `:queue` or equivalent bounded structure.
2. Track `event_count` explicitly instead of calling `length/1` on long lists.
3. Build per-turn event lists in reverse and reverse once at boundaries.
4. Replace all `state.events ++ session_events` style appends with a centralized bounded append.
5. Keep external APIs that require chronological lists by converting the queue to list at API boundaries.

**Acceptance criteria:**

- Appending new events is O(number_of_new_events), not O(total_history).
- Session event retention is bounded.
- Status event count is O(1).
- Existing consumers still receive events in chronological order.

**Tests to add:**

- Event queue cap is enforced.
- Chronological order is preserved when exported/read.
- `event_count` remains correct after cap drops old events.
- Long sequence of appends does not grow beyond cap.

---

### T1-17 — Stream JSONL persistence reads, imports, exports, and patch lookup

**Priority:** P1  
**Primary files:**

- `lib/muse/session_store.ex`
- `lib/muse/session_server.ex`

**Problem:** JSONL helpers read entire files into memory, split them into lists, decode all lines, and sometimes build full export/import strings. Patch lookup loads every patch before finding one. Large sessions can cause avoidable binary heap spikes.

**Required changes:**

1. Replace `File.read` + `String.split` JSONL loading with `File.stream!` line-by-line parsing.
2. Keep invalid-line counting behavior if it exists; do not silently lose diagnostics.
3. Add targeted streaming patch lookup, e.g. `SessionStore.find_patch/3`, instead of loading all patches.
4. Write JSONL imports/exports incrementally with `File.open` and `IO.write` instead of building one giant string.
5. Avoid duplicate startup I/O by passing already-loaded snapshot/memory into restore functions where practical.

**Acceptance criteria:**

- JSONL load memory usage is line-bounded rather than file-bounded.
- Invalid lines are skipped/reported as before.
- Patch lookup does not decode/store all patches at once.
- Import/export handles large sessions without large intermediate strings.

**Tests to add:**

- Loading many JSONL lines returns expected entries.
- Invalid JSONL line increments skipped count.
- `find_patch` finds correct patch without loading unrelated patches into a list.
- JSONL writer writes one line per entry and handles empty entries.

---

### T1-18 — Optimize tool loop CPU, concurrency, and token/API usage

**Priority:** P1  
**Primary files:**

- `lib/muse/conductor/tool_loop.ex`
- `lib/muse/conductor.ex`
- `lib/muse/prompt/project_rules.ex`
- `lib/muse/prompt/assembler.ex`
- Tool modules that produce large outputs

**Problem:** The tool loop repeatedly copies lists with `++`, executes independent tool calls serially, and sends large raw tool outputs back to the model. Prompt layers/project rules may also be rebuilt every turn. This wastes CPU, increases latency, and inflates token/API costs.

**Required changes:**

1. Replace repeated accumulator concatenation with reverse accumulation and one final reverse/flatten.
2. Mark tools as read-only/idempotent vs write/apply/approval. Only read-only independent tools may run concurrently.
3. Use bounded `Task.Supervisor.async_stream_nolink` for parallel read-only tools while preserving ordered results.
4. Keep write/apply/approval/stateful tools serial.
5. Add central `summarize_for_model/1` or equivalent to cap model-facing tool output bytes, map keys, list items, depth, and string lengths.
6. Prefer structured summaries over raw full payloads. Include path, range, status, error, summary, and relevant matches first.
7. Cache project rules and prompt layers by file path, mtime, size, and relevant config. Invalidate when files change.
8. Make truncation explicit to the model so it can request narrower follow-up context if needed.

**Acceptance criteria:**

- Hot accumulators avoid repeated `++` over growing lists.
- Multiple read-only tools can complete in roughly max-tool latency rather than sum-tool latency.
- Tool outputs sent to the model are bounded centrally.
- Large file/search tool output no longer explodes token usage.
- Prompt/project-rule cache invalidates on file changes.

**Tests to add:**

- Tool result accumulation preserves order.
- Read-only tools run concurrently with bounded max concurrency.
- Write/apply tools remain serial.
- Large tool output is truncated/summarized to configured size.
- Truncation marker is present when output is clipped.
- Prompt cache returns cached content when mtime/size unchanged and refreshes when changed.

---

### T2-19 — Replace broad silent rescues with structured diagnostics

**Priority:** P2  
**Primary files:** Multiple modules identified in the source plan

**Problem:** Broad `rescue` blocks and silent failure paths make production failures hard to diagnose and can hide security or persistence issues.

**Required changes:**

1. Replace broad silent rescues with narrow pattern matches where possible.
2. Log sanitized errors using structured metadata.
3. Emit diagnostic events for user-relevant failures.
4. Avoid exposing secrets, full file contents, or raw command output in logs.
5. Use `Logger.warning`/`Logger.error` consistently.

**Acceptance criteria:**

- Expected failures are handled explicitly.
- Unexpected failures are logged with sanitized context.
- No broad rescue silently swallows critical failures.

**Tests to add:**

- Representative failure paths produce logs/events.
- Sanitizer removes sensitive values from diagnostics.

---

### T2-20 — Split very large modules by lifecycle and responsibility

**Priority:** P2  
**Primary files:**

- `lib/muse/session_server.ex`
- `lib/muse/command_dispatcher.ex`
- `lib/muse/conductor.ex`
- `lib/muse/approval_gate.ex`
- LiveView/UI modules as applicable

**Problem:** Very large modules mix lifecycle management, persistence, event emission, tool execution, UI coordination, and recovery. This increases regression risk and makes performance/security patches harder to review.

**Required changes:**

1. Split only after P0/P1 correctness fixes land.
2. Extract pure helpers first: event append/serialization, persistence helpers, turn lifecycle helpers, prompt/cache helpers.
3. Keep public APIs stable during extraction.
4. Add tests around extracted modules before moving more logic.
5. Avoid changing behavior during extraction unless explicitly planned.

**Acceptance criteria:**

- Extracted modules have focused responsibilities.
- Existing tests still pass.
- Public behavior remains stable.
- Future P1/P2 patches become easier to review.

---

### T2-21 — Add CI for tests, formatting, smoke checks, and dependency audits

**Priority:** P2  
**Primary files:**

- `.github/workflows/`
- `mix.exs`
- `package.json` if frontend assets are present

**Problem:** Without CI, regressions in lifecycle, tool validation, security config, and performance helpers are easy to miss.

**Required changes:**

1. Add CI workflow for `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test`.
2. Add dependency audit where supported.
3. Add frontend asset checks if assets are part of the repo.
4. Add a minimal smoke check for app startup/config validation.
5. Run targeted tests for all P0/P1 fixes.

**Acceptance criteria:**

- CI fails on formatting errors, compile warnings, and test failures.
- Dependency/security audit is present or intentionally documented.
- Runtime config validation is covered by tests or smoke checks.

---

### T3-22 — Move cookie and LiveView salts to environment-specific configuration

**Priority:** P3  
**Primary files:**

- `lib/muse_web/endpoint.ex`
- `config/*.exs`

**Problem:** Shared/static cookie and LiveView salts reduce deployment isolation and can be unsafe if reused across environments.

**Required changes:**

1. Move salts to environment-specific config.
2. Require production secrets from environment variables or secret manager.
3. Fail closed if production secrets are missing or default.
4. Keep dev/test convenient but isolated.

**Acceptance criteria:**

- Production uses environment-specific secrets.
- Dev/test can run with safe local defaults.
- No production default secret is accepted silently.

---

### T3-23 — Replace runtime `Mix.env()` calls with application flags

**Priority:** P3  
**Primary files:** Runtime modules and UI components identified in source plan

**Problem:** Calling `Mix.env()` at runtime can break or behave unexpectedly in releases/embedded deployments where Mix is not available.

**Required changes:**

1. Replace runtime `Mix.env()` calls with compile/runtime application config flags.
2. Pass environment-specific behavior through config.
3. Update tests to set flags explicitly.

**Acceptance criteria:**

- App can run in release mode without relying on Mix.
- Environment-dependent UI/runtime behavior still works through config.

---

### T3-24 — Durable UX and reliability improvements tied to the fixes

**Priority:** P2/P3 depending on affected path  
**Primary files:** UI and state modules

**Problem:** Some loading, empty, failure, and incremental update states are tied to the core fixes above. Without UI work, users may not understand why a submit was rejected, a turn failed, or persistence is degraded.

**Required changes:**

1. Add durable loading/running states for active turns.
2. Add durable failure states for provider, tool, persistence, and submit errors.
3. Show clear messages for `:turn_in_progress`, `:submit_timeout`, `:persistence_failed`, and unauthorized external socket access where user-visible.
4. Ensure toasts are capped and not the only place critical state appears.
5. Prefer incremental LiveView updates over whole-state replacement.

**Acceptance criteria:**

- Users can tell when a turn is running.
- Users can cancel/approve while a turn is running.
- Critical failures remain visible after a transient toast disappears.
- UI stays responsive during streaming.

---

## Dependency Map

The following ordering minimizes risk:

1. **T0-01 and T0-02** can be implemented independently and should be first because they close exposure risks.
2. **T0-03** must precede or be developed alongside **T0-04**, because async submit needs a safe active-turn policy.
3. **T0-05** should follow **T0-04**, because live streaming needs the UI to receive PubSub updates while the turn is still active.
4. **T1-15** should follow **T0-05**, because true streaming increases PubSub event frequency and exposes whole-log recomputation costs.
5. **T1-14 and T1-16** should land near **T1-15**, because they bound the memory growth made visible by streaming.
6. **T1-06 and T1-07** should land before **T1-08 and T1-09**, because git metadata and bearer commands should use the hardened execution foundation.
7. **T1-10 and T1-11** can land independently but should precede broad tool-loop concurrency changes.
8. **T1-18** should land after tool validation and output-safety work so concurrent execution does not amplify unsafe behavior.
9. **T2-20 module splitting** should wait until core behavior is fixed and tested.

---

## Cross-Cutting Acceptance Criteria

The overall remediation is complete when these are true:

- Optional external WebSocket access is authenticated and session-authorized.
- Browser control surface is not remotely reachable without explicit authentication or explicit safe configuration.
- Concurrent submits cannot corrupt active turn state.
- Browser submit is non-blocking and UI remains responsive during long turns.
- Provider deltas stream live instead of being buffered until completion.
- Long sessions have bounded server and UI memory growth.
- Event rendering no longer uses O(n²) grouping.
- JSONL persistence uses streaming reads/writes for large files.
- Repository search stops at `max_results` without full tree materialization.
- Child commands do not inherit secrets by default.
- Timeout cleanup handles full process trees where supported.
- Tool calls are schema-validated and safe against malformed LLM output.
- Invalid UTF-8/binary file content does not crash text tools.
- Persistence failures are logged and surfaced without silent loss.
- Tool outputs sent back to the model are centrally bounded and summarized.
- CI covers formatting, compilation, tests, and dependency/security checks.

---

## Suggested Test Suite Layout

A planning agent can add tests incrementally, but the final test suite should include these groups:

```text
test/muse_web/channels/external_socket_auth_test.exs
test/muse_web/channels/session_channel_auth_test.exs
test/muse_web/live/home_live_submit_test.exs
test/muse/session_server_submit_lifecycle_test.exs
test/muse/session_server_event_retention_test.exs
test/muse/conductor_streaming_test.exs
test/muse/event_stream_performance_test.exs
test/muse/session_store_jsonl_stream_test.exs
test/muse/tools/repo_search_stream_test.exs
test/muse/tools/file_text_safety_test.exs
test/muse/tool/runner_validation_test.exs
test/muse/execution/local_runner_env_test.exs
test/muse/execution/local_runner_timeout_test.exs
test/muse/auth/bearer_command_test.exs
test/muse/conductor/tool_loop_efficiency_test.exs
```

Tests should use fake providers/tools where possible. Avoid depending on external network calls, real LLM APIs, or machine-specific process behavior except in tests explicitly tagged for platform support.

---

## Implementation Notes for the Planning Agent

- Use small PR-sized patches. A good patch boundary is one task from the backlog, or one subtask when the task touches critical lifecycle code.
- Prefer introducing helper modules over adding more responsibility to already large modules.
- Preserve public API compatibility where possible, but it is acceptable to add safer APIs and gradually migrate callers.
- When introducing caps, expose them through config with safe defaults.
- When truncating or summarizing data, include explicit metadata such as `truncated?: true`, `original_bytes`, `returned_bytes`, or `more_available?: true`.
- When adding concurrency, keep bounded max concurrency and preserve deterministic ordering of results.
- Do not parallelize tools with side effects, approval semantics, write operations, patch application, or stateful dependencies.
- Sanitize all diagnostics that include tool args, file paths, command output, env vars, provider responses, or raw errors.
- Use structured logging metadata rather than string-concatenated log messages.
- When replacing `++`, verify order. Reverse accumulation is safe only when reversed once at the correct boundary.
- For queue-based state, convert to lists only at public/read boundaries and keep chronological order documented.
- For LiveView incremental updates, preserve reconnect/mount behavior by still being able to reconstruct the initial view from current state.

---

## High-Risk Areas Requiring Extra Review

### Session turn lifecycle

Any change touching `active_turn_id`, `runner_pid`, `runner_task`, `from`, cancellation flags, or terminal turn events requires tests for success, failure, cancellation, stale task result, and concurrent submit.

### Provider streaming

Avoid duplicate assistant deltas. A common mistake is to emit deltas live and still return the buffered delta list at the end. The terminal response should contain final assistant text/state, while already-emitted delta events should not be replayed.

### External sockets and browser auth

Do not add authentication only at the channel layer and leave socket connection unauthenticated. Authenticate at connect and authorize at join.

### Execution environment

Do not start from `System.get_env()` and subtract secrets. Start from an allowlist and add explicit user-configured variables.

### JSONL streaming

Line streaming is safer, but the agent must preserve error/skipped-line behavior and ordering. Avoid changing stored JSON shapes unless the migration is explicit.

### Tool output summarization

Summarization must not hide critical failure data. Keep status, error class, path/range, counts, and truncation metadata even when content is shortened.

---

## Original Source Details Follow

The sections below preserve the detailed original plans. They are included so the planning agent has all line references, code sketches, and test suggestions from both source files. The integrated backlog above is the canonical implementation order.



# Appendix A — Original `fix.md`: Broad Remediation Plan

# Muse remediation plan

This plan is based on a static, read-only review of the uploaded `muse-main.zip`. No source files were modified. The code blocks below are implementation sketches showing how the fixes should be applied in the project; they are not patches that have been applied.

## Priority model

- **P0 — Critical:** likely security exposure, blocked callers, broken core correctness, or externally reachable control surfaces.
- **P1 — High:** major hardening, reliability, or high-impact performance work.
- **P2 — Medium:** maintainability, observability, test/process gaps, and lower-risk correctness work.
- **P3 — Low:** hygiene and release-readiness improvements.

Performance impact is called out separately so performance-related work is visible even when the primary category is security or reliability.

## Recommended implementation order

| Priority | Area | Main files | Performance impact | Primary gain |
|---|---|---|---:|---|
| P0 | External WebSocket authentication and session authorization | `lib/muse_web/channels/user_socket.ex`, `lib/muse_web/channels/session_channel.ex`, `lib/muse_web/external_socket_config.ex` | Low | Prevent unauthorized external event access |
| P0 | Browser LiveView access control / loopback enforcement | `lib/muse_web/router.ex`, `lib/muse_web/endpoint.ex`, `config/*.exs` | Low | Prevent accidental remote control of the local coding agent |
| P0 | Single active turn handling and finite submit calls | `lib/muse/session_server.ex`, callers of `Muse.submit/3` | Medium | Prevent overwritten turns and blocked callers |
| P0 | Non-blocking LiveView submit path | `lib/muse_web/live/home_live.ex`, `lib/muse/session_server.ex` | High | Keep UI responsive during long LLM/tool runs |
| P1 | Execution environment hardening | `lib/muse/execution/local_runner.ex`, `lib/muse/execution/command.ex`, `lib/muse/tools/test_runner.ex` | Low | Stop secret leakage to child commands |
| P1 | Process-tree timeout cleanup | `lib/muse/execution/local_runner.ex`, `lib/muse/execution/runner.ex` | Medium | Avoid orphaned test/build processes |
| P1 | Replace direct `System.cmd/3` git metadata calls | `lib/muse/checkpoint/store.ex` | Medium | Bounded, redacted, logged git execution |
| P1 | Bound bearer command stdout | `lib/muse/auth/bearer_command.ex` | Medium | Prevent memory blowups during credential resolution |
| P1 | Tool input validation and non-raising filesystem handling | `lib/muse/tool/runner.ex`, `lib/muse/tool/registry.ex`, tool modules | Medium | Prevent malformed LLM tool calls from crashing handlers |
| P1 | UTF-8 and binary handling in file tools | `lib/muse/tools/read_file.ex`, `lib/muse/tools/repo_search.ex` | Medium | Avoid crashes on invalid text/binary files |
| P1 | Persistence error handling | `lib/muse/session_server.ex`, `lib/muse/session_store.ex` | Low | Avoid crashes and invisible audit failures |
| P1 | Repository search streaming | `lib/muse/tools/repo_search.ex` | High | Avoid walking/materializing huge repositories unnecessarily |
| P1 | Bounded per-session events, command history, and toasts | `lib/muse/session_server.ex`, `lib/muse_web/live/home_live.ex` | High | Control memory and render cost in long sessions |
| P2 | Structured logging instead of broad silent rescues | Multiple modules | Low | Make production failures diagnosable |
| P2 | Split very large modules | `SessionServer`, `CommandDispatcher`, `Conductor`, `ApprovalGate`, UI modules | Medium | Improve correctness and maintainability |
| P2 | Add CI and security/dependency checks | `.github/workflows/`, `mix.exs`, `package.json` | Low | Catch regressions before release |
| P3 | Environment-specific cookie and LiveView salts | `lib/muse_web/endpoint.ex`, `config/*.exs` | Low | Better deployment isolation |
| P3 | Replace runtime `Mix.env()` calls | Runtime modules and UI components | Low | Improve release/embedded compatibility |

---

# P0-1. Authenticate and authorize the optional external WebSocket

## Finding

The optional external WebSocket accepts any client once enabled. `UserSocket.connect/3` checks only `ExternalSocketConfig.enabled?/0`, and `SessionChannel.join/3` accepts `session:<session_id>` topics based only on session-id shape.

## Why this should be fixed

The external socket can stream session events to non-LiveView clients. Even with event filtering, those events can reveal workflow state, file paths, user prompts, tool outcomes, and other sensitive context. If the endpoint is bound to `0.0.0.0`, tunneled, proxied, or otherwise exposed, any client can connect and subscribe to any session ID that passes format validation.

## Where it appears

- `lib/muse_web/channels/user_socket.ex:18-24`
- `lib/muse_web/channels/session_channel.ex:45-58`
- `lib/muse_web/external_socket_config.ex:62-100`
- `config/config.exs:32-42`
- `config/runtime.exs:3-8`

## Fix gains

- Prevents unauthorized event streaming.
- Enables scoped IDE/bot integrations safely.
- Supports per-session authorization instead of global on/off access.
- Makes accidental external exposure much less dangerous.

## Conceptual fix

1. Add token configuration for the external socket.
2. Store token hashes, not raw token values, in application config.
3. Authenticate the socket in `connect/3`.
4. Assign a principal to the socket.
5. Authorize the requested session during `join/3`.
6. Fail closed when the external socket is enabled but no valid token configuration exists.

## Implementation sketch

Create an auth helper such as `lib/muse_web/external_socket_auth.ex`:

```elixir
defmodule MuseWeb.ExternalSocketAuth do
  @moduledoc false

  @min_token_bytes 32

  @type principal :: %{
          token_id: String.t(),
          sessions: :all | MapSet.t(String.t()),
          scopes: MapSet.t(atom())
        }

  def authenticate(params) when is_map(params) do
    token = Map.get(params, "token") || Map.get(params, :token)

    with true <- is_binary(token),
         true <- byte_size(token) >= @min_token_bytes,
         {:ok, token_config} <- find_matching_token(token) do
      {:ok,
       %{
         token_id: token_config.id,
         sessions: normalize_sessions(token_config.sessions),
         scopes: MapSet.new(token_config.scopes || [:read_events])
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  def authorized_session?(%{scopes: scopes, sessions: sessions}, session_id)
      when is_binary(session_id) do
    MapSet.member?(scopes, :read_events) and session_allowed?(sessions, session_id)
  end

  def authorized_session?(_, _), do: false

  defp find_matching_token(token) do
    token_hash = sha256_hex(token)

    :muse
    |> Application.get_env(:external_ws, [])
    |> Keyword.get(:tokens, [])
    |> Enum.find(fn token_config ->
      expected_hash = Map.get(token_config, :sha256) || Map.get(token_config, "sha256")
      is_binary(expected_hash) and secure_compare(token_hash, expected_hash)
    end)
    |> case do
      nil -> {:error, :unauthorized}
      token_config -> {:ok, normalize_token_config(token_config)}
    end
  end

  defp normalize_token_config(token_config) when is_map(token_config) do
    %{
      id: to_string(Map.get(token_config, :id) || Map.get(token_config, "id") || "external"),
      sha256: Map.get(token_config, :sha256) || Map.get(token_config, "sha256"),
      sessions: Map.get(token_config, :sessions) || Map.get(token_config, "sessions") || :all,
      scopes: Map.get(token_config, :scopes) || Map.get(token_config, "scopes") || [:read_events]
    }
  end

  defp normalize_sessions(:all), do: :all
  defp normalize_sessions("*"), do: :all
  defp normalize_sessions(sessions) when is_list(sessions), do: MapSet.new(Enum.map(sessions, &to_string/1))
  defp normalize_sessions(_), do: MapSet.new()

  defp session_allowed?(:all, _session_id), do: true
  defp session_allowed?(%MapSet{} = sessions, session_id), do: MapSet.member?(sessions, session_id)

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false
end
```

Update `UserSocket` to authenticate and assign the principal:

```elixir
defmodule MuseWeb.UserSocket do
  use Phoenix.Socket

  channel("session:*", MuseWeb.SessionChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    with true <- MuseWeb.ExternalSocketConfig.enabled?(),
         {:ok, principal} <- MuseWeb.ExternalSocketAuth.authenticate(params) do
      {:ok, Phoenix.Socket.assign(socket, :external_principal, principal)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket) do
    case socket.assigns[:external_principal] do
      %{token_id: token_id} -> "external_socket:#{token_id}"
      _ -> nil
    end
  end
end
```

Update `SessionChannel.join/3` to authorize the requested session:

```elixir
def join("session:" <> session_id, _payload, socket) do
  principal = socket.assigns[:external_principal]

  with true <- ExternalSocketConfig.enabled?(),
       true <- ExternalEventFilter.valid_session_id?(session_id),
       true <- MuseWeb.ExternalSocketAuth.authorized_session?(principal, session_id) do
    :ok = Muse.State.subscribe()

    socket =
      socket
      |> Phoenix.Socket.assign(:session_id, session_id)
      |> Phoenix.Socket.assign(:external_principal, principal)

    send(self(), :after_join)
    {:ok, socket}
  else
    _ -> {:error, %{reason: "unauthorized"}}
  end
end
```

Add production runtime config that requires a token when the socket is enabled:

```elixir
# config/runtime.exs
if config_env() == :prod do
  external_ws_enabled? = System.get_env("MUSE_EXTERNAL_WS") == "true"

  if external_ws_enabled? do
    token =
      System.get_env("MUSE_EXTERNAL_WS_TOKEN") ||
        raise "MUSE_EXTERNAL_WS_TOKEN is required when MUSE_EXTERNAL_WS=true"

    if byte_size(token) < 32 do
      raise "MUSE_EXTERNAL_WS_TOKEN must be at least 32 bytes"
    end

    token_hash =
      :crypto.hash(:sha256, token)
      |> Base.encode16(case: :lower)

    config :muse, :external_ws,
      enabled: true,
      replay_limit: String.to_integer(System.get_env("MUSE_EXTERNAL_WS_REPLAY_LIMIT") || "100"),
      tokens: [
        %{
          id: "default",
          sha256: token_hash,
          sessions: :all,
          scopes: [:read_events]
        }
      ]
  end
end
```

For stronger per-session scoping, issue tokens per session rather than granting `sessions: :all`:

```elixir
config :muse, :external_ws,
  enabled: true,
  tokens: [
    %{id: "ide-session-123", sha256: "...", sessions: ["session_123"], scopes: [:read_events]}
  ]
```

## Tests to add

```elixir
describe "external websocket auth" do
  test "rejects connect when socket is disabled"
  test "rejects connect without token when enabled"
  test "rejects connect with invalid token"
  test "accepts connect with valid token"
  test "rejects session join outside token scope"
  test "accepts session join inside token scope"
  test "does not replay events from unauthorized sessions"
end
```

---

# P0-2. Add browser LiveView access control or enforce loopback-only access

## Finding

The browser route has session and CSRF protection, but no authentication. The production endpoint binds to loopback by default, but if it is changed to `0.0.0.0`, proxied, or tunneled, the app has no router-level protection. Development uses `check_origin: false`.

## Why this should be fixed

This application is a local coding agent. The browser UI can submit prompts, trigger tools, view session state, and approve workflows. Relying only on a default loopback bind is fragile because users often run local tools through Docker, tunnels, SSH forwarding, reverse proxies, or cloud workstations.

## Where it appears

- `lib/muse_web/router.ex:4-17`
- `lib/muse_web/endpoint.ex:10-14`
- `config/prod.exs:3-7`
- `config/dev.exs:3-5`

## Fix gains

- Prevents accidental remote control of the agent.
- Makes reverse-proxy/tunnel deployments explicit and safer.
- Gives users a clear failure mode when they expose the service without auth.

## Conceptual fix

Use two accepted access modes:

1. **Local-only mode:** allow loopback requests without auth.
2. **Authenticated mode:** allow non-loopback requests only with a configured token/session.

Fail closed for non-loopback access when no authenticated deployment mode is configured.

## Implementation sketch

Add a browser access plug:

```elixir
defmodule MuseWeb.Plugs.LocalOrAuthenticated do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      loopback?(conn.remote_ip) ->
        conn

      browser_auth_enabled?() and valid_bearer?(conn) ->
        conn

      true ->
        conn
        |> send_resp(:forbidden, "Muse web UI is local-only unless browser auth is configured")
        |> halt()
    end
  end

  defp loopback?({127, _a, _b, _c}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp browser_auth_enabled? do
    :muse
    |> Application.get_env(:browser_auth, [])
    |> Keyword.get(:enabled, false)
  end

  defp valid_bearer?(conn) do
    expected_hash =
      :muse
      |> Application.get_env(:browser_auth, [])
      |> Keyword.get(:token_sha256)

    with "Bearer " <> token <- get_req_header(conn, "authorization") |> List.first(),
         true <- is_binary(expected_hash) do
      actual_hash =
        :crypto.hash(:sha256, token)
        |> Base.encode16(case: :lower)

      byte_size(actual_hash) == byte_size(expected_hash) and
        Plug.Crypto.secure_compare(actual_hash, expected_hash)
    else
      _ -> false
    end
  end
end
```

Use it in the browser pipeline:

```elixir
defmodule MuseWeb.Router do
  use MuseWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MuseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MuseWeb.Plugs.LocalOrAuthenticated
  end

  scope "/", MuseWeb do
    pipe_through :browser
    live "/", HomeLive, :index
  end
end
```

Add runtime config for authenticated browser mode:

```elixir
# config/runtime.exs
if config_env() == :prod do
  case System.get_env("MUSE_BROWSER_TOKEN") do
    nil ->
      config :muse, :browser_auth, enabled: false

    token when byte_size(token) >= 32 ->
      token_hash =
        :crypto.hash(:sha256, token)
        |> Base.encode16(case: :lower)

      config :muse, :browser_auth,
        enabled: true,
        token_sha256: token_hash

    _ ->
      raise "MUSE_BROWSER_TOKEN must be at least 32 bytes when set"
  end
end
```

Tighten origins in dev/prod. Avoid `check_origin: false` except for a narrowly documented local dev case:

```elixir
# config/dev.exs
config :muse, MuseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: ["http://localhost:4000", "http://127.0.0.1:4000"]
```

## Tests to add

```elixir
describe MuseWeb.Plugs.LocalOrAuthenticated do
  test "allows loopback requests without token"
  test "rejects non-loopback request without configured auth"
  test "rejects non-loopback request with invalid bearer token"
  test "allows non-loopback request with valid bearer token when enabled"
end
```

---

# P0-3. Prevent concurrent session submissions from overwriting active turn state

## Finding

`SessionServer.submit/4` uses `GenServer.call(..., :infinity)`, while `do_submit/5` starts a new turn without checking whether another turn is already running. A second submit can overwrite `from`, `runner_pid`, `runner_task`, and `active_turn_id`. The first caller can block indefinitely, and its result can become stale.

## Why this should be fixed

This is a core correctness issue. The application exposes several submit paths, including CLI/TUI/web. Without a single-flight or queueing policy, a rapid double-submit can corrupt the active turn lifecycle and leave callers waiting forever.

## Where it appears

- `lib/muse/session_server.ex:151-154`
- `lib/muse/session_server.ex:481-488`
- `lib/muse/session_server.ex:666-758`
- `lib/muse/session_server.ex:792-824`

## Fix gains

- Prevents caller hangs.
- Prevents stale task results from silently discarding valid turns.
- Makes turn lifecycle predictable.
- Simplifies UI state because there is one explicit policy: reject, queue, or replace.

## Conceptual fix

Start with a safe single-flight policy: reject new submissions while a turn is active. This is the smallest behavior change that fixes correctness. Add a queue later if product behavior requires multi-submit buffering.

Also replace infinite submit calls with a finite, configurable timeout and return explicit error tuples.

## Implementation sketch

Change the public API to allow errors and avoid infinite calls:

```elixir
@default_submit_call_timeout_ms 120_000

@spec submit(pid(), atom(), String.t(), keyword()) ::
        {:ok, String.t()} | {:error, :turn_in_progress | :submit_timeout | term()}
def submit(pid, source, text, opts \\ []) do
  timeout = Keyword.get(opts, :call_timeout_ms, @default_submit_call_timeout_ms)

  GenServer.call(pid, {:submit, source, text, Keyword.delete(opts, :call_timeout_ms)}, timeout)
catch
  :exit, {:timeout, _} -> {:error, :submit_timeout}
  :exit, reason -> {:error, reason}
end
```

Guard the submit handler:

```elixir
@impl true
def handle_call({:submit, source, text, opts}, from, state) do
  if turn_active?(state) do
    reply = {:error, :turn_in_progress}
    state = emit_submit_rejected(state, source, text)
    {:reply, reply, state}
  else
    do_submit(source, text, opts, from, state)
  end
end

# Backward-compatible 3-tuple form
@impl true
def handle_call({:submit, source, text}, from, state) do
  if turn_active?(state) do
    reply = {:error, :turn_in_progress}
    state = emit_submit_rejected(state, source, text)
    {:reply, reply, state}
  else
    do_submit(source, text, [], from, state)
  end
end

defp turn_active?(state) do
  state.runner_task != nil or state.runner_pid != nil or state.status == :running
end

defp emit_submit_rejected(state, source, text) do
  {_event, state} =
    emit_session_event(
      state,
      source,
      :submit_rejected,
      %{reason: :turn_in_progress, user_text_length: String.length(text || "")},
      visibility: :internal
    )

  state
end
```

Make stale task handling observable rather than completely silent:

```elixir
@impl true
def handle_info({ref, _result}, state) do
  Process.demonitor(ref, [:flush])
  Logger.warning("Ignoring stale turn task result", session_id: state.session_id)
  {:noreply, state}
end

@impl true
def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
  Logger.warning("Ignoring stale turn task DOWN", session_id: state.session_id, reason: inspect(reason))
  {:noreply, state}
end
```

If queueing is preferred, add a bounded queue instead of rejection:

```elixir
# State shape
%{
  queued_submissions: :queue.new(),
  max_queued_submissions: 10
}

# On active submit
queued = :queue.in({source, text, opts, from}, state.queued_submissions)
{:noreply, %{state | queued_submissions: queued}}

# After clear_turn_state/1
case :queue.out(state.queued_submissions) do
  {{:value, {source, text, opts, from}}, queue} ->
    state = %{state | queued_submissions: queue}
    do_submit(source, text, opts, from, state)

  {:empty, _queue} ->
    {:noreply, state}
end
```

Use rejection first unless the product explicitly needs queuing. Queues require more UI work: queued status, cancel queued turn, and maximum queue length.

## Tests to add

```elixir
describe "concurrent submit handling" do
  test "rejects a second submit while a turn is running"
  test "does not overwrite active_turn_id on second submit"
  test "does not overwrite original caller"
  test "original caller receives a reply when the first turn completes"
  test "stale task result does not mutate active state"
  test "submit call returns {:error, :submit_timeout} when caller timeout is reached"
end
```

---

# P0-4. Make LiveView submit non-blocking

## Finding

`HomeLive.handle_event("submit", ...)` calls `Muse.submit(:web, msg, opts)` synchronously. The underlying submit call waits for the whole turn to finish.

## Why this should be fixed

A long provider call or tool run can block the LiveView process. While blocked, the UI cannot render updates, react to cancel/approval clicks, handle diagnostics, or show accurate progress. This also amplifies the concurrent-submit problem because the browser event loop is not managed explicitly.

## Where it appears

- `lib/muse_web/live/home_live.ex:116-143`
- `lib/muse/session_server.ex:666-758`

## Fix gains

- Keeps the UI responsive during long turns.
- Allows immediate loading/running state.
- Enables cancellation and approval interactions while the turn is active.
- Reduces LiveView timeout risk.

## Conceptual fix

Add a non-blocking submit API that starts a turn and returns immediately with a `turn_id`. The LiveView should rely on PubSub/session events to stream updates and status changes.

## Implementation sketch

Add an explicit asynchronous session API:

```elixir
# In SessionServer
@spec start_submit(pid(), atom(), String.t(), keyword()) ::
        {:ok, String.t()} | {:error, :turn_in_progress | term()}
def start_submit(pid, source, text, opts \\ []) do
  GenServer.call(pid, {:start_submit, source, text, opts}, 5_000)
end

@impl true
def handle_call({:start_submit, source, text, opts}, _from, state) do
  if turn_active?(state) do
    {:reply, {:error, :turn_in_progress}, state}
  else
    # Start the same turn lifecycle but do not store a blocking caller.
    {turn_id, state} = start_turn_without_sync_reply(source, text, opts, state)
    {:reply, {:ok, turn_id}, state}
  end
end
```

Factor turn startup so sync and async paths share the same implementation:

```elixir
defp start_turn(source, text, opts, reply_to, state) do
  turn_start_time = System.monotonic_time(:millisecond)
  turn_id = generate_turn_id()

  # Existing do_submit setup goes here: user event, queued issue claim,
  # turn_started event, Turn.transition/2, build_turn_session/2, TurnRunner.async/3.

  state = %{
    state
    | status: :running,
      active_turn_id: turn_id,
      runner_pid: task.pid,
      runner_task: task.ref,
      from: reply_to,
      turn_start_time: turn_start_time,
      session_events_before_turn: session_events,
      cancellation_requested: false
  }

  {turn_id, state}
end

defp do_submit(source, text, opts, from, state) do
  {_turn_id, state} = start_turn(source, text, opts, from, state)
  {:noreply, state}
end

defp start_turn_without_sync_reply(source, text, opts, state) do
  start_turn(source, text, opts, nil, state)
end
```

Only reply to a sync caller when one exists:

```elixir
defp reply_to_submitter(nil, _reply), do: :ok
defp reply_to_submitter(from, reply), do: GenServer.reply(from, reply)

# Replace direct GenServer.reply(state.from, ...) calls:
reply_to_submitter(state.from, {:ok, result.assistant_text})
```

Update LiveView to use the non-blocking path:

```elixir
def handle_event("submit", %{"text" => text}, socket) do
  text = String.trim(text)

  case Muse.Commands.parse(text) do
    {:message, msg} when msg != "" ->
      with {:ok, opts} <- RuntimeProvider.resolve_opts(),
           {:ok, turn_id} <- Muse.start_submit(:web, msg, opts) do
        {:noreply,
         socket
         |> assign(input: "", submitting?: true, active_turn_id: turn_id)
         |> push_clear_command_input()}
      else
        {:error, :turn_in_progress} ->
          {:noreply, add_toast(socket, "A turn is already running.", :warning)}

        {:error, reason} ->
          {:noreply, socket |> assign(input: text) |> add_toast(format_error(reason), :error)}
      end

    _ ->
      {:noreply, socket}
  end
end
```

Update `handle_info({:muse_event, event}, socket)` to clear `submitting?` on completion/failure/cancel:

```elixir
submitting? =
  case event.type do
    type when type in [:turn_completed, :turn_failed, :turn_cancelled] -> false
    _ -> socket.assigns[:submitting?] || false
  end

assign(socket, submitting?: submitting?)
```

## Tests to add

```elixir
describe "web submit" do
  test "submit event returns immediately after starting a turn"
  test "UI assigns submitting? while a turn is active"
  test "submit button is disabled or shows busy state while running"
  test "turn_completed clears submitting?"
  test "turn_failed clears submitting? and shows durable error feedback"
end
```

---

# P1-5. Harden child process environments and stop leaking secrets

## Finding

Local commands inherit the BEAM process environment unless variables are explicitly overridden. `test_runner.safe_env/0` starts from `System.get_env()` and only drops proxy variables. Provider credentials, GitHub tokens, cloud credentials, and `MUSE_*` secrets can be inherited by tests or other child commands.

## Why this should be fixed

Workspace commands and tests are arbitrary project code. A malicious or compromised test can read inherited credentials and leak them through files, logs, snapshots, network calls, or encoded output. Output redaction reduces display leakage but does not prevent child processes from accessing the secrets.

## Where it appears

- `lib/muse/execution/command.ex:34`
- `lib/muse/execution/local_runner.ex:12-13`
- `lib/muse/execution/local_runner.ex:179-184`
- `lib/muse/tools/test_runner.ex:341-349`

## Fix gains

- Strong defense against credential exfiltration by child commands.
- More deterministic tests.
- Clearer execution contract: environment inheritance is opt-in, not default.

## Conceptual fix

Create a central environment sanitizer. For ports, explicitly unset all currently present variables that are not allowlisted, then set a minimal safe environment and command-specific overrides. Do not build tool envs from `System.get_env()` unless a specific command opts into inheritance.

## Implementation sketch

Add `lib/muse/execution/env.ex`:

```elixir
defmodule Muse.Execution.Env do
  @moduledoc false

  @default_allowlist ~w(
    PATH HOME USER LOGNAME LANG LC_ALL LC_CTYPE TERM TMPDIR TEMP TMP
    MIX_ENV ERL_FLAGS ELIXIR_ERL_OPTIONS
  )

  @sensitive_patterns [
    ~r/token/i,
    ~r/secret/i,
    ~r/password/i,
    ~r/passphrase/i,
    ~r/api[_-]?key/i,
    ~r/private[_-]?key/i,
    ~r/^MUSE_/,
    ~r/^OPENAI_/,
    ~r/^ANTHROPIC_/,
    ~r/^GITHUB_/,
    ~r/^AWS_/,
    ~r/^GOOGLE_/,
    ~r/^AZURE_/
  ]

  def port_env(overrides \\ %{}, opts \\ []) do
    allowlist = Keyword.get(opts, :allowlist, @default_allowlist) |> MapSet.new()
    inherit? = Keyword.get(opts, :inherit?, false)

    base = if inherit?, do: allowlisted_system_env(allowlist), else: %{}

    env =
      base
      |> Map.merge(default_safe_env())
      |> Map.merge(stringify_map(overrides))
      |> Enum.reject(fn {key, _value} -> sensitive_key?(key) and not MapSet.member?(allowlist, key) end)
      |> Map.new()

    unset =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(env, &1))
      |> Enum.map(fn key -> {String.to_charlist(key), false} end)

    set =
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(to_string(value))}
      end)

    unset ++ set
  end

  def safe_system_env(overrides \\ %{}) do
    port_env(overrides)
    |> Enum.reduce(%{}, fn
      {key, false}, acc -> Map.delete(acc, List.to_string(key))
      {key, value}, acc -> Map.put(acc, List.to_string(key), List.to_string(value))
    end)
  end

  defp allowlisted_system_env(allowlist) do
    System.get_env()
    |> Enum.filter(fn {key, _value} -> MapSet.member?(allowlist, key) and not sensitive_key?(key) end)
    |> Map.new()
  end

  defp default_safe_env do
    %{
      "MIX_ENV" => "test",
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "PATH" => System.get_env("PATH") || "/usr/bin:/bin"
    }
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp stringify_map(list) when is_list(list) do
    Map.new(list, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp stringify_map(_), do: %{}

  defp sensitive_key?(key) do
    Enum.any?(@sensitive_patterns, &Regex.match?(&1, key))
  end
end
```

Update `LocalRunner.build_port_opts/2` to always set the sanitized env:

```elixir
defp build_port_opts(command, _executable_path) do
  base_opts = [
    {:args, command.args},
    :use_stdio,
    :stderr_to_stdout,
    :binary,
    :exit_status
  ]

  opts =
    case command.cwd do
      nil -> base_opts
      cwd -> [{:cd, cwd} | base_opts]
    end

  env = Muse.Execution.Env.port_env(command.env, inherit?: false)
  [{:env, env} | opts]
end
```

Update `TestRunner.safe_env/0` to use the same allowlist instead of `System.get_env()`:

```elixir
defp safe_env do
  Muse.Execution.Env.port_env(%{"MIX_ENV" => "test"}, inherit?: false)
end
```

For commands that truly need inherited environment variables, require an explicit metadata flag and a narrow allowlist:

```elixir
{:ok, cmd} =
  Command.new("some-tool",
    args: args,
    env: %{"SAFE_VAR" => value},
    metadata: %{env_inheritance: :explicit_allowlist}
  )
```

## Tests to add

```elixir
describe Muse.Execution.Env do
  test "unsets MUSE and provider secret variables"
  test "sets MIX_ENV=test for test runner"
  test "does not inherit arbitrary environment by default"
  test "allows explicit safe overrides"
end

describe Muse.Execution.LocalRunner do
  test "child process cannot see OPENAI_API_KEY by default"
  test "child process can see explicitly allowed non-sensitive env"
end
```

---

# P1-6. Terminate full process trees on timeout

## Finding

`LocalRunner` closes the port on timeout, but descendant processes may survive. The module docs acknowledge this, while the implementation comment says “no orphan processes,” which overstates the guarantee.

## Why this should be fixed

Tests and build tools often spawn child processes. Closing only the direct port can leave compilers, watchers, shells, or test subprocesses running. Orphans consume CPU/memory, keep files locked, and can keep writing to the workspace after Muse thinks a command is done.

## Where it appears

- `lib/muse/execution/local_runner.ex:145-160`
- `lib/muse/execution/local_runner.ex:207-230`
- `lib/muse/execution/runner.ex:8-10`

## Fix gains

- Fewer orphaned processes.
- More reliable cancellation/timeout semantics.
- Better resource control on long-running test commands.

## Conceptual fix

Use process-group/session based execution on Unix-like platforms and kill the whole group on timeout. Fall back to current best-effort port closure when process-group cleanup is unavailable. Keep documentation accurate for every platform.

## Implementation sketch

Wrap commands with `setsid` where available:

```elixir
defp executable_and_args_for_port(executable_path, command) do
  case System.find_executable("setsid") do
    nil ->
      {executable_path, command.args, :direct}

    setsid ->
      # --wait keeps setsid as a parent until the child exits on GNU util-linux.
      # If --wait is unavailable on a platform, detect that in tests and fall back.
      {setsid, ["--wait", executable_path | command.args], :process_group}
  end
end
```

Use that in `execute_with_port/3`:

```elixir
defp execute_with_port(%Command{} = command, executable_path, _opts) do
  {port_executable, port_args, cleanup_mode} = executable_and_args_for_port(executable_path, command)
  port_opts = build_port_opts(%{command | args: port_args}, port_executable)
  timeout = command.timeout_ms
  max_output = command.max_output_bytes

  port = Port.open({:spawn_executable, port_executable}, port_opts)

  try do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_output(port, deadline, max_output, command)
  after
    cleanup_port(port, cleanup_mode)
  end
end
```

On timeout, cleanup should terminate the process group when possible:

```elixir
defp cleanup_port(port, :process_group) do
  os_pid = port_os_pid(port)

  if os_pid do
    terminate_process_group(os_pid)
  end

  close_port(port)
end

defp cleanup_port(port, _mode), do: close_port(port)

defp port_os_pid(port) do
  case Port.info(port, :os_pid) do
    {:os_pid, pid} when is_integer(pid) -> pid
    _ -> nil
  end
end

defp terminate_process_group(pid) when is_integer(pid) do
  pgid = "-#{pid}"

  # Fixed executable and fixed signal args only; no user-controlled command string.
  _ = System.cmd("kill", ["-TERM", pgid], stderr_to_stdout: true)
  Process.sleep(200)
  _ = System.cmd("kill", ["-KILL", pgid], stderr_to_stdout: true)
  :ok
rescue
  _ -> :ok
end

defp close_port(port) do
  if Port.info(port) != nil do
    Port.close(port)
  end
rescue
  _ -> :ok
end
```

Also update the docs/comment in `LocalRunner`:

```elixir
# Before:
# Ensure port is closed — no orphan processes

# After:
# Ensure port is closed. On platforms where process-group cleanup is available,
# descendants are terminated best-effort; otherwise descendants may survive.
```

A stronger production-grade alternative is to use a supervised process execution library that provides process-tree cleanup, but the project can get most of the benefit with the process-group approach above.

## Tests to add

```elixir
describe "timeout cleanup" do
  test "timeout returns a timed_out result"
  test "direct child is terminated on timeout"
  test "grandchild process is terminated on Unix when process-group cleanup is available"
  test "cleanup fallback does not crash when os_pid is unavailable"
end
```

---

# P1-7. Route checkpoint git metadata through the hardened runner

## Finding

Checkpoint git metadata uses direct `System.cmd/3` calls without timeout, output caps, sanitized environment, or structured logging. Broad rescues silently return `nil`.

## Why this should be fixed

Git commands can hang, produce unexpectedly large output, inherit secrets, or fail in ways that are important for checkpoint correctness. Silent `nil` values make debugging difficult and can hide a broken rollback/checkpoint safety signal.

## Where it appears

- `lib/muse/checkpoint/store.ex:666-718`

## Fix gains

- Bounded git metadata capture.
- Secret-safe environment.
- Redacted and logged failure reasons.
- Consistent execution semantics with the rest of the app.

## Conceptual fix

Replace each direct `System.cmd/3` with `Muse.Execution.Command` plus `Muse.Execution.LocalRunner`. Use short timeouts and small output caps. Log sanitized failures at debug/warning level.

## Implementation sketch

```elixir
defp try_git_stash_create(workspace), do: run_git(workspace, ["stash", "create"])
defp try_git_rev_parse(workspace), do: run_git(workspace, ["rev-parse", "HEAD"])
defp try_git_branch(workspace), do: run_git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])

defp try_git_dirty?(workspace) do
  case run_git(workspace, ["status", "--porcelain"]) do
    nil -> nil
    output -> output != ""
  end
end

defp run_git(workspace, args) do
  with {:ok, cmd} <-
         Muse.Execution.Command.new("git",
           args: args,
           cwd: workspace,
           timeout_ms: 5_000,
           max_output_bytes: 16_000,
           env: %{"GIT_TERMINAL_PROMPT" => "0"}
         ),
       {:ok, %Muse.Execution.Result{status: :ok, output: output}} <-
         Muse.Execution.LocalRunner.run(cmd) do
    String.trim(output)
  else
    {:ok, %Muse.Execution.Result{} = result} ->
      log_git_metadata_failure(args, result.error || result.status)
      nil

    {:error, reason} ->
      log_git_metadata_failure(args, reason)
      nil
  end
rescue
  exception ->
    log_git_metadata_failure(args, Exception.message(exception))
    nil
end

defp log_git_metadata_failure(args, reason) do
  Logger.debug("Git metadata capture failed",
    git_args: Enum.join(args, " "),
    reason: Muse.MetadataSanitizer.sanitize(reason, max_string_len: 200)
  )
end
```

This depends on P1-5 so `LocalRunner` supplies a safe child environment.

## Tests to add

```elixir
describe "checkpoint git metadata" do
  test "uses bounded runner for git metadata"
  test "returns nil for git failures without crashing"
  test "logs sanitized failure reason"
  test "does not inherit provider secrets into git command environment"
end
```

---

# P1-8. Bound bearer command stdout and avoid unbounded `System.cmd/3` output

## Finding

`BearerCommand` declares an `:output_too_large` error type, but the real `System.cmd/3` path collects full stdout before parsing. A misconfigured command can consume excessive memory.

## Why this should be fixed

Credential resolution happens before provider calls and may run user-configured commands. It should be strictly bounded because a command such as `yes`, `cat largefile`, or a hung cloud CLI can produce huge output.

## Where it appears

- `lib/muse/auth/bearer_command.ex:28-35`
- `lib/muse/auth/bearer_command.ex:197-205`
- `lib/muse/auth/bearer_command.ex:232-246`

## Fix gains

- Prevents memory spikes during credential lookup.
- Makes the documented `:output_too_large` error real.
- Reuses hardened timeout/env/output behavior.

## Conceptual fix

Use the bounded `LocalRunner` path for real command execution, or implement a capped port reader locally. Prefer `LocalRunner` after P1-5/P1-6 are complete.

## Implementation sketch

```elixir
@max_bearer_output_bytes 8_192

defp do_exec(command, nil) do
  {prog, args} = normalize_command(command)

  with {:ok, cmd} <-
         Muse.Execution.Command.new(prog,
           args: args,
           timeout_ms: 5_000,
           max_output_bytes: @max_bearer_output_bytes,
           env: %{}
         ),
       {:ok, %Muse.Execution.Result{status: :ok, output: output}} <-
         Muse.Execution.LocalRunner.run(cmd),
       :ok <- ensure_not_truncated(output) do
    parse_output(output)
  else
    {:ok, %Muse.Execution.Result{status: :timeout}} ->
      {:error, {:timeout, "bearer_command"}}

    {:ok, %Muse.Execution.Result{} = result} ->
      {:error, {:exec_failed, result.error || "command exited with non-zero status"}}

    {:error, reason} ->
      {:error, {:exec_failed, safe_exit_reason(reason)}}
  end
end

defp ensure_not_truncated(output) when byte_size(output) >= @max_bearer_output_bytes do
  {:error, :output_too_large}
end

defp ensure_not_truncated(_), do: :ok
```

If `LocalRunner.Result` does not currently expose `truncated?`, add that field. It is more accurate than inferring from byte size:

```elixir
defstruct [
  :id,
  :status,
  :output,
  :error,
  :exit_status,
  :duration_ms,
  truncated?: false,
  metadata: %{}
]
```

Then check:

```elixir
defp ensure_not_truncated(%{truncated?: true}), do: {:error, :output_too_large}
defp ensure_not_truncated(_), do: :ok
```

## Tests to add

```elixir
describe Muse.Auth.BearerCommand do
  test "returns :output_too_large for oversized stdout"
  test "does not include stdout in error messages"
  test "times out long-running commands"
  test "does not inherit provider secrets into bearer command env"
end
```

---

# P1-9. Add strict tool input validation and replace bang filesystem calls

## Finding

Tool specs define schemas, but `Tool.Runner` checks only required keys. Several tool arguments are then used without type/range validation. `File.ls!/1` can raise after a directory check if the directory is removed or permissions change.

## Why this should be fixed

Tool calls are influenced by LLM output and user input. Malformed values such as strings, negative integers, floats, huge caps, or invalid patterns should return tool errors, not crash handlers or create excessive work.

## Where it appears

- `lib/muse/tool/runner.ex:219-232`
- `lib/muse/tool/registry.ex:95-193`
- `lib/muse/tools/list_files.ex:35-50`, `79-82`, `122-128`
- `lib/muse/tools/read_file.ex:147-168`
- `lib/muse/tools/repo_search.ex:40-45`

## Fix gains

- Prevents crashes from malformed tool args.
- Makes LLM tool failures predictable and user-safe.
- Reduces duplicated validation logic in individual tools.

## Conceptual fix

Implement a small schema validator for the subset used by the project: required fields, scalar types, integer minimum/maximum, string max length, and boolean type checks. Update registry schemas with bounds. Validate before executing handlers.

## Implementation sketch

Add `lib/muse/tool/input_validator.ex`:

```elixir
defmodule Muse.Tool.InputValidator do
  @moduledoc false

  def validate(args, %{input_schema: schema}) when is_map(args) and is_map(schema) do
    required = Map.get(schema, :required) || Map.get(schema, "required") || []
    properties = Map.get(schema, :properties) || Map.get(schema, "properties") || %{}

    with :ok <- validate_required(args, required),
         :ok <- validate_properties(args, properties) do
      {:ok, args}
    end
  end

  def validate(_args, _spec), do: {:error, "invalid tool schema"}

  defp validate_required(args, required) do
    missing = Enum.filter(required, fn key -> not Map.has_key?(args, key) end)

    case missing do
      [] -> :ok
      _ -> {:error, "missing required arguments: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_properties(args, properties) do
    Enum.reduce_while(args, :ok, fn {key, value}, :ok ->
      case Map.get(properties, key) || Map.get(properties, to_string(key)) do
        nil ->
          {:cont, :ok}

        property_schema ->
          case validate_value(key, value, property_schema) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp validate_value(key, value, schema) do
    type = Map.get(schema, :type) || Map.get(schema, "type")

    with :ok <- validate_type(key, value, type),
         :ok <- validate_minimum(key, value, schema),
         :ok <- validate_maximum(key, value, schema),
         :ok <- validate_max_length(key, value, schema) do
      :ok
    end
  end

  defp validate_type(_key, _value, nil), do: :ok
  defp validate_type(key, value, "string") when not is_binary(value), do: {:error, "#{key} must be a string"}
  defp validate_type(key, value, "integer") when not is_integer(value), do: {:error, "#{key} must be an integer"}
  defp validate_type(key, value, "boolean") when not is_boolean(value), do: {:error, "#{key} must be a boolean"}
  defp validate_type(_key, _value, _), do: :ok

  defp validate_minimum(key, value, schema) when is_integer(value) do
    case Map.get(schema, :minimum) || Map.get(schema, "minimum") do
      nil -> :ok
      min when value >= min -> :ok
      min -> {:error, "#{key} must be >= #{min}"}
    end
  end

  defp validate_minimum(_key, _value, _schema), do: :ok

  defp validate_maximum(key, value, schema) when is_integer(value) do
    case Map.get(schema, :maximum) || Map.get(schema, "maximum") do
      nil -> :ok
      max when value <= max -> :ok
      max -> {:error, "#{key} must be <= #{max}"}
    end
  end

  defp validate_maximum(_key, _value, _schema), do: :ok

  defp validate_max_length(key, value, schema) when is_binary(value) do
    case Map.get(schema, :maxLength) || Map.get(schema, "maxLength") do
      nil -> :ok
      max when byte_size(value) <= max -> :ok
      max -> {:error, "#{key} must be at most #{max} bytes"}
    end
  end

  defp validate_max_length(_key, _value, _schema), do: :ok
end
```

Call it from `Tool.Runner` after spec lookup and before approval/execution:

```elixir
with {:ok, spec} <- Registry.fetch(tool_name),
     {:ok, args} <- Muse.Tool.InputValidator.validate(args, spec),
     :ok <- validate_muse_allowed(spec, muse_id),
     :ok <- validate_approval(spec, args, context) do
  execute_handler(spec, args, context)
else
  {:error, reason} ->
    Result.error(tool_name, reason)
end
```

Add bounds to registry schemas:

```elixir
max_entries: %{
  type: "integer",
  minimum: 1,
  maximum: 2_000,
  description: "Maximum number of entries to return"
}

start_line: %{type: "integer", minimum: 1, maximum: 1_000_000}
end_line: %{type: "integer", minimum: 1, maximum: 1_000_000}
max_lines: %{type: "integer", minimum: 1, maximum: 2_000}
max_results: %{type: "integer", minimum: 1, maximum: 1_000}
pattern: %{type: "string", maxLength: 1_000}
file_pattern: %{type: "string", maxLength: 500}
```

Replace `File.ls!/1` in `ListFiles`:

```elixir
defp do_list(resolved, workspace, allow_hidden) do
  case File.ls(resolved) do
    {:ok, entries} ->
      entries
      |> Enum.reject(fn entry -> reject_entry?(resolved, workspace, entry, allow_hidden) end)
      |> Enum.flat_map(fn entry -> format_entry(resolved, workspace, entry, allow_hidden) end)

    {:error, :enoent} ->
      {:error, "directory no longer exists"}

    {:error, :eacces} ->
      {:error, "permission denied"}

    {:error, reason} ->
      {:error, "directory read error: #{inspect(reason)}"}
  end
end
```

Then adapt `execute/2` to handle `{:error, reason}` from `do_list/3`:

```elixir
with {:ok, resolved} <- safe_resolve(rel_path, workspace, opts),
     {:ok, _} <- ensure_directory(resolved),
     {:ok, entries} <- list_entries(resolved, workspace, allow_hidden) do
  {visible, truncated?} = cap_entries(entries, max_entries)
  Result.ok("list_files", %{root: workspace, entries: visible, truncated: truncated?})
else
  {:error, reason} -> Result.error("list_files", reason)
end
```

## Tests to add

```elixir
describe "tool input validation" do
  test "rejects non-integer max_entries"
  test "rejects negative max_entries"
  test "rejects oversized max_results"
  test "rejects non-string pattern"
  test "rejects non-integer read_file line args"
  test "list_files handles deleted directory race without raising"
end
```

---

# P1-10. Validate UTF-8 before using `String.*` in file tools

## Finding

Binary detection checks for NUL bytes only, then `String.split/2`, `String.contains?/2`, and `String.slice/3` are applied to arbitrary bytes. Invalid UTF-8 files or truncation in the middle of a multibyte character can raise.

## Why this should be fixed

File tools must be robust against arbitrary repository contents. Many repos contain generated files, binary-adjacent files, files in non-UTF-8 encodings, or partially written files. A read/search tool should return a clear error or skip invalid files, not crash.

## Where it appears

- `lib/muse/tools/read_file.ex:93-145`
- `lib/muse/tools/read_file.ex:171-180`
- `lib/muse/tools/repo_search.ex:163-208`

## Fix gains

- Prevents file tool crashes.
- Gives users clear encoding/truncation errors.
- Makes repo search safer on mixed-content repos.

## Conceptual fix

After bounded binary read and NUL detection, validate UTF-8. When truncating, preserve only a valid UTF-8 prefix. `read_file` should return an error for invalid UTF-8. `repo_search` should skip invalid UTF-8 files and optionally count skipped files.

## Implementation sketch

Add a shared helper:

```elixir
defmodule Muse.Tools.TextEncoding do
  @moduledoc false

  def text_from_bounded_binary(bin, max_bytes) when is_binary(bin) do
    sample_size = min(byte_size(bin), 8_192)
    <<sample::binary-size(sample_size), _::binary>> = bin

    cond do
      :binary.match(sample, <<0>>) != :nomatch ->
        {:error, :binary}

      byte_size(bin) > max_bytes ->
        bin
        |> binary_part(0, max_bytes)
        |> validate_utf8_prefix()
        |> case do
          {:ok, text} -> {:ok, text, true}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case :unicode.characters_to_binary(bin, :utf8, :utf8) do
          text when is_binary(text) -> {:ok, text, false}
          {:error, _valid_prefix, _rest} -> {:error, :invalid_utf8}
          {:incomplete, valid_prefix, _rest} -> {:ok, valid_prefix, true}
        end
    end
  end

  defp validate_utf8_prefix(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      text when is_binary(text) -> {:ok, text}
      {:incomplete, valid_prefix, _rest} -> {:ok, valid_prefix}
      {:error, _valid_prefix, _rest} -> {:error, :invalid_utf8}
    end
  end
end
```

Use it in `ReadFile.read_text/1`:

```elixir
bin when is_binary(bin) ->
  case Muse.Tools.TextEncoding.text_from_bounded_binary(bin, @max_bytes) do
    {:ok, content, truncated} -> {:ok, content, truncated}
    {:error, :binary} -> {:error, "binary files are not supported"}
    {:error, :invalid_utf8} -> {:error, "file is not valid UTF-8 text"}
  end
```

Make output capping UTF-8-safe:

```elixir
defp cap_output(text_lines) do
  joined = Enum.join(text_lines, "\n")

  if byte_size(joined) > @max_bytes do
    {:ok, safe_utf8_prefix(joined, @max_bytes), true}
  else
    {:ok, joined, false}
  end
end

defp safe_utf8_prefix(text, max_bytes) do
  text
  |> binary_part(0, min(byte_size(text), max_bytes))
  |> Muse.Tools.TextEncoding.valid_utf8_prefix!()
end
```

For `repo_search`, skip invalid text files:

```elixir
defp search_file(full_path, rel_path, pattern, max_matches) do
  with {:ok, bin} <- read_bounded(full_path, @max_per_file_bytes + 1),
       {:ok, content, _truncated?} <- Muse.Tools.TextEncoding.text_from_bounded_binary(bin, @max_per_file_bytes) do
    search_lines(content, rel_path, pattern, max_matches)
  else
    {:error, :binary} -> []
    {:error, :invalid_utf8} -> []
    {:error, _reason} -> []
  end
end
```

## Tests to add

```elixir
describe "file tool text encoding" do
  test "read_file rejects invalid UTF-8"
  test "read_file handles truncation at multibyte boundary"
  test "repo_search skips invalid UTF-8 files without crashing"
  test "repo_search skips binary files with NUL bytes"
end
```

---

# P1-11. Handle persistence failures explicitly

## Finding

Some persistence writes are pattern-matched as `:ok`, which can crash the session process. Other persistence failures are silently ignored.

## Why this should be fixed

Patch proposals, session snapshots, and approvals are part of auditability and recovery. If disk writes fail because of permissions, disk pressure, invalid data, or directory issues, the app should not silently lose audit data or crash unexpectedly.

## Where it appears

- `lib/muse/session_server.ex:876-885`
- `lib/muse/session_server.ex:1618-1621`
- `lib/muse/session_server.ex:2393-2418`

## Fix gains

- Avoids avoidable session crashes.
- Makes audit/persistence failures visible.
- Gives the UI a durable failure state instead of silent data loss.

## Conceptual fix

Replace `:ok = ...` and ignored `{:error, _}` with a persistence helper that logs sanitized errors, emits diagnostics, and records a state-level persistence warning if needed.

## Implementation sketch

```elixir
defp persist_patch(state, %Patch{} = patch) do
  case SessionStore.append_patch(state.store_base_dir, state.session_id, Patch.to_map(patch)) do
    :ok ->
      state

    {:error, reason} ->
      handle_persistence_failure(state, :append_patch, reason)
  end
end

defp persist_session_snapshot(state, data) do
  case SessionStore.save_session(state.store_base_dir, state.session_id, data) do
    :ok ->
      state

    {:error, reason} ->
      handle_persistence_failure(state, :save_session, reason)
  end
end

defp handle_persistence_failure(state, operation, reason) do
  safe_reason =
    Muse.MetadataSanitizer.sanitize(reason,
      max_depth: 3,
      max_map_keys: 10,
      max_list_length: 5,
      max_string_len: 200
    )

  Logger.error("Session persistence failed",
    session_id: state.session_id,
    operation: operation,
    reason: inspect(safe_reason)
  )

  {_event, state} =
    emit_session_event(
      state,
      :system,
      :persistence_failed,
      %{operation: operation, reason: safe_reason},
      visibility: :internal
    )

  state
end
```

Replace patch persistence sites:

```elixir
state =
  if pending_patch != nil and not had_pending_patch_before and match?(%Patch{}, pending_patch) do
    persist_patch(state, pending_patch)
  else
    state
  end
```

And:

```elixir
# Persist to patches.jsonl
state = persist_patch(state, patch)
```

Update snapshot persistence:

```elixir
defp maybe_persist_snapshot(state) do
  if state.plan != nil or state.pending_patch != nil or state.pending_remote_approval != nil do
    data = build_snapshot_data(state)
    persist_session_snapshot(state, data)
  else
    state
  end
end
```

## Tests to add

```elixir
describe "session persistence failure handling" do
  test "append_patch failure does not crash SessionServer"
  test "append_patch failure emits persistence_failed event"
  test "save_session failure is logged and visible"
  test "in-memory state remains consistent after persistence failure"
end
```

---

# P1-12. Stream repository search instead of materializing full file lists

## Finding

`repo_search` comments describe early termination, but the traversal builds full lists with recursive `Enum.flat_map/2` before reducing results. It also appends results with `results ++ file_results`.

## Why this should be fixed

Large repositories can contain tens or hundreds of thousands of files. Materializing the full tree defeats early termination and can waste memory/CPU even when `max_results` is small. Repeated list concatenation increases allocation overhead.

## Where it appears

- `lib/muse/tools/repo_search.ex:73-90`
- `lib/muse/tools/repo_search.ex:95-127`
- `lib/muse/tools/repo_search.ex:201-208`

## Fix gains

- Major performance improvement on large repositories.
- Lower memory use.
- Faster first results.
- Better honoring of `max_results`.

## Conceptual fix

Use lazy traversal and stop scanning when enough results have been found. Search each file only up to the remaining match capacity. Accumulate in reverse and reverse once at the end.

## Implementation sketch

```elixir
defp scan_workspace(workspace, pattern, file_pattern, max_results) do
  workspace
  |> walk_workspace_stream(workspace)
  |> Stream.filter(&file_pattern_match?(&1, file_pattern))
  |> Enum.reduce_while({[], 0, false}, fn rel, {acc, count, _more?} ->
    remaining = max_results - count

    if remaining <= 0 do
      {:halt, {acc, count, true}}
    else
      full = Path.join(workspace, rel)
      file_results = search_file(full, rel, pattern, remaining)
      new_count = count + length(file_results)
      new_acc = Enum.reverse(file_results) ++ acc

      if new_count >= max_results do
        {:halt, {new_acc, new_count, true}}
      else
        {:cont, {new_acc, new_count, false}}
      end
    end
  end)
  |> case do
    {acc, _count, more?} -> {Enum.reverse(acc), more?}
  end
end
```

Add a lazy walker:

```elixir
defp walk_workspace_stream(root, workspace) do
  Stream.resource(
    fn -> [root] end,
    fn
      [] ->
        {:halt, []}

      [dir | stack] ->
        case File.ls(dir) do
          {:ok, entries} ->
            {files, dirs} = partition_entries(dir, entries, workspace)
            {files, dirs ++ stack}

          {:error, _reason} ->
            {[], stack}
        end
    end,
    fn _ -> :ok end
  )
end

defp partition_entries(dir, entries, workspace) do
  entries
  |> Enum.reject(&hidden_entry?/1)
  |> Enum.reduce({[], []}, fn entry, {files, dirs} ->
    full = Path.join(dir, entry)
    rel = Path.relative_to(full, workspace)

    if not safe_to_access?(full, workspace) do
      {files, dirs}
    else
      case File.lstat(full) do
        {:ok, %File.Stat{type: :directory}} ->
          {files, [full | dirs]}

        {:ok, %File.Stat{type: :symlink}} ->
          if File.dir?(full), do: {files, [full | dirs]}, else: {[rel | files], dirs}

        {:ok, %File.Stat{type: :regular}} ->
          {[rel | files], dirs}

        _ ->
          {files, dirs}
      end
    end
  end)
end
```

Limit matches per file:

```elixir
defp search_lines(content, rel_path, pattern, max_matches) do
  content
  |> String.split("\n")
  |> Stream.with_index(1)
  |> Stream.filter(fn {line, _idx} -> String.contains?(line, pattern) end)
  |> Stream.map(fn {line, idx} ->
    %{file: rel_path, line: idx, excerpt: String.slice(line, 0, 200)}
  end)
  |> Enum.take(max_matches)
end
```

## Tests to add

```elixir
describe "repo_search performance" do
  test "stops scanning after max_results"
  test "does not materialize entire tree before first result"
  test "handles inaccessible directories without crashing"
  test "does not use repeated result concatenation"
end
```

---

# P1-13. Bound per-session events, command history, streaming buffers, and toasts

## Finding

Global `Muse.State` event storage is bounded, but per-session events and several UI collections are appended with `++` and do not appear capped the same way. Long sessions can accumulate memory and render cost.

## Why this should be fixed

Long-running coding sessions can produce many deltas, tool events, approval events, logs, command history entries, and toasts. Unbounded in-memory state affects both server memory and LiveView rendering performance.

## Where it appears

- `lib/muse/session_server.ex:919`
- `lib/muse/session_server.ex:992`
- `lib/muse/session_server.ex:1041`
- `lib/muse/session_server.ex:2187-2189`
- `lib/muse_web/live/home_live.ex:160-180`
- `lib/muse_web/live/home_live.ex:903-912`

## Fix gains

- Better long-session performance.
- Bounded memory use.
- Lower LiveView diff/render cost.
- Less risk of browser slowdowns from very large assigns.

## Conceptual fix

Add explicit caps for per-session event history and UI collections. Prefer newest-first lists or LiveView streams for frequently appended data. For a first fix, cap existing lists after append.

## Implementation sketch

Add constants/config:

```elixir
@max_session_events Application.compile_env(:muse, :max_session_events, 2_000)
@max_command_history Application.compile_env(:muse, :max_command_history, 100)
@max_toasts 5
```

Centralize bounded event appends:

```elixir
defp append_session_events(state, new_events) when is_list(new_events) do
  %{state | events: bounded_append(state.events, new_events, @max_session_events)}
end

defp bounded_append(existing, new_items, max) do
  combined = existing ++ new_items
  overflow = length(combined) - max

  if overflow > 0 do
    Enum.drop(combined, overflow)
  else
    combined
  end
end
```

Replace repeated direct appends:

```elixir
# Before
updated_events = state.events ++ session_events
state = %{state | events: updated_events}

# After
state = append_session_events(state, session_events)
```

For command history, store newest-first and cap:

```elixir
defp remember_command(socket, command) do
  history =
    [command | socket.assigns.command_history]
    |> Enum.uniq()
    |> Enum.take(@max_command_history)

  assign(socket, command_history: history)
end
```

For toasts:

```elixir
defp add_toast(socket, message, level) do
  toast = %{id: System.unique_integer([:positive]), message: message, level: level}

  update(socket, :toasts, fn toasts ->
    [toast | toasts]
    |> Enum.take(@max_toasts)
  end)
end
```

For high-frequency assistant deltas, move toward LiveView streams or store buffers by `turn_id` only, not every chunk as a full message assign:

```elixir
stream(socket, :events, [event], at: -1, limit: -500)
```

## Tests to add

```elixir
describe "bounded session state" do
  test "per-session events are capped"
  test "oldest events are dropped first"
  test "command history is capped and deduplicated"
  test "toasts are capped"
  test "streaming buffers are cleared on turn completion/failure/cancel"
end
```

---

# P2-14. Replace broad silent rescues with structured diagnostics

## Finding

Broad rescues often convert failures into `nil` values or transient UI toasts without structured logging. This hides operational issues and makes production debugging harder.

## Why this should be fixed

Unexpected exceptions in checkpointing, patch application, runtime provider resolution, and LiveView handling can signal real data loss or broken safety invariants. Silent failure makes those problems hard to detect.

## Where it appears

- `lib/muse_web/live/home_live.ex:129-143`
- `lib/muse_web/live/home_live.ex:280-282`
- `lib/muse/checkpoint/store.ex:681-718`
- `lib/muse/tools/patch_apply.ex:481-483`

## Fix gains

- Better debugging and incident response.
- More accurate operational health.
- Safer distinction between expected errors and unexpected exceptions.

## Conceptual fix

Use narrow rescue clauses for expected failures. For unexpected exceptions, log sanitized error details and emit telemetry/diagnostic events. Do not expose raw exception details to users.

## Implementation sketch

```elixir
defp safe_unexpected_error(context, exception, stacktrace) do
  safe_message =
    exception
    |> Exception.message()
    |> Muse.Prompt.Redactor.redact_text()
    |> String.slice(0, 300)

  Logger.error("Unexpected Muse error",
    context: context,
    error: safe_message,
    stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 2_000)
  )

  :telemetry.execute(
    [:muse, :error, :unexpected],
    %{count: 1},
    %{context: context, error: safe_message}
  )
end
```

Use it in LiveView:

```elixir
try do
  # operation
rescue
  e in [Muse.ProviderConfigError] ->
    {:noreply, add_toast(socket, Exception.message(e), :error)}

  e ->
    safe_unexpected_error(:home_live_submit, e, __STACKTRACE__)
    {:noreply, add_toast(socket, "Unexpected error while submitting message.", :error)}
end
```

For checkpoint metadata, return `nil` only after logging a sanitized failure:

```elixir
rescue
  e in [File.Error] ->
    log_checkpoint_failure(:file_error, e)
    nil

  e ->
    log_checkpoint_failure(:unexpected, e)
    nil
end
```

## Tests to add

```elixir
describe "diagnostics" do
  test "unexpected LiveView submit exception is logged with sanitized message"
  test "checkpoint git failure logs sanitized reason"
  test "user-facing error does not expose raw exception details"
end
```

---

# P2-15. Split very large modules by lifecycle and responsibility

## Finding

Several modules are very large and mix orchestration, state mutation, persistence, protocol handling, and UI behavior.

## Why this should be fixed

Large modules increase cognitive load and make regression boundaries unclear. Core invariants such as “one active turn per session,” “patch approval requires approved plan context,” and “persistence failure must be surfaced” become harder to maintain.

## Where it appears

- `lib/muse/session_server.ex`
- `lib/muse/command_dispatcher.ex`
- `lib/muse/conductor.ex`
- `lib/muse/approval_gate.ex`
- `lib/muse_web/console_components.ex`
- `lib/muse/llm/openai_compatible_provider.ex`
- `lib/muse/cli/tui.ex`

## Fix gains

- Easier review and testing.
- More stable invariants.
- Smaller, targeted unit tests.
- Easier onboarding for future developers.

## Conceptual fix

Refactor gradually after the P0/P1 correctness fixes. Do not start by moving everything. Extract modules around stable boundaries.

## Implementation sketch

Suggested `SessionServer` extraction boundaries:

```elixir
defmodule Muse.Session.TurnLifecycle do
  @moduledoc false

  def active?(state), do: state.runner_task != nil or state.runner_pid != nil or state.status == :running

  def start(state, source, text, opts, reply_to) do
    # Build Turn, emit user/turn_started events, start TurnRunner.
    # Return {:ok, turn_id, state} or {:error, reason, state}.
  end

  def complete_success(state, result) do
    # Fold event specs, persist snapshots, reply to sync caller, clear state.
  end

  def complete_failure(state, reason) do
    # Emit sanitized failure, reply to sync caller, clear state.
  end

  def cancel(state) do
    # Cancel active runner and update cancellation flag.
  end
end
```

Patch lifecycle boundary:

```elixir
defmodule Muse.Session.PatchLifecycle do
  @moduledoc false

  def create_proposal(state, patch_attrs) do
    # Validate approved plan context, create patch proposal, persist patch.
  end

  def approve(state, source), do: decide(state, source, :approved)
  def reject(state, source), do: decide(state, source, :rejected)

  defp decide(state, source, decision) do
    # Existing patch lifecycle decision logic.
  end
end
```

Persistence boundary:

```elixir
defmodule Muse.Session.Persistence do
  @moduledoc false

  def persist_patch(state, patch), do: # wrapper from P1-11
  def persist_snapshot(state), do: # wrapper from P1-11
  def restore(state), do: # snapshot + memory restore
end
```

Command dispatcher boundary:

```elixir
defmodule Muse.CommandDispatcher.Router do
  def route(command), do: # parse command into typed command struct
end

defmodule Muse.CommandDispatcher.Executor do
  def execute(%Muse.Command{} = command, context), do: # command-specific work
end
```

UI boundary:

```elixir
defmodule MuseWeb.HomeLive.SubmitController do
  def submit(socket, text), do: # parse, resolve provider, start async submit
end

defmodule MuseWeb.HomeLive.EventReducer do
  def reduce(socket, %Muse.Event{} = event), do: # streaming buffers, patch panel, status
end
```

## Tests to add

Add tests for each extracted module before moving more logic:

```elixir
describe Muse.Session.TurnLifecycle do
  test "active?/1 detects runner task/pid/status"
  test "start/5 sets exactly one active turn"
  test "complete_success/2 clears active turn state"
end
```

---

# P2-16. Add CI for tests, formatting, smoke checks, and dependency audits

## Finding

The only GitHub workflow found is a release workflow. I did not find a push/PR CI workflow for compile, tests, formatting, browser smoke tests, static analysis, or dependency audit.

## Why this should be fixed

The project has broad tests and documentation that imply quality gates. Without CI, regressions can enter before release. Security-sensitive code needs continuous checks.

## Where it appears

- `.github/workflows/release.yml:14-68`
- `mix.exs:50-55`
- `package.json:6-12`
- `docs/testing.md`

## Fix gains

- Catches regressions before release.
- Enforces documented quality gates.
- Makes dependency/security issues visible earlier.

## Conceptual fix

Add a PR/push workflow that runs Elixir formatting, compile, tests, optional browser smoke tests, and dependency audits.

## Implementation sketch

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  elixir:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          otp-version: '27'
          elixir-version: '1.17'

      - name: Restore dependencies cache
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-

      - name: Install dependencies
        run: mix deps.get

      - name: Check formatting
        run: mix format --check-formatted

      - name: Compile with warnings as errors
        run: mix compile --warnings-as-errors

      - name: Run tests
        run: mix test

      - name: Dependency audit
        run: mix deps.audit
        continue-on-error: false

  assets-and-smoke:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
          cache-dependency-path: package-lock.json

      - name: Install npm dependencies
        run: npm ci

      - name: NPM audit
        run: npm audit --audit-level=moderate

      - name: Install Playwright browsers
        run: npx playwright install --with-deps chromium

      - uses: erlef/setup-beam@v1
        with:
          otp-version: '27'
          elixir-version: '1.17'

      - name: Install Elixir dependencies
        run: mix deps.get

      - name: Run LiveView browser smoke tests
        run: npm run smoke
```

If `mix deps.audit` is not currently available, add a dependency such as `mix_audit` or replace that step with the project’s chosen audit tool.

## Tests to add

The workflow itself is the test. Also update `docs/testing.md` so it matches the actual CI gates.

---

# P3-17. Move cookie and LiveView salts to environment-specific configuration

## Finding

Cookie and LiveView signing salts are hardcoded placeholders. `MUSE_SECRET_KEY_BASE` is enforced in production, but fixed salts reduce environment isolation.

## Why this should be fixed

The secret key base is the main secret, but salts should still be environment-specific so dev/test/prod are clearly separated and deployments can rotate values deliberately.

## Where it appears

- `lib/muse_web/endpoint.ex:4-8`
- `config/config.exs:8-14`
- `config/runtime.exs:18-40`

## Fix gains

- Better separation between environments.
- Clearer deployment hygiene.
- Easier rotation process.

## Conceptual fix

Move session options and LiveView signing salt to config values. For compile-time endpoint/socket options, use environment-specific config files and document that changing salts requires rebuilding/restarting the release as appropriate.

## Implementation sketch

```elixir
# config/config.exs
config :muse, :session_options,
  store: :cookie,
  key: "_muse_key",
  signing_salt: "dev-session-signing-salt",
  same_site: "Lax",
  http_only: true

config :muse, MuseWeb.Endpoint,
  live_view: [signing_salt: "dev-live-view-signing-salt"]
```

```elixir
# config/prod.exs
config :muse, :session_options,
  store: :cookie,
  key: "_muse_key",
  signing_salt: System.get_env("MUSE_SESSION_SIGNING_SALT") || "replace-at-build-time",
  same_site: "Lax",
  secure: true,
  http_only: true
```

Because `System.get_env/1` in `prod.exs` is evaluated at build/config time, prefer a release-safe approach if this must be runtime-configurable. One option is to initialize the session plug dynamically rather than using a module attribute.

```elixir
defmodule MuseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :muse

  @session_options Application.compile_env!(:muse, :session_options)

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], log: false]
  )

  plug Plug.Session, @session_options
  plug MuseWeb.Router
end
```

Also set production LiveView salt:

```elixir
# config/runtime.exs
if config_env() == :prod do
  live_view_salt =
    System.get_env("MUSE_LIVE_VIEW_SIGNING_SALT") ||
      raise "MUSE_LIVE_VIEW_SIGNING_SALT is required in production"

  config :muse, MuseWeb.Endpoint,
    live_view: [signing_salt: live_view_salt]
end
```

Check Phoenix/LiveView runtime behavior before relying on runtime salt changes; some endpoint/socket options are compiled. When in doubt, set them through environment-specific release config and restart the release after rotation.

## Tests to add

```elixir
describe "endpoint config" do
  test "session options are loaded from app config"
  test "production requires non-placeholder salts"
  test "secure cookie flag is enabled in production config"
end
```

---

# P3-18. Replace runtime `Mix.env()` calls with application flags

## Finding

Runtime application code and UI components call `Mix.env()` directly. This couples runtime behavior to Mix and can be brittle in releases or embedded contexts.

## Why this should be fixed

Mix is a build tool. Release/runtime code should not depend on it to decide behavior. Runtime flags are easier to test and configure.

## Where it appears

- `lib/muse/runtime_provider.ex:86-89`
- `lib/muse/command_dispatcher.ex:216-230`
- `lib/muse_web/console_components.ex:226`
- `lib/muse_web/console_components.ex:1023`
- `lib/muse_web/live/home_live.ex:294-307`

## Fix gains

- Cleaner release behavior.
- Easier testing of dev-only features.
- Less coupling between runtime and build environment.

## Conceptual fix

Define application flags in config and use a runtime helper module.

## Implementation sketch

```elixir
# config/config.exs
config :muse,
  dev_tools_enabled?: config_env() in [:dev, :smoke],
  runtime_provider_enabled?: config_env() in [:dev, :prod]
```

Add a helper:

```elixir
defmodule Muse.RuntimeFlags do
  @moduledoc false

  def dev_tools_enabled? do
    Application.get_env(:muse, :dev_tools_enabled?, false) == true
  end

  def runtime_provider_enabled? do
    Application.get_env(:muse, :runtime_provider_enabled?, false) == true
  end
end
```

Update runtime provider:

```elixir
defp runtime_provider_enabled? do
  case Application.get_env(:muse, :runtime_provider_enabled?) do
    nil -> false
    explicit -> explicit == true
  end
end
```

Update dev commands:

```elixir
def dispatch(:simulate_event, _args, _context) do
  if Muse.RuntimeFlags.dev_tools_enabled?() do
    event = Muse.Event.new(:web, :simulated, %{text: "Simulated test event from command"})
    Muse.State.append(event)
    {:ok, "Simulated event created.", [{:refresh, :events}, {:toast, :success, "Simulated event created"}]}
  else
    {:ok, "Simulate not available.", []}
  end
end
```

Update components by assigning the flag from the LiveView instead of calling `Mix.env()` inside HEEx:

```elixir
# HomeLive mount
assign(socket, dev_tools_enabled?: Muse.RuntimeFlags.dev_tools_enabled?())
```

```elixir
# Component template
<%= if @dev_tools_enabled? do %>
  <button type="button" class="secondary-button" phx-click="simulate_log">Simulate log</button>
<% end %>
```

## Tests to add

```elixir
describe Muse.RuntimeFlags do
  test "dev tools flag comes from app config"
  test "runtime provider flag comes from app config"
end
```

---

# Additional UX and reliability improvements tied to the fixes

## Durable loading, empty, and failure states

Once P0-4 is implemented, expose explicit session states in the UI:

```elixir
assign(socket,
  submitting?: false,
  active_turn_id: nil,
  turn_state: :idle,
  durable_error: nil
)
```

Update on events:

```elixir
defp reduce_turn_state(socket, event) do
  case event.type do
    :turn_started -> assign(socket, turn_state: :running, durable_error: nil)
    :turn_completed -> assign(socket, turn_state: :idle, active_turn_id: nil)
    :turn_failed -> assign(socket, turn_state: :failed, durable_error: "The turn failed.")
    :turn_cancelled -> assign(socket, turn_state: :cancelled, active_turn_id: nil)
    :approval_requested -> assign(socket, turn_state: :awaiting_approval)
    _ -> socket
  end
end
```

Composer behavior:

```heex
<button
  type="submit"
  class="send-button"
  disabled={@turn_state in [:running, :awaiting_approval]}
  aria-disabled={@turn_state in [:running, :awaiting_approval]}
>
  <%= if @turn_state == :running, do: "Running…", else: "Send" %>
</button>
```

## Incremental LiveView event updates

After bounded state is in place, avoid full `Muse.State.get()` on every streamed delta. Update only the affected assigns:

```elixir
def handle_info({:muse_event, %Muse.Event{type: :assistant_delta} = event}, socket) do
  turn_id = event.turn_id
  chunk = Map.get(event.data, :text, "")

  socket =
    update(socket, :streaming_buffers, fn buffers ->
      Map.update(buffers, turn_id, chunk, &(&1 <> chunk))
    end)

  {:noreply, socket}
end
```

Use full refresh only for event types that truly require it.

---

# Final prioritized action plan

1. **Implement external WebSocket authentication and per-session authorization.** This is the highest-impact security fix because the socket is an explicit externally consumable surface.
2. **Add browser UI access control or enforce loopback-only access.** A local coding agent should not become remotely controllable because of a binding/proxy/tunnel mistake.
3. **Fix `SessionServer` active-turn handling and remove infinite submit calls.** This prevents caller hangs and overwritten turn state.
4. **Make LiveView submit non-blocking.** This improves responsiveness and enables clear running/cancel/approval UX.
5. **Harden all local process execution.** Add a deny-by-default environment, process-tree timeout cleanup, and route git/bearer commands through bounded execution.
6. **Add central tool input validation and UTF-8-safe file handling.** This prevents malformed LLM tool calls and arbitrary repository files from crashing handlers.
7. **Make persistence failures explicit.** Avoid crashes and invisible audit failures for patch/session writes.
8. **Fix high-impact performance issues.** Stream repository search and bound per-session/UI state.
9. **Add structured diagnostics and CI.** Make failures observable and enforce quality gates on every PR.
10. **Perform longer-term refactoring.** Split the largest modules after the core correctness and hardening work lands.
11. **Complete config hygiene.** Move salts to environment-specific config and replace runtime `Mix.env()` calls with application flags.



# Appendix B — Original `fix2.md`: Performance & Efficiency Fix Plan

# Performance & Efficiency Fix Plan

## Audit Scope

This document captures the high-impact performance fixes identified in the static audit of the `muse-main` Elixir/Phoenix LiveView application. The app includes a session runtime, LLM conductor, tool loop, JSONL session persistence, and PubSub-backed UI state.

The estimates below are based on code-path analysis rather than measured profiling because the audit environment did not include `mix` for running tests or benchmarks.

---

## Issue Summary

- **LiveView submits block on long-running LLM turns, while “streaming” deltas are buffered until the provider completes.** This creates high UI latency, back-pressure, and unnecessary memory accumulation.
- **The event-rendering path repeatedly recomputes the entire event log and contains an O(n²) grouping function.** This gets expensive during streaming, especially with many small assistant deltas.
- **`SessionServer` keeps an unbounded per-session event list and repeatedly copies historical lists with `++`.** Long sessions will grow heap usage and GC pauses over time.
- **JSONL persistence reads and splits whole files into memory for normal loads, exports, imports, and patch lookup.** Large sessions can cause avoidable binary heap spikes and slow patch operations.
- **The tool loop repeatedly copies lists, executes tool calls serially, and sends large raw tool outputs back to the model.** This wastes CPU, increases latency, and inflates token/API costs.

---

## 1. Blocking LiveView Submit and Buffered Provider Streaming

### Why this is a problem

The web submit path blocks the LiveView process until the entire LLM turn finishes. That means the LiveView cannot process PubSub messages smoothly while the turn is running. Even worse, the provider “streaming” implementation currently collects LLM deltas in the process dictionary and converts/emits them only after the provider call returns, so users do not receive true live token streaming.

### Lines involved

- `lib/muse_web/live/home_live.ex:116-193`  
  `handle_event("submit")` calls the runtime directly.
- `lib/muse_web/live/home_live.ex:127-135`  
  Resolves provider opts, calls `Muse.submit(:web, msg, opts)`, then fetches full state.
- `lib/muse.ex:58-62`  
  `Muse.submit/3` delegates to `SessionRouter.submit/4`.
- `lib/muse/session_router.ex:74-78`  
  Routes to `Muse.SessionServer.submit/4`.
- `lib/muse/session_server.ex:151-154`  
  Uses `GenServer.call(..., :infinity)`.
- `lib/muse/session_server.ex:728-758`  
  Starts a `TurnRunner` task but stores the caller `from`, leaving the original caller blocked.
- `lib/muse/session_server.ex:926-930`  
  Replies to the blocked caller only after the turn finishes.
- `lib/muse/conductor.ex:626-640`  
  `stream_provider/4` stores provider events in the process dictionary.
- `lib/muse/conductor.ex:654-655`  
  Converts buffered events only after the provider returns.
- `lib/muse/conductor/tool_loop.ex:259-275` and `524-543`  
  The tool-loop provider calls repeat the same buffered-streaming pattern.

### Refactored code suggestion

Split “submit a turn” from “wait for a completed answer.” The LiveView path should use an async submit API and update through PubSub events.

```elixir
# lib/muse/session_router.ex

def submit_async(session_id \\ @default_session_id, source, text, opts \\ [])
    when is_atom(source) and is_binary(text) and is_list(opts) do
  with {:ok, pid} <- find_or_start_session(session_id) do
    Muse.SessionServer.submit_async(pid, source, text, opts)
  end
end
```

```elixir
# lib/muse/session_server.ex

def submit_async(pid, source, text, opts \\ []) do
  GenServer.call(pid, {:submit_async, source, text, opts}, 5_000)
end

def handle_call({:submit_async, source, text, opts}, _from, state) do
  case start_turn(source, text, opts, nil, state) do
    {:ok, turn_id, state} ->
      {:reply, {:ok, turn_id}, state}

    {:error, reason, state} ->
      {:reply, {:error, reason}, state}
  end
end

def handle_call({:submit, source, text, opts}, from, state) do
  case start_turn(source, text, opts, from, state) do
    {:ok, _turn_id, state} ->
      {:noreply, state}

    {:error, reason, state} ->
      {:reply, {:error, reason}, state}
  end
end

defp maybe_reply(nil, _reply), do: :ok
defp maybe_reply(from, reply), do: GenServer.reply(from, reply)
```

Then update the web submit path:

```elixir
# lib/muse_web/live/home_live.ex

{:message, msg} ->
  case RuntimeProvider.resolve_opts() do
    {:ok, opts} ->
      case Muse.SessionRouter.submit_async("default", :web, msg, opts) do
        {:ok, _turn_id} ->
          {:noreply,
           socket
           |> assign(input: "")
           |> push_clear_command_input()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(input: text)
           |> add_toast("Submit failed: #{inspect(reason)}", :error)}
      end

    {:error, reason} ->
      {:noreply,
       socket
       |> assign(input: text)
       |> add_toast("Provider config error: #{reason}", :error)}
  end
```

For true streaming, avoid buffering provider events in the process dictionary. Pass a live event emitter into the conductor and emit each assistant delta as it arrives.

```elixir
# In the session turn startup path, pass an emitter to the runner.

session_server = self()

emit_event_fn = fn spec ->
  send(session_server, {:turn_event_spec, turn.id, spec})
end

task =
  TurnRunner.async(
    session,
    turn,
    Keyword.put(opts, :emit_event_fn, emit_event_fn)
  )
```

```elixir
# lib/muse/session_server.ex

def handle_info({:turn_event_spec, turn_id, event_spec}, state) do
  if state.active_turn_id == turn_id do
    {event, state} = emit_runtime_event(state, turn_id, event_spec)
    {:noreply, append_session_events(state, [event])}
  else
    {:noreply, state}
  end
end
```

```elixir
# lib/muse/conductor.ex

defp stream_provider(provider_module, request, _session, _turn, opts) do
  emit_event_fn = Keyword.get(opts, :emit_event_fn, fn _spec -> :ok end)

  emit_fn = fn
    %Muse.LLM.Event{} = llm_event ->
      llm_event
      |> convert_llm_events()
      |> Enum.each(emit_event_fn)

    _ ->
      :ok
  end

  case provider_module.stream(request, emit_fn) do
    {:ok, response} ->
      # Do not return already-emitted assistant deltas again.
      {:ok, response, []}

    {:error, reason} ->
      {:error, reason, []}
  end
end
```

### Estimated impact

- First-token latency moves from “after full provider response” to “as soon as provider emits a delta.”
- LiveView no longer blocks on full LLM turns.
- Lower burst memory pressure because deltas are not accumulated and replayed after completion.
- High practical UX impact; likely the single biggest latency improvement.

---

## 2. Whole-Log Recalculation and O(n²) Event Grouping

### Why this is a problem

Every PubSub event causes the LiveView to fetch the entire global state and rederive chat messages from the full event log. The event derivation code then performs grouping by repeatedly filtering the full event list for each turn. With many turns or streaming deltas, this becomes expensive quickly.

The global state has a default cap of 1,000 events, which helps, but the current path still repeatedly copies, reverses, filters, groups, sorts, and maps the full list on every event.

### Lines involved

- `lib/muse/state.ex:31-37`  
  `get/0`, `events/0`, and `append/1` are synchronous `GenServer.call`s.
- `lib/muse/state.ex:59-65`  
  `get/0` and `events/0` reverse the entire event list.
- `lib/muse/state.ex:69-73`  
  Append uses `[event | state.events] |> Enum.take(state.max_events)`, which scans up to the cap on each event.
- `lib/muse_web/live/home_live.ex:710-756`  
  Every `{:muse_event, event}` calls `Muse.State.get()` and assigns the whole state.
- `lib/muse_web/live/home_live.ex:878`  
  Render calls `chat_messages(@state.events)`.
- `lib/muse_web/live/home_live.ex:933-937`  
  `chat_messages/1` delegates to `EventStream.chat_messages/1`.
- `lib/muse/event_stream.ex:220-227`  
  Chat messages are derived by filtering, rejecting, grouping, and flattening the whole event list.
- `lib/muse/event_stream.ex:288-307`  
  `group_by_turn_preserving_order/1` uses `Enum.filter(events, ...)` for each turn, causing O(n²) behavior.
- `lib/muse/event_stream.ex:324-362`  
  Each group is sorted and filtered multiple times.

### Refactored code suggestion

First, replace the O(n²) grouping with a single-pass grouping function.

```elixir
# lib/muse/event_stream.ex

defp group_by_turn_preserving_order(events) do
  {order_rev, groups, nil_counter} =
    Enum.reduce(events, {[], %{}, 0}, fn event, {order, groups, nil_count} ->
      {key, nil_count} =
        case event.turn_id do
          nil -> {{:nil_turn, nil_count}, nil_count + 1}
          turn_id -> {turn_id, nil_count}
        end

      first_seen? = not Map.has_key?(groups, key)

      groups =
        Map.update(groups, key, [event], fn existing ->
          [event | existing]
        end)

      order =
        if first_seen? do
          [key | order]
        else
          order
        end

      {order, groups, nil_count}
    end)

  order_rev
  |> Enum.reverse()
  |> Enum.map(fn key ->
    {key, groups |> Map.fetch!(key) |> Enum.reverse()}
  end)
end
```

Second, avoid fetching full global state on every PubSub event. Use the event already delivered to the LiveView and update local assigns incrementally.

```elixir
# lib/muse_web/live/home_live.ex

def handle_info({:muse_event, event}, socket) do
  events = append_bounded(socket.assigns.events, event, 1_000)

  {:noreply,
   socket
   |> assign(events: events)
   |> assign(chat_messages: Muse.EventStream.chat_messages(events))
   |> assign(reload_status: BackendBridge.safe_reload_status())}
end

defp append_bounded(events, event, max_events) do
  events = events ++ [event]
  overflow = length(events) - max_events

  if overflow > 0 do
    Enum.drop(events, overflow)
  else
    events
  end
end
```

For an even better version, maintain a `messages_by_turn` assign and update only the affected turn instead of recalculating `EventStream.chat_messages(events)` on every delta.

### Estimated impact

- Converts the worst grouping step from O(n²) to O(n).
- Reduces repeated global-state copying.
- During streaming, this can plausibly cut UI/event CPU by 50–90% depending on event volume and number of connected LiveViews.

---

## 3. Unbounded Per-Session Events and Repeated List Copying in `SessionServer`

### Why this is a problem

The global `Muse.State` caps retained events, but `SessionServer` stores its own `events` list without an obvious cap. It also appends with `state.events ++ session_events`, which copies the entire historical event list every time. As sessions get longer, each turn becomes more expensive and the session process heap grows indefinitely.

This is leak-like behavior: not a classic dangling-reference leak, but unbounded retention that will eventually increase GC work and memory footprint.

### Lines involved

- `lib/muse/session_server.ex:414-443`  
  Initial state includes `events: []` without a visible retention cap.
- `lib/muse/session_server.ex:679-723`  
  `do_submit` builds `session_events` through repeated `session_events ++ [event]`.
- `lib/muse/session_server.ex:852-919`  
  Result path uses `session_events ++ conductor_events`, then `session_events ++ [turn_completed_event]`, then `state.events ++ session_events`.
- `lib/muse/session_server.ex:992-994` and `1092-1094`  
  Cancellation/failure paths also append with `++`.
- `lib/muse/session_server.ex:2187-2189`  
  `append_session_events/2` uses `%{state | events: state.events ++ events}`.
- `lib/muse/session_server.ex:491-516`  
  `status/1` calculates `event_count: length(state.events)`, which becomes O(n) as the list grows.

### Refactored code suggestion

Use a bounded queue for per-session events and track `event_count` explicitly.

```elixir
# lib/muse/session_server.ex

@default_session_event_limit 1_000

defp initial_state(args) do
  %{
    # existing fields...
    events: :queue.new(),
    event_count: 0,
    max_events: Keyword.get(args, :max_events, @default_session_event_limit)
  }
end

defp append_session_events(state, new_events) when is_list(new_events) do
  {queue, count} =
    Enum.reduce(new_events, {state.events, state.event_count}, fn event, {queue, count} ->
      enqueue_bounded(queue, count, event, state.max_events)
    end)

  %{state | events: queue, event_count: count}
end

defp enqueue_bounded(queue, count, event, max_events) do
  queue = :queue.in(event, queue)
  count = count + 1

  if count > max_events do
    {{:value, _oldest}, queue} = :queue.out(queue)
    {queue, count - 1}
  else
    {queue, count}
  end
end

defp session_events_list(state) do
  :queue.to_list(state.events)
end
```

Avoid repeated `++ [event]` while building per-turn event lists. Build in reverse and reverse once.

```elixir
# Instead of:
session_events = session_events ++ [event]

# Prefer:
session_events_rev = [event | session_events_rev]

# At the boundary:
session_events = Enum.reverse(session_events_rev)
state = append_session_events(state, session_events)
```

Update status to use the tracked count:

```elixir
event_count: state.event_count
```

### Estimated impact

- Prevents unbounded per-session memory growth.
- Avoids repeated copying of historical event lists.
- Stabilizes GenServer heap size and reduces GC pauses in long-running sessions.
- Turns long-session append cost from O(history) toward O(new_events).

---

## 4. Full-File JSONL Reads, Exports, Imports, and Patch Lookup

### Why this is a problem

The session store reads entire JSONL files into memory, splits the full binary into lines, then parses all lines. That creates unnecessary peak memory usage, especially because large binaries, split line lists, decoded maps, and scrubbed/exported maps may coexist.

Patch lookup also loads every patch into memory and then searches for one patch. For long sessions, applying or locating a patch becomes increasingly expensive.

### Lines involved

- `lib/muse/session_store.ex:1008-1025`  
  `load_jsonl/3` uses `File.read(path)` and `String.split(content, "\n")`.
- `lib/muse/session_store.ex:1027-1042`  
  `parse_jsonl_lines/1` parses the full list and reverses the accumulator.
- `lib/muse/session_store.ex:570-590`  
  `export_session/2` loads snapshot, all events, all messages, all patches, and memory into one map.
- `lib/muse/session_store.ex:757-772`  
  Import encodes all JSONL entries and joins them into one large string before writing.
- `lib/muse/session_server.ex:1960-1974`  
  `find_patch_in_store/3` calls `SessionStore.load_patches/2` and then `Enum.find/2`.

There is also duplicated startup I/O:

- `lib/muse/session_server.ex:449-455`  
  Loads a session snapshot to check existence.
- `lib/muse/session_server.ex:2193-2195`  
  Loads the session snapshot again while restoring plan data.
- `lib/muse/session_server.ex:460-467`  
  Loads memory to check existence.
- `lib/muse/session_server.ex:2655-2658`  
  Loads memory again during restore.

### Refactored code suggestion

Stream JSONL line by line instead of reading and splitting the whole file.

```elixir
# lib/muse/session_store.ex

defp load_jsonl(base_dir, session_id, file_name) do
  with :ok <- validate_session_id(session_id) do
    path = Path.join(session_dir(base_dir, session_id), file_name)

    if File.exists?(path) do
      {entries_rev, skipped} =
        path
        |> File.stream!([], :line)
        |> Enum.reduce({[], 0}, fn line, {entries, skipped} ->
          line = String.trim(line)

          cond do
            line == "" ->
              {entries, skipped}

            true ->
              case Jason.decode(line) do
                {:ok, decoded} -> {[decoded | entries], skipped}
                {:error, _} -> {entries, skipped + 1}
              end
          end
        end)

      {:ok, Enum.reverse(entries_rev), %{skipped: skipped}}
    else
      {:ok, [], %{skipped: 0}}
    end
  end
end
```

Add a targeted streaming patch lookup instead of loading every patch.

```elixir
# lib/muse/session_store.ex

def find_patch(base_dir, session_id, patch_id) do
  with :ok <- validate_session_id(session_id) do
    path = Path.join(session_dir(base_dir, session_id), "patches.jsonl")

    if File.exists?(path) do
      patch =
        path
        |> File.stream!([], :line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&Jason.decode/1)
        |> Stream.filter(&match?({:ok, _}, &1))
        |> Stream.map(fn {:ok, decoded} -> decoded end)
        |> Enum.find(fn patch ->
          Map.get(patch, "id") == patch_id or Map.get(patch, "patch_id") == patch_id
        end)

      case patch do
        nil -> {:error, :no_approved_patch}
        patch -> {:ok, patch}
      end
    else
      {:error, :no_approved_patch}
    end
  end
end
```

Then replace the full-load lookup:

```elixir
# lib/muse/session_server.ex

defp find_patch_in_store(store, session_id, patch_id) do
  with {:ok, patch_map} <- SessionStore.find_patch(store.base_dir, session_id, patch_id),
       {:ok, patch} <- Patch.from_map(patch_map) do
    {:ok, patch}
  end
end
```

For imports, write each JSONL entry incrementally instead of building one giant string.

```elixir
defp write_jsonl_stream(path, entries) do
  File.open(path, [:write, :utf8], fn io ->
    Enum.each(entries, fn entry ->
      IO.write(io, Jason.encode!(entry))
      IO.write(io, "\n")
    end)
  end)
end
```

### Estimated impact

- Peak memory drops from “entire file + split lines + decoded data” to line-at-a-time parsing.
- Large exports/imports avoid unnecessary binary spikes.
- Patch lookup remains O(n) unless indexed, but with much lower memory pressure.
- Startup I/O can be reduced by passing already-loaded snapshot/memory into restore functions.

---

## 5. Tool Loop List Copying, Serial Tool Execution, and Inefficient Model Payloads

### Why this is a problem

The tool loop uses repeated list concatenation in hot paths and executes tool calls serially. If an LLM requests several independent read/search tools, latency becomes the sum of all tool latencies. The loop also sends tool outputs back to the model with weak central compression. Some individual tools may cap outputs, but the model-facing payload should still be centrally bounded and summarized.

This affects both CPU and token/API efficiency.

### Lines involved

- `lib/muse/conductor/tool_loop.ex:145-153`  
  Appends event specs and patch proposals with `++`.
- `lib/muse/conductor/tool_loop.ex:161`  
  Builds `new_messages = state.messages ++ [assistant_msg] ++ tool_messages`.
- `lib/muse/conductor/tool_loop.ex:186-195`, `216-224`, `236-251`, and `565`  
  Repeated `event_specs ++ specs`.
- `lib/muse/conductor/tool_loop.ex:315-329`  
  Executes tool calls through a serial `Enum.reduce/3` and uses `res_acc ++ [result]` plus `spec_acc ++ tool_specs`.
- `lib/muse/conductor/tool_loop.ex:351-352`  
  Concatenates results/specs again.
- `lib/muse/conductor/tool_loop.ex:487-503`  
  Encodes tool results into model-facing JSON.
- `lib/muse/conductor/tool_loop.ex:513-516`  
  `summarize_for_model/1` returns binaries and maps essentially as-is.
- `lib/muse/prompt/project_rules.ex:76-120`  
  Project rules are loaded and concatenated per prompt assembly.
- `lib/muse/prompt/project_rules.ex:93`  
  Uses repeated string concatenation.
- `lib/muse/prompt/assembler.ex:120-168` and `545-567`  
  Rebuilds prompt layers and concatenates system layers each turn.

### Refactored code suggestion

Fix the hot `execute_tool_calls` accumulator first.

```elixir
# lib/muse/conductor/tool_loop.ex

{results_rev, specs_groups_rev, final_total} =
  Enum.reduce(executable, {[], [], total}, fn tool_call, {results, spec_groups, current_total} ->
    if TurnRunner.cancelled?() do
      {results, spec_groups, current_total}
    else
      {result, tool_specs, updated_total} =
        execute_single_tool(
          tool_call,
          tool_runner,
          session,
          turn,
          muse,
          updated_total: current_total,
          max_total: max_total
        )

      {[result | results], [tool_specs | spec_groups], updated_total}
    end
  end)

results = Enum.reverse(results_rev)

specs =
  specs_groups_rev
  |> Enum.reverse()
  |> List.flatten()
```

For independent read-only tools, use bounded concurrency while preserving result order.

```elixir
# Only use this for tools marked read-only/idempotent.
# Keep write/apply/approval tools serial.

max_concurrency =
  executable
  |> length()
  |> min(System.schedulers_online())

tool_outputs =
  executable
  |> Enum.with_index(total)
  |> Task.Supervisor.async_stream_nolink(
    Muse.TaskSupervisor,
    fn {tool_call, current_total} ->
      execute_single_tool(
        tool_call,
        tool_runner,
        session,
        turn,
        muse,
        updated_total: current_total,
        max_total: max_total
      )
    end,
    ordered: true,
    max_concurrency: max_concurrency,
    timeout: 30_000
  )
  |> Enum.map(fn
    {:ok, output} -> output
    {:exit, reason} -> tool_failure_result(reason)
  end)
```

Add central model-output compression so token usage is bounded regardless of individual tool behavior.

```elixir
# lib/muse/conductor/tool_loop.ex

@max_model_output_bytes 8_000
@max_model_list_items 30
@max_model_map_keys 30

defp summarize_for_model(output) when is_binary(output) do
  if byte_size(output) > @max_model_output_bytes do
    binary_part(output, 0, @max_model_output_bytes) <>
      "\n\n…truncated for model context. Ask for a narrower file range or query to inspect more."
  else
    output
  end
end

defp summarize_for_model(output) when is_map(output) do
  output
  |> take_model_relevant_fields()
  |> Muse.MetadataSanitizer.sanitize(
    max_depth: 4,
    max_map_keys: @max_model_map_keys,
    max_list_length: @max_model_list_items,
    max_string_len: 800
  )
end

defp summarize_for_model(output) when is_list(output) do
  output
  |> Enum.take(@max_model_list_items)
  |> Muse.MetadataSanitizer.sanitize(
    max_depth: 4,
    max_map_keys: @max_model_map_keys,
    max_list_length: @max_model_list_items,
    max_string_len: 800
  )
end

defp summarize_for_model(output), do: output

defp take_model_relevant_fields(map) do
  preferred_keys = [
    :summary,
    "summary",
    :path,
    "path",
    :range,
    "range",
    :matches,
    "matches",
    :error,
    "error",
    :status,
    "status"
  ]

  case Map.take(map, preferred_keys) do
    empty when map_size(empty) == 0 -> map
    compact -> compact
  end
end
```

Cache project rules by file path and `mtime` instead of re-reading and rebuilding them every turn.

```elixir
# Sketch: store in ETS or persistent_term-backed cache.

def get_project_rules_cached(root) do
  files = discover_rule_files(root)

  cache_key =
    Enum.map(files, fn path ->
      {:ok, stat} = File.stat(path)
      {path, stat.mtime, stat.size}
    end)

  case :ets.lookup(:muse_prompt_cache, {:project_rules, cache_key}) do
    [{_, rules}] ->
      rules

    [] ->
      rules = read_project_rules(files)
      :ets.insert(:muse_prompt_cache, {{:project_rules, cache_key}, rules})
      rules
  end
end
```

### Estimated impact

- CPU: avoids repeated list copying in the tool loop.
- Latency: parallel read-only tool execution can reduce tool phase time from roughly sum-of-tools to max-of-tools.
- Token/API cost: central truncation and summarization can reduce tool-result token volume by 50–90% on file/search-heavy turns.
- Prompt assembly caching reduces repeated disk I/O and string construction on every LLM call.

---

## Highest-Priority Fix Order

1. **Make web submits non-blocking and emit provider deltas live.** This directly improves perceived latency and scaling.
2. **Replace O(n²) event grouping and stop full-state fetches on every PubSub event.** This prevents streaming from overwhelming the UI path.
3. **Bound `SessionServer` event retention with a queue.** This prevents long-session heap growth.
4. **Stream JSONL loads and patch lookup.** This makes large sessions safer.
5. **Compress tool outputs and parallelize read-only tools.** This reduces token cost and multi-tool latency.

---

## Implementation Notes

- Run the existing test suite after each fix category. The async submit and true streaming changes are the most behavior-sensitive and should be landed behind small, testable interfaces.
- Add regression tests for event ordering, grouped chat message rendering, cancellation during streaming, JSONL parse failures, and bounded event retention.
- Add lightweight telemetry around turn duration, first-delta latency, number of retained session events, JSONL load size/duration, tool output byte size, and model payload size.
