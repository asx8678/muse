# Phase 4 — Session Persistence, Export/Import, Retention, and Workspace Profiles

> **Companion docs:** [Architecture](architecture.md) · [Security](security.md) · [Provider Roadmap](provider-roadmap.md) · [Testing](testing.md) · [Executive Summary](../PLAN.md)
>
> **Scope:** This document covers the Phase 4 persistence layer added in `muse-9sr`, `muse-ss5`, `muse-b04`, and `muse-02e`. It describes where session data is stored, how export/import works, memory persistence safety, session retention, and workspace profile isolation.

---

## Table of Contents

1. [Session Persistence](#1-session-persistence)
2. [Memory Persistence Safety](#2-memory-persistence-safety)
3. [Export and Import](#3-export-and-import)
4. [Session Retention](#4-session-retention)
5. [Workspace Profiles](#5-workspace-profiles)
6. [Session ID Validation](#6-session-id-validation)
7. [Security Notes](#7-security-notes)
8. [Limitations and Follow-ups](#8-limitations-and-follow-ups)

---

## 1. Session Persistence

### 1.1 Where sessions are stored

By default, session data is stored under the workspace root at:

```text
<workspace_root>/.muse/sessions/<session_id>/
```

The `workspace_root` defaults to the current working directory. It can be set via `--workspace /path` (CLI flag), `MUSE_WORKSPACE` (environment variable), or through the active workspace profile (see §5).

### 1.2 Session directory artifacts

Each session directory contains:

| File | Purpose | Write behavior |
|---|---|---|
| `session.json` | Session snapshot (status, metadata, plan state) | Atomic: write to `.tmp`, then rename |
| `events.jsonl` | Append-only event log | Append-only; corrupt lines are skipped on read |
| `messages.jsonl` | Append-only message log (user/assistant messages) | Append-only |
| `patches.jsonl` | Append-only patch proposal log | Append-only |
| `memory.json` | Compacted memory artifact | Atomic (see §2) |

### 1.3 Schema versioning

`session.json` and `memory.json` include a `schema_version` integer field. On load, the version field is stripped before returning data to callers. Future migration logic can inspect the version field before stripping.

### 1.4 Atomicity and crash safety

- `session.json` and `memory.json` use atomic writes: content is written to a `.tmp` sibling file first, then renamed — preventing partial writes from producing corrupt snapshots on crash. On failure, the `.tmp` file is cleaned up.
- JSONL files (`events.jsonl`, `messages.jsonl`, `patches.jsonl`) are append-only. Each line is a complete JSON object, so only the last (possibly incomplete) line is at risk on crash. The `load_*` functions skip corrupt lines and report the count.

### 1.5 Workspace-scoped store paths

When a workspace profile is active, the session store base directory changes to that profile's `sessions_dir` (see §5). This means:

- **The same session ID in different workspaces is fully isolated.** Sessions are stored under the active workspace's `.muse/sessions` directory, and the runtime registry key is `{store_base_dir, session_id}`.
- **Running sessions keep their captured store directory.** When a session starts, it captures the active workspace's `store_base_dir`. Switching workspace profiles affects only **newly started** sessions — already-running sessions continue reading/writing to the store directory they were initialized with.
- **Session lookup is workspace-scoped.** `Muse.SessionRouter.find_or_start_session/1` resolves the active workspace context before looking up or starting a session, so the same session ID in a different workspace is a different runtime process.

### 1.6 Session listing and existence checks

`Muse.SessionStore.list_sessions/1` returns all session IDs in the base directory that pass `validate_session_id/1`. `session_exists?/2` checks whether a `session.json` exists for a given session ID.

---

## 2. Memory Persistence Safety

### 2.1 Fail-closed validation

Memory persistence uses a **fail-closed** approach: if secrets are detected in a memory artifact, the memory is **not** persisted, not loaded, and not exported. Unsafe memory is rejected rather than trusted.

The validation pipeline is:

1. **`Muse.Memory.validate_no_secrets/1`** — checks for two classes of secrets:
   - **Sensitive keys** — any key (atom or string) matching `Muse.MetadataSanitizer.sensitive_key?/1` (e.g., `:password`, `"api_key"`) is flagged regardless of value content.
   - **Secret patterns** — binary values containing known credential patterns (API keys, Bearer tokens, private keys, etc.). Recursively walks maps, lists, tuples, keywords, and charlists.

2. **`Muse.Memory.validate_and_persist/3`** — validates memory before calling `SessionStore.save_memory/3`. If validation fails, the memory is not written and `{:error, {:unsafe_memory, reasons}}` is returned.

3. **`Muse.SessionStore.save_memory/4`** with `validate: true` — the store-level persistence function also validates before any disk I/O when the option is passed.

4. **`Muse.Memory.validate_loaded_memory/1`** — validates memory loaded from `memory.json` before trusting it. Unsafe loaded memory is rejected (returns `{:error, {:unsafe_memory, reasons}}`), not returned to the caller.

### 2.2 Memory commands

| Command | Behavior |
|---|---|
| `/memory` | Show session memory summary (redacted output) |
| `/memory compact` | Compact session context into safe durable memory. Uses `compact_safe/2` for fail-closed validation. If secrets are detected, compaction is blocked and the error is reported. On success, memory is persisted via `SessionRouter.set_memory/2`. |
| `/memory clear` | Clear session memory. Removes the in-memory artifact and the persisted `memory.json` file. |

### 2.3 Legacy unsafe memory

Memory loaded from `memory.json` (e.g., from a legacy session or a corrupted file) is validated before use. If unsafe memory is detected:

- It is **not** returned to the caller or loaded into session state.
- It is **not** included in exports.
- The error `{:error, {:unsafe_memory, reasons}}` is returned so the caller can handle it explicitly.

Legacy memory is never silently trusted.

### 2.4 Secrets never in memory artifacts

The security invariant from `security.md` §10 is enforced at every boundary:

- Compaction redacts secrets before producing the memory artifact.
- `validate_no_secrets/1` is called before persistence and before loading.
- Export includes memory only when it passes `validate: true` validation.
- Import validates memory before writing it to disk.
- Rendering uses the full redaction pipeline (`EventPayloadRedactor` + `Prompt.Redactor`) before displaying.

---

## 3. Export and Import

### 3.1 Export (`/export session`)

`/export session` bundles the current session into a portable JSON map and copies it to the clipboard.

**What is included:**

| Field | Content |
|---|---|
| `export_schema_version` | Integer schema version for future migration |
| `session_id` | The session ID |
| `exported_at` | ISO 8601 timestamp of the export |
| `snapshot` | Session snapshot map (from `session.json`) |
| `events` | List of event maps (from `events.jsonl`) |
| `messages` | List of message maps (from `messages.jsonl`) |
| `patches` | List of patch maps (from `patches.jsonl`) |
| `memory` | Memory artifact (only if present **and** passes `validate: true` check) |

**Safety:**

- All data is redacted through the sensitive-key scrubbing pipeline before export — secrets are never included.
- Memory is included only when it passes `validate_no_secrets/1`. If the memory file is missing, the `memory` field is omitted. If the memory is unsafe, the entire export fails with an error.
- Session IDs are validated for path traversal before constructing file paths.

### 3.2 Import (`/import session <path>`)

`/import session <path>` reads a `.muse-session` JSON file from the given file path and writes it to the active workspace's session store.

**Syntax:** `/import session path/to/export.json`

**What happens on import:**

1. The file is read and decoded as JSON.
2. The export map is validated for required fields (`session_id`, `snapshot`).
3. Session ID is validated for path traversal (see §6).
4. Memory (if present) is validated through `validate_no_secrets/1`. Unsafe memory causes the import to fail — it is **not** written.
5. Snapshot, events, messages, and patches are scrubbed and written to the session directory.
6. If the export has no memory field, any existing `memory.json` in the target session directory is removed.
7. All data is re-scrubbed before writing as an additional defense-in-depth measure.

**Safety:**

- Imported session IDs are validated for path traversal.
- Memory is validated before being written to disk.
- All data passes through the scrub pipeline before persistence.
- If any step fails, the import returns an error and no partial state is left.

### 3.3 Workspace scoping

Export and import are scoped to the **active workspace's session store directory**:

- Export reads from the active workspace's `store_base_dir`.
- Import writes to the active workspace's `store_base_dir`.
- The session ID in the export map can be overridden via the `:session_id` option (internal API only), but the base directory is always the active workspace's store.

---

## 4. Session Retention

### 4.1 Retention API

`Muse.SessionStore.evict_sessions/3` enforces a retention policy by removing the oldest sessions when limits are exceeded.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `:max_sessions` | integer or nil | nil (unlimited) | Maximum number of sessions to retain. Oldest sessions are evicted first. |
| `:ttl_seconds` | integer or nil | nil (unlimited) | Maximum age in seconds for a session directory. Sessions older than this are evicted regardless of count. |

Eviction is based on session directory modification time (`mtime`), oldest first.

**Example:**

```elixir
# Keep only the 10 most recent sessions
Muse.SessionStore.evict_sessions(".muse/sessions", max_sessions: 10)

# Remove sessions older than 7 days
Muse.SessionStore.evict_sessions(".muse/sessions", ttl_seconds: 604_800)
```

### 4.2 No user-facing retention command

Retention is currently an **API-only feature**. There is no `/retention` or `/evict` slash command. Retention policy is applied programmatically (e.g., at session start, by a scheduled task, or by a caller managing session lifecycle).

The `evict_sessions/3` function returns `{:ok, evicted_ids}` so callers can log or report what was removed.

---

## 5. Workspace Profiles

### 5.1 What workspace profiles do

Workspace profiles provide multi-project session isolation. Each profile defines a workspace root directory and derives a per-workspace session store path, ensuring sessions from different projects never share state.

### 5.2 Commands

| Command | Description |
|---|---|
| `/workspace create <name> <root_path>` | Create a workspace profile. The `sessions_dir` is derived as `<root_path>/.muse/sessions`. |
| `/workspace list` | List all configured workspace profiles. |
| `/workspace switch <name>` | Switch the active workspace to the named profile. Only **newly started** sessions will use the new workspace's session store directory. Already-running sessions keep the `store_base_dir` they captured at init. |
| `/workspace info` | Show detailed workspace info: root path, sessions directory, stored session count, and active profile name. |

### 5.3 Profile storage

Workspace profiles are stored in `<global_muse_dir>/profiles.json`, where `global_muse_dir` defaults to `.muse` (relative to the current directory). It can be overridden via:

- `MUSE_DIR` environment variable
- `:muse_dir` application config key

A profile map contains:

| Field | Description |
|---|---|
| `name` | Unique profile name |
| `root_path` | Absolute workspace root path |
| `sessions_dir` | Derived: `<root_path>/.muse/sessions` |
| `created_at` | ISO 8601 timestamp |
| `updated_at` | ISO 8601 timestamp |

No secrets are stored in `profiles.json`.

### 5.4 Workspace switching behavior

When `/workspace switch <name>` is called:

1. The profile is looked up via `Muse.WorkspaceProfile.get_profile/1`.
2. `Muse.ActiveWorkspace` updates its state to the profile's `root_path` and `sessions_dir`.
3. **New sessions** started after the switch will use the new workspace's session store directory.
4. **Already-running sessions** are not affected — they continue using the `store_base_dir` they captured at startup.
5. The runtime registry key for sessions is `{store_base_dir, session_id}`, so the same session ID in different workspaces coexists as separate processes.

### 5.5 Path and name validation

Profile names are validated to block path traversal characters (`/`, `\`, NUL) and reserved names (`.`, `..`). Root paths are expanded to absolute paths. Session directories are always derived from the root path — they cannot be set to an arbitrary value that escapes the workspace.

---

## 6. Session ID Validation

### 6.1 Canonical validator

`Muse.SessionStore.validate_session_id/1` is the canonical validator used by `SessionStore`, `SessionRouter`, and `SessionServer` to reject invalid or dangerous session IDs before any Registry lookup, process start, or file I/O.

A session ID is **rejected** if it is:

- Not a binary
- Empty (`""`)
- `.` or `..`
- Contains path-traversal characters (`/`, `\`, NUL)
- Exceeds 255 bytes

### 6.2 Validation before runtime process start

Session IDs are validated in `SessionRouter.find_or_start_session/1` before looking up or starting a `SessionServer` process. This prevents invalid IDs from entering the Registry or causing process misbehavior.

---

## 7. Security Notes

### 7.1 Secrets never in persisted data

All data written through `SessionStore` is scrubbed through the sensitive-key pipeline (`Muse.MetadataSanitizer.sensitive_key?/1` for key detection, `Muse.EventPayloadRedactor.redact_string/1` for value pattern detection). Values at sensitive key names are replaced with `"**REDACTED**"` before persistence. Secret-like string values under otherwise non-sensitive keys are also redacted.

### 7.2 Memory persistence is fail-closed

Memory artifacts are validated at every boundary:

- Before persistence (`validate_and_persist/3`)
- Before loading from disk (`validate_loaded_memory/1`)
- Before export (`load_memory/2` with `validate: true`)
- Before import (memory validated in `validate_memory/1` within `import_session/3`)

If secrets are detected at any point, the memory is rejected — not persisted, not loaded, not exported. This is the fail-closed approach.

### 7.3 Session ID path traversal protection

Session IDs are validated to block `/`, `\`, NUL, `.`, `..`, and maximum length. This prevents path traversal attacks that could write or read files outside the session directory.

### 7.4 Workspace isolation

Sessions in different workspaces are fully isolated by both filesystem path and runtime registry key. Switching workspaces does not silently redirect running sessions. Cross-workspace session access requires explicitly switching the active workspace profile first.

### 7.5 Export is redacted

All export data passes through the scrub pipeline. Memory is included only when it passes validation. Secrets are never included in export output, even if they somehow reached the persisted files (defense-in-depth).

### 7.6 Import validates before writing

Import validates the export map structure, session IDs, and memory before writing any data to disk. Unsafe memory causes the import to fail entirely — no partial state is left.

### 7.7 No secrets in profile data

`profiles.json` stores only profile name, root path, sessions directory, and timestamps. No credentials, API keys, or other secrets are stored in workspace profile data.

---

## 8. Limitations and Follow-ups

### 8.1 Retention is API-only

There is no user-facing `/retention` or `/evict` command. Retention policy must be applied programmatically. A future follow-up could add a slash command or automatic retention on session start.

### 8.2 No automatic retention enforcement

Retention is not automatically enforced at session start or on a schedule. Callers must invoke `evict_sessions/3` explicitly.

### 8.3 User-facing invalid session ID errors

When an invalid session ID is provided through user-facing surfaces (e.g., the REPL), the error message is `{:error, {:invalid_session_id, id}}`. The display of this error to end users is tracked separately (`muse-4iq`).

### 8.4 No cross-workspace session migration

There is no command to move or copy a session from one workspace to another. `/import session` writes to the active workspace, which can serve as a manual migration path, but there is no dedicated migration command.

### 8.5 Export format is JSON only

Export produces JSON. There is no binary format, compressed archive, or streaming export. Large sessions may produce large export files.

### 8.6 Import requires a file path

`/import session` reads from a file path, not from clipboard content. The `/export session` command copies to clipboard, so the user must save the clipboard content to a file before importing.

### 8.7 Remote providers and external tests are opt-in

This document covers persistence and workspace isolation only. Remote execution, SSH runners, and external provider tests remain opt-in and are not enabled by default. See `security.md` §14 and `testing.md` for details.

---

## Module Reference

| Module | Role |
|---|---|
| `Muse.SessionStore` | Crash-safe persistence for sessions (JSON/JSONL files), export/import, retention, memory persistence |
| `Muse.SessionRouter` | Routes `submit/2` calls to the correct `SessionServer`; workspace-scoped lookup/start |
| `Muse.SessionServer` | Per-session GenServer; owns state, persistence, memory, approval state |
| `Muse.ActiveWorkspace` | Tracks the active workspace profile and `store_base_dir` |
| `Muse.WorkspaceProfile` | Creates, lists, and manages workspace profiles; derives `sessions_dir` |
| `Muse.Memory` | Memory compaction, validation (`validate_no_secrets/1`), persistence boundary (`validate_and_persist/3`), rendering |
| `Muse.CommandDispatcher` | Dispatches slash commands including `/memory`, `/export session`, `/import session`, `/workspace *` |
