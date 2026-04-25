# Howl Session Active Queue

## Current State

LMVP-RC quality correction batch complete. All defects resolved and validated. Queue ready for M5-B planning.

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

## M5-B Planning (Integration Patterns and Multi-Host Support)

Queue definition pending. Planned scope:
1. Define host adapter interface and contract
2. Add integration patterns guide (async loop, error handling, resize coordination)
3. Plan conformance patterns for multiple host types

Guardrail: One ticket per commit. Mandatory validation per ticket:
- `zig build`
- `zig build test`
- `rg -n "compat[^ib]|fallback|workaround|shim" --glob '*.zig' src`
- `test ! -f src/main.zig`
- `find src -maxdepth 1 -type f -name '*.zig' | rg -n 'src/(conformance|ops|perf|reliability|snapshot)\.zig' || true`
