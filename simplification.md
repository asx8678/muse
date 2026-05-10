# Simplification Findings So Far

> Status: partial investigation notes captured before the full `APP_SIMPLIFICATION_PLAN.md` is completed. These findings are based only on files already inspected. No application code changes have been made.

## 1. Project Type and Runtime Shape

- The application is an Elixir/OTP CLI application.
  - Evidence: `mix.exs` defines the Mix project and application; inspected runtime modules include `lib/muse/application.ex`, `lib/muse/cli/main.ex`, `lib/muse/cli/repl.ex`, `lib/muse/cli/tui.ex`, `lib/muse/session_server.ex`, and `lib/muse/session_router.ex`.
- The architecture appears to be organized around:
  - CLI entry modules under `lib/muse/cli/`
  - OTP/application boot under `lib/muse/application.ex`
  - Session and conversation routing under `lib/muse/session_server.ex` and `lib/muse/session_router.ex`
  - LLM provider behavior/adapters under `lib/muse/llm/`
  - Slash command dispatch under `lib/muse/commands.ex` and `lib/muse/command_dispatcher.ex`
  - Agent/muse profile management under `lib/muse/muse_registry.ex`, `lib/muse/muse_profile.ex`, and `lib/muse/conductor.ex`

## 2. Launch / CLI Entrypoint Findings

- A `muse` command target already exists at the packaging/configuration level.
  - Evidence: `mix.exs` was inspected and contains escript configuration with `name: "muse"` and `main_module: Muse.CLI.Main`.
- A development/runtime wrapper named `bin/muse` exists.
  - Evidence: `bin/muse` was inspected as part of the launch-flow review.
- The primary CLI main module is `Muse.CLI.Main`.
  - Evidence: `lib/muse/cli/main.ex` was inspected and is referenced by the escript config in `mix.exs`.
- Additional CLI UI/runtime modules exist:
  - `lib/muse/cli/repl.ex`
  - `lib/muse/cli/tui.ex`
  - `lib/muse/cli/stream_printer.ex`
  - Evidence: these files were inspected while tracing how the app starts and renders output.
- Current launch simplification issue:
  - Even though the binary name is already configured as `muse`, the runtime is still not yet simplified around a single real-provider-first path because provider defaults still include fake-provider behavior.
  - Evidence: `Muse.LLM.ProviderConfig.build_from_env/2` currently resolves `provider_str = env_value(env_map, "MUSE_PROVIDER") || "fake"`, making fake provider the default when no provider is configured.

## 3. Provider System Findings

### 3.1 Provider Behavior and Router

- Providers implement a common behavior.
  - Evidence: `lib/muse/llm/provider.ex` was inspected; concrete providers use `@behaviour Muse.LLM.Provider`.
- Provider dispatch exists through a router.
  - Evidence: `lib/muse/llm/provider_router.ex` was inspected as part of provider review.
- Provider configuration is centralized in `Muse.LLM.ProviderConfig`.
  - Evidence: `lib/muse/llm/provider_config.ex` defines provider defaults, environment loading, known provider parsing, streaming/tool capability flags, and validation helpers.

### 3.2 Fake Provider Is Still a First-Class Runtime Provider

- `Muse.LLM.FakeProvider` exists and is not merely a tiny test fixture; it implements the full provider behavior.
  - Evidence: `lib/muse/llm/fake_provider.ex` defines `defmodule Muse.LLM.FakeProvider` and declares `@behaviour Muse.LLM.Provider`.
- The fake provider is explicitly described as a deterministic offline fake provider for testing and development.
  - Evidence: module documentation in `lib/muse/llm/fake_provider.ex` says: `Deterministic offline fake provider for testing and development.`
- The fake provider can emit scripted assistant events, tool-call events, delays, provider errors, and batches.
  - Evidence: `Muse.LLM.FakeProvider.stream/2` reads request options including `:fake_events`, `:fake_error`, and `:fake_event_batches` through `classify_options/1`.
- The fake provider has a default response path.
  - Evidence: `handle_default/2` emits `Event.response_started()`, `Event.assistant_delta(text)`, `Event.assistant_completed(text)`, and `Event.response_completed()`.
- The fake provider returns placeholder content.
  - Evidence: `default_text/1` returns `"Placeholder response: received #{Request.latest_user_text(request)}"`.
- The fake provider simulates multi-turn/tool-loop testing.
  - Evidence: `handle_scripted_batches/2` uses `request.options[:fake_iteration]` and `request.options[:fake_event_batches]`, and `default_text_for_request/1` emits a placeholder summary after tool-role messages.

### 3.3 Fake Provider Is the Current Default

- The app currently defaults to the fake provider if `MUSE_PROVIDER` is unset.
  - Evidence: `Muse.LLM.ProviderConfig.build_from_env/2` sets `provider_str = env_value(env_map, "MUSE_PROVIDER") || "fake"`.
- The fake model is also hardcoded as a default.
  - Evidence: `Muse.LLM.ProviderConfig.resolve_model(:fake, env_map)` returns `env_value(env_map, "MUSE_MODEL") || "fake-planning-model"`.
- `Muse.LLM.ModelRouter` still treats `fake` as a known provider string.
  - Evidence: `lib/muse/llm/model_router.ex` has `@known_provider_strings %{ "fake" => :fake, "openai_compatible" => :openai_compatible }`.
- `ModelRouter` documentation/examples also use `ProviderConfig.fake()` and `"fake-planning-model"`.
  - Evidence: `lib/muse/llm/model_router.ex` doctests/examples include `config = Muse.LLM.ProviderConfig.fake()` and expectations around `"fake-planning-model"`.

### 3.4 Real Providers Exist

- An OpenAI-compatible real provider exists.
  - Evidence: `lib/muse/llm/openai_compatible_provider.ex` defines `Muse.LLM.OpenAICompatibleProvider` and declares `@behaviour Muse.LLM.Provider`.
- An Anthropic provider exists.
  - Evidence: `lib/muse/llm/anthropic_provider.ex` defines `Muse.LLM.AnthropicProvider` and declares `@behaviour Muse.LLM.Provider`.
- OpenRouter and Ollama are represented as provider configuration defaults.
  - Evidence: `Muse.LLM.ProviderConfig` contains `openrouter_defaults/2` and `ollama_defaults/2`.
- Anthropic is represented as a provider configuration default.
  - Evidence: `Muse.LLM.ProviderConfig.anthropic_defaults/2` sets id `"anthropic"`, name `"Anthropic"`, base URL, wire API, auth, streaming support, and tool support.

## 4. Real Provider Details Found So Far

### 4.1 OpenAI-Compatible Provider

- File: `lib/muse/llm/openai_compatible_provider.ex`.
- Module: `Muse.LLM.OpenAICompatibleProvider`.
- Behavior: implements `Muse.LLM.Provider`.
  - Evidence: file declares `@behaviour Muse.LLM.Provider`.
- It supports non-streaming completion.
  - Evidence: `complete/2` builds a chat-completions request via `RequestBuilder.build_chat_completions/1`, attaches auth, posts with `Req.post/2` by default, decodes the HTTP response, and validates non-empty output.
- It supports streaming dispatch.
  - Evidence: `stream/2` dispatches to:
    - `stream_responses_ws/2` for Responses WebSocket transport
    - `stream_responses_sse/2` for Responses SSE transport
    - `stream_sse/2` for Chat Completions SSE transport
    - `stream_non_streaming/2` otherwise
- It supports Chat Completions SSE.
  - Evidence: `stream_sse/2` builds a streaming request with `RequestBuilder.build_chat_completions_stream/1`, uses `SSEParser`, decodes chunks with `ChatCompletionsStreamDecoder.feed/2`, emits provider events, and finalizes with `ChatCompletionsStreamDecoder.finalize/1`.
- It supports OpenAI Responses SSE.
  - Evidence: `stream_responses_sse/2` uses `ResponsesMapper.to_payload(request) |> Map.put("stream", true)` and decodes events with `ResponsesStreamDecoder.feed/2`.
- It has a Responses WebSocket branch, but the WebSocket path currently requires injection of a `ws_stream_fn`.
  - Evidence: `resolve_ws_stream_fn/1` returns `{:error, {:ws_stream_fn_required, "WebSocket streaming requires a ws_stream_fn to be provided"}}` if no function is supplied.
- It has SSE fallback logic for WebSocket setup failures.
  - Evidence: `ws_fallback_to_sse?/1`, `ws_should_fallback_to_sse?/3`, and `fallback_to_responses_sse/2` exist.
- It attaches authorization through `Muse.Auth.Resolver`.
  - Evidence: `attach_auth/3` calls `Resolver.resolve(request, opts)` unless an explicit Authorization header is already present.
- It redacts/sanitizes errors.
  - Evidence: `redact_error/1`, `safe_summary/1`, `EventPayloadRedactor`, and `MetadataSanitizer` are used before provider errors are emitted or returned.
- It validates empty responses.
  - Evidence: `validate_non_empty_response/1` returns `{:error, {:provider_empty_response, metadata}}` when there is no content and no tool calls.
- It decodes tool calls from Chat Completions responses.
  - Evidence: `decode_tool_calls/1`, `decode_tool_call_list/1`, and `decode_tool_call/2` parse `choices[0].message.tool_calls` into `Muse.LLM.ToolCall` structs.

### 4.2 Anthropic Provider

- File: `lib/muse/llm/anthropic_provider.ex`.
- Module: `Muse.LLM.AnthropicProvider`.
- Behavior: implements `Muse.LLM.Provider`.
  - Evidence: file declares `@behaviour Muse.LLM.Provider`.
- It uses the Anthropic Messages API.
  - Evidence: module docs say `Anthropic Messages API provider adapter implementing Muse.LLM.Provider`.
- Its `stream/2` currently performs non-streaming replay rather than true token streaming.
  - Evidence: module docs state: `stream/2 currently performs a non-streaming POST and replays normalized events (full-response replay).`
- It authenticates with Anthropic-specific headers.
  - Evidence: `append_x_api_key_header/2` adds `{"x-api-key", credential.value}` and `ensure_version_header/1` adds `{"anthropic-version", "2023-06-01"}`.
- It uses `Muse.Auth.Resolver` for credential resolution.
  - Evidence: `resolve_and_attach_auth/3` calls `Resolver.resolve(request, opts)`.
- It supports injected `post_fn` / `http_post` for tests.
  - Evidence: `resolve_post_fn/2` checks `opts[:post_fn]`, `request.options[:post_fn]`, and `request.options[:http_post]` before defaulting to `Req.post/2`.
- It decodes Anthropic tool calls from content blocks.
  - Evidence: `decode_anthropic_messages/1` calls `extract_tool_calls(content_blocks)` and builds a normalized `Muse.LLM.Response` with `tool_calls`.

## 5. Provider Configuration Findings

- `Muse.LLM.ProviderConfig` supports provider capability flags.
  - Evidence: `supports_structured_outputs?/1` and `supports_tools?/1` exist.
- Tool support can be overridden via environment.
  - Evidence: `maybe_set_tools/2` reads `MUSE_TOOLS` and uses `parse_tools/1`.
- Structured-output support can be overridden via environment.
  - Evidence: `maybe_set_structured_outputs/2` reads `MUSE_STRUCTURED_OUTPUTS` and uses `parse_structured_outputs/1`.
- Transport can be configured safely.
  - Evidence: `parse_transport/1` accepts only known values: `"none"`, `"sse"`, and `"websocket"` or known atoms.
- Wire API can be configured safely.
  - Evidence: `parse_wire_api/1` accepts `"responses"`, `"chat_completions"`, and `"anthropic_messages"` or known atoms.
- Unknown provider strings are handled without creating atoms.
  - Evidence: `parse_provider/1` maps known strings through `@known_provider_strings` and returns `:unknown` instead of calling `String.to_atom/1`.

## 6. Model Loading / `.code_puppy` Findings

- No implemented `.code_puppy` model source was found in the files inspected so far.
  - Evidence: repository searches were performed for `.code_puppy`, `code_puppy`, `CODE_PUPPY`, `/model`, `/model_settings`, and `MUSE_MODEL`; no runtime `.code_puppy` model loader was identified during the partial investigation.
- `.code_puppy` appears to be mentioned as a desired direction in planning documentation rather than implemented runtime behavior.
  - Evidence: `FINAL_MUSE_APP_PLAN.md` was inspected and references `.code_puppy` as a target/future direction.
- Current model selection appears to come from environment/config defaults and provider-specific static catalogs rather than `.code_puppy`.
  - Evidence: `Muse.LLM.ProviderConfig.resolve_model/2` reads environment variables such as `MUSE_MODEL`, `MUSE_OPENROUTER_MODEL`, `MUSE_OLLAMA_MODEL`, and `MUSE_ANTHROPIC_MODEL`.
- Fake model names are currently hardcoded.
  - Evidence: `resolve_model(:fake, env_map)` falls back to `"fake-planning-model"`.
- Provider model listing appears to rely on provider status/catalog logic rather than `.code_puppy`.
  - Evidence: `lib/muse/llm/provider_status.ex` was inspected during command/provider review and includes known-model behavior; `/provider models` was found in command handling.

## 7. Slash Command Findings

- Slash command handling exists.
  - Evidence: `lib/muse/commands.ex` and `lib/muse/command_dispatcher.ex` were inspected.
- Provider commands exist.
  - Evidence: command review found provider commands including `/provider status` and `/provider models`.
- Agent/muse commands exist.
  - Evidence: command review found `/muses`, `/agents`, and `/handoff` paths.
- `/agents` appears to be implemented as an agent/muse listing or switching-related command, but needs deeper validation before final conclusions.
  - Evidence: `/agents` was found while inspecting `lib/muse/commands.ex` and `lib/muse/command_dispatcher.ex`.
- `/handoff <muse_id>` exists for explicit agent/muse handoff.
  - Evidence: handoff handling was found in `lib/muse/command_dispatcher.ex` and linked to `Muse.Conductor` / `Muse.SessionRouter` behavior.
- `/model` and `/model_settings` were not yet confirmed as fully implemented slash menus.
  - Evidence: repository search and command review did not yet identify a clear `/model` or `/model_settings` implementation comparable to the discovered provider and agent commands.
- Current model listing path appears to be `/provider models`, not the requested `/model` menu.
  - Evidence: provider command review found `/provider models`; current model source appears tied to `ProviderStatus.known_models/1` rather than `.code_puppy`.

## 8. Streaming Findings

- CLI streaming infrastructure exists.
  - Evidence: `lib/muse/cli/stream_printer.ex` was inspected.
- Streaming/event publication is connected to session execution.
  - Evidence: `lib/muse/session_router.ex` and `lib/muse/session_server.ex` were inspected as part of tracing output and turn flow.
- OpenAI-compatible real streaming exists.
  - Evidence: `Muse.LLM.OpenAICompatibleProvider.stream/2` dispatches to SSE and Responses streaming implementations.
- Chat Completions SSE rendering is event-based.
  - Evidence: `stream_sse/2` emits `Event.response_started()`, then emits decoded events from `ChatCompletionsStreamDecoder.feed/2`, then emits final events from `ChatCompletionsStreamDecoder.finalize/1`.
- Non-streaming replay also emits canonical events.
  - Evidence: `stream_non_streaming/2` calls `emit_response_events/2`, which emits `response_started`, assistant delta/completed events, tool-call events, and `response_completed`.
- The current CLI output likely does not yet expose the full execution trace required by the target behavior.
  - Evidence: current stream-printer investigation showed output around assistant deltas/final assistant output and turn completion, while the target requires explicit user prompt, selected model, selected agent, agent changes, tool calls, tool results, errors, final answer, and safe execution summary.

## 9. Tool Calling Findings

- Tool-call event types exist at the provider-event level.
  - Evidence: `Muse.LLM.FakeProvider` emits `Event.tool_call_started(tool_call)` and `Event.tool_call_completed(tool_call)` for scripted tool calls.
- The OpenAI-compatible provider decodes provider tool calls.
  - Evidence: `decode_tool_calls/1`, `decode_tool_call_list/1`, and `decode_tool_call/2` in `lib/muse/llm/openai_compatible_provider.ex` parse tool calls into `Muse.LLM.ToolCall` structs.
- Non-streaming replay emits tool-call started/completed events from response tool calls.
  - Evidence: `emit_response_events/2` iterates `response.tool_calls`, emits `Event.tool_call_started(tool_call)`, then `Event.tool_call_completed(tool_call)`.
- There is not yet enough evidence from the partial investigation to confirm that actual local tool execution results are always printed clearly to the user.
  - Evidence: provider events show tool-call request/completion at the LLM event layer, but the final execution-loop and tool-runner output still need deeper inspection.

## 10. Agent / Muse Switching Findings

- Agent-like profiles are represented as muse profiles.
  - Evidence: inspected files include `lib/muse/muse_registry.ex` and `lib/muse/muse_profile.ex`.
- A conductor module exists for handoff/switching coordination.
  - Evidence: `lib/muse/conductor.ex` was inspected.
- Explicit handoff appears to be supported.
  - Evidence: `/handoff <muse_id>` command handling was found and connects to `Muse.Conductor.request_handoff/complete_handoff` and `Muse.SessionRouter.set_active_muse/2`.
- Active muse/agent selection is session-related.
  - Evidence: `lib/muse/session_router.ex` and `lib/muse/session_server.ex` were inspected while tracing active-agent/session behavior.
- Manual switching likely exists through `/handoff` and/or `/agents`, but automatic switching during a running execution turn still needs confirmation.
  - Evidence: command and conductor files show explicit handoff behavior; the full turn-loop behavior still needs deeper review.
- Agent switching visibility is likely incomplete for the target behavior.
  - Evidence: current CLI streaming review did not yet show a complete visible execution trace containing `[agent:switch]`-style events.

## 11. Current Biggest Blockers Found So Far

1. Fake provider is still the default runtime provider.
   - Evidence: `Muse.LLM.ProviderConfig.build_from_env/2` falls back to `"fake"` when `MUSE_PROVIDER` is not set.
2. Fake model defaults still exist in production configuration paths.
   - Evidence: `resolve_model(:fake, env_map)` falls back to `"fake-planning-model"`.
3. `.code_puppy` does not appear to be implemented as the canonical model source.
   - Evidence: no runtime `.code_puppy` loader was found during searches/inspection; current model resolution uses environment variables and provider status/catalog logic.
4. `/model` and `/model_settings` are not yet confirmed as implemented menus.
   - Evidence: command review found `/provider models`, `/muses`, `/agents`, and `/handoff`, but not a clear implementation of requested `/model` and `/model_settings` menus.
5. Full visible execution trace output is not yet present.
   - Evidence: streaming/event output exists, but the CLI output reviewed so far appears focused on assistant output and turn completion, not the full target timeline of prompt/model/agent/tool/agent-switch/error/final events.

## 12. Early Simplification Direction

The eventual simplification plan should likely focus on these concrete changes:

1. Make `muse` the single documented and packaged entrypoint.
   - Use existing evidence from `mix.exs` escript config and `bin/muse`.
   - Verify install/build workflow so `muse` is available without `mix` commands.
2. Remove fake provider from normal runtime defaults.
   - Change `ProviderConfig.build_from_env/2` so missing provider does not silently become `fake`.
   - Keep `Muse.LLM.FakeProvider` only for tests if tests depend on it.
3. Choose one real runtime provider path.
   - Candidate real provider: `Muse.LLM.OpenAICompatibleProvider`, because it already supports real SSE streaming and tool-call decoding.
   - Anthropic exists, but its `stream/2` currently performs non-streaming replay according to module docs.
4. Implement or wire a `.code_puppy` loader.
   - It should become the canonical model source for startup, `/model`, and `/model_settings`.
   - It should reject or hide fake/demo models in normal runtime.
5. Implement reliable `/model` and `/model_settings` menus.
   - `/model` should display models loaded from `.code_puppy`.
   - `/model_settings` should edit supported settings for the selected real provider/model.
6. Make `/agents` and handoff behavior visibly update the session.
   - Existing `/handoff` and conductor/session-router pieces should be reused if appropriate.
7. Expand visible CLI execution trace output.
   - Safe trace should include user prompt, selected model, selected agent, agent switches, tool calls, redacted tool args/results, streaming assistant output, errors, final answer, and a concise execution summary.
   - This must not expose hidden/private chain-of-thought.

## 13. What Still Needs Investigation Before the Full Plan

The following areas were identified but not fully completed before this findings snapshot:

- Exact `Muse.CLI.Main` argument parsing and install path behavior.
- Full contents and behavior of `Muse.SessionServer` and `Muse.SessionRouter` during multi-turn execution.
- Actual tool execution modules and whether tool results are appended back into the conversation loop.
- Exact command implementation details for `/agents` and whether it confirms/persists switches.
- Whether `/model` or `/model_settings` exist under another route/name.
- Test coverage around fake provider, provider config defaults, streaming, commands, agents, and tools.
- Documentation alignment in `README.md`, `PLAN.md`, and `FINAL_MUSE_APP_PLAN.md`.
- Environment-variable assumptions for the intended real provider.
- Build/deployment/install assumptions for making `muse` easy to launch.
