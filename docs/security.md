# Muse Universal Runtime — Security Document

> **Companion docs:** [Architecture](architecture.md) · [Prompts](prompts.md) · [Provider Roadmap](provider-roadmap.md) · [Testing](testing.md) · [Executive Summary](../PLAN.md)
>
> **Canonical source:** Workspace safety, secret handling, redaction, approval/security rules, and MVP security checklist.
>
> **Status (PR21):** Plan approval, patch proposal approval, auth layer, external channel, memory compaction, and handoff safety are implemented. Patch apply, test runner, and shell/network approval gates are PR18/PR19+.

---

## Table of Contents

1. [Security Checklist Before MVP](#1-security-checklist-before-mvp)
2. [Workspace Path Policy](#2-workspace-path-policy)
   - 2.1 [Harden Workspace Functions](#21-harden-workspace-functions)
3. [Secret Path Denylist](#3-secret-path-denylist)
   - 3.1 [User Override Behavior](#31-user-override-behavior)
4. [Redaction Rules](#4-redaction-rules)
5. [Tool Permissions Matrix](#5-tool-permissions-matrix)
6. [Plan Approval Lifecycle Security (PR09)](#6-plan-approval-lifecycle-security-pr09)
7. [Patch Approval Lifecycle Security (PR17)](#7-patch-approval-lifecycle-security-pr17)
8. [Patch Apply, Checkpoint, and Rollback Security (PR18)](#8-patch-apply-checkpoint-and-rollback-security-pr18)
9. [Test Runner Security (PR19)](#9-test-runner-security-pr19)
10. [Memory Compaction and Handoff Safety (PR21)](#10-memory-compaction-and-handoff-safety-pr21)
11. [Auth Security Rules](#11-auth-security-rules)
12. [Prompt Security](#12-prompt-security)
13. [External WebSocket Channel Security (PR16)](#13-external-websocket-channel-security-pr16)

---

## 1. Security Checklist Before MVP

Every item must be verified before the Muse Runtime reaches MVP. Status reflects implementation through PR21.

### Secrets & Redaction

- [x] No API keys in events (enforced by `Muse.Event` struct, `EventPayloadRedactor`)
- [x] No bearer tokens in logs (enforced by `MetadataSanitizer`, redaction helpers)
- [x] No Codex auth tokens in prompt preview (enforced by `Prompt.Redactor`)
- [x] Authorization headers redacted from provider debug output (enforced by `ProviderConfig.redacted_inspect/1`)
- [x] Secret-like files blocked or redacted (enforced by `Workspace.safe_resolve!` denylist)
- [x] Secrets not in memory artifacts (enforced by memory compaction redaction)
- [x] Secrets not in handoff specs (enforced by handoff restoration safety checks)

### Workspace Safety

- [x] Workspace path checks are symlink-aware (enforced by `Workspace.safe_resolve!`)
- [ ] Patch apply blocks outside-workspace paths (PR18)
- [ ] Patch apply blocks secret file paths (PR18)
- [ ] Patch apply creates checkpoint first (PR18)

### Approval Lifecycle

- [x] Plan approval is lifecycle-only and does not execute tools (PR09)
- [x] Patch approval is lifecycle-only and does not apply files (PR17)
- [x] Patch proposals are content-hashed and stale approvals rejected (PR17)

### Execution Gates

- [ ] Shell commands are approval-gated (PR19)
- [ ] Network calls are approval-gated or disabled (PR19)
- [x] Remote execution is disabled (no remote execution tool)
- [ ] Test runner is approval-gated (PR19)

### Network & Channels

- [x] Web server defaults to localhost (Phoenix endpoint config)
- [x] External WebSocket channel does not forward internal/sensitive events (PR16, `ExternalEventFilter`)
- [x] External WebSocket channel is read-only (PR16, no mutation authority)
- [x] External WebSocket channel is disabled by default (PR16, `config :muse, :external_ws, enabled: false`)

### Provider & Prompt

- [x] Prompt preview is redacted and does not show full hidden prompt
- [x] Tool outputs are capped (enforced by `EventDisplay.safe_data/1`)
- [x] Provider errors do not leak secrets (enforced by error payload redaction)
- [x] Configuration validated at startup (enforced by `ProviderConfig.validate/1`)

### Process Safety

- [x] All processes are supervised (`Muse.Application` supervision tree)
- [x] No orphan processes on turn crash (supervised `SessionSupervisor`, `Tool.Runner` cleanup)

---

## 2. Workspace Path Policy

Every file tool in the Muse Runtime must pass through the following 9-step path validation before any filesystem operation occurs. No shortcuts, no bypasses — prompt text is guidance, not a security boundary.

```text
1. Accept workspace-relative paths.
2. Reject absolute paths unless explicitly allowed by a high-trust internal call.
3. Normalize the path.
4. Resolve symlinks when possible.
5. Confirm the real target remains inside workspace.
6. Enforce read/write permission policy.
7. Enforce secret-file policy.
8. Block writes through symlinks by default.
9. Emit a tool event.
```

**Why each step matters:**

| Step | Purpose |
|---|---|
| 1. Accept relative paths | Prevents absolute-path traversal attacks (`/etc/passwd`, `~/.ssh/id_rsa`) |
| 2. Reject absolute paths | Only internal high-trust callers (e.g., checkpoint restore) may use absolute paths |
| 3. Normalize the path | Eliminates `..` traversal, double slashes, and encoding tricks (`lib/../../etc/shadow`) |
| 4. Resolve symlinks | Symlinks can point outside the workspace; they must be followed and checked |
| 5. Confirm inside workspace | After resolution, the real path must still fall under the workspace root |
| 6. Enforce permission policy | Read-only vs. read/write depends on the active Muse and approval state |
| 7. Enforce secret-file policy | Secret paths are always blocked regardless of other permissions (see §3) |
| 8. Block writes through symlinks | Prevents writing to targets outside the workspace via symlink chains |
| 9. Emit a tool event | Auditability — every file access is recorded in the session event log |

### 2.1 Harden Workspace Functions

All workspace resolution is centralized through a single hardened function:

```elixir
Muse.Workspace.safe_resolve!(path, opts \\ [])
```

**Rules enforced by `safe_resolve!/2`:**

```text
✓ Path must resolve inside workspace.
✓ Symlink target must also resolve inside workspace.
✓ Secret paths are blocked.
✓ Hidden files are blocked unless explicitly allowed by a safe tool.
✓ Binary files are not returned as text.
✓ File size limits are enforced.
```

If any rule fails, `safe_resolve!/2` raises or returns an error — it never silently allows access. Tools must call this function before any filesystem operation. Direct use of `Path.expand/2` or `File.read/1` without `safe_resolve!` is a security violation.

---

## 3. Secret Path Denylist

The following paths are **blocked by default** for all file tools. This denylist is enforced at the `safe_resolve!` level, not at the prompt level, so it cannot be bypassed by prompt injection or Muse misbehavior.

```text
.env
.env.*
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519
.ssh/
.aws/
.gcp/
.gcloud/
.azure/
.npmrc
.pypirc
.netrc
.git-credentials
credentials.json
secrets.*
~/.codex/auth.json
files under .git/ (except safe read-only status/diff usage)
```

**Pattern matching rules:**

| Pattern | Meaning |
|---|---|
| `.env` | Exact match for `.env` at any directory level |
| `.env.*` | Any file starting with `.env.` (e.g., `.env.local`, `.env.production`) |
| `*.pem` | Any file ending in `.pem` |
| `*.key` | Any file ending in `.key` |
| `*.p12` / `*.pfx` | PKCS#12 certificate bundles |
| `id_rsa` / `id_ed25519` | Default SSH private key filenames |
| `.ssh/` | Entire `.ssh` directory |
| `.aws/` / `.gcp/` / `.gcloud/` / `.azure/` | Cloud credential directories |
| `.npmrc` / `.pypirc` / `.netrc` | Package manager and net credential files |
| `.git-credentials` | Git credential store |
| `credentials.json` | Generic credential file (GCP, etc.) |
| `secrets.*` | Any file named `secrets.*` (e.g., `secrets.yml`, `secrets.json`) |
| `~/.codex/auth.json` | Codex auth cache — treated as password-equivalent |
| `.git/` contents | Blocked except for safe read-only `git status` / `git diff` usage |

### 3.1 User Override Behavior

If the user **explicitly** asks to inspect a secret-related file (e.g., "show me my `.env` file"), Muse must:

1. **Ask for confirmation** before proceeding — do not silently open the file.
2. **Explain the risk** — the user should understand that the file contains sensitive data.
3. **Redact obvious secrets** in the response even after confirmation. API keys, tokens, and private keys are replaced with `REDACTED` placeholders. Non-secret structure (variable names, comments) may be shown.

This override is for **read-only inspection** only. Writing to secret paths is never allowed through user override — it must be blocked unconditionally.

---

## 4. Redaction Rules

The following categories of data are **always redacted** before they appear in events, logs, prompt previews, provider debug output, crash text, or any user-facing channel.

```text
API keys              sk-*, key-*, API_KEY=..., etc.
Bearer tokens         Bearer eyJ..., Authorization: Bearer ...
Authorization headers Authorization: Bearer ..., X-Api-Key: ...
.env values           DATABASE_URL=..., SECRET_KEY=..., etc.
SSH private keys      -----BEGIN RSA PRIVATE KEY-----, etc.
Known secret path contents  Contents of any file matching §3 denylist
Long opaque token-looking strings  Strings matching known token patterns
                      (JWTs, opaque bearer strings, etc.)
Provider URLs with embedded credentials
                      https://user:pass@host/path, etc.
Codex auth tokens     Tokens from ~/.codex/auth.json
```

**Redaction format:**

| Category | Redacted Form |
|---|---|
| API key | `sk-...REDACTED` |
| Bearer token | `Bearer ...REDACTED` |
| Authorization header | `Authorization: ...REDACTED` |
| `.env` value | `KEY=REDACTED` |
| SSH private key | `-----BEGIN ... KEY----- REDACTED` |
| Embedded credentials in URL | `https://REDACTED:REDACTED@host/path` |
| Codex auth token | (token omitted entirely) |

**Implementation note:** Prompt previews use `Muse.Prompt.Redactor`; event/log payloads and provider config debug strings use the shared redaction/sanitization helpers (`Muse.EventPayloadRedactor`, `Muse.MetadataSanitizer`, and `ProviderConfig.redacted_inspect/1`). PR12's `OpenAICompatibleProvider` redacts all error payloads through `EventPayloadRedactor` before returning them — provider HTTP bodies, response terms, and error messages never leak into `Muse.Event` structs, logs, or debug output. Downstream consumers (CLI, TUI, LiveView, WebSocket channels) never see raw secrets.

---

## 5. Tool Permissions Matrix

PR09 runtime enforcement uses both `Muse.Tool.Registry` + `Muse.Tool.Runner` and plan lifecycle checks in `Muse.ApprovalGate`.

### Registered runtime tools (available)

| Tool | Planning Muse | Coding Muse | Notes |
|---|:---:|:---:|---|
| `list_files` | ✅ | ✅ | Workspace-scoped directory listing |
| `read_file` | ✅ | ✅ | Workspace + secret/ignored checks |
| `repo_search` | ✅ | ✅ | Workspace-scoped content search |
| `git_status` | ✅ | ✅ | Read-only git command |
| `git_diff_readonly` | ✅ | ✅ | Read-only git diff |
| `ask_user_question` | ✅ | ✅ | Interactive prompt back to user |
| `list_muses` | ✅ | ✅ | Profile summaries |
| `list_skills` | ✅ | ✅ | Deterministic skills listing |

### Known blocked tool names (hard deny)

| Tool | Enforcement |
|---|---|
| `write_file` | blocked as dangerous |
| `replace_in_file` | blocked as dangerous |
| `delete_file` | blocked as dangerous |
| `patch_apply` | blocked as dangerous |
| `shell_command` | blocked as dangerous |
| `network_call` | blocked as dangerous |
| `remote_execution` | blocked as dangerous |

Runner behavior:

- blocked tool name → `:tool_call_blocked`
- destructive unknown tool-name shapes (write/patch/shell/network/remote-like names) → blocked
- unknown tool → error result
- `requires_approval: true` tool spec → blocked (PR09 deny-by-default behavior until later approval categories are implemented)

---

## 6. Plan Approval Lifecycle Security (PR09)

PR09 secures plan lifecycle commands with content-bound approval validation.

### Implemented command lifecycle

- `/approve plan` transitions active plan from `:awaiting_approval` to `:approved`
- `/reject plan` transitions active plan from `:awaiting_approval` to `:rejected`
- if session was `:awaiting_plan_approval`, it returns to `:idle`

### Content-bound approval binding

Plan lifecycle actions are validated against a binding that includes:

```text
session_id
plan_id
plan_version
plan_hash
workspace
```

The hash is deterministic over stable plan content, so stale approvals are rejected when plan identity/content changes.

### Stale rejection behavior

`Muse.ApprovalGate` rejects stale or mismatched requests (for example wrong session/workspace, content mismatch, missing binding, or expired binding). This prevents accidental approval of a superseded or modified plan.

### Auditable security properties

- lifecycle commands do not execute filesystem/shell/network tools
- lifecycle commands operate only on the active session plan
- approval events are emitted (`:approval_requested`, `:approval_approved`, `:approval_rejected`) with id/version/hash metadata only
- lifecycle events are emitted (`:plan_created`, `:plan_approved`, `:plan_rejected`) with safe metadata; raw plan JSON, objectives containing secrets, and raw file contents are not exposed in event/export summaries
- session status transitions are recorded (`:session_status_changed`)

### Explicit PR09 boundary

Plan approval in PR09 is lifecycle-only. It does **not** apply patches, write files, run shell/network operations, or hand off execution to Coding Muse.

Future scope (PR18/PR19): patch apply with checkpoint, checkpoint restore approvals, shell/test/network approval categories.

---

## 7. Patch Approval Lifecycle Security (PR17)

PR17 introduces patch approval as a lifecycle-only gate, extending the PR09 plan approval pattern to the Coding Muse workflow.

### Implemented data models

- `Muse.Approval` struct supports `:patch` kind with `patch_id` and `patch_hash` fields.
- `Muse.Session` includes `:awaiting_patch_approval` status and `pending_patch` field.
- `Muse.Patch` struct (see `docs/architecture.md` §3.10) defines id, diff, hash, affected_files, and status.

### Patch approval security properties

- **Coding Muse can propose patches only after an approved plan.** Conductor routes to Coding Muse when the session is `:idle` with an approved plan. The `patch_propose` tool is blocked for Planning Muse and only available to Coding Muse after plan approval.
- **Patch proposals are content-hashed.** Hash is deterministic over stable patch content; stale patch approvals are rejected by `Muse.ApprovalGate` binding checks (session_id, patch_id, patch_hash, plan_id).
- **Diff is displayed and approval requested.** The user sees the unified diff and affected files before approving.
- **`/approve patch` records approval only — no apply authority in PR17.** Patch approval does not trigger `patch_apply`, checkpoint creation, or file writes. That authority is reserved for PR18.
- **No file modifications occur before patch approval.** `patch_propose` generates/stores a diff only. `patch_apply` remains blocked in `Muse.Tool.Registry` for all roles.
- **Shell/network remain blocked/approval-gated future scope.** No shell execution, network calls, or remote execution is enabled in PR17.

### Explicit PR17 boundary

Patch approval in PR17 is **lifecycle-only**. It does **not**:

- apply the patch to files,
- create checkpoints,
- run shell commands or test runners,
- perform network calls,
- or trigger automatic execution of any kind.

Future scope (PR18/PR19): patch apply with checkpoint, checkpoint restore approvals, shell/test/network approval categories.

---

## 8. Patch Apply, Checkpoint, and Rollback Security (PR18)

**PR18 scope (not yet implemented).** The patch apply workflow will introduce approval-gated file modification with checkpoint/rollback support.

### Planned security properties

- **Patch apply requires prior patch approval.** A patch must be approved (`/approve patch`) before `patch_apply` is available.
- **Checkpoint created before apply.** The `patch_apply` tool creates a checkpoint (git stash or file copy) before modifying any files.
- **Checkpoint metadata includes integrity hashes.** File hashes and branch/head state are recorded for verification.
- **Rollback available on failure.** If patch apply fails, the checkpoint can be restored.
- **Outside-workspace paths blocked.** `patch_apply` only operates on files inside the workspace root.
- **Secret file paths blocked.** The denylist from §3 is enforced for patch targets.

### Explicit PR18 boundary

Patch apply in PR18 is **approval-gated**. It does **not**:

- execute shell commands (that's PR19),
- perform network calls (that's PR19),
- or bypass the checkpoint requirement.

---

## 9. Test Runner Security (PR19)

**PR19 scope (not yet implemented).** The test runner workflow will introduce approval-gated shell execution for verification.

### Planned security properties

- **Test runner requires approval.** `test_runner` tool is blocked by default; requires explicit approval.
- **Safe command allowlist.** Only known-safe test commands (e.g., `mix test`, `npm test`) are allowed without shell approval.
- **No arbitrary shell.** The test runner does not accept arbitrary shell commands; only configured test commands.
- **Workspace-scoped execution.** Commands run in the workspace directory only.
- **Timeout enforced.** Test commands have a maximum execution time.
- **Output capped.** Test output is truncated to prevent memory exhaustion.

### Explicit PR19 boundary

Test runner in PR19 is **approval-gated and restricted**. It does **not**:

- grant general shell execution (use `shell_command` approval category, future),
- perform network calls beyond what the test command itself does,
- or bypass workspace isolation.

---

## 10. Memory Compaction and Handoff Safety (PR21)

**Implemented in PR21.** Memory compaction and Muse handoff introduce additional safety considerations for secret handling.

### Memory compaction security

Memory compaction summarizes and truncates session history to fit within context limits. The compaction process:

- **Redacts secrets from memory summaries.** `Muse.Memory.Compactor` applies the same redaction rules as `EventPayloadRedactor`.
- **Never stores raw credentials.** Memory artifacts contain redacted summaries only.
- **Preserves audit trail.** Compaction events (`:memory_compacted`) record what was summarized without including secret content.
- **Compact artifacts are workspace-safe.** Memory files under `.muse/sessions/<id>/memory/` do not contain secrets.

### Handoff and restoration safety

Muse handoff (transferring context between Planning/Coding/Testing Muse) follows these rules:

- **Handoff specs do not include credentials.** The handoff payload contains session state, plan, patches, and memory — no auth tokens.
- **Restoration preserves approval state.** When a handoff is restored, approval bindings are validated against the current session.
- **Handoff events are redacted.** `:muse_handoff_requested` and `:muse_handoff_completed` events contain no secrets.
- **Cross-Muse credential isolation.** Each Muse process resolves auth independently; credentials are not passed between Muse processes.

### Security rules for memory and handoff

```text
✓ Secrets must not appear in memory artifacts.
✓ Secrets must not appear in handoff specs.
✓ Memory summaries use the same redaction as events.
✓ Handoff events are redacted before emission.
✓ Restoration validates approval bindings.
```

---

## 11. Auth Security Rules

Authentication tokens and credentials are among the most sensitive data in the Muse Runtime. The following rules are absolute — no exceptions, no convenience shortcuts.

```text
✓ Never emit tokens into Muse.Event.
✓ Never include tokens in prompt previews.
✓ Never store tokens under workspace .muse/ by default.
✓ Check file permissions on ~/.codex/auth.json where possible.
✓ Treat ~/.codex/auth.json as password-equivalent.
✓ Redact Authorization headers in all debug events.
```

**Token handling rules in detail:**

| Rule | Rationale |
|---|---|
| No tokens in `Muse.Event` | Events are broadcast to CLI, TUI, LiveView, and WebSocket channels — tokens would leak everywhere |
| No tokens in prompt previews | Users and developers inspect prompts; tokens must never appear in `/prompt preview` output |
| No tokens in `.muse/` workspace storage | Workspace directories may be version-controlled or shared; tokens must not persist there |
| Check `~/.codex/auth.json` permissions | If the file is world-readable (permissions `0644` or wider), warn the user |
| Treat `auth.json` as password-equivalent | It contains OAuth tokens — handle with the same care as a password vault |
| Redact Authorization headers | Provider debug snapshots, request logs, and error messages must strip `Authorization` header values |

**Credential struct:**

```elixir
%Muse.Auth.Credential{
  type: :bearer,
  value: "...",                         # never logged, never shown
  source: :env | :codex_cache | :command,
  expires_at: nil,
  redacted: "sk-...REDACTED"             # safe representation for events/logs
}
```

The `redacted` field is the **only** value that may appear in events, logs, or debug output. The `value` field is never exposed outside the auth subsystem.

---

## 12. Prompt Security

The internal prompt system is assembled from multiple layers (core invariants, mode policies, Muse profiles, workspace policies, project rules, memory, plan state, history). Users and developers must **not** see the full raw internal prompt.

**Debug preview rules:**

The `/prompt preview` command shows **layer metadata**, not raw content:

```text
Prompt bundle for session s_123
Active Muse: Planning Muse
Model: fake
Tools: list_files, read_file, repo_search, git_status, git_diff_readonly, ask_user_question, list_muses, list_skills
Blocked tools: write_file, replace_in_file, delete_file, patch_apply, shell_command, network_call, remote_execution

Layers:
 1. muse_core_invariants      internal    720 tokens
 2. active_mode_policy        internal    180 tokens
 3. planning_muse_profile    internal    950 tokens
 4. workspace_policy          internal    310 tokens
 5. approval_policy           internal    420 tokens
 6. project_rules             context     260 tokens
 7. memory_summary            context     140 tokens
 8. active_plan_state         context       0 tokens
 9. recent_history            context     220 tokens
10. current_user_message      user         18 tokens
```

**Debug preview API:**

```elixir
defmodule Muse.Prompt.DebugPreview do
  def render(bundle) do
    bundle.layers
    |> Enum.map(&redacted_layer_summary/1)
  end
end
```

**Never show in any prompt preview, log, or debug output:**

```text
✗ Secrets
✗ API keys
✗ Bearer tokens
✗ Private keys
✗ Shell history
✗ Hidden tokens
✗ Codex auth tokens
✗ Unredacted .env content
```

These restrictions apply regardless of the user's intent. Even in `--debug` mode, the full internal prompt is never dumped verbatim — only the redacted layer summary is shown. This prevents accidental credential exposure during debugging or support interactions.

---

## 13. External WebSocket Channel Security (PR16)

The optional external Phoenix WebSocket channel (documented in [`architecture.md` §8.5](architecture.md#85-optional-external-phoenix-websocket-channel-pr16)) exposes session events to non-LiveView clients. The following security rules are **mandatory** — they are enforced in `MuseWeb.ExternalEventFilter` and cannot be bypassed by client configuration.

### 13.1 Network Binding

```text
✓ Server binds to 127.0.0.1 (localhost) by default.
✓ Do NOT expose the WebSocket endpoint externally without authentication.
✓ Production deployments MUST use a reverse proxy (nginx, caddy, etc.) with TLS termination.
✓ Do NOT bind to 0.0.0.0 without explicit authentication and transport encryption.
```

### 13.2 Disabled by Default

The external WebSocket channel is **disabled by default** (`config :muse, :external_ws, enabled: false`). When disabled:

- `MuseWeb.UserSocket.connect/3` rejects all connections.
- No channel processes start; no resources consumed.
- Opt-in via `MUSE_EXTERNAL_WS` env var in production (accepted values: `true`, `1`, `yes`, `on`), or explicit config in dev/test.

### 13.3 Visibility Filtering

The channel enforces strict visibility-based filtering before forwarding any event:

| Visibility | Forwarding | Rationale |
|---|---|---|
| `:user` | **Allowed** — payload redacted before forwarding | Safe for external consumption after redaction |
| `:internal` | **DENIED** — never forwarded | Internal runtime events |
| `:sensitive` | **DENIED** — never forwarded | Secrets, credentials, auth tokens |
| `:debug` | **DENIED** by default — `allow_debug?` option exists but is NOT used by the channel | Debug/diagnostic events not designed for external consumers |
| `nil` | **DENIED by default** — only allowlisted event types forwarded | Events without explicit visibility must be reviewed before exposure |

**Allowlist for nil-visibility events** (safe types only):

```text
user_message, assistant_delta, assistant_message,
plan_created, plan_approved, plan_rejected,
approval_requested, approval_approved, approval_rejected,
turn_completed, turn_failed, session_status_changed,
patch_proposed, patch_approval_requested, patch_approved, patch_rejected
```

**Provider/auth/debug denial:** Even if a nil-visibility event type is on the allowlist, it is denied when the source:type combination suggests provider/auth/debug content (e.g., `openai_provider_debug:assistant_delta`).

Any event type **not** on this allowlist and without `:user` visibility is silently dropped.

### 13.4 Session Isolation

- A client must join topic `session:<session_id>` explicitly.
- Only events with an **exact** `session_id` match are forwarded.
- Nil `session_id` (global/legacy) events are **NOT** forwarded on session-scoped topics.
- Cross-session events are never forwarded.
- Session IDs are validated: empty, `.`, `..`, and path-traversal characters (`/`, `\`, NUL) are rejected.

### 13.5 Payload Redaction

Even for allowed events, payloads are redacted before forwarding:

```text
✓ Data passes through Muse.EventDisplay.safe_data/1 first.
✓ Then converted to JSON-safe format with depth limits and struct suppression.
✓ API keys, bearer tokens, OAuth/Codex/GitHub tokens are redacted.
✓ Arbitrary structs are replaced with "[struct omitted]".
✓ Nested Muse.Event structs are replaced with "[event omitted]".
✓ Strings exceeding 2000 chars are truncated.
✓ No String.to_atom/1 on client input.
```

### 13.6 No Secrets Exposed

The external channel must **never** expose:

```text
✗ Auth tokens (Bearer tokens, API keys, session tokens)
✗ Provider secrets (API keys, base URLs with embedded credentials)
✗ Session secrets (internal state tokens, approval bindings with raw hashes)
✗ Credential values (from Muse.Auth.Credential or ~/.codex/auth.json)
✗ Internal event types (approval_state_change, secret_read_attempt, etc.)
```

### 13.7 Read-Only Channel

The external WebSocket channel is **read-only**. It does **not** grant:

```text
✗ Tool execution permissions
✗ File write/patch/delete permissions
✗ Shell command execution permissions
✗ Network call permissions
✗ Ability to invoke Muse.submit/2 or any mutation API
```

Subscribing to the channel allows observing filtered session events only. No user action through the WebSocket can trigger runtime mutations. This is the **PR17+ safety invariant**: external WS grants zero tool/write/shell/network/approval authority.
