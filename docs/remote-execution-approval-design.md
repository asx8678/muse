# Remote Execution Approval — Design Spike (Phase 5)

> **Companion docs:** [Security](security.md) · [Architecture](architecture.md) · [Prompts](prompts.md) · [Provider Roadmap](provider-roadmap.md) · [Testing](testing.md) · [Executive Summary](../PLAN.md)
>
> **Canonical source:** Design-only spike for remote execution approval. No implementation of remote execution capability. Remote execution remains denied by default throughout v0.2.0.
>
> **Status:** Design spike — **approved for reference**. Phase D implements `SSHRunner` with approval-bound execution, credential resolution, and host key verification. Remote execution remains denied by default without valid approval context.

---

## Table of Contents

1. [Objective](#1-objective)
2. [Threat Model](#2-threat-model)
   - 2.1 [Assets](#21-assets)
   - 2.2 [Trust Boundaries](#22-trust-boundaries)
   - 2.3 [Threat Catalog](#23-threat-catalog)
   - 2.4 [In-Scope Threats](#24-in-scope-threats)
   - 2.5 [Out-of-Scope Threats](#25-out-of-scope-threats)
3. [Approval Model](#3-approval-model)
   - 3.1 [Design Tenets](#31-design-tenets)
   - 3.2 [Approval Flow](#32-approval-flow)
   - 3.3 [Approval Record Schema](#33-approval-record-schema)
   - 3.4 [Scope Definitions](#34-scope-definitions)
   - 3.5 [Expiry and Staleness](#35-expiry-and-staleness)
4. [Audit Event Schema](#4-audit-event-schema)
   - 4.1 [New Event Types](#41-new-event-types)
   - 4.2 [Event Payload Shape](#42-event-payload-shape)
   - 4.3 [Event Visibility Rules](#43-event-visibility-rules)
5. [Runner Contract Extension](#5-runner-contract-extension)
   - 5.1 [RemoteRunner Behaviour](#51-remoterunner-behaviour)
   - 5.2 [Capability Declaration](#52-capability-declaration)
   - 5.3 [Registration and Routing](#53-registration-and-routing)
   - 5.4 [Example: SSH RemoteRunner Sketch](#54-example-ssh-remoterunner-sketch)
6. [Data Model / Events](#6-data-model--events)
   - 6.1 [Execution Target Descriptor](#61-execution-target-descriptor)
   - 6.2 [Target Registry](#62-target-registry)
   - 6.3 [Execution Policy Extension](#63-execution-policy-extension)
7. [Test Strategy](#7-test-strategy)
8. [Rollout Plan](#8-rollout-plan)
9. [Explicit Non-Goals](#9-explicit-non-goals)

---

## 1. Objective

Design a secure, auditable approval flow for remote execution in the Muse Runtime. This is a **design-only spike** — no implementation of remote execution capability. Remote execution remains denied by default throughout v0.2.0.

### Scope

- Threat model document for remote execution (what threats exist, what's in/out of scope)
- Approval model: what approvals would be needed before remote execution could run
- Audit events: what events remote execution would emit and how they'd be tracked
- Runner contract: what the Runner behaviour extension for remote targets would look like
- Gating: a second approval (separate from patch/plan approval) required for remote execution

### Non-Goals (see §9 for complete list)

- No implementation of remote execution
- No SSH/VPS connection code
- No changes to existing Runner, Policy, or ApprovalGate
- No remote execution in CI/CD

### Safety Invariants (Never Relaxed)

From the v0.2.0 roadmap and security document:

> **Remote execution remains denied by default** — Runner.Policy denies `:remote`, `:ssh`, string targets
> **All approval gates remain enforced** — no bypass of plan/patch/approval gating

These invariants are absolute. This design introduces a gating layer that, when implemented, would **add** an approval gate, never bypass one.

---

## 2. Threat Model

### 2.1 Assets

| Asset | Sensitivity | Description |
|---|---|---|
| Remote host credentials (SSH keys, passwords, tokens) | **Critical** | Provide access to remote infrastructure |
| Remote host filesystem | **High** | Contains source code, configuration, data |
| Remote host process environment | **High** | Can contain API keys, database URLs, secrets |
| Remote execution target configuration | **High** | Target hostnames, IPs, port numbers |
| Session — user/assistant message history | **Medium** | Conversation content, plan text, patch diffs |
| Approval binding data | **Low** | Approval IDs, hashes, timestamps (metadata only) |

### 2.2 Trust Boundaries

```
┌──────────────────────────────────────────────────┐
│                  Local Machine                    │
│  ┌──────────┐   ┌────────────┐   ┌────────────┐  │
│  │  Muse    │──▶│ Conductor  │──▶│ Tool.Runner│  │
│  │ Session  │   │            │   │            │  │
│  └──────────┘   └────────────┘   └──────┬─────┘  │
│                                         │        │
│                                         ▼        │
│                                  ┌────────────┐  │
│                                  │Policy.check│  │
│                                  │  :remote?  │──┼── Trust Boundary ①
│                                  └──────┬─────┘  │
└──────────────────────────────────────────┼────────┘
                                           │
                                           ▼
                               ┌──────────────────────┐
                               │   Remote Host         │
                               │   (SSH / SSH-like)    │
                               │                       │
                               │  ┌─────────────────┐  │
                               │  │ Remote File System│  │
                               │  ├─────────────────┤  │
                               │  │ Remote Processes │  │
                               │  ├─────────────────┤  │
                               │  │ Remote Env Vars  │  │
                               │  └─────────────────┘  │
                               └──────────────────────┘
                                    ↑
                                    │ Trust Boundary ②
                                    │ (network)
```

**Trust Boundary ①** (tool → policy): The `Tool.Runner` must enforce policy before invoking any runner. No runner is invoked without policy clearance.

**Trust Boundary ②** (local → remote network): The network transport itself is untrusted. Remote connections must use authenticated, encrypted channels (SSH or equivalent).

### 2.3 Threat Catalog

| ID | Threat | Risk | Description |
|----|--------|------|-------------|
| T1 | **Unauthorized remote access** | Critical | An attacker gains SSH access to a host the user never intended to expose. Could be prompt injection, compromised Muse profile, or misconfigured target. |
| T2 | **Credential exfiltration** | Critical | SSH keys, passwords, or tokens are read from local config and leaked into session events, logs, or remote command output. |
| T3 | **Lateral movement** | High | A compromised remote host is used as a pivot to attack other internal infrastructure. |
| T4 | **Accidental target misrouting** | High | A command intended for host A is executed on host B (typo, hostname collision, stale target config). |
| T5 | **Privilege escalation on remote host** | High | The remote user has more permissions than intended (e.g., root instead of limited user). |
| T6 | **Data exfiltration from remote host** | High | Remote command output contains secrets, credentials, or sensitive customer data that leaks back into Muse session events. |
| T7 | **Race condition between approval and execution** | Medium | A user approves "run tests on staging" but by the time execution starts, the target has been reconfigured. |
| T8 | **Approval fatigue / rubber-stamping** | Medium | Frequent approval prompts lead users to approve without reviewing target/host details. |
| T9 | **Stale approval reuse** | Medium | A user approved an SSH key for 24h; an attacker reuses that approval after the key has been rotated. |
| T10 | **Remote host compromise via untrusted command** | High | A Muse proposes a destructive command (rm -rf, curl | sh) and the user approves without understanding the remote impact. |
| T11 | **Man-in-the-middle on SSH connection** | Medium | First-connection host key verification bypassed or TOFU policy exploited. |
| T12 | **No audit trail for remote actions** | Medium | Remote commands execute but no structured event is recorded — no trace for post-hoc investigation. |

### 2.4 In-Scope Threats

The following threats are **in scope** for this design spike:

- T1 — Unauthorized remote access → mitigated by **approval gating** (§3), **target registry** (§6.2)
- T2 — Credential exfiltration → mitigated by **no credentials in events** (§4.3), **redacted approval metadata**
- T4 — Accidental target misrouting → mitigated by **content-hashed approval bindings** (§3.2)
- T6 — Data exfiltration → mitigated by **output capping and redaction** (§5.1)
- T7 — Race condition → mitigated by **approval expiry** (§3.5)
- T8 — Approval fatigue → mitigated by **explicit target/command display** in approval requests (§3.2)
- T9 — Stale approval reuse → mitigated by **content-hashed, session-scoped bindings** (§3.5)
- T10 — Destructive commands → mitigated by **command argv preview** in approval requests
- T12 — No audit trail → mitigated by **structured audit events** (§4.1)

### 2.5 Out-of-Scope Threats

The following threats are **out of scope** and deferred to implementation/review stages:

- T3 — Lateral movement (network-level controls, beyond Muse scope)
- T5 — Privilege escalation (operational concern, beyond Muse scope)
- T11 — MITM (SSH host key verification is an SSH client concern)

---

## 3. Approval Model

### 3.1 Design Tenets

1. **Remote execution approval is a separate gate** from plan approval and patch approval. A user must explicitly approve a remote execution request even if the plan and patches have already been approved.
2. **Approval is target-scoped, not blanket.** The user approves execution against a specific target (hostname, IP, or target descriptor), not "all remote execution for this session."
3. **Approval is command-scoped.** The user sees what command/argv would be executed on the remote target.
4. **Approval content is hashed.** Stale or modified commands are rejected by binding checks.
5. **No remote execution capability without approval.** The Policy remains deny-by-default; approval only lifts the denial for a specific (session, target, command) tuple.

### 3.2 Approval Flow

```
Session flow for remote execution:

  1. Muse proposes a plan that includes a remote execution step.
     └── Existing plan approval flow (PR09). Plan states intent.

  2. (If remote execution is part of the approved plan)
     Coding Muse produces a patch and user approves (PR17).

  3. Remote execution tool is invoked (e.g., remote_run or ssh_exec).
     └── Tool.Runner checks Policy → :remote → requires :remote_execution approval
     └── If no active remote_execution approval exists:
         └── Session enters :awaiting_remote_execution_approval
         └── User sees: target host + command argv + hash preview
         └── User types /approve remote
         └── Approval bound to session_id + target_id + command_hash + plan_id

  4. Approved remote execution runs.
     └── Runner invoked, output streamed back with capping and redaction
     └── Audit event emitted

  5. Subsequent remote execution commands in the same session:
     └── If target + command differ → new approval required
     └── If same target + same command → same approval may be reused (within expiry)
```

**Command flow for approval:**

```
User: /approve remote              → Session transitions to :idle
User: /reject remote               → Session transitions to :idle, tool blocked
User: /status                      → Shows pending remote approval with target + command preview
```

### 3.3 Approval Record Schema

The existing `Muse.Approval` struct (kind: `:remote_execution`) is extended with:

**New fields on `Muse.Approval`:**

```elixir
%Muse.Approval{
  id: "apr_20260507_abc123",
  kind: :remote_execution,
  status: :pending | :approved | :rejected | :expired | :stale,
  session_id: "sess_1",
  plan_id: "pln_20260507_def456",
  target_id: "tgt_staging_web_1",         # references Target Registry
  command_hash: "sha256-abcd...",          # hash of normalized Command
  argv_preview: ["ssh", "user@host", "ls", "-la"],  # for user display
  approved_at: ~U[2026-05-07 10:00:00Z],
  expires_at: ~U[2026-05-07 10:05:00Z],    # 5-minute default expiry
  metadata: %{
    target_host: "staging.example.com",
    target_user: "deploy",
    command_preview: "ls -la"
  }
}
```

**Existing fields reused:**
- `id`, `session_id`, `plan_id`, `kind`, `status`, `created_at`, `approved_at`, `rejected_at`, `expires_at`, `reason`, `metadata`

**New fields added:**
- `target_id` — references a target descriptor in the (future) Target Registry (§6.2)
- `command_hash` — content hash of the normalized command argv
- `argv_preview` — safe display copy of the command for user approval UI

### 3.4 Scope Definitions

| Scope | Meaning | Expiry | Example |
|-------|---------|--------|---------|
| `:single_command` | One specific command on one target | 5 minutes | `ssh deploy@staging1 ls /var/log` |
| `:session_target` | Multiple commands on same target within session | Session-bound | All remote commands on `staging1` |
| `:session_workspace` | Any remote execution anywhere in session | Session-bound | DANGER: broad scope, require explicit user |

**Recommendation:** Start with `:single_command` scope only. `:session_target` and `:session_workspace` should be deferred to later phases.

### 3.5 Expiry and Staleness

| Rule | Value | Rationale |
|------|-------|-----------|
| Default approval expiry | 5 minutes | Short window reduces race windows (T7) |
| Max approval expiry | Session lifetime | Hard limit set by config |
| Stale rejection | On content change | If the command or target changes, existing approval is invalidated |
| Stale rejection | On plan change | If the plan is superseded, remote approvals bound to that plan are invalidated |

**Expiry enforcement:**

```elixir
# In ApprovalGate
def authorize_remote_execution?(approval, current_command) do
  with {:ok, _} <- validate_binding(approval, current_command),
       :ok <- validate_freshness(approval),
       :ok <- validate_content_hash(approval, current_command) do
    true
  else
    _ -> false
  end
end
```

---

## 4. Audit Event Schema

### 4.1 New Event Types

| Event Type | Source | Visibility | Description |
|---|---|---|---|
| `:remote_execution_requested` | Conductor / Tool.Runner | `:user` | User or Muse requested remote execution; awaiting approval |
| `:remote_execution_approved` | SessionServer | `:user` | Remote execution approved by user |
| `:remote_execution_rejected` | SessionServer | `:user` | Remote execution rejected by user |
| `:remote_execution_started` | Runner | `:user` | Remote command started executing |
| `:remote_execution_completed` | Runner | `:user` | Remote command completed (with result summary) |
| `:remote_execution_failed` | Runner | `:user` | Remote command failed (connection error, timeout, etc.) |
| `:remote_execution_denied` | Policy | `:internal` | Remote execution denied by Policy (no approval) |
| `:remote_execution_output` | Runner | `:user` | Output chunk from remote command (capped, redacted) |
| `:target_registered` | Target Registry | `:internal` | Target descriptor created |
| `:target_updated` | Target Registry | `:internal` | Target descriptor updated |
| `:target_removed` | Target Registry | `:internal` | Target descriptor removed |

### 4.2 Event Payload Shape

```elixir
# :remote_execution_requested
%{
  target_id: "tgt_staging_web_1",
  target_host: "staging.example.com",
  command_preview: "ls -la /var/log",
  command_hash: "sha256-abcd...",
  plan_id: "pln_20260507_def456",
  session_id: "sess_1"
}

# :remote_execution_approved
%{
  target_id: "tgt_staging_web_1",
  approval_id: "apr_20260507_abc123",
  target_host: "staging.example.com",
  command_preview: "ls -la /var/log",
  scope: :single_command
}

# :remote_execution_started
%{
  target_id: "tgt_staging_web_1",
  approval_id: "apr_20260507_abc123",
  command_preview: "ls -la /var/log",
  started_at: "2026-05-07T10:00:00Z"
}

# :remote_execution_completed
%{
  target_id: "tgt_staging_web_1",
  approval_id: "apr_20260507_abc123",
  exit_status: 0,
  output_summary: "total 42\n...",
  output_capped?: false,
  duration_ms: 1234
}

# :remote_execution_denied
%{
  target_id: "tgt_staging_web_1",
  reason: "no active remote execution approval",
  # Target host NOT included — internal event only
}
```

### 4.3 Event Visibility Rules

| Field | `:user` Events | `:internal` Events |
|---|---|---|
| `target_id` | ✅ Always shown (safe reference) | ✅ Always shown |
| `target_host` | ✅ Shown | ✅ Shown |
| `target_user` | ❌ **Never shown** | ❌ Never shown |
| `command_preview` | ✅ Shown (redacted) | ❌ Omitted |
| `command_hash` | ✅ Shown | ✅ Shown |
| `output_summary` | ✅ Shown (capped, redacted) | ❌ Omitted |
| `full_output` | ❌ Never shown in events | ❌ Never shown |
| `credential_ref` | ❌ Never shown | ❌ Never shown |
| `exit_status` | ✅ Shown | ✅ Shown |
| `duration_ms` | ✅ Shown | ✅ Shown |
| `denial_reason` | N/A | ✅ Shown |

**Redaction rules (matching `docs/security.md` §4):**

- All remote command output passes through `Muse.Prompt.Redactor.redact_text/1` before event emission.
- Target hostnames that match known secret patterns are redacted.
- Command argv values are redacted for secret-like tokens.
- Target user (SSH user) is **never** included in user-visibility events.

---

## 5. Runner Contract Extension

### 5.1 RemoteRunner Behaviour

The `Muse.Execution.Runner` behaviour is extended with an optional `RemoteRunner` sub-behaviour for remote execution runners. This is a **separate module** — not a modification to the existing `Runner` behaviour, preserving backward compatibility.

```elixir
defmodule Muse.Execution.RemoteRunner do
  @moduledoc """
  Extension behaviour for remote execution runners.

  Remote runners implement the standard `Muse.Execution.Runner` behaviour
  plus additional callbacks for:

    * Connection lifecycle (connect, disconnect, heartbeat)
    * Credential resolution (with explicit user approval)
    * Host key verification
    * Output streaming

  All remote runners must:
    * Enforce connection timeout.
    * Validate host identity (host key verification or equivalent).
    * Resolve credentials only through the approved credential store.
    * Never emit credentials in events, logs, or debug output.
    * Cap and redact output (inherits from Runner).
    * Emit structured audit events for connect/disconnect/execution.
  """

  alias Muse.Execution.{Command, Result}

  @doc """
  Connect to a remote target.

  Returns `{:ok, connection_ref}` on success, `{:error, reason}` on failure.
  Connection refs are opaque tokens used for subsequent execution.
  """
  @callback connect(target :: map(), opts :: keyword()) ::
              {:ok, connection_ref :: term()} | {:error, String.t()}

  @doc """
  Disconnect from a remote target.

  Called at session end or on error cleanup. Best-effort.
  """
  @callback disconnect(connection_ref :: term()) :: :ok

  @doc """
  Execute a command on the connected remote target.

  Same contract as `Runner.run/2` but operates on a connection ref.
  """
  @callback remote_run(connection_ref :: term(), Command.t(), keyword()) :: Result.t()
end
```

**Design rationale for a separate behaviour:**

1. Not all runners are remote — keeping `RemoteRunner` separate avoids forcing local runners to implement callbacks they don't need.
2. Backward compatible — existing `Runner` modules (`LocalRunner`, `RemoteDeniedRunner`) are unchanged.
3. Self-documenting — a module that `use Muse.Execution.RemoteRunner` is explicitly declaring remote capability.

### 5.2 Capability Declaration

Each runner declares its capabilities. Remote runners add:

```elixir
def capabilities do
  %{
    local: false,
    remote: true,
    ssh: true,
    shell: true,
    network: true,
    timeout_ms: 120_000,
    max_output_bytes: 500_000,
    # Remote-specific:
    protocols: [:ssh],
    supports_keepalive?: true,
    supports_connection_reuse?: true,
    max_connections: 5
  }
end
```

The existing `Runner.supports_remote?/1` helper already works with this pattern.

### 5.3 Registration and Routing

The `Policy` module gains an additional resolver:

```elixir
# In Policy:
@remote_runner_registry %{
  ssh: Muse.Execution.SSHRunner,         # future module
  # docker: Muse.Execution.DockerRunner,  # future
  # kubernetes: Muse.Execution.K8sRunner  # future
}

def resolve_remote_runner(:ssh), do: {:ok, Muse.Execution.SSHRunner}
def resolve_remote_runner(_), do: {:error, "no runner for remote target type"}
```

The routing logic in `Runner.run/2` is updated to:

```elixir
def run(%Command{target: :remote, protocol: :ssh} = command, opts) do
  # Requires :remote_execution approval — enforced by Tool.Runner
  Muse.Execution.SSHRunner.run(command, opts)
end
```

This is a **future implementation** detail — the design shows the extension point without modifying existing code.

### 5.4 Example: SSH RemoteRunner Sketch

```elixir
defmodule Muse.Execution.SSHRunner do
  @behaviour Muse.Execution.Runner
  @behaviour Muse.Execution.RemoteRunner

  @impl Muse.Execution.Runner
  def run(%Command{} = command, opts) do
    # 1. Resolve target from Command.target_info
    # 2. Resolve credential (SSH key) from CredentialStore
    # 3. Open SSH connection (Erlang :ssh module or system ssh)
    # 4. Execute argv-vector command on remote
    # 5. Collect, cap, redact output
    # 6. Emit audit events
    # 7. Return Result
    {:error, Result.blocked("SSH runner not implemented", denial: true)}
  end

  @impl Muse.Execution.RemoteRunner
  def connect(target, opts) do
    # Returns {:ok, connection_ref}
    {:error, "not implemented"}
  end

  @impl Muse.Execution.RemoteRunner
  def disconnect(connection_ref), do: :ok
end
```

**Key design points:**
- The SSH runner uses Erlang's built-in `:ssh` application or shell-outs to the system `ssh` command (argv-vector, not shell interpolation).
- No credentials are stored in the runner module — all credential resolution goes through the auth subsystem.
- Output is capped and redated identically to `LocalRunner`.

---

## 6. Data Model / Events

### 6.1 Execution Target Descriptor

```elixir
defmodule Muse.Execution.Target do
  @moduledoc """
  Describes a remote execution target.

  Targets are stored in the Target Registry and referenced by
  `target_id` in approval records and audit events.
  """

  defstruct [
    :id,                    # "tgt_staging_web_1"
    :label,                 # "Staging Web 1"
    :protocol,              # :ssh
    :host,                  # "staging.example.com"
    :port,                  # 22
    :user,                  # "deploy" — NEVER in user-visibility events
    :connection_opts,       # [user_known_hosts_file: ...]
    :credential_ref,        # opaque reference to CredentialStore
    :tags,                  # ["staging", "web"]
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t() | nil,
          protocol: :ssh | :local | :docker,
          host: String.t(),
          port: non_neg_integer(),
          user: String.t() | nil,
          connection_opts: keyword(),
          credential_ref: term(),
          tags: [String.t()],
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
```

### 6.2 Target Registry

A lightweight ETS-based registry for target descriptors.

```
Target Registry
───────────────
- Stored in ETS (GenServer wraps it for consistency)
- Targets are created by user configuration (env vars, config files)
- Targets are referenced by `target_id` in approval records
- Registry never stores credentials — only opaque credential_refs
- Targets emit :target_registered / :target_updated / :target_removed events
```

**Not in scope for this design spike:** The Target Registry itself is a reference concept. Its implementation is deferred.

### 6.3 Execution Policy Extension

The `Policy` module gains awareness of remote execution approvals:

```elixir
# Concept — not implementation in v0.2.0
def resolve_target(:remote, context) do
  case context do
    %{approval: %{kind: :remote_execution, status: :approved}} ->
      {:ok, resolve_remote_runner(context.target_protocol)}
    _ ->
      {:error, "remote execution requires explicit approval"}
  end
end
```

The `remote_execution_denied?/1` function becomes context-aware:

```elixir
def remote_execution_denied?(%{approval: %{kind: :remote_execution}}) do
  # If there's an approval record, check its validity
  false  # Permission to proceed to ApprovalGate for authorization
end

def remote_execution_denied?(_context) do
  # No approval context — unconditionally denied
  true
end
```

---

## 7. Test Strategy

| Layer | Approach | Tool | Coverage Target |
|-------|----------|------|-----------------|
| **ApprovalGate** | Unit tests for `authorize_remote_execution?/2` | ExUnit | Binding validation, expiry, content hash mismatch, missing approval |
| **Policy** | Unit tests for `resolve_target(:remote, context)` | ExUnit | Denied by default, approved with valid approval, stale approval |
| **Runner** | Unit tests for `RemoteRunner` behaviour callbacks | ExUnit | Contract enforcement, error handling |
| **Integration** | Session flow: plan → approve plan → patch → approve patch → remote run → approve remote | ExUnit + fake SSH runner | Full approval chain, event emission, state transitions |
| **Security** | Threat model coverage: each T1–T12 mapped to at least one test | ExUnit + property tests | Regression against known threat patterns |
| **Fake runner** | `Muse.Execution.FakeRemoteRunner` returns deterministic results | ExUnit | Tests that don't need real SSH, verify approval flow |

**Key testing rules (matching `docs/testing.md`):**

- No real SSH connections in `mix test` — fake provider remains default.
- `FakeRemoteRunner` returns configurable results (ok, error, timeout, denied) without network.
- Property tests for approval binding: random content changes must always invalidate.
- Security regression tests: each threat T1–T12 as a named test case.

---

## 8. Rollout Plan

```
Phase A: Design spike (THIS DOCUMENT)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ Threat model
  ✓ Approval model & record schema
  ✓ Audit event schema
  ✓ Runner contract extension
  ✓ Test strategy
  → Follow-up beads created for each implementation phase

Phase B: Approval infrastructure (future)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  - Add :remote_execution kind to Approval struct
  - Add :awaiting_remote_execution_approval session state
  - Add /approve remote and /reject remote commands
  - Add approval flow to SessionServer
  - Update ApprovalGate with remote_execution authorization
  - Unit tests for approval flow
  - No remote runner yet — approval infra standalone

Phase C: Remote runner foundations (future)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  - Implement RemoteRunner behaviour
  - Implement FakeRemoteRunner for testing
  - Implement Target struct and Target Registry
  - Update Policy to route remote targets through approval
  - Integration tests with FakeRemoteRunner

Phase D: SSH runner implementation (**IMPLEMENTED**)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  - ✓ Implement SSHRunner using :ssh Erlang library
  - ✓ Credential resolution (SSH identity-file references via SSHCredentialResolver)
  - ✓ Host key verification (required; no silent acceptance)
  - ✓ SSH client behaviour/adapter (SSHClient behaviour, ErlangSSHClient, FakeSSHClient)
  - ✓ SSH-specific Target validation (user, credential_ref, port, connection_opts safety)
  - ✓ Policy routing for :ssh protocol targets
  - ✓ Command quoting (POSIX single-quote escaping)
  - ✓ Output capping and redaction (inherits from Runner contract)
  - ✓ Deny-by-default: direct SSHRunner.run/2 without valid context is denied
  - ✓ Existing fake remote behavior unchanged
  - No connection pooling yet (future)
  - No live SSH integration tests in default mix test (opt-in via :ssh_live tag)
  - Connection pooling / reuse
  - Full integration tests
  - Security audit before release

Phase E: Release gate (future)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  - Security review
  - Documentation update (architecture, security, manual)
  - Release notes
  - Remote execution remains opt-in, default-off

Guarding:
  Each phase gates progress. Phase B does not start until Phase A is
  reviewed and follow-up beads are triaged. Phases C–E are deferred to
  a future milestone (v0.3.0 or later).
```

---

## 9. Explicit Non-Goals

The following are explicitly out of scope for this design spike and for Phase 5:

- ❌ **No SSH/VPS connection code** — No implementation of any remote transport.
- ❌ **No changes to existing Runner, Policy, or ApprovalGate** — Existing modules are read-only in this spike.
- ❌ **No remote execution in CI/CD** — Remote execution remains opt-in and user-approved only.
- ❌ **No Docker or Kubernetes runners** — Only `:ssh` protocol is sketched.
- ❌ **No WebSocket or HTTP remote runners** — Network execution beyond SSH is deferred.
- ❌ **No target auto-discovery** — Targets are user-configured, not auto-detected.
- ❌ **No sudo or privilege escalation** — Remote commands run as the SSH user only.
- ❌ **No file transfer (SCP/RSYNC)** — Only command execution; file transfer would be a separate capability.
- ❌ **No remote session persistence** — No `tmux`/`screen`-like session keepalive.
- ❌ **No MCP server/ecosystem integration** — MCP is explicitly out of scope per the v0.2.0 roadmap.
- ❌ **No changes to Muse profiles** — No new Muse specialist for remote execution.
- ❌ **No breaking changes** — The existing `Muse.submit/2` API is unchanged.
- ❌ **No implementation** — This document is a design reference for future implementation. No code changes result from this spike.

---

## Appendix A: Key Decisions Log

| Decision | Rationale | Date |
|----------|-----------|------|
| RemoteRunner as separate behaviour | Preserves backward compatibility with LocalRunner/RemoteDeniedRunner | 2026-05-07 |
| `:single_command` scope only for initial rollout | Reduces attack surface, prevents broad approvals | 2026-05-07 |
| 5-minute default approval expiry | Balances usability (short session) with security (narrow window) | 2026-05-07 |
| Target Registry via ETS + GenServer | Matches existing runtime patterns (session store, state module) | 2026-05-07 |
| No credential refs in user-visibility events | Prevents accidental credential leakage per Security §4 | 2026-05-07 |
| FakeRemoteRunner for testing | Matches fake provider pattern — no real network in `mix test` | 2026-05-07 |

## Appendix B: Cross-Reference to Security Document

| Security Doc § | Relevance to Remote Execution |
|---|---|
| §2 Workspace Path Policy | Remote execution operates on remote filesystems; workspace policy does not apply. Separate remote path safety is needed. |
| §3 Secret Path Denylist | Denylist must extend to remote filesystem paths. |
| §4 Redaction Rules | All remote output passes through redaction. Extend redaction for remote-specific patterns (cloud metadata endpoints, infra secrets). |
| §5 Tool Permissions Matrix | New column for `:remote` target. All existing tools are local-only unless they declare remote capability. |
| §6 Plan Approval Lifecycle | Plan approval does **not** approve remote execution (separate gate). |
| §11 Auth Security Rules | Remote credentials (SSH keys) follow the same rules as provider auth tokens: never in events, never in prompts, never in memory artifacts. |
| §12 Prompt Security | Remote target configuration is **never** included in prompt layer content. |
| §13 External WS Channel | Remote execution events follow the same visibility filtering as all other events. |
