# Review Summary

- **Mode**: commit (tip of main)
- **Target**: c58c564 "feat: support model configs + OAuth from ~/Documents/.muse (and MUSE_CONFIG_DIR)"
- **Files reviewed**: 8 (lib/muse/config_dir.ex new + 6 updated + README + beads + test)
- **Diff stats**: 299 insertions, 64 deletions (from git show)
- **Issue counts**: 2 bugs, 4 suggestions, 3 nits (from detailed review)

## Top issues

[bug] config_dir.ex:37 -- MUSE_CONFIG_DIR="" (empty) silently resolves to CWD via Path.expand, causing init to pollute project root
[bug] config_dir.ex:91 -- ensure_dir_exists/0 is dead/unwired; ProfileLoader uses raising mkdir_p! instead of error-returning paths
[suggestion] profile_loader.ex:105 -- ensure_initialized uses ! APIs that can crash callers despite :: :ok spec
[suggestion] resolver.ex:24 -- stale module docstring still claims :openai_oauth is unsupported
[suggestion] no tests -- zero coverage for ConfigDir discovery, precedence, or 0-arity ProfileLoader under multi-dir scenarios
[nit] config_dir.ex -- ~/Documents/.muse candidate is unconditional on all OSes (creates Documents/ on Linux/Windows)
[nit] project_rules.ex -- global rules still hard-coded to ~/.muse, inconsistent with new config dir

See the full review at: /tmp/grok-review-5ee40550.md

Project context: Working tree clean on main (up-to-date with origin). Quality gates (format, compile --warnings-as-errors) pass. Large completed safety/performance work (O(n) everything, silent-rescue removal, bounds, persistence). 2 new bugs filed from this review (muse-asd, muse-d61) for the ConfigDir issues. 3 in_progress elsewhere (muse-2bp ToolLoop, muse-1rq a11y). The reviewed feature is a solid incremental addition with minor polish needed before heavy reliance.
