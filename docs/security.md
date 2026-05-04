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
6. [Approval Gate Rules](#6-approval-gate-rules)
   - 6.1 [Approval Binding Rules](#61-approval-binding-rules)
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

The following matrix defines which tools are available to each Muse role and under what approval conditions. This is enforced by `Muse.ApprovalGate` at runtime — not by prompt instructions.

| Tool | Planning Muse (before approval) | Coding Muse (after plan approval) | Patch approval required | Notes |
|---|:---:|:---:|:---:|---|
| `list_files` | ✅ allow | ✅ allow | no | Workspace only |
| `read_file` | ✅ allow | ✅ allow | no | Secret policy enforced |
| `repo_search` | ✅ allow | ✅ allow | no | Output limits required |
| `git_status` | ✅ allow | ✅ allow | no | Read-only |
| `git_diff_readonly` | ✅ allow | ✅ allow | no | Read-only |
| `ask_user_question` | ✅ allow | ✅ allow | no | Non-blocking |
| `list_muses` | ✅ allow | ✅ allow | no | Product discovery |
| `list_skills` | ✅ allow | ✅ allow | no | Optional later |
| `patch_propose` | 🚫 block | ✅ allow after approved plan | no | Generates/stores diff only |
| `patch_apply` | 🚫 block | ✅ allow only after patch approval | yes | Checkpoint first |
| `write_file` | 🚫 block | ⚠️ approval-gated | yes | Prefer patch workflow |
| `replace_in_file` | 🚫 block | ⚠️ approval-gated | yes | Checkpoint first |
| `delete_file` | 🚫 block | ⚠️ explicit delete approval | explicit delete approval | High risk |
| `test_runner` | 🚫 block | ⚠️ conditional | command approval unless configured safe | No arbitrary shell |
| `shell_command` | 🚫 block | ⚠️ conditional | yes | Command allowlist recommended |
| `network_call` | 🚫 block | ⚠️ conditional | yes | Default block |
| `remote_execution` | 🚫 block | 🚫 later only | yes | Implement late |

**Approval categories:**

| Category | Meaning |
|---|---|
| `:always_allowed` | Tool can run without user confirmation |
| `:approval_required` | Tool must receive explicit user approval before running |
| `:blocked` | Tool is not available in the current context |

---

## 6. Approval Gate Rules

The `Muse.ApprovalGate` enforces all approval requirements at runtime. Every tool execution path must check `ApprovalGate.allowed?/2` before proceeding — prompt text is guidance, not a security boundary.

**Runtime enforcement rules:**

| Rule | Enforcement |
|---|---|
| Read tools | Allowed for Planning Muse unless path/secret policy blocks them |
| Plan creation | Allowed for Planning Muse |
| Patch proposal | Requires an approved plan |
| Patch apply | Requires an approved plan **and** an approved patch hash |
| Shell command | Requires explicit shell approval (except future safe-command allowlist) |
| Remote execution | **Always denied** until remote execution milestone |

**Enforcement pattern:**

```elixir
case Muse.ApprovalGate.allowed?(session, tool_call) do
  {:ok, :allowed}    -> run_tool()
  {:blocked, reason} -> block_tool(reason)
end
```

This pattern is invoked by `Muse.Tool.Runner` before **every** tool call. There is no code path that executes a tool without passing through the approval gate.

### 6.1 Approval Binding Rules

Approvals are cryptographically bound to the specific content they approve. If the content changes, the approval is invalidated — preventing stale-approval attacks.

**Plan approval binds to:**

```text
session_id
plan_id
plan_version
workspace
approved_by
approved_at
approval_scope
```

**Patch approval binds to:**

```text
session_id
plan_id
plan_version
patch_id
patch_hash
affected_files
workspace
```

**Stale approval rules:**

| Condition | Result |
|---|---|
| Plan version changes | Old approvals are **invalid** — must be re-approved |
| Patch hash changes | Old patch approvals are **invalid** — must be re-approved |
| Session workspace changes | All approvals are **invalid** — context mismatch |

This ensures that a user who approved a plan or patch cannot have a modified version applied without re-approval.

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
Tools: list_files, read_file, repo_search, git_status
Blocked tools: patch_apply, shell_command, delete_file, network_call

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
