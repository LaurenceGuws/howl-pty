# Test Hygiene Baseline - howl-session

## Overview

Session and transport layer. Manages lifecycle, I/O queuing, and host-transport integration.

## Test Entrypoints

| Entrypoint | Status | Count | Classification |
| --- | --- | --- | --- |
| `zig build test` | ✓ passing | 140 | Package-aware; primary authority |
| Direct file `zig test src/session/core.zig` | ✗ fails | - | Import context (../../types, vt_core) |

## Test Failure Classification

**Module-path/import-context**: 
- Direct file testing fails: core.zig imports `../transport.zig`, `../../types.zig`, `vt_core` (--dep)
- Test files reference helper modules that aren't available in direct-file context

**Dependency wiring**:
- `vt_core` passed via `--dep` in build.zig; not accessible to direct zig test
- transport_api (internal module) requires build context

**libc/platform gating**: None observed

**Test/assertion regressions**: None observed

## Direct-File Test Limitations

Files with cross-module dependencies cannot run via direct `zig test`:
- `src/session/core.zig` - imports transport_api, vt_core
- `src/session.zig` (facade) - aggregates core and depends on external modules

Only self-contained files or files with local-only imports would pass direct testing.

## Architecture Safety Notes

- No platform types in core APIs ✓
- No fallback/shim paths detected ✓
- Cross-module imports are clean (types, vt_core) ✓
- I/O direction invariants enforced (no fallback to engine feed on transport error) ✓

## Files Structure

- `src/root.zig` - Public API facade
- `src/session.zig` - Module aggregator
- `src/session/core.zig` - Core lifecycle and I/O
- `src/transport/` - Transport abstraction (interface, implementations)
- `src/test_support/` - Testing helpers and conformance harnesses

## Test Coverage Breakdown

(From 140 passing tests)

- Session lifecycle (init, start, stop): ~15 tests
- Feed/apply/reset queue semantics: ~25 tests
- Transport delegation and error handling: ~30 tests
- Resize and control operations: ~20 tests
- Regression tests (I/O direction, engine consistency): ~10 tests
- Conformance checkpoints: ~5 tests
- Performance and reliability harnesses: ~30 tests
- Transport implementations (MemTransport, PartialTransport, UnixPtyTransport): ~20 tests

## Known Intentional Limits

- Direct-file testing requires facade module wrapper (TH-2 candidate)
- FailTransport intentionally always fails (test fixture)
- PartialTransport simulates write backpressure (testing helper)

## Pending Fixes (from RC batch)

- RC-FIX-1: Removed transport write-error fallback; apply() now preserves pending on error
- RC-FIX-2: Transactional resize (engine creation atomic)

## Status

Ready for TH-2 (file-testability normalization): Consider local facade wrapper for direct-file testing of core semantics. Current package-aware approach is primary and sufficient.
