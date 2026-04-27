# Howl Session Active Queue

## Current State

M5 complete (M5-A + M5-B). Current gate is live-host revalidation via the shared
terminal boundary (`howl-term`, currently `howl-term-surface`). M6+ planning does
not start until live-host pressure identifies real conformance gaps.
Transport-facing changes in this lane must preserve parity accounting across
POSIX PTY (Linux), Android bridge pressure, and future ConPTY expectations.

## Read Before Execution

- `app_architecture/authorities/SCOPE.md`
- `app_architecture/authorities/MILESTONE.md`
- `docs/architect/MILESTONE_PROGRESS.md`
- `app_architecture/contracts/API.md`

## M2 + M3 + M4 Closure Batches

### M2-R (Topology Refactor)
| Ticket | Status | Commit | Intent |
| --- | --- | --- | --- |
| `M2-R1` | done | `0cc48b4` | Transport Topology Split |
| `M2-R2` | done | `ada5d7f` | Session Topology Split |
| `M2-R3` | done | `9d0a463` | Root/API Integrity and Wiring |
| `M2-R4` | done | `8b16b01` | Queue Closeout (refactor batch) |

### M2-C (PTY Closure)
| Ticket | Status | Commit | Intent |
| --- | --- | --- | --- |
| `M2-C1` | done | `e4594f4` | Unix PTY Contract Closure |
| `M2-C2` | done | `e272829` | Unix PTY Evidence Hardening |
| `M2-C3` | done | `93b4461` | M2 Closeout and Queue Advance |

### M3-A (Lifecycle Safety)
| Ticket | Status | Commit | Intent |
| --- | --- | --- | --- |
| `M3-A1` | done | `5ff6ce7` | Lifecycle Contract Closure |
| `M3-A2` | done | `b8f4aff` | Lifecycle Enforcement (verified in-place) |
| `M3-A3` | done | `093c811` | Lifecycle Evidence Tests + Queue Closeout |

### M4-A (Resize and Control Flow)
| Ticket | Status | Commit | Intent |
| --- | --- | --- | --- |
| `M4-A1` | done | `c2d522d` | Resize/Control Contract Closure |
| `M4-A2` | done | `57a8dc4` | Resize/Control Enforcement Audit (verified correct) |
| `M4-A3` | done | `b9bb00e` | Resize/Control Evidence Tests + Queue Closeout |

## M5-A (Host Integration Readiness - Contract Closure)
| Ticket | Status | Commit | Intent |
| --- | --- | --- | --- |
| `M5-A1` | done | `d5c9e49` | Host API Contract Closure |
| `M5-A2` | done | `9ea48b7` | Root/API Conformance Tests |
| `M5-A3` | done | `5d21d46` | Queue Closeout + M5 Progress Lock |

## LMVP-R (Recovery Batch - Defect Fixes)
| Ticket | Status | Commit | Intent |
| --- | --- | --- | --- |
| `LMVP-R1` | done | `f06c6da` | Session I/O direction fix (outbound vs inbound) |
| `LMVP-R2` | done | `067c495` | Session resize consistency (engine dims) |
| `LMVP-R4` | done | `66e2c41` | Session regression tests + evidence |

## LMVP-RC (Quality Correction Batch)
| Ticket | Status | Intent |
| --- | --- | --- |
| `LMVP-RC1` | done | Partial-write correctness (apply respects transport.write() return) |
| `LMVP-RC2` | done | Session.resize transactional safety (engine creation atomic) |
| `LMVP-RC3` | done | Surface.resize transactional safety (cells_buf allocation atomic) |
| `LMVP-RC4` | done | Surface contract/code drift resolution (SurfaceConfig.session, docs) |
| `LMVP-RC5` | done | Defect-to-test trace table and evidence documentation |

## TH (Test Hygiene) - Cross-Repo Quality Round

| Ticket | Status | Intent |
| --- | --- | --- |
| `TH-1` | done | Baseline test inventory (TEST_HYGIENE_MATRIX.md) |
| `TH-2` | done | File-testability assessment (cross-module tests require zig build) |
| `TH-3` | done | VS Code debug config (tasks.json, launch.json) |
| `TH-4` | done | Platform gating verification (explicit Linux guard on unix_pty tests) |

## TH (Test Hygiene) Closeout

**Phase complete.** Package-context test authority: `zig build test` (140 tests passing). Known intentional limits: cross-module tests require build context.

## M5-B (Integration Rules and Multi-Host Support - Bounded)

| Ticket | Status | Commit | Intent | Target | Change Type |
| --- | --- | --- | --- | --- | --- |
| `M5-B1` | done | `96bac9c` | Host implementation rule guide | `docs/architect/HOST_SESSION_LOOP_CONTRACT.md` | Documentation (new) |
| `M5-B2` | done | `e9985eb` | Session async loop envelope | `src/ops/host_loop.zig` | New module |
| `M5-B3` | done | `8a634a9` | Integration test fixture | `src/conformance/host_integration_test.zig` | New module |
| `M5-B4` | done | (this commit) | Queue closeout and evidence | (commit only) | Documentation + test validation |

### M5-B Scope (Complete)
- Host integration envelope (async loop, event model, error recovery)
- Session lifecycle coordination with host
- Minimal SDL host binding (integration test fixture, not production)
- Cross-session resize and async rules

### M5-B Closure Summary
**All tickets complete.** Host implementation rule and integration scaffolding established:
- **B1**: Documented ordering guarantees (feed → apply → feedProcessOutput) with error handling guide
- **B2**: Implemented host_loop.tick() utility (6 unit tests, 146→152 test count)
- **B3**: Validated rule end-to-end with 11 integration tests (MemTransport, PartialTransport, lifecycle)
- **Evidence**: docs/engineer/M5_B_EVIDENCE.md (artifact mapping, test delta, validation results)
- **Status**: Ready for M6 Conformance Evidence phase

### M5-B Known Intentional Limits
- No production host implementations in session repo (host repo responsibility)
- No platform-specific code (host repos handle SDL, Android, browser bindings)
- No optimization of loop latency or throughput (scope deferred to M7)
- Integration fixture is deterministic and test-only (no timers, no external I/O)
- No API signature changes to session core (host_loop is envelope utility, not core subsystem)

### M5-B Non-Goals
- Multi-host production implementations (host repo responsibility)
- Platform-specific integration (deferred to per-host repos)
- Optimization of loop latency or throughput

### M5-B Stop Conditions (Not Triggered)
- ✓ No changes to Session vtable or core API
- ✓ No platform types in session/core modules
- ✓ No external (non-Zig) dependencies

Guardrail: One ticket per commit. Mandatory validation per ticket:
- `zig build`
- `zig build test`
- `rg -n "compat[^ib]|fallback|workaround|shim" --glob '*.zig' src`
- `test ! -f src/main.zig`
- `find src -maxdepth 1 -type f -name '*.zig' | rg -n 'src/(conformance|ops|perf|reliability|snapshot)\.zig' || true`
