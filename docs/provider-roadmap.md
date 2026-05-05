# Muse Universal Runtime — Provider & Auth Roadmap

> **Companion docs:** [Architecture](architecture.md) · [Prompts](prompts.md) · [Testing](testing.md) · [Security](security.md) · [Executive Summary](../PLAN.md)
>
> **Canonical source:** Provider sequencing, fake-provider behavior, provider configuration, OpenAI-compatible wire mapping, transports, and auth roadmap.

---

## Table of Contents

1. [Implementation Principle](#1-implementation-principle)
2. [Fake Provider](#2-fake-provider)
   - 2.1 [Scenarios](#21-scenarios)
   - 2.2 [Scriptable Test API](#22-scriptable-test-api)
3. [Provider Environment Variables](#3-provider-environment-variables)
   - 3.1 [Initial (Fake)](#31-initial-fake)
   - 3.2 [OpenAI-Compatible (Later)](#32-openai-compatible-later)
   - 3.3 [App Config Example](#33-app-config-example)
4. [Configuration Validation at Startup](#4-configuration-validation-at-startup)
5. [OpenAI-Compatible Non-Streaming Provider](#5-openai-compatible-non-streaming-provider)
6. [OpenAI Responses Request Mapper](#6-openai-responses-request-mapper)
7. [Chat Completions Request Mapper](#7-chat-completions-request-mapper)
8. [HTTP SSE Transport](#8-http-sse-transport)
9. [OpenAI Responses WebSocket Transport](#9-openai-responses-websocket-transport)
10. [Auth Layer](#10-auth-layer)
    - 10.1 [Auth Modes](#101-auth-modes)
    - 10.2 [Implementation Order](#102-implementation-order)
    - 10.3 [Commands](#103-commands)
    - 10.4 [Recommended Behavior](#104-recommended-behavior)
    - 10.5 [Credential Shape](#105-credential-shape)
    - 10.6 [Security Rules](#106-security-rules)
11. [External API References to Verify](#11-external-api-references-to-verify)

---

## 1. Implementation Principle

> **Do not touch real model APIs until the fake model can drive a full read-only planning turn.**

The fake provider is the foundation. Every provider feature — streaming, tool calls, error recovery, cancellation — must be demonstrated with the fake provider first. Only after the fake provider can drive a complete read-only planning turn end-to-end do we wire up real network calls.

**Fake provider remains the default in tests and should never require an API key.**

This principle ensures:

- **Deterministic offline tests by default.** No test suite should depend on network availability or API keys.
- **Risk reduction.** Wire-format bugs, auth errors, and rate-limit surprises are discovered with real providers later — not during core runtime development.
- **Fast iteration.** Developers can run the full turn loop locally without credentials.
- **CI safety.** Automated builds never hit external APIs.

PR09 approval boundary reminder:

- `/approve plan` and `/reject plan` are lifecycle-only and auditable.
- They do not execute patch/file/shell/network actions.
- Provider work in this document must preserve that boundary until PR17/PR18/PR19 gates land.

---

## 2. Fake Provider

The fake provider (`Muse.LLM.FakeProvider`) implements the `Muse.LLM.Provider` behavior and produces scripted, deterministic responses for testing and development.

### 2.1 Scenarios

The fake provider must cover every event shape the runtime will encounter from real providers:

| Scenario | Description |
|---|---|
| `:echo` | Streams `"Placeholder response: received ..."` for basic compatibility. No tool calls, no special behavior. |
| `:planning_plan` | Streams a plan-like text response with no tool calls. Simulates Planning Muse producing a structured plan from context it already has. |
| `:read_file_tool_call` | Emits a `read_file` tool call with JSON args (`{"path": "lib/muse.ex"}`). Tests the runtime's ability to dispatch a single tool call and return the result. |
| `:list_files_then_plan` | Emits a `list_files` tool call, waits for the tool result from the runtime, then emits a plan. Tests the multi-step tool loop: model → tool call → result → continuation. |
| `:malformed_tool_call` | Emits a tool call with invalid JSON arguments. Tests the runtime's recovery path when `Jason.decode!/1` fails on tool arguments. |
| `:mid_stream_error` | Emits several assistant deltas, then fails mid-stream. Tests error handling during active streaming — the runtime must emit a `:provider_error` event and not hang. |
| `:cancellation` | Streams slowly (with deliberate delays), and checks for a cancellation signal on each step. Tests the TurnRunner's ability to cancel an in-flight provider call. |
| Coding Muse proposes a patch (roadmap) | Emits a `patch_propose` tool call with structured patch arguments. Planned for post-PR09 write workflow (PR17+). |
| Coding Muse requests `patch_apply` (roadmap) | Emits a `patch_apply` tool call. Planned for post-PR09 approval-gated write flow (PR18+). |
| Testing Muse requests `test_runner` (roadmap) | Emits a `test_runner` tool call. Planned for post-PR09 verification workflow (PR19). |
| Provider streams partial response | Emits a sequence of `:assistant_delta` events without completing. Tests the runtime's handling of incomplete responses. |
| Provider fails and runtime retries or fails safely | Emits a `:provider_error` event. Tests retry logic and safe failure propagation — the runtime must not silently swallow errors. |

### 2.2 Scriptable Test API

Each test gets its own script process — **NOT a global `Application.put_env` override**. This avoids the classic Elixir test concurrency trap where one test's `Application.put_env` leaks into another.

**Test setup:**

```elixir
defmodule Muse.Conductor.PlanningTurnTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, script_server} = Muse.LLM.Providers.Fake.TestScriptServer.start_link()
    Muse.LLM.Providers.Fake.TestScriptServer.set_script(script_server, [
      {:assistant_delta, "I'll inspect the workspace structure first."},
      {:tool_call, "list_files", %{"path" => "."}},
      {:assistant_delta, "Based on the file listing, here is my plan:"},
      {:assistant_delta, "1. Locate CLI command routing."},
      {:assistant_delta, "2. Add /version handling."},
      {:assistant_delta, "3. Source version from mix.exs."},
      {:assistant_delta, "4. Add tests."},
      {:assistant_completed, nil}
    ])
    %{script_server: script_server}
  end

  test "planning turn with tool call and plan", %{script_server: script_server} do
    {:ok, session} = Muse.Session.create("test-session")
    Muse.Conductor.run_turn(session, "add a /version command",
      fake_script_server: script_server
    )

    assert session.status == :awaiting_plan_approval
    assert length(session.events) > 0
  end
end
```

**Script tuple reference:**

| Tuple | Emits | Notes |
|---|---|---|
| `{:assistant_delta, text}` | `:assistant_delta` event | Incremental text chunk |
| `{:tool_call, name, args}` | `:tool_call_started` → `:tool_call_completed` | Waits for tool result before continuing |
| `{:assistant_completed, nil}` | `:assistant_completed` | Signals end of response |
| `{:error, reason}` | `:provider_error` | Simulates provider failure |
| `{:delay, ms}` | _(internal)_ | Pauses emission for `ms` milliseconds (for cancellation tests) |

**Why per-test `TestScriptServer` instead of `Application.put_env`:**

- `Application.put_env` is **global mutable state**. In `async: true` tests, Test A's config overwrites Test B's config, causing flaky failures.
- `TestScriptServer` is a per-test GenServer with a unique PID. Each test passes its own `script_server` reference, ensuring zero cross-contamination.
- The fake provider looks up the script server from the turn's options, not from global application env. This is the same pattern used by `Mox` for per-test mocks.

---

## 3. Provider Environment Variables

### 3.1 Initial (Fake)

The default provider is the fake provider. It requires **no API key, no auth flow, and no network**:

```text
# Optional; leaving all provider env vars unset has the same effect.
MUSE_PROVIDER=fake
MUSE_MODEL=fake-planning-model
```

This is the zero-config Muse-first experience. Running `muse` out of the box uses deterministic offline responses suitable for local development and CI.

### 3.2 OpenAI-Compatible Config

PR12 reads the OpenAI-compatible provider **configuration** and uses it to perform real HTTP calls against a configured `base_url` for non-streaming Chat Completions. Auth/API-key loading is in the auth layer (PR13, now implemented); the provider now resolves credentials via `Muse.Auth.Resolver` and injects the `Authorization` header.

Example config values for an OpenAI-compatible provider:

```text
MUSE_PROVIDER=openai_compatible
MUSE_OPENAI_BASE_URL=https://api.openai.com/v1
MUSE_MODEL=gpt-4.1
MUSE_LLM_TIMEOUT_MS=60000
MUSE_LLM_MAX_RETRIES=2
```

`ProviderConfig.from_env/0` reads the variables below from `System.get_env/1` and returns a config struct. `Muse.Config.llm_provider_config/1` is pure/testable and accepts an explicit env map plus `config :muse, :llm` values before validating the resolved config.

| Variable | Required | Default | Description |
|---|---|---|---|
| `MUSE_PROVIDER` | No | `fake` | Provider identifier: `fake`, `openai_compatible` |
| `MUSE_MODEL` | Non-fake only | `fake-planning-model` for fake; none for non-fake | Model identifier (e.g., `gpt-4.1`, `gpt-4.1-mini`) |
| `MUSE_OPENAI_BASE_URL` | No for `openai_compatible` defaults | `https://api.openai.com/v1` for `openai_compatible` | Base URL for HTTP calls; PR12 posts non-streaming Chat Completions to `{base_url}/chat/completions` |
| `MUSE_LLM_TIMEOUT_MS` | No | `120000` | Per-request timeout in milliseconds |
| `MUSE_LLM_MAX_RETRIES` | No | `0` for fake; `2` for openai-compatible | Maximum retry attempts (carried as Req option) |
| `MUSE_WIRE_API` | No (`Muse.Config` only) | `responses` for openai-compatible | `responses` or `chat_completions`; PR12 only supports `nil`/`:chat_completions`; `:responses` returns an unsupported error |
| `MUSE_TRANSPORT` | No (`Muse.Config` only) | `sse` for openai-compatible; `none` for fake | `none`, `sse`, or `websocket`; unknown values resolve to `nil` |
| `MUSE_OPENAI_API_KEY` | Not read in PR12 | — | Auth/API-key loading is in the auth layer (PR13, now implemented); caller-provided headers may be sent via `request.options[:headers]` but are redacted in errors/events |

### 3.3 App Config Example

For application-level configuration (e.g., `config/runtime.exs`), keep secrets out of the provider config:

```elixir
config :muse, :llm,
  provider: :openai_compatible,
  base_url: System.get_env("MUSE_OPENAI_BASE_URL") || "https://api.openai.com/v1",
  wire_api: :responses,
  transport: :sse,
  model: System.get_env("MUSE_MODEL"),
  timeout_ms: 120_000,
  max_retries: 2
```

Do **not** put `api_key` in this config for PR11. The config may record which env var should be checked later (`env_key`), but it must not read, validate, log, or store the secret value.

**Current config source priority (highest first):**

1. Explicit env map passed to `Muse.Config.llm_provider_config/1`
2. Application env (`config :muse, :llm, [...]`)
3. Built-in safe defaults (`ProviderConfig.fake/0`)

Workspace/user TOML config remains future work. Do not add TOML parsing until it is actually needed. YAGNI is not a suggestion, it's pest control.

---

## 4. Configuration Validation

PR11 validation is local and side-effect-free. `Muse.LLM.ProviderConfig.validate/1` returns `:ok` or `{:error, reason}`; `Muse.Config.llm_provider_config/1` returns `{:ok, config}` or `{:error, reason}` after resolving values from an explicit env map/app config.

Important boundaries:

- The fake provider always validates and remains the safe default.
- Validation never starts clients, opens sockets, or calls real provider APIs.
- Validation does **not** read or require `MUSE_OPENAI_API_KEY`; auth loading is in PR13 (now implemented).
- Startup wiring may call this validation before the provider makes its first HTTP call.
- `ProviderConfig.redacted_inspect/1` and the `Inspect` implementation must be used for safe logging/debugging.

**Validation checks summary:**

| Check | Condition | Behavior |
|---|---|---|
| Known provider | `id` maps to `:fake` or `:openai_compatible` | Error if unknown; never creates atoms from user input |
| Known wire API | `wire_api` is `:responses`, `:chat_completions`, or `nil` | Error if another atom reaches validation |
| Known transport | `transport` is `:none`, `:sse`, `:websocket`, or `nil` | Error if another atom reaches validation |
| Model present | Required for non-fake providers | Error if missing/empty |
| Valid URL | Non-fake network configs need an HTTP(S) `base_url` unless `transport: :none` | Error if invalid |
| Positive timeout | `timeout_ms` is integer > 0 | Error if non-positive |
| Non-negative retries | `max_retries` is integer >= 0 | Error if negative |
| Provider is `fake` | All network/auth checks bypassed | Always valid and offline |

---

## 5. OpenAI-Compatible Non-Streaming Provider

PR12 adds `Muse.LLM.OpenAICompatibleProvider`, a real provider adapter that performs HTTP requests against any OpenAI-compatible Chat Completions endpoint. It uses [`Req`](https://hexdocs.pm/req/) (`{:req, "~> 0.5"}`) for the default `POST` call, with an injectable `post_fn` for offline tests.

**Non-streaming only.** PR12 supports Chat Completions non-streaming exclusively. No SSE parser, no WebSocket client, no synthetic `Authorization` header. Responses provider execution via `ResponsesMapper` is future work.

### `Muse.LLM.OpenAICompatibleProvider`

File: `lib/muse/llm/openai_compatible_provider.ex`

Implements `Muse.LLM.Provider` behaviour.

#### `complete/1` and `complete/2`

```elixir
@spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
def complete(request), do: complete(request, [])

@spec complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
def complete(%Request{} = request, opts) when is_list(opts)
```

`complete/1` performs a non-streaming Chat Completions POST by delegating to `complete/2` with an empty options list. `complete/2` accepts `opts[:post_fn]` to inject a custom HTTP function. Default: `&Req.post/2`.

The request flow:

1. `RequestBuilder.build_chat_completions(request)` produces the HTTP spec (URL, payload, headers).
2. `post_fn.(url, [json: payload, headers: headers] ++ req_options)` performs the POST.
3. A 2xx response body is JSON-decoded and passed to `ChatCompletionsDecoder.decode/1`.
4. Non-2xx responses produce `{:error, {:provider_http_error, %{status:, body_summary:}}}`.
5. Network/exception failures produce `{:error, {:provider_network_error, %{reason:}}}`.

All error payloads are redacted through `EventPayloadRedactor` and truncated to 500 characters — provider HTTP bodies, raw response terms, and error messages never leak secrets.

#### `stream/2` — Event Replay

```elixir
@spec stream(Request.t(), (Event.t() -> :ok)) :: {:ok, Response.t()} | {:error, term()}
```

`stream/2` performs the same single non-streaming HTTP call as `complete/2`, then replays the result as canonical Muse LLM events via the `emit_fn`:

| Event | When |
|---|---|
| `Event.response_started()` | Before any content |
| `Event.assistant_delta(text)` | Once for the full response text |
| `Event.assistant_completed(text)` | After the text delta |
| `Event.tool_call_started(tool_call)` | Per tool call |
| `Event.tool_call_completed(tool_call)` | Per tool call (immediately after started in non-streaming) |
| `Event.response_completed(usage)` | After all tool calls |
| `Event.provider_error(redacted_reason)` | On failure instead of the above |

Offline tests may inject `post_fn` via `request.options[:post_fn]` or `request.options[:http_post]` (both checked in `stream/2`).

### `Muse.LLM.OpenAI.RequestBuilder.build_chat_completions/1`

File: `lib/muse/llm/openai/request_builder.ex`

```elixir
@spec build_chat_completions(Request.t()) :: {:ok, spec()} | {:error, error_reason()}
```

Pure data-preparation function — no HTTP calls, no side effects. Returns `{:ok, spec}` where `spec` is a map:

| Key | Description |
|---|---|
| `:url` | Full request URL: `base_url` (trimmed trailing slash) + `/chat/completions` |
| `:endpoint_path` | `"/chat/completions"` |
| `:payload` | JSON-ready map with string keys, `"stream" => false` forced |
| `:headers` | Sorted list of `{name, value}` tuples from caller-provided options only |
| `:req_options` | Keyword list with `:timeout_ms` / `:max_retries` when valid |

**Key behaviour:**

- Resolves `base_url` from `request.options[:base_url]` or `request.options["base_url"]`.
- Validates `base_url` is HTTP(S), has a host, and contains no embedded credentials (userinfo). Returns `{:error, {:invalid_base_url, reason}}` on violation.
- Only supports `wire_api` values `nil` and `:chat_completions`. Returns `{:error, {:unsupported_wire_api, :responses}}` for all other values.
- Forces `"stream" => false` regardless of `request.stream`.
- Carries **only explicit caller headers** from `request.options[:headers]` or `request.options["headers"]`. Does **not** synthesize auth headers, read env vars, or load `MUSE_OPENAI_API_KEY`.
- Normalizes header keys to strings; atom keys are converted.

**Error reasons:**

| Error | When |
|---|---|
| `{:unsupported_wire_api, value}` | `wire_api` is not `nil` or `:chat_completions` |
| `{:missing_base_url, message}` | `base_url` not provided, empty, or options is not a map |
| `{:invalid_base_url, message}` | URL uses non-HTTP scheme, lacks host, or contains embedded credentials |

### `Muse.LLM.OpenAI.ChatCompletionsDecoder.decode/1`

File: `lib/muse/llm/openai/chat_completions_decoder.ex`

```elixir
@spec decode(map()) :: {:ok, Response.t()} | {:error, term()}
def decode(body) when is_map(body)
```

Pure decoder that converts a parsed JSON Chat Completions response body into `Muse.LLM.Response`. Extracts:

| Response Field | Source |
|---|---|
| `id` | `body["id"]` (optional; string or nil) |
| `content` / `text` | `choices[0].message.content` |
| `tool_calls` | `choices[0].message.tool_calls` decoded to `[%ToolCall{}]` |
| `finish_reason` | `choices[0].finish_reason` (optional) |
| `usage` | `body["usage"]` normalized to atom keys: `:prompt_tokens`, `:completion_tokens`, `:total_tokens` |
| `raw` | The original body map |

Error messages are redacted and truncated to 300 characters. The decoder handles both string-key and atom-key provider responses via a known-key map.

**Tool call decoding** parses `arguments` from JSON string to map, handling `nil`, empty string, already-decoded map, and invalid JSON — never crashes the turn loop.

### `Muse.LLM.ProviderRouter` & Conductor Integration

File: `lib/muse/llm/provider_router.ex`

`ProviderRouter` is a pure resolver mapping provider identifiers to provider modules. Known providers:

| Identifier | Module |
|---|---|
| `:fake` / `"fake"` | `Muse.LLM.FakeProvider` |
| `:openai_compatible` / `"openai_compatible"` | `Muse.LLM.OpenAICompatibleProvider` |

`resolve/1` accepts an atom, string, or `%ProviderConfig{}` and returns `{:ok, module}` or `{:error, {:unknown_provider, value}}`. Never creates atoms from user input, never starts clients or reads environment variables.

The Conductor (`Muse.Conductor`) uses `ProviderRouter.resolve/1` in `resolve_provider_module/2`. If the resolved module is not loaded (or resolution fails), it falls back to `FakeProvider`. This conservative approach ensures offline operation by default — real network calls only happen when an explicit `openai_compatible` config is present and the provider module is genuinely loaded.

```elixir
# Conductor excerpt — conservative fallback to FakeProvider
defp resolve_provider_module(opts, request) do
  if Keyword.has_key?(opts, :provider_module) do
    Keyword.fetch!(opts, :provider_module)
  else
    case ProviderRouter.resolve(request.provider) do
      {:ok, module} ->
        if Code.ensure_loaded?(module), do: module, else: FakeProvider
      {:error, _reason} ->
        FakeProvider
    end
  end
end
```

### `Req` Dependency & Default `post_fn`

The `Req` library is a compile-time dependency in `mix.exs`. `OpenAICompatibleProvider` defaults to `&Req.post/2` for HTTP calls. Tests inject a custom `post_fn` (a two-arity function matching `Req.post/2`'s call shape: `(url, options) -> {:ok, %{status:, body:, headers:}}` or `{:error, reason}`).

```elixir
# Default: Req.post/2
post_fn.(url, [json: payload, headers: headers] ++ req_options)

# Test injection: custom function
{:ok, response} = OpenAICompatibleProvider.complete(request, post_fn: fn _url, _opts ->
  {:ok, %{status: 200, body: fixture_body, headers: []}}
end)
```

### Custom `base_url` Rules

- Must be HTTP or HTTPS (`http://` or `https://`).
- Must have a host (not empty, not IP-only without scheme).
- Must **not** contain embedded credentials (`user:pass@host`). `RequestBuilder` returns `{:error, {:invalid_base_url, ...}}` in that case.
- Trailing slashes are stripped before appending `/chat/completions`.

The full request URL becomes `#{base_url}/chat/completions` (exactly one `/chat/completions` segment).

---

## 6. OpenAI Responses Request Mapper

The OpenAI Responses API uses a different request shape than Chat Completions. `Muse.LLM.OpenAI.ResponsesMapper` is a pure/offline mapper:

- `endpoint_path/0` returns `"/responses"`.
- `to_payload/1` converts `%Muse.LLM.Request{}` into a JSON-compatible map with string keys, ready for `Jason.encode!/1`.
- It maps system messages to `"instructions"`, non-system text history to typed `"input"` messages, and tool-result messages to `"function_call_output"` items.
- It maps tools into Responses function-tool shape and strips debug-only atom keys.
- It maps `previous_response_id`, `stream`, `store`, `temperature`, `max_tokens` as `"max_output_tokens"`, and `response_format` as `"text" => %{"format" => ...}`.
- It does **not** load auth, create headers, perform retries, parse SSE, or call a real provider.

**Offline payload shape (streaming flag shown):**

```json
{
  "model": "gpt-4.1",
  "store": false,
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "add a /version command"
        }
      ]
    }
  ],
  "tools": [],
  "stream": true
}
```

**Endpoint path metadata:**

```text
/responses
```

**PR12 limitation:** `Muse.LLM.OpenAI.RequestBuilder` only supports `wire_api` values `nil` and `:chat_completions`. Passing `:responses` returns `{:error, {:unsupported_wire_api, :responses}}`. Responses provider execution — and any transport POSTing to `{base_url}/responses` — remains future work, though the mapper itself exists and is tested.

**Key differences from Chat Completions:**

| Aspect | Responses API | Chat Completions |
|---|---|---|
| Message container | `input` array with typed content | `messages` array with role/content |
| Content format | `[{type: "input_text", text: "..."}]` | Plain string |
| Conversation state | `previous_response_id` | Full message history |
| Persistence | `store: false` | N/A |
| Streaming flag | `stream: true` | `stream: true` |

The Responses API can maintain conversation state server-side using `previous_response_id`, which reduces the size of subsequent requests once real provider support exists. The mapper preserves/maps that field; it does not create server-side state.

---

## 7. Chat Completions Request Mapper

The Chat Completions API is the OpenAI-compatible fallback used by routers and local providers (OpenRouter, Ollama, etc.). In PR11, `Muse.LLM.OpenAI.ChatCompletionsMapper` is a pure/offline mapper:

- `endpoint_path/0` returns `"/chat/completions"`.
- `to_payload/1` converts `%Muse.LLM.Request{}` into a JSON-compatible map with string keys, ready for `Jason.encode!/1`.
- It maps messages, tools, `tool_choice`, `stream`, `temperature`, `max_tokens`, and `response_format`.
- It strips debug-only atom keys such as `:name` from tool specs.
- It does **not** load auth, create headers, perform retries, or call a real provider.

**Offline payload shape (streaming flag shown):**

```json
{
  "model": "gpt-4.1",
  "messages": [
    {
      "role": "system",
      "content": "You are Planning Muse. Inspect the workspace with read-only tools..."
    },
    {
      "role": "user",
      "content": "add a /version command"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read a text file inside the workspace.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {"type": "string"},
            "start_line": {"type": "integer"},
            "max_lines": {"type": "integer"}
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    }
  ],
  "stream": true
}
```

**Endpoint path metadata:**

```text
/chat/completions
```

PR12's `RequestBuilder.build_chat_completions/1` uses `ChatCompletionsMapper.to_payload/1` and `endpoint_path/0`, then assembles the full HTTP spec (URL, headers, Req options) and passes it to the provider for dispatch. See §5 for the complete request flow.

The Chat Completions mapper includes the full message history (system prompt + all prior messages) because the API is stateless — there is no `previous_response_id` equivalent. Auth header injection is in PR13 (now implemented), not in the PR12 mapper or PR12 provider core.

---

## 8. HTTP SSE Transport

**Implemented in PR14.** The SSE transport is now live with the following modules:

- `Muse.LLM.Transport.SSE.Parser` — pure incremental SSE parser (`new/0`, `parse_chunk/2`, `flush/1`)
- `Muse.LLM.OpenAI.ChatCompletionsStreamDecoder` — pure streaming accumulator (`new/0`, `feed/2`, `finalize/1`)
- `Muse.LLM.OpenAI.RequestBuilder.build_chat_completions_stream/1` — streaming spec builder with `"stream" => true`
- `Muse.LLM.Transport.SSE.ReqStream` — Req `into: fun` streaming adapter (`request/2`)
- `OpenAICompatibleProvider.stream/2` — dispatches to SSE path when `request.transport == :sse`

### Architecture

```text
OpenAICompatibleProvider.stream/2
  ├── transport == :sse? → SSE streaming path
  │     ├── RequestBuilder.build_chat_completions_stream/1
  │     ├── attach_auth (PR13, explicit Authorization wins)
  │     ├── resolve_sse_post_fn (injectable for tests)
  │     ├── on_chunk callback → SSEParser.parse_chunk → ChatCompletionsStreamDecoder.feed
  │     └── finalize → emit assistant_completed, tool_call_completed, response_completed
  └── otherwise → non-streaming replay path (PR12/PR13 preserved)
```

### SSE Function Injection (Tests)

```elixir
# Inject sse_post_fn in request.options to avoid real network:
sse_post_fn = fn url, req_options, on_chunk ->
  on_chunk.("data: {...}\n\n")
  on_chunk.("data: [DONE]\n\n")
  {:ok, %{status: 200}}
end
```

### Error Handling

- Malformed JSON, mid-stream failure, transport error, non-2xx: emit exactly one `:provider_error`, return error
- No `:assistant_completed` / `:response_completed` emitted after failure
- All errors are redacted — no raw tokens, request bodies, or full response payloads leak
- Raw token only appears in outbound Authorization header

### Implemented Normalizing Rules

Provider-specific Chat Completions SSE frames are normalized by
`Muse.LLM.OpenAI.ChatCompletionsStreamDecoder` after raw frames are parsed by
`Muse.LLM.Transport.SSE.Parser`. There is no standalone
`Muse.LLM.Transport.SSE.Normalizer` module in the current implementation.

| Provider Data | Normalized Muse Event | Notes |
|---|---|---|
| Text delta (`choices[].delta.content`) | `:assistant_delta` | Incremental text append |
| Tool-call start/name delta | `:tool_call_started` / `:tool_call_delta` | Accumulates OpenAI tool-call fragments by index |
| Tool-call argument delta | `:tool_call_delta` | Partial argument accumulation |
| Tool call finalized | `:tool_call_completed` | Full `Muse.LLM.ToolCall` emitted during finalization |
| Usage/stats data | _(stored, not emitted immediately)_ | `Response.usage` populated and emitted with `:response_completed` |
| Response completed / `[DONE]` | `:response_completed` | Final event with usage after decoder finalization |
| Unknown/unrecognized chunks or fields | _(ignored safely)_ | No `:debug` event is emitted; unknown data must never crash the runtime |

### Backpressure

Use `Req` with streaming support. Process events in the TurnRunner process. The TurnRunner controls the pace:

- If the TurnRunner is waiting for a tool execution result, the HTTP stream naturally pauses (TCP backpressure).
- If the TurnRunner is blocked on an approval gate, SSE frames buffer in the Req streaming handler.
- The TurnRunner processes events one at a time — no unbounded async queue between the SSE parser and the turn loop.

```elixir
Req.post!(
  url,
  json: json,
  into: fn {:data, data}, {req, resp} ->
    # Called by Req as response body data arrives. Production code should use
    # Muse.LLM.Transport.SSE.ReqStream, which wraps this callback shape.
    on_chunk.(data)
    {:cont, {req, resp}}
  end
)
```

For the actual implementation, prefer `Muse.LLM.Transport.SSE.ReqStream.request/2`
so callers only provide an `on_chunk` callback and do not depend directly on Req's
streaming accumulator shape.

### Testing Strategy

```text
1. Unit test parser and stream-decoder normalization with fixture JSON/SSE data.
   - Load saved provider response JSON/SSE/WS frames from `test/fixtures/chat_completions/` and `test/fixtures/openai_responses/`
   - Assert ChatCompletionsStreamDecoder emits the expected Muse.LLM.Event values

2. Unit test SSE parser with chunked strings.
   - Feed partial SSE frames (split mid-line) to SSE.Parser
   - Assert parser buffers correctly and emits complete events
   - Test edge cases: empty data frames, multi-line data, comments

3. Do NOT call OpenAI in the normal test suite.
   - No network calls in `mix test`
   - All provider tests use fake provider or fixture data

4. Optional integration tests behind MUSE_OPENAI_TEST=1.
   - Tagged with @tag :openai_integration
   - Excluded by default in test_helper.exs
   - Run manually: MUSE_OPENAI_TEST=1 MUSE_OPENAI_API_KEY=sk-... mix test --include openai_integration
```

---

## 9. OpenAI Responses WebSocket Transport

**PR15 MVP — implemented.** The Responses WebSocket path is now available alongside the SSE transport. The architecture is dependency-free at the transport layer: callers inject a `ws_stream_fn` for both production use and offline testing.

### Modules

| Module | Role |
|--------|------|
| `Muse.LLM.OpenAI.ResponsesStreamDecoder` | Shared pure decoder for both WS JSON frames and SSE data frames; `new/0`, `feed/2`, `finalize/1` API |
| `Muse.LLM.OpenAI.ResponsesWebSocket.RequestBuilder` | Pure WS request spec builder; URL derivation (https→wss), create frame, headers, options |
| `Muse.LLM.Transport.WebSocket.Stream` | Dependency-free WS transport lifecycle; canonical `ws_stream_fn` injection; `:websocket_client_not_configured` when no low-level client |
| `Muse.LLM.Transport.WebSocket.SafeError` | Redacting error summaries for WS transport errors |

### Provider dispatch

In `OpenAICompatibleProvider.stream/2`:

- `wire_api == :responses` + `transport == :websocket` → Responses WebSocket path
- `wire_api == :responses` + `transport == :sse` → Responses HTTP SSE path (shared decoder)
- `wire_api == :chat_completions`/`nil` + `transport == :sse` → existing Chat Completions SSE path
- Otherwise → non-streaming Chat Completions

### SSE fallback

When WebSocket setup fails **before any inbound provider frame**, callers can enable SSE fallback via `request.options[:fallback_transport] == :sse` or `request.options[:fallback_to_sse] == true`. Fallback uses the Responses HTTP SSE path. **No fallback after midstream failure** — a redacted `:provider_error` is emitted instead.

### Conductor/session continuity

- `Conductor.hydrate_previous_response_id/3` copies `session.provider_state[:previous_response_id]` into `request.previous_response_id` when not explicitly set.
- `Conductor.merge_provider_state/2` merges safe keys (`:previous_response_id`) back from `response.provider_state` into `session.provider_state`.
- `ToolLoop.advance_provider_state/2` carries `provider_state` between iterations for Responses API conversation continuity.

### Limitations (PR16 scope)

- No built-in low-level WebSocket client dependency — callers must provide `ws_stream_fn` or configure a `:websocket_client`. The `default_stream/3` returns `{:error, {:transport_error, :websocket_client_not_configured}}` without one.
- External Phoenix WebSocket channel is **PR16 — implemented**. See [`architecture.md` §8.5](architecture.md#85-optional-external-phoenix-websocket-channel-pr16) and [`security.md` §9](security.md#9-external-websocket-channel-security-pr16).
- No automatic reconnection or subscription-style persistent connections.

### Responsibilities

```text
- Connect to wss://api.openai.com/v1/responses or configured equivalent.
- Send Authorization bearer header during WebSocket handshake.
- Send response.create events to initiate model responses.
- Receive response stream events from the server.
- Maintain previous_response_id in session.provider_state for conversation continuity.
- Continue turns with incremental input plus previous_response_id.
- Enforce one in-flight response per connection (unless client/docs support says otherwise).
- Reconnect/fallback cleanly when connection closes.
```

### Request Event Example

First turn — initiating a new response:

```json
{
  "type": "response.create",
  "response": {
    "model": "gpt-4.1",
    "store": false,
    "input": [
      {
        "type": "message",
        "role": "user",
        "content": [
          {
            "type": "input_text",
            "text": "add a /version command"
          }
        ]
      }
    ],
    "tools": [
      {
        "type": "function",
        "name": "read_file",
        "description": "Read a text file inside the workspace.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {"type": "string"}
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    ]
  }
}
```

### Continuation After Tool Output

After the runtime executes a tool call and has the result, send the continuation using `previous_response_id`:

```json
{
  "type": "response.create",
  "response": {
    "model": "gpt-4.1",
    "store": false,
    "previous_response_id": "resp_abc123def456",
    "input": [
      {
        "type": "function_call_output",
        "call_id": "call_xyz789",
        "output": "defmodule Muse.CLI do\n  def handle_command(\"version\", _) do\n    IO.puts(\"Muse v#{Application.spec(:muse, :vsn)}\")\n  end\nend"
      }
    ]
  }
}
```

**Key fields:**

| Field | Purpose |
|---|---|
| `previous_response_id` | Links to the prior server-side response for conversation continuity |
| `call_id` | Matches the tool call ID from the prior response's `function_call` event |
| `output` | The tool execution result string |

### Fallback Strategy

The WebSocket transport must handle connection failures gracefully:

```text
Before request starts:
  - If WebSocket connection fails, fallback to SSE if provider config allows
    (ProviderConfig.supports_streaming == true && transport == :sse available)

Mid-turn failure:
  - If connection fails mid-response, mark the turn as failed
  - Unless safe continuation is possible (idempotent read-only operations)

Write tool safety:
  - NEVER silently retry write tool side effects
  - For read-only tool loops, retry may be safe (tool results are idempotent)
  - For write tools (patch_apply, test_runner), require explicit user confirmation
    before continuing after a mid-turn failure

Reconnection:
  - Attempt WebSocket reconnect with exponential backoff
  - If reconnect fails after max retries, fallback to SSE or fail the turn
  - Log reconnection attempts at warning level
```

---

## 10. Auth Layer

**PR13 (implemented).** The auth layer (`Muse.Auth`) provides credential resolution
via API key (`ApiKey`), bearer command (`BearerCommand`), Codex cache bridge
(`CodexCache`), and a common facade (`Resolver`). All values are redacted in
inspect, events, logs, and debug output.

`ProviderConfig` records `auth` and `env_key` metadata but never reads API keys,
executes commands, or inspects caches — auth resolution is deferred to the
`Resolver`/provider layer at HTTP-dispatch time.

### 10.1 Auth Modes

The supported authentication strategies (selected via provider config `auth` field):

| Mode | Status | Description | Use Case |
|---|---|---|---|
| `:none` | ✅ Implemented | No authentication | Fake provider, local Ollama |
| `:api_key` | ✅ Implemented | Static API key from environment variable | Direct API key usage |
| `:bearer_command` | ✅ Implemented | Shell command that outputs a bearer token | Custom token refresh scripts |
| `:codex_cache` | ✅ Implemented | Read token from `~/.codex/auth.json` | Reuse Codex CLI authentication |
| `:openai_oauth` | 🔜 Future | Native OAuth flow | Browser sign-in without Codex |

### 10.2 Implementation Status

```text
1. ✅ API key from env
   Muse.Auth.ApiKey.resolve/2 — reads MUSE_OPENAI_API_KEY or provider-specific
   env var from explicit env map, system env, provider config, or app config.
   Pure when given an explicit env map; never logs the value.

2. ✅ Bearer token command
   Muse.Auth.BearerCommand.resolve/1 — executes a configured shell command
   with argv support, timeout, exit-status handling, bounded output parsing,
   and redacted error messages. Default allow_exec?: false — callers must
   opt in. Runner/cmd_fn injection for test isolation.

3. ✅ Codex cache reader for ~/.codex/auth.json
   Muse.Auth.CodexCache.resolve/1 — reads ~/.codex/auth.json (or explicit
   path), handles multiple JSON shapes (top-level, nested tokens/auth/openai),
   enforces 1 MB size cap, checks file permissions, redacts in inspect.

4. 🔜 Command bridge to codex login / codex login --device-auth
   NOT implemented in PR13. Future: shell out to Codex CLI for auth flows.

5. 🔜 Native Muse OAuth
   NOT implemented in PR13. Only if Codex CLI is not available and users
   need browser-based auth. High complexity — deferred.
```

### 10.3 Commands

```text
/auth status                                      ✅ PR13 MVP implemented
  Shows current auth state for the configured provider.
  Read-only: never executes bearer commands, never reads Codex caches.
  Redacts all token values; shows source and status labels only.
  For configured providers with :api_key mode, shows env key name
  and whether a credential is configured/missing (but never the value).

/auth login openai                                 🔜 Future (not PR13)
  Initiates OpenAI authentication. Prefer codex CLI bridge when
  implemented. Not part of PR13 MVP.

/auth login openai --device                        🔜 Future (not PR13)
  Device-code flow for headless environments.

/auth logout openai                                🔜 Future (not PR13)
  Clears stored credentials. Does not revoke server-side.
```

### 10.4 Resolution Behavior (Implemented)

Auth is resolved at HTTP-dispatch time by the provider, **not** by
`RequestBuilder` or any pre-request mapper. `RequestBuilder.build_chat_completions/1`
remains pure — it never reads env vars, secrets, or auth config. After the spec
is built, `OpenAICompatibleProvider.attach_auth/3` invokes `Muse.Auth.Resolver`
to attach the `Authorization` header.

**Resolution order for `:api_key` mode (highest to lowest):**

1. `opts[:api_key]` — explicit key value, no lookup needed
2. `opts[:env]` / `opts[:env_map]` — explicit env map with provider `env_key`
3. `opts[:app_config][:api_key]` — application config secret
4. `System.get_env("MUSE_OPENAI_API_KEY")` — runtime system env
   (only when `system_env?: true`, which is the runtime default; tests
   set `system_env?: false` to stay offline)

**Codex cache resolution** is only attempted when `auth: :codex_cache` is
explicit or callers opt into fallback with `allow_auth_fallback?: true` and
`allow_codex_cache?: true`. It is never silent.

**`/auth status`** is read-only: it shows the configured auth mode, source,
and whether a credential is present (redacted). It never executes bearer
commands or reads Codex cache files.

**Explicit `Authorization` header wins.** If the caller provides an
`Authorization` header in `request.options[:headers]`, the auth layer does not
overwrite or duplicate it.

### 10.4b Future Behavior (Not Implemented)

```text
/auth login openai:
  → Prefer shelling out to `codex login` if codex is installed.
  → Do NOT manually invent refresh endpoints or OAuth flows.
  → If codex is not installed, prompt for API key or suggest installation.

/auth login openai --device:
  → Prefer `codex login --device-auth` if codex is installed.
  → Displays device code + verification URL from Codex output.
  → Falls back to manual API key entry if no Codex.
```

### 10.5 Credential Shape

All credentials are represented as a structured `Muse.Auth.Credential`:

```elixir
defmodule Muse.Auth.Credential do
  @moduledoc """
  A resolved authentication credential for an LLM provider.
  The `value` field contains the secret — handle with extreme care.
  """

  @type auth_type :: :api_key | :bearer | :oauth_token
  @type source :: :env | :codex_cache | :command | :oauth | :prompt

  @enforce_keys [:type, :value, :source]
  defstruct [
    :type,
    :value,
    :source,
    :expires_at,
    :redacted
  ]

  @type t :: %__MODULE__{
    type: auth_type(),
    value: String.t(),
    source: source(),
    expires_at: DateTime.t() | nil,
    redacted: String.t()
  }
end
```

**Example credentials:**

```elixir
# API key from environment variable
%Muse.Auth.Credential{
  type: :api_key,
  value: "sk-proj-abc123...",
  source: :env,
  expires_at: nil,
  redacted: "sk-...REDACTED"
}

# Bearer token from Codex cache
%Muse.Auth.Credential{
  type: :bearer,
  value: "eyJhbGciOi...",
  source: :codex_cache,
  expires_at: ~U[2025-06-01 12:00:00Z],
  redacted: "eyJ...REDACTED"
}

# Bearer token from shell command
%Muse.Auth.Credential{
  type: :bearer,
  value: "tok_abc123...",
  source: :command,
  expires_at: nil,
  redacted: "tok_...REDACTED"
}
```

The `redacted` field is always populated and is the only field that may appear in logs, events, or debug output. The `value` field is **never** emitted into `Muse.Event`, prompt previews, or log output.

### 10.6 Security Rules (Enforced in PR13)

These rules are non-negotiable. Violations are security bugs. All are enforced
in the current implementation.

```text
1. Never emit tokens into Muse.Event.
   - The Muse.Event struct has no token/credential field.
   - The Credential `value` field appears only at the outbound HTTP
     Authorization boundary (`Authorization: Bearer ...`).
   - Events broadcast via PubSub (CLI, TUI, LiveView) never carry raw tokens.

2. Never include tokens in prompt previews.
   - The Prompt.Assembler never sees raw credentials — auth headers are
     injected at the provider HTTP layer, not the prompt layer.
   - `/prompt preview` shows layer metadata only, never raw secrets.

3. Never store tokens under workspace .muse/ by default.
   - Workspace .muse/ is for session state and plan data.
   - Credentials stay in environment variables, ~/.codex/auth.json, or
     short-lived Credential structs in memory.

4. Check file permissions on ~/.codex/auth.json.
   - CodexCache checks POSIX mode bits: group/other readable or writable
     modes produce a `{:permissive_permissions, "0600 recommended"}` warning
     attached to the credential struct.

5. Treat ~/.codex/auth.json as password-equivalent.
   - The access token is as sensitive as an API key.
   - Never logged, never included in path labels (safe_path_label/1 returns
     "~/.codex/auth.json" or the basename only).
   - File reads are capped at 1 MB to prevent resource exhaustion.

6. Redact Authorization headers in all debug events.
   - `EventPayloadRedactor` and `MetadataSanitizer` redact all Authorization
     header values before they reach events, logs, or debug output.
   - `ProviderConfig.redacted_inspect/1` shows `"Authorization: ...REDACTED"`.
```

---

## 11. External API References to Verify

All provider PRs must re-check official documentation immediately before implementation. The source plans referenced OpenAI Responses streaming, Responses WebSocket mode, function/tool calling, Codex auth, and Codex device auth. **Treat docs as the source of truth for wire formats.** The items below are the topics that must be verified against current official docs before each provider PR is coded:

| Topic | What to verify | Risk if outdated |
|---|---|---|
| **OpenAI Responses API HTTP streaming over SSE** | `stream: true` behavior, SSE event format, `data: [DONE]` terminator, event types (`response.output_text.delta`, `response.function_call_arguments.delta`, etc.) | Wrong event names → parser crashes or silently drops events |
| **OpenAI Responses WebSocket mode** | Connection URL (`wss://api.openai.com/v1/responses`?), handshake headers, `previous_response_id` mechanics, reconnection protocol, max connection lifetime | Broken WS handshake or lost conversation state |
| **OpenAI function/tool calling with app-side tool execution** | `tool_choice: "auto"` behavior, `function` vs `function` nesting, `tool_calls` response format, `function_call_output` input type for Responses API, `tool` role message for Chat Completions | Tool calls not dispatched, wrong continuation format |
| **Structured outputs / JSON schema support** | `response_format: {type: "json_schema", ...}` syntax, supported models, schema validation errors, interaction with tool calls | Incorrect request shape → API errors |
| **Codex auth methods** | ChatGPT sign-in flow, API-key sign-in flow, token types returned, token refresh mechanics | Auth fails or uses wrong grant type |
| **Codex login cache at `~/.codex/auth.json`** | File format (JSON fields), token field names, expiry handling, refresh token presence, file permissions expectations | Token not found or wrong field read |
| **Codex `login --device-auth`** | Device-code flow output format, polling interval, success/failure indicators, headless environment support | Device flow can't be parsed or hangs |

**Verification process for each provider PR:**

1. **Read current official docs** at `platform.openai.com/docs` for the relevant API.
2. **Update request/response shapes** in this roadmap and in the mapper code.
3. **Update fixture JSON** in `test/fixtures/` if event formats have changed.
4. **Run integration tests** (`MUSE_OPENAI_TEST=1`) against the current API.
5. **Document any divergences** from the shapes specified here — update this doc.
