# Connecting to wafer.ai (OpenAI-Compatible Provider)

Muse can connect to [wafer.ai](https://wafer.ai) using the built-in `openai_compatible` provider. Instead of maintaining a long list of `MUSE_*` environment variables, you define generic provider profiles in `~/.muse/config.json` and keep credentials in `~/.muse/secrets.json`.

## Profile-Based Setup (Recommended)

### 1. Create the config directory and files

Muse auto-initializes both files on startup if they are missing, or you can create them manually:

```bash
mkdir -p ~/.muse
```

### 2. Edit `~/.muse/config.json`

```json
{
  "profiles": {
    "default": {
      "provider": "openai_compatible",
      "model": "gpt-4o",
      "base_url": "https://api.openai.com/v1",
      "api_key": "my_openai_key",
      "tools_enabled": true,
      "structured_outputs_enabled": true
    },
    "wafer": {
      "provider": "openai_compatible",
      "model": "glm-5.1",
      "base_url": "https://api.wafer.ai/v1",
      "api_key": "my_wafer_key",
      "tools_enabled": false,
      "structured_outputs_enabled": false
    }
  }
}
```

Field reference:

| Field | Description |
|-------|-------------|
| `provider` | Provider adapter to use (`openai_compatible`, `anthropic`, `openrouter`, `ollama`, or `fake`). |
| `model` | Model identifier sent to the provider. |
| `base_url` | Provider API endpoint. For wafer.ai this is `https://api.wafer.ai/v1`. |
| `api_key` | A **reference** to a key in `secrets.json`, an env-var reference (`${VAR}` or `$VAR`), or a literal key (discouraged). |
| `tools_enabled` | Whether native tool/function calling is supported. Set `false` for wafer.ai because it uses text-based tool markers. |
| `structured_outputs_enabled` | Whether strict structured outputs (`json_schema`) are supported. Set `false` for wafer.ai. |

### 3. Edit `~/.muse/secrets.json`

Store actual credentials here. The keys must match the `api_key` values you used in `config.json`:

```json
{
  "my_openai_key": "sk-YourOpenAIKeyHere",
  "my_wafer_key": "your_wafer_api_key"
}
```

### 4. Secure the secrets file

`~/.muse/secrets.json` contains credentials and **must not be readable by other users**. Muse sets `600` permissions automatically when it creates the file, but you should verify this manually:

```bash
chmod 600 ~/.muse/secrets.json
```

If the permissions are ever too open, Muse emits a warning on every load.

## Applying the profile

**Option A — Apply at runtime (shell or startup script):**

```bash
export MUSE_PROFILE=wafer
# Start an iex session or embed this in a startup script
mix phx.server
```

`Muse.LLM.ProfileLoader` reads `MUSE_PROFILE`, loads the matching profile from `~/.muse/config.json`, resolves `api_key` through `~/.muse/secrets.json`, and exports the standard `MUSE_*` environment variables that the rest of the app already reads.

Muse auto-initializes both files on startup if they are missing, creating sensible defaults (`default` profile with the `fake` provider and an empty secrets map).

**Option B — Pure merge (no side effects on the OS environment):**

```elixir
{:ok, env} = Muse.LLM.ProfileLoader.merged_env("wafer")
{:ok, config} = Muse.Config.llm_provider_config(env)
```

**Option C — Let Muse fall back to standard environment variables:**

If `~/.muse/config.json` does not exist, Muse safely falls back to the legacy `MUSE_*` variables shown below. This lets you keep using `.env` files or shell exports if you prefer.

## Legacy Environment-Variable Setup

If you do not want to use `~/.muse/config.json`, set the variables directly:

```bash
export MUSE_PROVIDER=openai_compatible
export MUSE_OPENAI_BASE_URL=https://api.wafer.ai/v1
export MUSE_OPENAI_API_KEY=your_wafer_api_key
export MUSE_MODEL=glm-5.1
export MUSE_TOOLS=false
export MUSE_STRUCTURED_OUTPUTS=false
```

Then start Muse normally (e.g., `mix phx.server`). The `openai_compatible` provider reads these variables at runtime and routes requests to wafer.ai automatically.

## Notes

- `MUSE_OPENAI_BASE_URL` is the key override that redirects the standard OpenAI client to wafer.ai's API.
- If you switch back to standard OpenAI, change the active profile to `default` (or set `MUSE_PROVIDER=openai_compatible` with the OpenAI base URL).
- No custom modules or code changes are needed; the provider adapter handles the rest.
- The `~/.muse/config.json` and `~/.muse/secrets.json` files are optional. If they are missing or the requested profile is not found, Muse falls back to standard environment variables.
- Keep `config.json` under version control if you like — it contains no secrets. Never commit `secrets.json`.
