# Howl Session Milestone Authority

This document defines high-level milestones from scaffold to long-term target.
It is intentionally non-implementation-detailed.

## Milestone Ladder

| ID | Name | Outcome |
| --- | --- | --- |
| `M0` | Repo Scaffold | Package compiles, tests run, authority/docs baseline exists. |
| `M1` | Session API Foundation | Stable public session API with explicit lifecycle contracts. |
| `M2` | Transport Foundation | Transport contract plus Unix PTY/process implementation path is deterministic and bounded. |
| `M3` | Lifecycle Safety | Startup/shutdown/restart/error boundaries are explicit and tested. |
| `M4` | Resize and Control Flow | Resize/control paths are deterministic and contract-backed. |
| `M5` | Host Integration Readiness | Host-facing API is stable for multiple host implementations. |
| `M6` | Conformance Evidence | Session behavior equivalence checks are reproducible and frozen. |
| `M7` | Performance Discipline | Session loop latency and resource bounds are measured and enforced. |
| `M8` | Reliability Hardening | Long-run stability and failure recovery are production-grade. |
| `M9` | Operational Surface | Diagnostics, observability, and release policy are stable. |
| `M10` | Best-in-Class Session Runtime | Session runtime quality is top-tier in correctness and operations. |

## Current Target

Current target is live-host revalidation against the primary terminal boundary.
The local ladder remains valid, but the next real gaps are determined by SDL and
Android host pressure through the shared `howl-term` boundary.
