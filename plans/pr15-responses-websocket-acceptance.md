# PR15 Responses WebSocket Acceptance Scout

Scope owner: `pr15/lane01-acceptance-scout`

Parent bead: `muse-1ki.2.5` — PR 15 Responses WebSocket provider

This note is the convergence contract for PR15 lanes. It is intentionally
non-invasive: it records the expected architecture, test seams, and acceptance
criteria for adding persistent OpenAI Responses WebSocket support on top of the
PR12–PR14 provider work.

## Existing baseline from PR12–PR14

- `Muse.LLM.OpenAI.ResponsesMapper` is already the canonical pure mapper for
  Responses request payloads. It emits JSON-safe string-key maps and includes
  `"previous_response_id"` when `request.previous_response_id` is set.
- `Muse.LLM.OpenAI.RequestBuilder` currently builds only Chat Completions HTTP
  specs. Passing `wire_api: :responses` remains unsupported there until PR15
  adds a Responses-specific builder/path.
- `Muse.LLM.OpenAICompatibleProvider.stream/2` dispatches to the PR14 SSE path
  only when `request.transport == :sse` or `request.options[:transport] == :sse`.
  The SSE path uses `sse_post_fn = fn url, req_options, on_chunk -> ... end`
  as its offline test seam.
- `Muse.LLM.Transport.SSE.Parser` and `Muse.LLM.Transport.SSE.ReqStream` show the
  desired separation: pure frame parsing/decoding is independent from network
  transport, and real I/O is hidden behind injectable functions.
- `Muse.LLM.Request` already has `:wire_api`, `:transport`, and
  `:previous_response_id`; `Muse.LLM.Response` already has `:provider_state`.
  PR15 should use these fields rather than inventing parallel state.
- `Muse.Conductor` and `Muse.Conductor.ToolLoop` currently pass provider events
  through as normalized `Muse.LLM.Event` values, but they do not yet persist or
  rehydrate `Response.provider_state`. PR15 must add that continuity without
  exposing provider state in user/debug event payloads.

## Canonical PR15 architecture

### Dispatch

`Muse.LLM.OpenAICompatibleProvider.stream/2` should add a Responses WebSocket
branch before the existing SSE/non-streaming branches:

```text
OpenAICompatibleProvider.stream/2
  ├── wire_api == :responses and transport == :websocket
  │     ├── build Responses payload via ResponsesMapper.to_payload/1
  │     ├── wrap as response.create frame
  │     ├── attach auth headers using existing explicit-Authorization-wins rule
  │     ├── call injected/default ws_stream_fn
  │     ├── decode WebSocket frames into canonical Muse.LLM.Event values
  │     └── return Muse.LLM.Response with provider_state.previous_response_id
  ├── transport == :sse → existing explicit SSE path
  └── otherwise → existing non-streaming replay path
```

Recommended module boundaries:

- Keep request mapping pure in `Muse.LLM.OpenAI.ResponsesMapper`.
- Put Responses WebSocket URL/header/spec construction in a small builder module
  or in a clearly separated provider helper.
- Put the default network client in `lib/muse/llm/transport/...` using the
  existing singular `transport` namespace, for example
  `Muse.LLM.Transport.ResponsesWebSocket`.
- Put frame decoding/accumulation in a pure module, for example
  `Muse.LLM.OpenAI.ResponsesWebSocketDecoder`, so tests can feed decoded maps
  without opening sockets.

### Wire create frame

The outgoing WebSocket create frame is canonical and should not vary by lane:

```elixir
payload = Muse.LLM.OpenAI.ResponsesMapper.to_payload(request)

create_frame = %{
  "type" => "response.create",
  "response" => payload
}
```

Acceptance requirements:

- The `"response"` value is exactly the mapper payload, not a hand-built copy.
- No request metadata, prompt bundle debug data, provider options, raw tokens, or
  event/debug fields are added to the wire frame.
- `previous_response_id` appears only inside the mapper payload when
  `request.previous_response_id` is set.

### WebSocket URL derivation

Default URL derivation starts from `request.options[:base_url]` or
`request.options["base_url"]`:

| `base_url` input | Derived WebSocket URL |
|---|---|
| `https://api.openai.com/v1` | `wss://api.openai.com/v1/responses` |
| `https://example.test/v1/` | `wss://example.test/v1/responses` |
| `http://localhost:4000/v1` | `ws://localhost:4000/v1/responses` |
| `http://localhost:4000/v1/responses` | `ws://localhost:4000/v1/responses` |

Rules:

- `https` becomes `wss`; `http` becomes `ws`.
- Trim trailing slashes and append `/responses` exactly once unless the path
  already ends with `/responses`.
- Reject missing/blank/non-binary URLs, unsupported schemes, missing hosts, and
  embedded credentials/userinfo. Error summaries must redact full URLs.
- Caller override wins via `request.options[:websocket_url]` or
  `request.options["websocket_url"]`. The override should be a full `ws://` or
  `wss://` URL and should receive the same validation/redaction treatment.

### Test injection shape

All normal tests must remain offline. The canonical WebSocket seam mirrors PR14's
`sse_post_fn` but sends complete WebSocket frames instead of SSE chunks:

```elixir
ws_stream_fn = fn url, ws_options, on_frame ->
  assert String.starts_with?(url, "wss://")
  assert is_list(ws_options[:headers])
  assert %{"type" => "response.create"} = ws_options[:create_frame]

  on_frame.(%{"type" => "response.created", "response" => %{"id" => "resp_123"}})
  on_frame.(~s({"type":"response.output_text.delta","delta":"hello"}))
  on_frame.(%{"type" => "response.completed", "response" => %{"id" => "resp_123"}})

  {:ok, %{close_code: 1000}}
end
```

Acceptance requirements:

- Provider options should accept `request.options[:ws_stream_fn]` and may also
  accept a string key for symmetry with other provider options.
- `ws_stream_fn` arity is exactly three: `fn url, ws_options, on_frame -> ... end`.
- `ws_options` includes at least:
  - `:headers` — final handshake headers after auth attachment.
  - `:create_frame` — the exact `%{"type" => "response.create", "response" => payload}` map.
  - Timeout/retry options forwarded from existing request options, including
    `:timeout_ms`, `:receive_timeout`, and `:max_retries` when valid.
- `on_frame` accepts either binary JSON frames or already decoded maps. The
  decoder/provider must not require tests to encode maps just to stay offline.
- Invalid injected function shape returns a redacted `:provider_error` and an
  error tuple; it must not raise through `stream/2`.

### Default transport implementation

- A real WebSocket implementation may add a dependency only if it compiles
  cleanly with the project (`elixir: "~> 1.17"`) and does not force network use
  in tests.
- The default transport belongs behind the same `ws_stream_fn` contract. Provider
  tests should exercise the default provider path by injecting a lower-level
  transport function or the top-level `ws_stream_fn`; no test should call OpenAI
  or any external WebSocket endpoint by default.
- The implementation should enforce one in-flight Responses create frame per
  WebSocket call/connection unless current provider documentation explicitly
  permits concurrency and tests cover the ordering semantics.

## Decoder and event contract

The Responses WebSocket decoder must emit only existing canonical event types:

- `:response_started`
- `:assistant_delta`
- `:tool_call_started`
- `:tool_call_delta`
- `:tool_call_completed`
- `:assistant_completed`
- `:response_completed`
- `:provider_error`

No PR15 lane should add new `Muse.LLM.Event` types for provider-specific
Responses frame names. Unknown non-error frames should be ignored safely or kept
only in bounded/redacted decoder state. Provider error frames should normalize to
exactly one `:provider_error` event for the failure.

Minimum frame normalization expectations:

| Responses WebSocket frame family | Canonical output |
|---|---|
| create/start frame (`response.created`, first valid frame, etc.) | one `:response_started` |
| text delta (`response.output_text.delta` or current docs equivalent) | `:assistant_delta` with delta text |
| function/tool call item started | `:tool_call_started` |
| function/tool argument delta | `:tool_call_delta` |
| function/tool call completed | `:tool_call_completed` with `Muse.LLM.ToolCall` |
| text/output completed | `:assistant_completed` with assembled text |
| `response.completed` | `:response_completed` with usage, final `Response` |
| error frames, decode failures, transport failures | exactly one `:provider_error` and `{:error, redacted}` |

`Response.provider_state` must include `%{previous_response_id: response_id}`
after a successful `response.completed` frame. Prefer the completed response id;
fall back to an earlier captured response id only if the completed frame omits it.
If no response id is available, omit `previous_response_id` rather than storing a
placeholder.

## Conductor and tool-loop continuity

PR15 must preserve Responses conversation continuity without leaking provider
state into events.

Acceptance requirements:

- At the start of a turn, if the request has no explicit `previous_response_id`,
  the Conductor should hydrate it from `session.provider_state[:previous_response_id]`
  when present.
- An explicit request/config value wins over session state.
- After a successful provider call, safe keys from `response.provider_state` are
  merged into `session.provider_state`; initially the only safe key should be
  `:previous_response_id`.
- Existing unrelated `session.provider_state` keys are preserved, but raw
  provider payloads, tokens, headers, and sensitive keys are never stored.
- In the tool loop, each continuation request after a tool-result message must
  carry the latest prior `provider_state.previous_response_id` from the provider
  response that requested the tool call.
- The final tool-loop response's provider state should be merged back into the
  session just like the non-tool path.
- Provider state must not appear in `:provider_request_started`,
  `:provider_response_completed`, `:assistant_delta`, `:assistant_message`, or
  any other emitted event spec.

## Auth and redaction

- Continue PR13's rule: an explicit `Authorization` header in
  `request.options[:headers]` or `request.options["headers"]` wins. The auth
  resolver must not overwrite or duplicate it.
- Raw bearer/API tokens may appear only in outbound WebSocket handshake headers.
- Error terms, emitted events, telemetry metadata, transport return values, and
  logs must redact tokens, headers, request bodies, create frames, and full raw
  provider payloads.
- Header assertions in tests should verify presence/precedence without printing
  raw secrets in failures where possible.

## Fallback and retry semantics

- Before sending `response.create`, a WebSocket connection/setup failure may fall
  back to an explicit SSE path only when the caller/provider config opts in.
  There should be no silent default downgrade.
- The fallback path must be observable in tests without a network call. Suggested
  shape: configure the request to use a failing `ws_stream_fn` plus an injected
  `sse_post_fn` and assert the SSE path is called.
- Mid-turn WebSocket failure after `response.create` has been sent returns a
  redacted provider error and marks the turn/provider call failed.
- Mid-turn failure must not silently retry create frames, tool continuations, or
  write/tool side effects. If a retry is ever introduced, it must be explicit,
  bounded, and safe for the operation's idempotency.
- No `:assistant_completed` or `:response_completed` should be emitted after a
  mid-turn failure unless the decoder already received a valid completed frame.

## Acceptance test checklist for implementation lanes

Recommended offline tests:

1. Request builder/spec tests:
   - wraps `ResponsesMapper.to_payload/1` in `response.create`;
   - derives `wss`/`ws` URLs and honors `:websocket_url` overrides;
   - forwards headers and timeout/retry options;
   - rejects bad URLs with redacted errors.
2. Provider WebSocket happy-path tests with injected `ws_stream_fn`:
   - asserts `url`, `ws_options[:headers]`, and `ws_options[:create_frame]`;
   - feeds binary and map frames through `on_frame`;
   - asserts canonical event order and final `%Response{}`.
3. Decoder unit tests:
   - text deltas assemble into content and `:assistant_completed`;
   - tool-call deltas assemble into `Muse.LLM.ToolCall`;
   - `response.completed` stores `%{previous_response_id: id}`;
   - unknown frames are ignored and error frames produce one provider error.
4. Auth/redaction tests:
   - explicit Authorization header wins;
   - resolver-provided token is present only in handshake headers;
   - provider/transport errors do not include raw tokens, headers, or frames.
5. Conductor/tool-loop tests:
   - session provider state hydrates subsequent request `previous_response_id`;
   - explicit request value overrides session state;
   - tool-loop continuations carry the newest prior response id;
   - event specs do not contain provider state.
6. Fallback/failure tests:
   - pre-request WebSocket failure falls back only when explicitly configured;
   - mid-turn failure emits one provider error, returns an error, and does not
     finalize the response.

## Risks and open verification items

- The exact OpenAI Responses WebSocket frame names and tool-call shapes must be
  checked against current official documentation immediately before coding the
  decoder. This note defines the Muse-normalized contract, not a replacement for
  provider docs.
- Existing PR14 SSE support is Chat Completions-oriented. If PR15 falls back to
  SSE for Responses requests, the implementation must make the selected fallback
  wire API explicit and test the downgrade/compatibility path.
- Dependency choice is still open. Prefer the smallest transport dependency that
  compiles cleanly and stays hidden behind `ws_stream_fn` so most PR15 work is
  testable without network I/O.
- Provider-state persistence touches Conductor and ToolLoop, so those changes
  should be small, whitelisted, and covered by tests to avoid leaking provider
  internals into user-visible events.
