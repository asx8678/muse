# Muse Troubleshooting Guide

## Quick Diagnostics

- `muse --version` — verify installation
- `muse --help` — list all CLI flags
- `/provider status` — check provider configuration
- `/auth status` — check API key/auth status
- `/diagnostics` — view diagnostic events

## Common Issues

### "Provider error" in chat

Check provider connectivity: `/provider status`
Check API key: `/auth status`
Check model name: `/provider models`

### Server won't start

- Port already in use: try `--port 4101` or different port
- Missing secret key base (prod): set `MUSE_SECRET_KEY_BASE`
- Dependency issues: run `mix deps.get`

### Escript won't run

- Ensure Erlang/Elixir installed
- TUI mode unavailable in escript (NIF limitation)
- Use Mix release for TUI support

### Session not restoring

- Sessions persist in `.muse/sessions/`
- Check disk space and permissions
- Retention policy may have evicted old sessions

## Debug Flags

- `MUSE_TELEMETRY_EXPORT=stdout` — emit telemetry to stdout
- `MUSE_PROVIDER_CONNECTIVITY_CHECK=true` — verify provider reachability
- `mix muse.smoke` — run HTTP smoke assertions

## Log File Locations

- Session data: `.muse/sessions/<session_id>/`
- Telemetry export (if configured): path set in `MUSE_TELEMETRY_FILE`
- Crash dumps: `erl_crash.dump` (in working directory)
