# Code Review: c58c564 "feat: support model configs + OAuth from ~/Documents/.muse (and MUSE_CONFIG_DIR)"

**Review mode:** commit (latest on main)  
**Date of review:** 2026-05-20  
**Reviewer:** Grok (subagent code review)  
**Files changed (per diff):** .beads/issues.jsonl, README.md, lib/muse/auth/codex_cache.ex, lib/muse/auth/resolver.ex, lib/muse/auth/status.ex, lib/muse/config_dir.ex (new), lib/muse/llm/profile_loader.ex, test/muse/auth/resolver_test.exs

## Summary

The change introduces `Muse.ConfigDir` to support a new precedence for user-level LLM profiles/secrets (`config.json`/`secrets.json`) and OpenAI OAuth material (`auth.json`): `MUSE_CONFIG_DIR` env > `~/Documents/.muse` > `~/.muse`. It wires the discovery into `ProfileLoader` (all default paths now delegate), enables the previously-stubbed `:openai_oauth` auth mode in `Resolver` (reusing `CodexCache` with explicit path), updates `CodexCache` default probing to try classic `~/.codex` then the Muse config dir location, and refreshes status messages/README. 

Overall the implementation is correct for the stated scope, maintains backwards compatibility for users with only `~/.muse`, and reuses existing Codex JSON parsing/permission logic cleanly. Dominant risk areas are: (1) incomplete test coverage of the new discovery/precedence logic and `ConfigDir` itself, (2) a latent bug in `candidates/0` when `MUSE_CONFIG_DIR` is set to the empty string (pollutes cwd), (3) `ensure_dir_exists/0` being dead code while `ProfileLoader` duplicates directory creation with raising `!` APIs, and (4) limited symlink/permission hardening and cross-platform considerations for the new `~/Documents/.muse` candidate (always present, even on Linux/Windows). The project shows good maturity in redaction, error safety, and incremental auth evolution, but the PR would benefit from dedicated unit tests before relying on the feature in production multi-dir setups.

No critical correctness regressions for classic `~/.muse` users; the diff + full file reads confirm all profile-loading call sites were updated.

## Issues

### Issue 1 -- Severity: bug
- File: /Users/adam2/projects/muse/lib/muse/config_dir.ex:37
- Description: `candidates/0` only rejects `nil` for `MUSE_CONFIG_DIR` (`explicit = System.get_env(...)`). An empty string (`MUSE_CONFIG_DIR=""`) or whitespace value is kept, passed through `Path.expand("")` (resolves to CWD), placed first in the list, and used by `preferred_init_dir/0` (via `hd/0`) and `config_dir/0`. This causes `ProfileLoader.ensure_initialized/0` (and subsequent writes) to create `config.json`/`secrets.json` in the current working directory instead of a user config location. `has_config_json?/1` on CWD will also match a stray `config.json` there.
- Suggestion: Filter empty/whitespace values: `Enum.reject(&(&1 in [nil, ""]))` (or trim + reject blank). Add validation or fallback in `preferred_init_dir/0` and document that `MUSE_CONFIG_DIR` must be a non-empty absolute or tilde path. Add a guard test.
- Status: open

### Issue 2 -- Severity: bug
- File: /Users/adam2/projects/muse/lib/muse/config_dir.ex:91 (and callers)
- Description: `preferred_init_dir/0` does `candidates() |> hd() |> Path.expand()`. While the list is currently never empty (always includes expanded `~/Documents/.muse` and `~/.muse`), `hd/0` on an empty list crashes. More importantly, `ensure_dir_exists/0` (which uses it) is exported and documented but **never called** anywhere in the source (grep found 0 call sites outside the module). `ProfileLoader.ensure_initialized/2` duplicates `mkdir_p!` logic instead of delegating.
- Suggestion: Either remove the dead `ensure_dir_exists/0` (or wire it into `ProfileLoader` before the `!` calls) or make `preferred_init_dir` robust (`List.first(candidates()) || fallback`). Replace `!` APIs in ProfileLoader with error-returning paths so init failures are reported rather than raising (update its `@spec` too).
- Status: open

### Issue 3 -- Severity: suggestion
- File: /Users/adam2/projects/muse/lib/muse/config_dir.ex:101 (has_config_json?), 299 (config_dir), 337 (candidates)
- Description: Discovery relies on `File.exists?/1` (which follows symlinks and returns `false` on permission errors without surfacing them). No `realpath` hardening (unlike `prompt/project_rules.ex:147`), no readability test, and no check that the found `config.json` is a regular file. A symlink `~/Documents/.muse -> /sensitive` or an unreadable `config.json` (exists but `EACCES`) would cause the probe to claim "present" and later `load/1` to fail with a raw FS error. `has_config_json?` also accepts any binary (no type check on input dir).
- Suggestion: Consider `File.regular?/1` + try `File.read/1` (or at least `File.stat` + access check) for probes. Document symlink risks. Align with security.md workspace rules if user config dirs ever need equivalent hardening.
- Status: open

### Issue 4 -- Severity: suggestion
- File: /Users/adam2/projects/muse/lib/muse/llm/profile_loader.ex:105 (ensure_initialized/2), 106 (mkdir_p!), 381 (write!), and config_dir.ex:117
- Description: `ensure_initialized` (both arities) and internal `init_*_file` use `mkdir_p!` / `write!` / `chmod!` which raise on FS errors (permission denied, disk full, read-only FS). The public `@spec ensure_initialized() :: :ok` (and 2-arity) promises only `:ok`; callers (CLI startup, application boot, `Muse` init) can crash instead of receiving `{:error, reason}`. `chmod 0o600` is already best-effort (`_ =`), but mkdir/write are not. `ensure_dir_exists/0` returns `{:error, term()}` but is unused.
- Suggestion: Make the 2-arity return `{:ok, :ok} | {:error, term()}` (or `{:ok, paths}`), catch/translate the `!` exceptions, and update all 0-arity wrappers + docs. Have `ProfileLoader` call `ConfigDir.ensure_dir_exists/0` (or inline equivalent) before file creation.
- Status: open

### Issue 5 -- Severity: suggestion
- File: /Users/adam2/projects/muse/lib/muse/auth/resolver.ex:24 (module docstring)
- Description: The `@moduledoc` still states ":openai_oauth — currently unsupported and returns a clear error". The implementation (lines 89-90, 153-168) now fully supports it via `resolve_openai_oauth` + `ConfigDir.oauth_path()`. Stale docs can mislead readers/maintainers.
- Suggestion: Update the supported auth modes list and any other outdated references (e.g., "OpenAI OAuth auth is not supported yet" was removed from the error path but lingers in prose).
- Status: open

### Issue 6 -- Severity: suggestion
- File: /Users/adam2/projects/muse/test/muse/auth/resolver_test.exs:128 (and entire test suite); absence of tests in profile_loader_test.exs and no `test/muse/config_dir_test.exs`
- Description: The only change to resolver tests updates the oauth case to expect `:no_token` (correct). However, there are **no tests** exercising `Muse.ConfigDir` (candidates, precedence, `has_config_json?`, `MUSE_CONFIG_DIR` env, Documents vs home), the new 0-arity `ProfileLoader.get_profile/0` / `merged_env/0` / `ensure_initialized/0` under discovery, or multi-dir scenarios (e.g., config.json present only in `~/Documents/.muse`, or both locations). All existing profile_loader tests use explicit 2/3-arity paths. 2-arity convenience overloads (deriving secrets.json sibling) are exercised but not the discovery core.
- Suggestion: Add a `ConfigDirTest` (or expand profile_loader_test) covering: (a) env var override, (b) Documents precedence when it has `config.json`, (c) fallback to `~/.muse` when Documents lacks it, (d) empty env var case, (e) `oauth_path()` / `CodexCache` default probe integration. Use temp dirs + env mocking (`with_env` or `System.put_env` in setup).
- Status: open

### Issue 7 -- Severity: nit
- File: /Users/adam2/projects/muse/lib/muse/config_dir.ex:274 (docs), 39 (code), and README.md:53
- Description: `~/Documents/.muse` is unconditionally the #2 candidate on every platform (Linux, Windows, etc.). On non-macOS systems `~/Documents` may not conventionally exist for config; `mkdir_p!` during `ensure_initialized` will create `~/Documents/.muse` (and parent `Documents`) as a side effect. Docs/README correctly note it is "macOS / iCloud-friendly" but the implementation always includes it.
- Suggestion: Either gate the Documents candidate behind `System.get_env("MUSE_DOCUMENTS_MUSE")` or `os.type` heuristic, or clearly document the cross-platform creation side-effect. Consider adding `XDG_CONFIG_HOME` or `~/.config/muse` as an additional Linux-friendly candidate in a follow-up.
- Status: open

### Issue 8 -- Severity: nit
- File: /Users/adam2/projects/muse/lib/muse/prompt/project_rules.ex:129 (and diagnostics/storage.ex:15)
- Description: Hard-coded `~/.muse/{MUSE.md,rules.md,AGENTS.md}` and `~/.muse/diagnostics/` remain for global rules and diagnostic logs. These bypass `ConfigDir` entirely (as expected per commit scope, which targeted only "model configs + OAuth"). However, this creates inconsistency: users who adopt `~/Documents/.muse` for profiles will still need a separate `~/.muse` tree for rules/diagnostics.
- Suggestion: (Future) Unify rules + diagnostics under `ConfigDir` too, or expose `ConfigDir` helpers so `project_rules` and `diagnostics/storage` can optionally honor the same precedence. Update architecture.md (which still references old `~/.muse/config.toml` plans).
- Status: open

### Issue 9 -- Severity: nit
- File: /Users/adam2/projects/muse/lib/muse/config_dir.ex:252 (safe_path_label in codex_cache), 229 (status.ex oauth_lines)
- Description: `safe_path_label` uses a heuristic `String.contains?(path, ".muse")` + "auth.json" to produce the redacted label `"~/.muse/auth.json (or Documents/.muse)"`. The label is approximate (never reports the actual resolved `Documents` path) and the oauth status text is similarly generic. Not a correctness problem but reduces diagnostic precision when the effective dir is `MUSE_CONFIG_DIR` or Documents.
- Suggestion: Store the resolved dir or make `safe_path_label` take/return a more precise "Muse config dir" label. Minor.
- Status: open

## Additional Observations (no severity)

- **Backwards compatibility**: Verified correct. When only `~/.muse/config.json` exists, `has_config_json?` will skip the (absent) Documents candidate and select `~/.muse`. Classic Codex path is still tried first in `CodexCache`.
- **CodexCache integration**: `default_probe_paths/0` + `try_paths/1` (swallow only `enoent`/`no_token`) and the mapping in `resolve_openai_oauth` are well-reasoned and preserve prior error semantics for explicit paths.
- **No other bypasses for profile loading**: All `ProfileLoader` entry points (load, get_profile, apply, merged_env, ensure) now go through `ConfigDir`. `runtime_provider.ex:96` benefits automatically via `merged_env/0`.
- **Permission model**: `secrets.json` 600 + warning logic unchanged and still applied. `auth.json` inherits Codex permission checks.
- **Build hygiene**: Change touches only intended modules; format/compile expectations from the beads issue description should pass.

The review file is at `/tmp/grok-review-5ee40550.md`. All cited paths are absolute within the workspace. The changes are solid for an incremental feature but would be stronger with the test and error-handling improvements noted.