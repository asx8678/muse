# Muse — Provider Health, Model Routing, and Error Troubleshooting

> **Phase 3 documentation** for provider/model routing UX and resilience features.

---

## Slash Commands

### `/provider status`

Reports the current configured provider's health and configuration status.

```
> /provider status
Provider: Fake Provider
Status: ok (fake/offline)
Model: fake-planning-model
Auth: none required
Config source: env
```

For a configured non-fake provider:

```
> /provider status
Provider: OpenRouter
Status: configured (not verified)
Model: anthropic/claude-3.5-sonnet
Auth: api_key
Wire API: chat_completions
Transport: sse
Config source: env
```

For a misconfigured provider:

```
> /provider status
Provider: unknown
Status: misconfigured
Validation errors:
  - unknown provider: "nonexistent" (parsed as :unknown). Known: [:fake, :openai_compatible, :openrouter, :ollama, :anthropic]
Hint: Review provider configuration. Use /auth status to check credentials.
```

**Safety:** This command never makes network calls by default. To opt in to a connectivity check, set `MUSE_PROVIDER_CONNECTIVITY_CHECK=true` in your environment.

### `/provider models`

Lists known models for the currently configured provider, marking the current model with `← current`.

```
> /provider models
Known models for OpenRouter (openrouter):
  - anthropic/claude-sonnet-4-20250514  (Claude Sonnet 4 (via OpenRouter))
  - anthropic/claude-3.5-sonnet  (Claude 3.5 Sonnet (via OpenRouter)) ← current
  - openai/gpt-4o  (GPT-4o (via OpenRouter))
  - openai/gpt-4o-mini  (GPT-4o Mini (via OpenRouter))
```

**Note:** This is a static catalog of well-known models. It does not make API calls to discover models. Set `MUSE_PROVIDER` and `MUSE_MODEL` to configure your provider and model.

---

## Provider Error Messages

Muse classifies provider errors into actionable categories with user-friendly messages and hints:

| Category | HTTP Status | Retryable | Example Hint |
|---|---|---|---|
| `:auth` | 401, 403 | No | Check your API key with: /auth status |
| `:rate_limit` | 429 | Yes | Wait and retry, reduce request frequency |
| `:invalid_model` | 404 | No | Check available models with: /provider models |
| `:invalid_request` | 400 | No | May be a model capability mismatch |
| `:timeout` | — | Yes | Try increasing MUSE_LLM_TIMEOUT_MS |
| `:connection` | — | Yes | Check network connection and base URL |
| `:server` | 5xx | Yes | Transient provider-side issue, retry in a few seconds |
| `:quota` | 402 | No | Check provider account billing status |
| `:context_length` | — | No | Reduce conversation length or use larger context model |
| `:unknown` | — | No | Check /auth status and /provider status |

All error messages are secret-safe — they never contain API keys, bearer tokens, or other sensitive values.

---

## Retry and Backoff

Muse includes a bounded exponential backoff helper for transient provider failures:

- **Base delay:** 1000ms (1 second)
- **Multiplier:** 2 (exponential)
- **Max delay:** 30,000ms (30 seconds)
- **Jitter:** ±20% of computed delay (prevents thundering herd)
- **Max retries:** from `ProviderConfig.max_retries` (default: 2, 0 for fake)

When this helper is wired into a call path, only **retryable** error categories are retried:
- Rate limits (429)
- Timeouts
- Connection errors
- Server errors (5xx)

**Non-retryable** errors (auth, invalid model, invalid request, quota) should never be retried — retrying would produce the same failure.

Configure max retries via `MUSE_LLM_MAX_RETRIES` environment variable.

**Runtime note:** `Muse.LLM.Retry` is a reusable helper and only applies where a provider call path explicitly wraps an operation with it. Provider transports may also pass `max_retries` to their underlying HTTP client where supported. User-facing output should not claim an individual request was retried unless that specific call path reports retry activity.

---

## Startup Config Validation

Muse validates provider configuration at startup and emits diagnostics for common misconfigurations:

- Unknown provider identifiers
- Missing required model for non-fake providers
- Missing base URL for network providers
- Missing API key environment variable (warning only)

Diagnostics are emitted to the Diagnostics GenServer and visible via `/diagnostics`.

---

## External Provider Tests

Integration tests for real (external) LLM providers are available but **excluded by default** from `mix test`. They require valid API keys and make actual network calls.

To run external provider tests:

```bash
mix test --include external_provider
```

Required environment:
- `MUSE_PROVIDER` set to a non-fake provider
- Appropriate model env var (e.g., `MUSE_OPENROUTER_MODEL`)
- API key env var (e.g., `MUSE_OPENROUTER_API_KEY`)

**Safety:** These tests NEVER run in CI or during normal `mix test`. The default test suite uses only the fake/offline provider.
