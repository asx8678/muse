# Muse Universal Runtime — Security Document

> **Companion docs:** [Architecture](architecture.md) · [Prompts](prompts.md) · [Provider Roadmap](provider-roadmap.md) · [Testing](testing.md) · [Executive Summary](../PLAN.md)
>
> **Canonical source:** Workspace safety, secret handling, redaction, approval/security rules, and MVP security checklist.

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
7. [Auth Security Rules](#7-auth-security-rules)
8. [Prompt Security](#8-prompt-security)

---

## 1. Security Checklist Before MVP

Every item must be verified before the Muse Runtime reaches MVP. No exceptions.

- [ ] No API keys in events
- [ ] No bearer tokens in logs
- [ ] No Codex auth tokens in prompt preview
- [ ] Authorization headers redacted from provider debug output
- [ ] Secret-like files blocked or redacted
- [ ] Workspace path checks are symlink-aware
- [ ] Patch apply blocks outside-workspace paths
- [ ] Patch apply blocks secret file paths
- [ ] Patch apply creates checkpoint first
- [ ] Shell commands are approval-gated
- [ ] Network calls are approval-gated or disabled
- [ ] Remote execution is disabled
- [ ] Web server defaults to localhost
- [ ] External WebSocket channel does not forward internal/sensitive events
- [ ] Prompt preview is redacted and does not show full hidden prompt
- [ ] Tool outputs are capped
- [ ] Provider errors do not leak secrets
- [ ] Configuration validated at startup
- [ ] All processes are supervised
- [ ] No orphan processes on turn crash

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
- lifecycle events are emitted (`:plan_approved` / `:plan_rejected`) with safe metadata
- session status transitions are recorded (`:session_status_changed`)

### Explicit PR09 boundary

Plan approval in PR09 is lifecycle-only. It does **not** apply patches, write files, run shell/network operations, or hand off execution to Coding Muse.

Future scope (PR17/PR18/PR19): patch approval/apply, checkpoint restore approvals, shell/test/network approval categories.

---

## 7. Auth Security Rules

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

## 8. Prompt Security

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
