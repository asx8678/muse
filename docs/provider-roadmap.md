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
| Coding Muse proposes a patch | Emits a `patch_propose` tool call with structured patch arguments. Tests the full patch proposal flow. |
| Coding Muse requests `patch_apply` | Emits a `patch_apply` tool call. Tests the approval gate for write operations. |
| Testing Muse requests `test_runner` | Emits a `test_runner` tool call. Tests safe test execution gating. |
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

### 3.2 OpenAI-Compatible Config (Offline in PR11)

PR11 can resolve OpenAI-compatible provider **configuration** and build request JSON payloads, but it does **not** call OpenAI or any other real provider. Real HTTP providers/transports are later roadmap work; auth/API-key loading remains in the auth layer.

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
| `MUSE_OPENAI_BASE_URL` | No for `openai_compatible` defaults | `https://api.openai.com/v1` for `openai_compatible` | Base URL stored on the config; PR11 does not connect to it |
| `MUSE_LLM_TIMEOUT_MS` | No | `120000` | Per-request timeout in milliseconds |
| `MUSE_LLM_MAX_RETRIES` | No | `0` for fake; `2` for openai-compatible | Maximum retry attempts stored for future transports |
| `MUSE_WIRE_API` | No (`Muse.Config` only) | `responses` for openai-compatible | `responses` or `chat_completions`; unknown values resolve to `nil` |
| `MUSE_TRANSPORT` | No (`Muse.Config` only) | `sse` for openai-compatible; `none` for fake | `none`, `sse`, or `websocket`; unknown values resolve to `nil` |
| `MUSE_OPENAI_API_KEY` | Not read in PR11 | — | Auth/API-key loading is deferred to the auth layer (PR13); PR11 stores `env_key: "MUSE_OPENAI_API_KEY"` only |

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
- Validation does **not** read or require `MUSE_OPENAI_API_KEY`; auth loading remains PR13.
- Startup wiring may call this validation, but PR11 itself is config/request-mapper plumbing, not a real provider bootstrap.
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

**Future provider phase, not PR11.** PR11 stops at provider config plus offline request mappers. It does not add an HTTP client, does not load credentials, and does not call real providers.

When real provider work begins, implement non-streaming Chat Completions-compatible requests **before** SSE/WebSocket to reduce integration risk. A non-streaming provider validates the request/response shape, auth, and error handling without the complexity of incremental parsing.

**Add dependency only in the real provider phase:**

```elixir
# mix.exs — only added when provider PRs begin
{:req, "~> 0.5"}
```

### Request Shape

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
            "path": {
              "type": "string",
              "description": "Relative path within the workspace root."
            },
            "start_line": {
              "type": "integer",
              "description": "Optional 1-based start line."
            },
            "max_lines": {
              "type": "integer",
              "description": "Optional maximum number of lines to return."
            }
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "list_files",
        "description": "List files and directories in the workspace.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Directory path relative to workspace root."
            },
            "recursive": {
              "type": "boolean",
              "description": "Whether to recurse into subdirectories."
            }
          },
          "required": ["path"],
          "additionalProperties": false
        }
      }
    }
  ],
  "tool_choice": "auto"
}
```

### Response Decoder

Parse the non-streaming Chat Completions response:

```elixir
defmodule Muse.LLM.Providers.OpenAICompatible.Decoder do
  @moduledoc """
  Decodes OpenAI-compatible Chat Completions responses into Muse LLM structs.
  """

  alias Muse.LLM.{Response, ToolCall}

  @spec decode(map()) :: {:ok, Response.t()} | {:error, term()}
  def decode(body) do
    choice = get_in(body, ["choices", Access.at(0)])

    with {:ok, message} <- fetch(choice, "message"),
         {:ok, content} <- fetch(message, "content"),
         {:ok, tool_calls} <- decode_tool_calls(message["tool_calls"]),
         {:ok, finish_reason} <- fetch(choice, "finish_reason") do
      {:ok, %Response{
        id: body["id"],
        content: content,
        text: content,
        tool_calls: tool_calls,
        usage: body["usage"],
        finish_reason: finish_reason,
        raw: body
      }}
    end
  end

  defp decode_tool_calls(nil), do: {:ok, []}
  defp decode_tool_calls(calls) when is_list(calls) do
    result =
      Enum.map(calls, fn call ->
        with {:ok, args} <- decode_arguments(call["function"]["arguments"]) do
          %ToolCall{
            id: call["id"],
            name: call["function"]["name"],
            arguments: args,
            raw: call
          }
        end
      end)

    case Enum.find(result, &match?({:error, _}, &1)) do
      nil -> {:ok, result}
      error -> error
    end
  end

  defp decode_arguments(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, args} -> {:ok, args}
      {:error, _} -> {:error, :invalid_tool_arguments}
    end
  end
  defp decode_arguments(args) when is_map(args), do: {:ok, args}

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
```

**Decoder extracts:**

| Field | Path | Maps to |
|---|---|---|
| `choices[0].message.content` | Assistant text | `Response.text` / `Response.content` |
| `choices[0].message.tool_calls` | Tool call array | `Response.tool_calls` (list of `Muse.LLM.ToolCall`) |
| `choices[0].finish_reason` | Stop reason | `Response.finish_reason` |
| `usage` | Token counts | `Response.usage` |

**Tool call conversion:**

```elixir
%Muse.LLM.ToolCall{
  id: "call_abc123",
  name: "read_file",
  arguments: %{"path" => "lib/muse.ex"},
  raw: %{
    "id" => "call_abc123",
    "type" => "function",
    "function" => %{
      "name" => "read_file",
      "arguments" => "{\"path\": \"lib/muse.ex\"}"
    }
  }
}
```

Arguments arrive as JSON strings from the API. Decode with `Jason.decode!/1`. If decoding fails, return a `:tool_call_validation_error` — never crash the turn loop.

---

## 6. OpenAI Responses Request Mapper

The OpenAI Responses API uses a different request shape than Chat Completions. In PR11, `Muse.LLM.OpenAI.ResponsesMapper` is a pure/offline mapper:

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

A future transport may `POST` to `{base_url}/responses`; the PR11 mapper only returns payload/path data.

**Key differences from Chat Completions:**

| Aspect | Responses API | Chat Completions |
|---|---|---|
| Message container | `input` array with typed content | `messages` array with role/content |
| Content format | `[{type: "input_text", text: "..."}]` | Plain string |
| Conversation state | `previous_response_id` | Full message history |
| Persistence | `store: false` | N/A |
| Streaming flag | `stream: true` | `stream: true` |

The Responses API can maintain conversation state server-side using `previous_response_id`, which reduces the size of subsequent requests once real provider support exists. PR11 only preserves/maps that field; it does not create server-side state.

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

A future transport may `POST` to `{base_url}/chat/completions`; the PR11 mapper only returns payload/path data.

The Chat Completions mapper includes the full message history (system prompt + all prior messages) because the API is stateless — there is no `previous_response_id` equivalent. Any network dispatch/auth wrapper belongs to later provider/auth PRs, not to this mapper.

---

## 8. HTTP SSE Transport

**Future transport phase, not PR11.** The details below are the roadmap for real streaming provider support after offline config/mappers are in place.

### Responsibilities

```text
- POST request to configured endpoint (Responses or Chat Completions path).
- Add Authorization header from Auth layer (Bearer token or API key).
- Add stream=true query parameter or body field for supported wire APIs.
- Parse SSE data frames incrementally (data: {...}\n\n).
- Decode JSON events from each SSE frame.
- Normalize provider-specific events into Muse.LLM.Event structs.
- Redact errors before emitting to Muse.Event or log output.
```

### Normalizing Rules

Provider-specific SSE event types must be normalized into the Muse event model. Unknown events must never crash the runtime.

| Provider Event | Normalized Muse Event | Notes |
|---|---|---|
| Text delta (content chunk) | `:assistant_delta` | Incremental text append |
| Function/tool-call argument delta | `:tool_call_delta` | Partial argument accumulation |
| Tool call completed (arguments complete) | `:tool_call_completed` | Full `Muse.LLM.ToolCall` available |
| Usage/stats event | _(stored, not emitted as event)_ | `Response.usage` populated at end |
| Response completed | `:response_completed` | Final event with usage |
| Unknown/unrecognized event | `:debug` event with raw payload | Logged at debug level, never crashes |

```elixir
defmodule Muse.LLM.Transport.SSE.Normalizer do
  @moduledoc """
  Normalizes provider-specific SSE events into Muse.LLM.Event structs.
  """

  alias Muse.LLM.Event

  @spec normalize(atom(), map()) :: Event.t()
  def normalize(:text_delta, data) do
    %Event{type: :assistant_delta, text: data["delta"]}
  end

  def normalize(:tool_call_delta, data) do
    %Event{type: :tool_call_delta, tool_call: %{
      id: data["id"],
      name: data["name"],
      arguments_delta: data["arguments_delta"]
    }}
  end

  def normalize(:tool_call_completed, data) do
    %Event{type: :tool_call_completed, tool_call: %{
      id: data["id"],
      name: data["name"],
      arguments: data["arguments"]
    }}
  end

  def normalize(:usage, data) do
    %Event{type: :response_completed, usage: data}
  end

  def normalize(:unknown, raw) do
    %Event{type: :debug, raw: raw}
  end
end
```

### Backpressure

Use `Req` with streaming support. Process events in the TurnRunner process. The TurnRunner controls the pace:

- If the TurnRunner is waiting for a tool execution result, the HTTP stream naturally pauses (TCP backpressure).
- If the TurnRunner is blocked on an approval gate, SSE frames buffer in the Req streaming handler.
- The TurnRunner processes events one at a time — no unbounded async queue between the SSE parser and the turn loop.

```text
Req.post!(url, body: json, into: fn chunk, acc ->
  # Called in the TurnRunner process — natural backpressure
  events = SSE.Parser.parse_chunk(chunk)
  Enum.each(events, &TurnRunner.handle_llm_event/1)
  {:cont, acc}
end)
```

### Testing Strategy

```text
1. Unit test event normalization with fixture JSON files.
   - Load saved provider response JSON from test/fixtures/sse/
   - Assert each frame normalizes to the expected Muse.LLM.Event

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

**Add dependency only in this phase:**

```elixir
# Choose after checking current Elixir/OTP version and project style:
{:websockex, "~> 0.5"}
# or
{:mint_web_socket, "~> 0.1"}  # if using Mint for HTTP already
```

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

**Future auth phase (PR13+), not PR11.** PR11 provider config may record `auth` and `env_key`, but it does not read API keys, execute bearer commands, inspect Codex caches, or attach Authorization headers.

### 10.1 Auth Modes

The auth layer will support multiple authentication strategies, selected by the provider config:

| Mode | Description | Use Case |
|---|---|---|
| `:none` | No authentication | Fake provider, local Ollama |
| `:api_key` | Static API key from environment variable | Direct OpenAI API key usage |
| `:bearer_command` | Shell command that outputs a bearer token | Custom token refresh scripts |
| `:codex_cache` | Read token from `~/.codex/auth.json` | Reuse Codex CLI authentication |
| `:openai_oauth` | Native Muse OAuth flow (future) | Browser-based sign-in without Codex |

### 10.2 Implementation Order

Build auth capabilities incrementally — each step is usable on its own:

```text
1. API key from env
   Read MUSE_OPENAI_API_KEY or provider-specific env var.
   Simplest possible auth. Ship first.

2. Bearer token command
   Execute a configurable shell command that outputs a bearer token.
   Supports custom token refresh scripts and corporate auth proxies.

3. Codex cache reader for ~/.codex/auth.json
   Read the existing Codex CLI auth cache.
   Avoids re-authentication if the user already ran `codex login`.

4. Command bridge to codex login / codex login --device-auth
   Shell out to the Codex CLI for authentication flows.
   Delegates OAuth complexity to a trusted external tool.

5. Native Muse OAuth only if truly needed later
   Implement browser-based OAuth flow directly in Muse.
   Only if Codex is not installed and users need browser auth.
   High complexity — defer as long as possible.
```

### 10.3 Commands

```text
/auth status
  Shows current auth state for all configured providers.
  Redacts all token values.

/auth login openai
  Initiates OpenAI authentication.
  Prefers `codex login` if Codex CLI is installed.
  Falls back to API key prompt if no Codex.

/auth login openai --device
  Initiates device-code flow for headless environments.
  Prefers `codex login --device-auth` if Codex CLI is installed.
  Displays the device code and verification URL.

/auth logout openai
  Clears stored credentials for the OpenAI provider.
  Does not revoke tokens server-side (Codex handles its own logout).
```

### 10.4 Recommended Behavior

The auth layer follows a deterministic resolution order:

```text
OPENAI_API_KEY present:
  → Use API key auth. Simplest, most common path.

No OPENAI_API_KEY, Codex auth cache present (~/.codex/auth.json exists),
and config explicitly allows codex_cache auth:
  → Use Codex-managed access token, redacted in all logs.
  → Check file permissions on ~/.codex/auth.json.
  → Warn if file is world-readable.

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

### 10.6 Security Rules

These rules are non-negotiable. Violations are security bugs.

```text
1. Never emit tokens into Muse.Event.
   - The Muse.Event struct does not have a token/credential field.
   - Events are broadcast via PubSub and visible to CLI, TUI, and LiveView.

2. Never include tokens in prompt previews.
   - /prompt preview must show "[REDACTED]" for any auth headers.
   - The Prompt.Assembler never sees raw credentials — auth headers are
     injected at the transport layer, not the prompt layer.

3. Never store tokens under workspace .muse/ by default.
   - Workspace .muse/ is for session state and plan data.
   - Credentials belong in environment variables or ~/.codex/auth.json.
   - A future ~/.muse/credentials store may be added with strict permissions.

4. Check file permissions on ~/.codex/auth.json.
   - Warn if the file is readable by group or others (mode > 0600).
   - Log a warning: "~/.codex/auth.json has overly permissive permissions (0644).
     Consider: chmod 600 ~/.codex/auth.json"

5. Treat ~/.codex/auth.json as password-equivalent.
   - The access token inside is as sensitive as an API key.
   - Never log its contents.
   - Never include its path in error messages that might be visible to
     other users on shared systems.

6. Redact Authorization headers in all debug events.
   - Provider debug events that log HTTP request details must show
     "Authorization: Bearer ...REDACTED" or "Authorization: Bearer sk-...REDACTED".
   - Req's request/response logging must be configured to redact
     the Authorization header.
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
