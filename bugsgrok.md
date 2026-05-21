# Grok Review Bugs – Muse Project

**Review ID**: 5ee40550  
**Reviewed commit**: `c58c564` — "feat: support model configs + OAuth from ~/Documents/.muse (and MUSE_CONFIG_DIR)"  
**Review date**: 2026-05-20  
**Reviewer**: Grok (via reviewer persona + subagent)  
**Scope**: Latest tip on `main` (clean tree, up-to-date with `origin/main`). Focused review of the new `Muse.ConfigDir` feature and its integration, plus broader project health signals from the diff, source reads, and existing docs.

This file captures issues found during a structured code review of the Muse project. The two highest-severity bugs were also filed as official `bd` issues (per project rules) for tracking and resolution.

**Full detailed review artifacts** (persisted in repo):
- `docs/reviews/review-5ee40550.md` — complete structured findings
- `docs/reviews/review-5ee40550-summary.md` — one-page executive summary
- (Temporary copies also existed in `/tmp/` during the session)

---

## Critical Bugs (Filed in bd)

### muse-asd (P1 — bug)
**Title**: ConfigDir: `MUSE_CONFIG_DIR=""` (empty) resolves to CWD and pollutes project root

**File**: `lib/muse/config_dir.ex:37`

**Description**:
In `Muse.ConfigDir.candidates/0`, `System.get_env("MUSE_CONFIG_DIR")` is only filtered for `nil`:
```elixir
explicit = System.get_env("MUSE_CONFIG_DIR")
...
[explicit, docs, home]
|> Enum.reject(&is_nil/1)
```
An empty string (`MUSE_CONFIG_DIR=""`) or whitespace value is kept, `Path.expand("")` resolves to the current working directory, and it becomes the first (highest-precedence) candidate. `preferred_init_dir/0` uses `hd/0` on the list, and `config_dir/0` + `ProfileLoader.ensure_initialized/0` will therefore create `config.json`, `secrets.json`, and `auth.json` inside the user's CWD (commonly the Muse repo root or any directory where `mix muse` or profile loading is invoked).

`has_config_json?/1` will also happily match a stray `config.json` in the current directory.

**Risk**: Data pollution of working trees, accidental creation of config files in the wrong place, silent surprising behavior when users experiment with the env var.

**Suggestion**:
- Filter blank values: `Enum.reject(&(&1 in [nil, ""] or String.trim(&1) == ""))`
- Add validation / loud fallback in `preferred_init_dir/0` and `config_dir/0`
- Document that `MUSE_CONFIG_DIR` must be a non-empty path
- Add a dedicated test case for the empty-env scenario

**Status**: open (bd issue `muse-asd`, priority P1)

---

### muse-d61 (P2 — bug)
**Title**: ConfigDir/ProfileLoader: `ensure_dir_exists/0` is dead code; init uses raising `mkdir_p!`/`write!` despite `:: :ok` spec

**Files**:
- `lib/muse/config_dir.ex:114` (`ensure_dir_exists/0`)
- `lib/muse/llm/profile_loader.ex:105` (`ensure_initialized/2` and helpers)

**Description**:
- `ConfigDir.ensure_dir_exists/0` is public, documented (`@spec ... :: :ok | {:error, term()}`), and uses `preferred_init_dir()`, but **has zero call sites** outside the module (grep confirmed).
- `ProfileLoader.ensure_initialized/0` and `/2` (and the internal `init_config_file` / `init_secrets_file` writers) use `File.mkdir_p!`, `File.write!`, and related bang functions. These raise on any filesystem error (permission denied, disk full, read-only FS, etc.).
- The public specs promise only `:ok` (or the 2-arity form), yet real callers (CLI startup, `Muse` initialization, `Application` boot, tests, `ensure_initialized` from the new ConfigDir path) can receive unhandled exceptions instead of structured `{:error, reason}` tuples.

This violates the error-handling and "no silent crashes" contracts established during the T0/T1 safety work (qw4 series: explicit errors, `SilentRescue` removal, bounded diagnostics, etc.). The `chmod 0o600` for `secrets.json` is already best-effort (`_ = File.chmod...`), but the directory and file creation steps are not.

**Suggestion**:
- Wire `ConfigDir.ensure_dir_exists/0` (or a non-raising variant) into `ProfileLoader` before any writes.
- Change the 0- and 2-arity `ensure_initialized` functions to return `{:ok, ...} | {:error, term()}` (or `{:ok, paths}`), catch/translate the `!` exceptions, and update all callers + docs.
- Add tests covering permission-denied and read-only scenarios.
- Either promote `ensure_dir_exists/0` or remove the now-redundant dead code.

**Status**: open (bd issue `muse-d61`, priority P2)

---

## Other Issues from the Review (Suggestions & Nits)

### Suggestion: Stale module documentation
**File**: `lib/muse/auth/resolver.ex:24` (`@moduledoc`)

The docstring still lists:
> `:openai_oauth` — currently unsupported and returns a clear error

The implementation (added in this commit: `resolve_openai_oauth/1`, delegation to `CodexCache` via `ConfigDir.oauth_path()`) now fully supports it. The old error path was removed from the resolver but the prose was not updated.

**Suggestion**: Refresh the supported auth modes list and any other outdated references.

---

### Suggestion: Missing test coverage for the new discovery logic
**Files**: No `test/muse/config_dir_test.exs`; `test/muse/llm/profile_loader_test.exs` and `resolver_test.exs` only exercise explicit-path (2-/3-arity) forms.

- Zero tests for `Muse.ConfigDir` ( `candidates/0`, precedence, `MUSE_CONFIG_DIR` override, `has_config_json?`, `oauth_path()` )
- No tests for 0-arity `ProfileLoader.get_profile/0`, `ensure_initialized/0`, `merged_env/0` under multi-directory discovery
- No scenario tests (Documents present but no `config.json`, both locations present, `MUSE_CONFIG_DIR` pointing at a populated tree, etc.)

All existing loader tests continue to pass because they pass explicit paths. The new default-path behavior is untested.

**Suggestion**: Add `ConfigDirTest` (or expand the profile loader tests) using temp directories + env mocking. Cover at minimum: env override, Documents precedence, fallback to `~/.muse`, empty env var, CodexCache integration via `oauth_path()`.

---

### Suggestion: Raising APIs in initialization paths
(See also the P2 bug above.) The `!` functions (`mkdir_p!`, `write!`) appear in `profile_loader.ex:105`, `106`, `381` (and the writers). Even after fixing the spec/return-value contract, consider whether some call sites would prefer to surface friendly errors to end users rather than let the process crash.

---

### Nit: Unconditional `~/Documents/.muse` candidate on all platforms
**File**: `lib/muse/config_dir.ex:39` (and `README.md`, module docs)

`~/Documents/.muse` is always the #2 candidate after `MUSE_CONFIG_DIR`, even on Linux and Windows where `~/Documents` is not a conventional user config location. `ensure_initialized` will happily `mkdir_p!` the entire `~/Documents/.muse` tree as a side effect.

The documentation correctly calls it "macOS / iCloud-friendly", but the implementation does not gate it.

**Suggestion**: Either make the Documents candidate opt-in (env var or `os.type` heuristic) or clearly document the cross-platform creation side-effect. Consider adding `XDG_CONFIG_HOME/muse` or `~/.config/muse` as a Linux-friendly peer candidate in a follow-up.

---

### Nit: Global rules and diagnostics still hard-coded to classic `~/.muse`
**Files**:
- `lib/muse/prompt/project_rules.ex:129` (and nearby) — `~/.muse/MUSE.md`, `rules.md`, `AGENTS.md`
- `lib/muse/diagnostics/storage.ex:15` — `~/.muse/diagnostics/`

These paths deliberately bypass `ConfigDir` (the commit scope was "model configs + OAuth" only). Users who adopt `~/Documents/.muse` for profiles/secrets/OAuth will still need a separate `~/.muse` tree for project rules and diagnostic logs. This is an inconsistency.

**Suggestion**: Future unification work — expose `ConfigDir` helpers (or a `rules_path/0` etc.) so the rules and diagnostics layers can optionally honor the same precedence. Also update stale references in `docs/architecture.md` (still mentions old `~/.muse/config.toml`).

---

### Nit: Redacted path labels are approximate for new locations
**Files**: `lib/muse/auth/codex_cache.ex:252` (`safe_path_label`), `lib/muse/auth/status.ex:229` (oauth status text)

The heuristic `String.contains?(path, ".muse")` produces the generic label `"~/.muse/auth.json (or Documents/.muse)"`. When the effective directory comes from `MUSE_CONFIG_DIR` or is the Documents variant, the displayed status is not precise.

Minor diagnostic quality issue, not a correctness problem.

**Suggestion**: Store the resolved directory or improve the label helper to say "Muse config dir (auth.json)" with the actual base when possible.

---

## Additional Positive Observations (from the review)

- Backwards compatibility is correct: when only `~/.muse/config.json` exists, `has_config_json?` skips the absent Documents candidate and selects the classic location. `CodexCache` still tries `~/.codex` first.
- All `ProfileLoader` public entry points (0-arity and convenience forms) now correctly delegate through `ConfigDir`.
- `CodexCache` multi-path probing (`default_probe_paths/0` + `try_paths/1`) only swallows "not present" errors and surfaces real parse/size/permission errors — good design.
- Permission model (600 for `secrets.json`, warnings on broad perms) and redaction logic are unchanged and still applied.
- `auth.json` for OAuth is now discoverable in the Muse config dir with the same Codex JSON shape.
- The change touches only the intended surface; format + strict compile gates pass.
- Broader project signals remain strong: hundreds of safety/performance refactors landed cleanly, 5000+ tests, disciplined use of `bd`, offline-first testing, etc.

---

## How to Use This File

- Treat `bugsgrok.md` as the canonical capture of issues discovered by Grok during project reviews.
- When a new Grok review is performed, append new sections (with a fresh Review ID header) rather than overwriting.
- High-severity items should still be filed as `bd` issues (as was done for `muse-asd` and `muse-d61`).
- Use `bd remember` for any durable cross-session insights that are *not* bugs.
- When the listed items are resolved, update their status here and close the corresponding `bd` records.
- Persist full review artifacts under `docs/reviews/review-<id>.md` (and `-summary.md`) so they survive reboots and travel with the repo.

**Last updated**: 2026-05-20 (initial population from review 5ee40550)

---

*Generated as part of a `grok review this project` session. Direct user request to file the surfaced bugs into this markdown document took precedence over the project's normal "bd-only" tracking rule for this specific artifact.*