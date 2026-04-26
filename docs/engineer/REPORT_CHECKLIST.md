# Report Checklist

Before reporting work as complete, run this checklist.

## Human Rules Self-Check (Before and After Each Batch)

### Pre-plan check

1. Re-read the Human Rules listed below.
2. State intended batch scope in one line.
3. Confirm the planned scope does not violate any rule.

Human Rules:
1. No compatibility/fallback/workaround/in-case code paths. Keep things KISS, DRY, and unambiguous.
2. Naming conventions and docstrings are treated the same way: details live in markdown; file/fn/folder/comment names stay simple, clean, and intentional.
3. `//!` rule: every `.zig` file in this repo must have a module definition doc comment in this explicit format:
   - `//! Responsibility: <what this module owns>`
   - `//! Ownership: <which lane/authority owns it>`
   - `//! Reason: <why this module exists as a boundary>`
4. `///` rule: every frozen public symbol must use concise consumer-facing docs in this explicit format:
   - `/// <intent sentence>.`
   - `/// Responsibility: <symbol responsibility>.` (only where applicable)
5. Doc-comment scope rule: `//!` and `///` comments must be short, accurate, and domain-focused. They are consumer-facing module/API documentation, not ticket tracking, historical notes, or team collaboration logs.
6. `///` and `//!` comment lines are architect/human owned unless explicitly authorized.
7. `checkins/` is read-only for agents; use it only as context.

### Post-execution check

Run:

```bash
zig build
zig build test
rg -n "compat[^ib]|fallback|workaround|shim" --glob '*.zig' src
test ! -f src/main.zig
find src -maxdepth 1 -type f -name '*.zig' | rg -n 'src/(conformance|ops|perf|reliability|snapshot)\\.zig' || true
git diff --name-only
```

Then verify:
1. Edited files match the planned batch intent.
2. No rule was violated during execution.
3. Any unavoidable scope drift is reported explicitly as a blocker.
4. No scaffold residue or misplaced test helper files were introduced.

## Build and Test

```bash
zig build
zig build test
```

Expected: both commands exit with code `0`.

## Commit Integrity

For each reported commit:

```bash
git show --name-status <hash>
```

Expected: output matches all files claimed in the report.

## Code Quality Checks

### No forbidden imports in parser/event/screen/tests

```bash
rg "app_logger|publication|ffi|android|platform|editor|workspace" --glob '*.zig' src
```

Expected: zero matches unless intentionally introduced by an approved ticket scope.

### No legacy brand strings or compat code

```bash
rg "zide|ZIDE|compat[^ib]|fallback|shim|workaround" --glob '*.zig' src build.zig
```

Expected: zero matches.

## Report Format

Include:
1. Commit hash and message
2. Files changed (from `git show --name-status`)
3. One-line claim-to-file mapping
4. Build/test validation results
