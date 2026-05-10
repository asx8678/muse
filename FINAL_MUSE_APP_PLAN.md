# Final Muse App Plan

**Merged from:** `APP_AUDIT.md` and `APP_SIMPLIFICATION_PLAN.md`  
**Final direction:** stabilize and secure the runtime first, then simplify Muse into a real-provider-first local AI coding CLI/web runtime powered by `.code_puppy`.

---

## 1. Executive Summary

Muse should be treated as a **local single-user AI coding runtime** with a CLI, optional local web console, session runtime, agent/Muse profiles, provider adapters, tool execution, approvals, checkpoints, and persistence.

The two source plans agree that the codebase has a strong foundation, but they emphasize different risks:

- `APP_AUDIT.md` identifies the critical blockers that could make the app unsafe or unreliable: unauthenticated web UI, missing release JS asset, broken concurrent-submit handling, broken restore approval flow, unsafe session import path, weak workspace-root validation, and missing CI verification.
- `APP_SIMPLIFICATION_PLAN.md` identifies the product/runtime direction: make `muse` the normal entrypoint, load real models from `.code_puppy`, remove silent fake-provider fallback from normal runtime, add `/model`, `/model_settings`, and first-class `/agents`, and make streaming/tool output visible.

The merged plan resolves the main conflict this way:

> **Keep the fake provider for tests, smoke runs, demos, and explicit developer fixtures. Do not allow normal `muse` runtime to silently fall back to fake.**

The final implementation order is:

1. **Secure and stabilize critical runtime paths.**
2. **Make real provider/model resolution explicit and `.code_puppy`-backed.**
3. **Add model, settings, and agent menus.**
4. **Make streaming, tool usage, errors, and trace output visible and safe.**
5. **Finish CI, release, docs, and long-term cleanup.**

---

## 2. Final Product Decision

### Product identity

Muse is a **local developer runtime**, not a public multi-tenant SaaS app.

The default supported mode should be:

- one local operator;
- local filesystem workspace access;
- CLI-first usage through `muse`;
- optional Phoenix LiveView web console bound to localhost;
- file-based session persistence;
- explicit approval gates for risky actions;
- real LLM provider configured from `.code_puppy`;
- fake provider only for tests, smoke, and explicit demo mode.

### Security posture

The web UI and external socket must be considered control surfaces for a coding agent. They can expose session state, workspace switching, patch approval/application, import flows, logs, diagnostics, and runtime commands.

Therefore:

- Default web bind should remain `127.0.0.1`.
- Non-localhost exposure must require explicit opt-in and authentication.
- External WebSocket access must require signed, session-scoped, expiring tokens when enabled.
- The app should not claim production web readiness until authentication, authorization, path safety, static asset build, concurrent-submit safety, and CI verification are complete.

### Runtime posture

The normal runtime should not behave like a demo.

- `muse` should require a valid real provider/model selection from `.code_puppy` or an explicit compatible override.
- Missing/invalid real-provider configuration should fail clearly.
- Fake output should never appear as a silent fallback in normal runtime.
- Test and smoke environments should keep deterministic fake behavior.

---

## 3. Target End State

At the end of this plan, Muse should have the following behavior.

### Launch

- `muse` is the primary installed/local command.
- `mix muse` remains a development fallback.
- Release artifacts expose `bin/muse`, not a confusing alternate wrapper name.
- Startup loads `.code_puppy` before accepting prompts in normal runtime.
- Startup prints safe status only: selected model/provider, whether key is present, endpoint hostname/base URL if safe, streaming/tools capability, and web bind address. It must not print secrets.

### Provider/model system

- `.code_puppy` is the canonical model source.
- Runtime model catalog is loaded from:
  - `MUSE_CODE_PUPPY_DIR`, or
  - `$HOME/.code_puppy`, with compatibility overrides for `PUPPY_CFG`, `EXTRA_MODELS`, and `CHATGPT_MODELS`.
- The catalog validates model id, provider id, API model, base URL, API key source, wire API, transport, streaming capability, tool capability, structured-output capability, and default settings.
- Env vars remain supported as explicit overrides or compatibility inputs, not as silent fake fallback.
- Fake provider is only allowed under test/smoke/dev-fixture flags.

### CLI and web UX

- `/model` lists `.code_puppy` catalog models and allows validated session model selection.
- `/model_settings` shows and edits supported settings for the selected model.
- `/agents` becomes a first-class list/switch command.
- `/handoff` reuses the same validated agent-switching mechanism.
- Streaming output appears live in CLI/web.
- Tool start/result/error events are visible using safe summaries.
- Final trace is a concise execution timeline, not hidden/private chain-of-thought.

### Runtime correctness

- Concurrent submits are rejected or queued deterministically.
- Restore approval flow works end to end.
- Session import cannot read arbitrary server paths.
- Workspace profile roots are validated and operator-approved.
- Tool execution continues to enforce existing safety/approval gates.
- Cancellation, timeouts, and max loop caps are explicit and tested.

### Release and verification

- CI runs format, compile, tests, asset build, release build, and smoke checks.
- Production release includes generated JS/CSS assets.
- `.env.example` documents required and optional environment variables.
- Security/deployment docs clearly say the web console is local-only unless protected.

---

## 4. Priority Roadmap

| Priority | Theme | Goal | Status after completion |
|---|---|---|---|
| P0 | Critical safety and correctness | Fix issues that can make Muse unsafe, broken, or unreleasable. | Safe local MVP baseline. |
| P1 | Real-provider runtime | Make `.code_puppy` and real providers the normal runtime path. | `muse` behaves like a real AI runtime, not a demo. |
| P2 | Slash menus and session state | Add `/model`, `/model_settings`, and first-class `/agents`. | Users can control model/settings/agent without env edits. |
| P3 | Streaming, tool output, and traces | Show live tokens, tool calls/results, errors, and safe trace. | Runtime behavior becomes transparent and debuggable. |
| P4 | CI, release, docs, and cleanup | Make build/test/release repeatable and docs accurate. | Ship-ready local app. |
| P5 | Long-term product decisions | Decide local-only vs multi-user/server and clean architecture. | Future product path is clear. |

---

## 5. P0 — Critical Safety and Correctness

These tasks must be completed before investing heavily in provider UX or exposing the app beyond a trusted local environment.

### P0.1 Protect the web UI and external control surfaces

**Problem:** The Phoenix LiveView route exposes command-capable UI without app-user authentication or authorization. Any reachable user can submit prompts and slash commands.

**Final decision:**

- Keep default web binding to `127.0.0.1`.
- Add an explicit exposed-web mode requiring authentication.
- Treat LiveView, command dispatch, and external WebSocket as privileged control surfaces.

**Implementation tasks:**

- Add a web access configuration layer:
  - `MUSE_WEB_BIND`, default `127.0.0.1`.
  - `MUSE_WEB_EXPOSED=true` or equivalent required for non-loopback bind.
  - `MUSE_WEB_AUTH_TOKEN` or local password/token mechanism required when exposed.
- Add router/LiveView authentication:
  - plug or LiveView `on_mount` auth check;
  - CSRF/session handling remains enabled;
  - unauthenticated requests get a safe error or login/token prompt.
- Add command authorization boundaries:
  - sensitive commands require authenticated local operator context;
  - patch approval/application, workspace switching/creation, import, log clearing, and restore confirmation should not be callable anonymously.
- Harden external WebSocket when enabled:
  - signed tokens;
  - session-scoped topics;
  - expiration;
  - replay limits;
  - reject unauthenticated connections.
- Add a security doc section: “localhost-only by default; exposed mode requires auth and reverse proxy/TLS.”

**Acceptance criteria:**

- Web UI is not anonymously usable when bound beyond localhost.
- External socket rejects unauthenticated connections.
- Tests cover unauthorized LiveView access, command dispatch, and socket connection.
- Docs clearly warn against exposing the unauthenticated local console.

---

### P0.2 Fix production asset generation

**Problem:** The layout loads `/assets/app.js`, but the extracted static assets did not include the built JS file. Release scripts do not run asset deployment.

**Final decision:** Release builds must generate and verify web assets before packaging.

**Implementation tasks:**

- Ensure JS source in `assets/js/app.js` is bundled to `priv/static/assets/app.js` or the proper digested equivalent.
- Make `esbuild` available in the production build environment or run asset build before deps are pruned.
- Update `script/build-release-artifacts` to run:
  - `mix deps.get --only prod` as needed;
  - `MIX_ENV=prod mix assets.deploy` or equivalent;
  - `MIX_ENV=prod mix release` only after assets succeed.
- Add CI/release assertion that the generated asset exists.
- Add browser smoke check for LiveView connection, keyboard shortcuts/hooks if applicable, and no missing JS asset.

**Acceptance criteria:**

- Release artifact contains generated JS/CSS assets.
- Browser console has no missing `/assets/app.js` error.
- CI fails if assets are missing.

---

### P0.3 Fix concurrent submit handling

**Problem:** `SessionServer` can start a new async turn while another turn is running, overwriting running-turn state.

**Final decision:** Start with rejection, then optionally add a queue.

**Implementation tasks:**

- In `SessionServer.handle_call({:submit, ...})`, check `turn_running?/1` before starting a new turn.
- Return a clear error such as `{:error, :turn_running}` or a user-visible “A turn is already running” message.
- Make CLI/web render the error without killing the current turn.
- Add telemetry/event entry for rejected concurrent submit.
- Optional later enhancement: add a FIFO turn queue with explicit user-visible queue status.

**Acceptance criteria:**

- Double-submit cannot overwrite `active_turn_id`, `runner_pid`, `runner_task`, or waiting caller state.
- Tests cover immediate double-submit, submit while streaming, cancellation then submit, and failed turn then submit.

---

### P0.4 Fix restore approval flow

**Problem:** `/restore` instructs the user to run `/approve restore`, but that command is not registered or implemented.

**Final decision:** Implement a real restore approval lifecycle instead of leaving a broken instruction.

**Implementation tasks:**

- Add slash command registration for `/approve restore` and `/reject restore`, or replace the flow with a supported explicit command such as `/restore --confirm <checkpoint_id>`.
- Prefer content-bound approval, similar to plan/patch approval:
  - checkpoint id;
  - target workspace/session;
  - restore preview summary;
  - timestamp;
  - approval decision.
- Persist restore approval/rejection event.
- Ensure actual restore checks the approval token/decision before mutating state.
- Update README/help text.

**Acceptance criteria:**

- `/restore` no longer points to a nonexistent command.
- Restore can be previewed, approved, rejected, and executed through tested paths.
- Restore actions are recorded in session events.

---

### P0.5 Restrict `/import session`

**Problem:** `/import session` expands a user-supplied path and reads it directly, bypassing workspace-safe path handling.

**Final decision:** Session import must only read from safe, explicit locations.

**Implementation options:**

Choose one primary approach:

1. **Workspace-safe import:** resolve import path through `Workspace.safe_resolve!`.
2. **Approved import directory:** allow imports only from a configured directory such as `MUSE_IMPORT_DIR`.
3. **Web upload flow:** in web mode, accept an uploaded file and never read arbitrary server paths from user input.

**Implementation tasks:**

- Reject absolute paths, traversal, hidden/system paths, and paths outside the allowed import root.
- Cap file size.
- Validate JSON schema before import.
- Redact/sanitize import errors so they do not leak sensitive server paths.
- Log import decisions safely.

**Acceptance criteria:**

- `/import session /etc/passwd`, traversal paths, secret paths, and non-workspace paths are rejected.
- Valid exported session files can still be imported through the approved path.
- Tests cover CLI and web command dispatch.

---

### P0.6 Harden workspace profile creation

**Problem:** Workspace profile root creation only expands paths and does not strongly validate target roots.

**Final decision:** A workspace profile root must be a real, approved, safe directory.

**Implementation tasks:**

- Validate root exists and is a directory.
- Reject sensitive system roots such as `/`, `/etc`, `/var`, `/usr`, home root if too broad, and platform equivalents.
- Optionally require roots under an allowlisted parent such as `MUSE_WORKSPACE_PARENT`.
- Require explicit operator approval when creating/switching to a new root.
- Store approval metadata in profile/session events.

**Acceptance criteria:**

- Creating a profile for a sensitive root fails.
- Creating a profile for a valid project directory succeeds.
- Switching profiles remains audited and visible.

---

### P0.7 Expand secret filtering and runtime salts

**Problem:** Internal redaction is strong in many places, but Phoenix parameter filtering and placeholder salts need hardening.

**Implementation tasks:**

- Expand Phoenix `:filter_parameters` to include:
  - `api_key`;
  - `authorization`;
  - `bearer`;
  - provider-specific key names;
  - token-like parameter names.
- Move LiveView/cookie salts to runtime configuration for production where appropriate.
- Ensure startup fails clearly if production secrets are missing/weak.

**Acceptance criteria:**

- Logs do not show API keys or authorization headers.
- Production runtime does not rely on placeholder signing values.

---

### P0.8 Establish a verified baseline

**Problem:** The audit could not run Elixir/Mix commands in its environment.

**Implementation tasks:**

Run and preserve results for:

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Also run browser smoke checks for the LiveView UI and CLI smoke checks for `mix muse` / `muse` after provider configuration.

**Acceptance criteria:**

- All baseline commands pass in CI and local verification.
- Failing checks block release.

---

## 6. P1 — Real Provider and `.code_puppy` Runtime

This phase applies the simplification plan after the critical safety/correctness fixes are in place.

### P1.1 Add `.code_puppy` loader

**Goal:** Make `.code_puppy` the canonical provider/model source for normal runtime.

**New modules:**

- `Muse.CodePuppy.Loader`
- `Muse.ModelCatalog`
- `Muse.ModelCatalog.Entry`
- `Muse.ModelSelection`
- `Muse.ModelSettings`

**Input locations:**

- `MUSE_CODE_PUPPY_DIR`
- `$HOME/.code_puppy`
- compatibility overrides:
  - `PUPPY_CFG`
  - `EXTRA_MODELS`
  - `CHATGPT_MODELS`

**Files to parse:**

- `puppy.cfg` — INI-style `key = value`, with `model` as the default logical model.
- `extra_models.json` — model definitions, provider type, custom endpoint URL, API key source, and optional Muse metadata.
- `chatgpt_models.json` — validation/detection only; unsupported OAuth-style ChatGPT models should produce a clear error unless runtime support is explicitly implemented later.

**Model catalog entry fields:**

```elixir
%Muse.ModelCatalog.Entry{
  id: "wafer.ai-GLM-5.1",
  display_name: "wafer.ai GLM-5.1",
  api_model: "GLM-5.1",
  provider_id: :openai_compatible,
  base_url: "https://pass.wafer.ai/v1",
  wire_api: :chat_completions,
  transport: :sse,
  auth: :api_key,
  env_key: "WAFER_API_KEY",
  puppy_key: "wafer_api_key",
  supports_streaming: true,
  supports_tools: false,
  supports_structured_outputs: false,
  default_settings: %{stream: true, temperature: 0.2, max_tokens: 4096, tool_usage_mode: :disabled},
  source_file: "extra_models.json"
}
```

**Acceptance criteria:**

- Loader returns a validated catalog from `.code_puppy` fixtures.
- Missing `puppy.cfg`, missing default model, invalid JSON, unsupported auth, missing API key, invalid base URL, fake provider, and unsupported wire API all produce safe, actionable errors.
- Catalog supports exact and case-insensitive lookup for compatibility.

---

### P1.2 Preserve a backward-compatible `.code_puppy` schema

Keep the current script-compatible fields and add an optional `muse` block.

```ini
# ~/.code_puppy/puppy.cfg
model = wafer.ai-GLM-5.1
wafer_api_key = ...
openrouter_api_key = ...
anthropic_api_key = ...
```

```json
{
  "wafer.ai-GLM-5.1": {
    "type": "custom_openai",
    "provider": "wafer.ai",
    "custom_endpoint": {
      "url": "https://pass.wafer.ai/v1",
      "api_key": "$WAFER_API_KEY"
    },
    "muse": {
      "provider": "openai_compatible",
      "api_model": "GLM-5.1",
      "wire_api": "chat_completions",
      "transport": "sse",
      "auth": "api_key",
      "supports_streaming": true,
      "supports_tools": false,
      "supports_structured_outputs": false,
      "default_settings": {
        "stream": true,
        "temperature": 0.2,
        "max_tokens": 4096,
        "tool_usage_mode": "disabled"
      }
    }
  }
}
```

**Rule:** Do not require users to rewrite existing `.code_puppy` files if the current fields are enough to infer a provider config safely.

---

### P1.3 Change provider resolution

**Problem:** Current normal runtime allows fake defaults and fake fallback.

**Final decision:** Normal runtime must resolve a real provider config or fail clearly.

**Implementation tasks:**

- Update `Muse.RuntimeProvider.resolve_opts/0`:
  - load model catalog;
  - select current/default model;
  - build validated `ProviderConfig`;
  - return explicit provider/model opts for CLI and web.
- Update CLI REPL submission to pass provider/model opts into `SessionRouter.submit/4`, matching web behavior.
- Update `Conductor` so normal runtime does not fall back to `ProviderConfig.fake()` or `FakeProvider` after invalid real-provider config.
- Keep env vars as explicit overrides:
  - `MUSE_PROVIDER`
  - `MUSE_MODEL`
  - `MUSE_OPENAI_BASE_URL`
  - `MUSE_OPENAI_API_KEY`
  - `MUSE_OPENROUTER_MODEL`
  - `MUSE_OPENROUTER_API_KEY`
  - `MUSE_OLLAMA_MODEL`
  - `MUSE_OLLAMA_BASE_URL`
  - `MUSE_ANTHROPIC_MODEL`
  - `MUSE_ANTHROPIC_API_KEY`
  - `MUSE_LLM_TIMEOUT_MS`
  - `MUSE_LLM_MAX_RETRIES`
  - `MUSE_MAX_TOKENS`
  - `MUSE_STRUCTURED_OUTPUTS`
  - `MUSE_TOOLS`
- Ensure startup/runtime error messages are safe:
  - “No valid `.code_puppy` model found.”
  - “Selected model requires API key env var `X`, but it is not set.”
  - “Provider `chatgpt_oauth` is not supported by this runtime.”

**Acceptance criteria:**

- Normal `muse` does not produce fake-provider output unless an explicit fake/test/smoke flag is set.
- Invalid real-provider config returns a safe user-visible error.
- CLI and web use the same provider resolution behavior.

---

### P1.4 Isolate fake/demo components

**Final decision:** Fake components are valuable, but they must be isolated.

**Keep for:**

- unit tests;
- smoke tests;
- offline demos;
- deterministic scripted streaming tests;
- development fixtures explicitly enabled by env/config.

**Do not allow for:**

- normal `muse` runtime;
- production release defaults;
- silent fallback after provider config failure.

**Implementation tasks:**

- Add a clear runtime mode check:
  - `Mix.env() == :test`;
  - smoke config;
  - explicit `MUSE_ALLOW_FAKE_PROVIDER=true` for dev fixtures only.
- Remove fake from default provider resolution in normal runtime.
- Update docs to say fake is test/smoke/demo-only.
- Update tests that assumed fake default to opt into fake explicitly.

**Acceptance criteria:**

- No normal runtime path silently chooses fake.
- Tests still run offline using explicit fake fixtures.
- Smoke docs remain easy to use.

---

### P1.5 Make `muse` the single normal entrypoint

**Implementation tasks:**

- Keep `mix muse` as development mode.
- Preserve escript name `muse`.
- Build/install docs should show how to place `muse` on `PATH`.
- Release overlay should expose `bin/muse` as the end-user command.
- CLI help should mention:
  - `.code_puppy` directory;
  - `/model`;
  - `/model_settings`;
  - `/agents`;
  - fake provider only as test/smoke/demo mode.

**Acceptance criteria:**

- A user can run `muse` after escript/release install.
- The same provider/model resolution path is used by `muse`, `mix muse`, CLI REPL, and web submit.

---

## 7. P2 — Slash Menus and Session Runtime State

### P2.1 Add session model/settings state

**Goal:** Model and settings should be session state, not only env/global config.

**Implementation tasks:**

- Add `active_model_id` to session state.
- Add per-session `model_settings` map validated against the selected catalog entry.
- Preserve settings across agent switches.
- Persist selected model/settings in session snapshot if session persistence semantics require it.
- Include active model/settings in status output.

**Acceptance criteria:**

- A session can switch model without restarting Muse.
- Model selection affects the next provider request.
- Settings are validated and applied through request building.

---

### P2.2 Implement `/model`

**Current state:** Not registered. Closest command is `/provider models`, which uses static provider model lists.

**Target behavior:**

- `/model` lists catalog entries loaded from `.code_puppy`.
- It marks:
  - current selected model;
  - default model from `puppy.cfg`;
  - validity/auth status;
  - streaming/tool/structured-output capabilities.
- `/model <id>` selects a model for the current session.
- `/model --persist <id>` can optionally update persistent default if that is desired later, but should not be required for v1.

**Implementation tasks:**

- Register parser entries in `Muse.Commands`.
- Add dispatcher handlers.
- Replace static model listing in user-facing model menus with `Muse.ModelCatalog`.
- Validate model id without dynamic atom creation.
- Show safe errors for missing key, invalid URL, unsupported provider, or unknown model.

**Acceptance criteria:**

- `/model` works in CLI and web.
- `/model <id>` changes next-turn provider config.
- Fake/demo entries are hidden or rejected in normal runtime.

---

### P2.3 Implement `/model_settings`

**Current state:** Not registered. Request supports several settings, but there is no menu.

**Target behavior:**

- `/model_settings` shows current editable settings for selected model.
- Supported examples:
  - `/model_settings temperature 0.2`
  - `/model_settings max_tokens 4096`
  - `/model_settings streaming on`
  - `/model_settings tools auto|off|required`
- Unsupported settings are hidden or shown read-only with explanation.
- `top_p` should appear only after it is added to request/provider mappers.

**Implementation tasks:**

- Register command and parser.
- Add validation:
  - temperature numeric range;
  - max token bounds;
  - streaming boolean;
  - tools mode compatible with provider capabilities;
  - structured outputs compatible with provider capabilities.
- Map settings into `Request` / `ModelPreparer`.
- Add provider-specific capability rules from catalog entry.

**Acceptance criteria:**

- Invalid setting values are rejected clearly.
- Unsupported provider settings cannot be enabled accidentally.
- Settings affect generated provider requests.
- Settings changes do not switch agent.

---

### P2.4 Promote `/agents` to first-class command

**Current state:** `/agents` is a legacy alias to `/muses`; it lists profiles but does not switch agent state.

**Target behavior:**

- `/agents` lists available agents/Muses from `MuseRegistry`.
- It marks current active agent.
- It shows tools, permissions, response mode, and allowed handoff targets.
- `/agents <id>` or `/agents switch <id>` validates and switches active agent.
- Switch emits a visible `[agent:switch]` event.

**Implementation tasks:**

- Register `/agents` directly in `Muse.Commands`.
- Use `MuseRegistry` as canonical source.
- Replace raw `set_active_muse` behavior with validated switching.
- Reject unknown ids safely without dynamic atom creation.
- Make `/handoff` reuse the same switch function and preserve request/complete event specs.

**Acceptance criteria:**

- `/agents` lists current agent.
- `/agents coding` switches safely if valid.
- `/handoff` and `/agents` share validation and event emission.
- CLI/web visibly report agent switches.

---

## 8. P3 — Streaming, Turn Loop, Tool Output, and Trace

### P3.1 Add live event sink

**Problem:** Provider-level streaming exists, but Conductor/ToolLoop/SessionServer buffer events until the task finishes.

**Final decision:** Events should be emitted to the session and UI as they occur.

**Implementation tasks:**

- Pass an `event_sink` callback from `SessionServer` into `TurnRunner`, `Conductor`, and `ToolLoop`.
- Replace process-dictionary buffering with direct sink calls.
- Add `SessionServer.handle_info({:turn_event, turn_id, spec}, state)` or safe casts to append and broadcast running-turn events.
- Preserve event ordering by turn id and sequence number.
- Ignore late events from stale/cancelled turn ids.

**Acceptance criteria:**

- CLI/web receive streamed deltas before final response.
- Tool start/result events appear while the turn is running.
- Cancelled/stale turn events do not corrupt current session.

---

### P3.2 Define visible event taxonomy

Use stable event names for CLI and web rendering.

Required visible/safe events:

- `user_message`
- `turn_started`
- `model_selected`
- `agent_selected` / `muse_selected`
- `stream_started`
- `assistant_delta`
- `tool_call_started`
- `tool_call_completed`
- `tool_call_failed`
- `tool_call_blocked`
- `agent_switch`
- `provider_error`
- `assistant_message`
- `approval_required`
- `turn_completed`
- `turn_cancelled`

**Visibility rule:** show safe trace summaries, not hidden/private reasoning.

---

### P3.3 Update CLI and web renderers

**Target CLI output format:**

```text
[user]
Inspect the provider registry and simplify startup.

[model] provider=openai_compatible model=GLM-5.1 stream=true tools=false
[agent] id=planning name="Planning Muse"

[stream:start] agent=planning model=GLM-5.1

[tool:start] agent=planning model=GLM-5.1 tool=repo_search id=tc_abc123
args: {"query":"provider registry"}

[tool:result] tool=repo_search id=tc_abc123 success=true
summary: Found 4 matching files.
added_to_context=true

[agent:switch] from=planning to=coding reason="Implementation planning"

[stream:start] agent=coding model=GLM-5.1
...streamed assistant output...

[error] source=provider kind=http_error status=401 hint="Check configured API key for selected model."

[final]
Final answer here.

[trace]
1. Received user prompt.
2. Selected model GLM-5.1 from .code_puppy.
3. Selected Planning Muse.
4. Called repo_search and added result to context.
5. Switched to Coding Muse.
6. Streamed final response.
```

**Implementation tasks:**

- Update `StreamPrinter` to render model, agent, tool, error, final, and trace events.
- Keep duplicate suppression for final assistant text when deltas were already printed.
- Update web UI components to show a compact trace/timeline.
- Ensure event payloads are redacted and capped.

**Acceptance criteria:**

- CLI no longer ignores generic Muse events.
- Tool summaries and provider errors are visible.
- Raw secrets, API keys, headers, and uncapped file contents are never printed.

---

### P3.4 Fix timeout and cancellation semantics

**Problem:** CLI has a short default timeout and can kill a turn task, which conflicts with long real-provider streams.

**Implementation tasks:**

- Replace UI-level short timeout with explicit provider/request timeouts.
- Add user-facing cancellation command or key path.
- Preserve existing `TurnRunner.cancel` semantics.
- Ensure cancellation emits `turn_cancelled` and ignores late provider events.

**Acceptance criteria:**

- Long-running real provider streams are not killed by a 5-second UI timeout.
- Cancellation works predictably.
- Timeout and cancellation are tested separately.

---

### P3.5 Refine turn loop coordination

The turn loop should coordinate prompt, model, agent, streaming, tool execution, optional agent switch, and final trace.

**Design requirements:**

- Start each turn by recording prompt, selected model, selected settings, and selected agent.
- Build provider request from agent + model + settings + conversation messages.
- Stream provider events live.
- Execute tool calls through existing `Tool.Runner` safety gates.
- Append safe tool result messages back into provider context.
- Continue until final answer, approval boundary, cancellation, error, or max loop cap.
- Add max agent-switch count per turn to prevent handoff loops.
- Preserve existing tool-loop caps and cancellation checks.

**Acceptance criteria:**

- Tool loops still stop on caps.
- Agent switching cannot loop forever.
- Approval-required states pause rather than continuing unsafely.
- Final trace is built from emitted events only.

---

### P3.6 Tool usage output

**Final rule:** Tool events should be visible through safe summaries, not raw data dumps.

**Implementation tasks:**

- Use existing `Tool.Result.safe_summary` and redaction paths.
- Extend tool events with selected agent and model.
- Mark `added_to_context=true` when a tool result is appended to provider messages.
- Do not claim the model semantically used a result unless future citation/attribution support proves it.
- Render blocked/failed tool calls clearly.

**Acceptance criteria:**

- Users can see what tools were called, by which agent/model, and whether results were added to context.
- Secrets and raw large outputs remain hidden.

---

## 9. P4 — CI, Release, Documentation, and QA

### P4.1 Add full CI workflow

**Required checks:**

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Add smoke checks for:

- CLI startup;
- `.code_puppy` fixture loading;
- fake-only test mode;
- LiveView asset presence;
- web route auth behavior;
- external socket auth when enabled.

---

### P4.2 Add regression test suite

Add or update tests for:

- web UI authentication/authorization;
- external socket auth;
- concurrent submit rejection/queue behavior;
- `/restore` approval lifecycle;
- `/import session` safe-path restrictions;
- workspace root validation;
- production static asset presence;
- `.code_puppy` loader;
- unsupported ChatGPT OAuth models;
- provider config resolution;
- no fake fallback in normal runtime;
- CLI provider propagation;
- `/model` parser/dispatcher;
- `/model_settings` validation/application;
- `/agents` list/switch;
- `/handoff` reuse of validated switching;
- live streaming event order;
- tool start/result/error rendering;
- cancellation and timeout behavior.

---

### P4.3 Add `.env.example`

Include at least:

```bash
# Runtime
MUSE_SECRET_KEY_BASE=
MUSE_WORKSPACE=
MUSE_WORKSPACE_PARENT=
MUSE_CODE_PUPPY_DIR=$HOME/.code_puppy

# Web
MUSE_WEB_BIND=127.0.0.1
MUSE_WEB_PORT=4000
MUSE_WEB_EXPOSED=false
MUSE_WEB_AUTH_TOKEN=
MUSE_EXTERNAL_WS=false

# Provider overrides / compatibility
MUSE_PROVIDER=
MUSE_MODEL=
MUSE_OPENAI_BASE_URL=
MUSE_OPENAI_API_KEY=
MUSE_OPENROUTER_MODEL=
MUSE_OPENROUTER_API_KEY=
MUSE_OPENROUTER_BASE_URL=
MUSE_OLLAMA_MODEL=
MUSE_OLLAMA_BASE_URL=
MUSE_ANTHROPIC_MODEL=
MUSE_ANTHROPIC_API_KEY=
MUSE_ANTHROPIC_BASE_URL=

# Provider behavior
MUSE_LLM_TIMEOUT_MS=
MUSE_LLM_MAX_RETRIES=
MUSE_MAX_TOKENS=
MUSE_STRUCTURED_OUTPUTS=
MUSE_TOOLS=

# Test/smoke/demo only
MUSE_ALLOW_FAKE_PROVIDER=false
```

Do not include real secrets.

---

### P4.4 Update documentation

Update:

- README startup section;
- provider configuration docs;
- `.code_puppy` schema docs;
- slash command docs;
- security docs;
- testing docs;
- release/deployment docs;
- CLI help text;
- provider roadmap sections that currently describe fake as default.

Docs should clearly state:

- normal runtime requires real provider config;
- fake provider is test/smoke/demo-only;
- web UI is localhost-only unless protected;
- exposed mode requires auth/TLS/reverse proxy guidance;
- `.code_puppy` is canonical model source;
- `/model`, `/model_settings`, and `/agents` are supported controls.

---

### P4.5 Improve release assets and static serving

Implementation tasks:

- Run asset deployment before release.
- Consider digested assets.
- Add gzip/brotli/cache headers for static files after correctness is fixed.
- Add release smoke test verifying generated static files.

---

## 10. P5 — Medium- and Long-Term Cleanup

These are valuable but should not block P0–P4.

### P5.1 Split large UI modules

- Split `console_components.ex` into focused components.
- Remove or quarantine legacy components.
- Split `HomeLive` command handling/state update logic into helpers.

### P5.2 Decide local-only vs server product

If Muse remains local-only:

- keep file-based state;
- keep localhost-first UI;
- optimize CLI/web local experience;
- avoid unnecessary account/database complexity.

If Muse becomes multi-user/server:

- add accounts;
- add per-user authorization;
- isolate workspaces and sessions;
- encrypt secrets;
- introduce database-backed user/session models;
- add audit log isolation;
- add admin controls;
- revisit every command as a multi-tenant authorization surface.

### P5.3 Complete provider WebSocket runtime wiring

- Ensure `MUSE_WS_CLIENT=mint` actually enables the provider WebSocket transport.
- Add tests for WebSocket streaming.
- Keep SSE as a stable default where possible.

### P5.4 Build real skills system

- Replace placeholder `list_skills` with a real skills registry if the product needs skills.
- Keep skill execution behind the same tool safety gates.

### P5.5 Remote/SSH execution

- Keep remote execution denial-first unless there is a clear product need.
- Require explicit target registration, approval, and audit trails.

### P5.6 Retention and observability

- Add session/log retention commands or UI if persisted state grows.
- Add structured telemetry/export dashboards after deployment mode is defined.

---

## 11. Final Implementation Sequence

This is the recommended order to avoid building new UX on unsafe or broken foundations.

### Phase 0 — Baseline branch and verification

1. Create a dedicated branch.
2. Install Elixir/Mix/Node dependencies.
3. Run baseline commands.
4. Record failing tests/build issues.
5. Do not refactor provider architecture until P0 blockers are fixed or isolated.

### Phase 1 — P0 critical fixes

1. Protect web UI / exposed mode.
2. Fix asset build in release.
3. Add concurrent-submit guard.
4. Fix restore approval lifecycle.
5. Restrict session import.
6. Harden workspace root validation.
7. Expand filtering/secrets config.
8. Add regression tests for each item.

### Phase 2 — `.code_puppy` and real-provider runtime

1. Add `.code_puppy` loader and model catalog.
2. Convert selected catalog entry to `ProviderConfig`.
3. Make CLI REPL pass provider opts.
4. Remove silent fake fallback from normal runtime.
5. Gate fake behind test/smoke/explicit dev mode.
6. Update provider tests and no-fallback tests.

### Phase 3 — Menus and session state

1. Add active model/settings session state.
2. Implement `/model`.
3. Implement `/model_settings`.
4. Promote `/agents` to first-class list/switch command.
5. Make `/handoff` reuse the same validated switch path.

### Phase 4 — Streaming and trace visibility

1. Add live event sink.
2. Emit model/agent/stream/tool/error/final events while the turn is running.
3. Update CLI renderer.
4. Update web trace/timeline.
5. Fix timeout/cancellation semantics.
6. Add streaming event-order tests.

### Phase 5 — CI, docs, release polish

1. Add full CI workflow.
2. Add `.env.example`.
3. Update README/provider/security/testing docs.
4. Expose release command as `muse`.
5. Add browser and CLI smoke tests.

### Phase 6 — Long-term cleanup

1. Split large UI modules.
2. Decide local-only vs multi-user/server.
3. Complete provider WebSocket runtime if needed.
4. Add skills, retention, and observability only after the core runtime is stable.

---

## 12. Definition of Done

The merged plan is complete when all of the following are true:

- `muse` starts as the primary command.
- Normal runtime requires a valid real provider from `.code_puppy` or explicit compatible override.
- Fake provider is impossible to reach silently in normal runtime.
- CLI and web submit paths use the same provider/model resolution.
- Web UI is localhost-only by default and authenticated when exposed.
- External WebSocket is authenticated when enabled.
- Production release includes generated JS assets.
- Concurrent submit cannot corrupt session state.
- `/restore` approval works.
- `/import session` cannot read arbitrary server files.
- Workspace profile roots are validated.
- `/model`, `/model_settings`, and `/agents` work in CLI and web.
- Streaming deltas, tool events, errors, and final output are visible live.
- Trace output is safe and does not reveal private chain-of-thought.
- CI runs format, compile, tests, assets, release, and smoke checks.
- Docs match actual runtime behavior.

---

## 13. Final Verdict

The best final plan is not to choose between the audit and the simplification plan. The correct merged plan is:

> **Secure and stabilize the app first, then make it a real-provider-first `muse` runtime using `.code_puppy`, with clear model/agent controls and live safe execution traces.**

This keeps the strongest parts of both source plans:

- the audit’s safety-first blockers and deployment checks;
- the simplification plan’s product direction, `.code_puppy` model catalog, real provider enforcement, slash menus, streaming, and trace UX.

