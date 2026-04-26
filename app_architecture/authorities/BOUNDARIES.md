# Howl Session Boundary Authority

## Hard Boundaries

- Owns session lifecycle and transport orchestration only.
- Must expose host-neutral APIs; no SDL, Android, window, or renderer types.
- Consumes the `howl-vt-core` public API only; no core internals.
- Must stay reusable by the primary terminal boundary and by advanced direct
  consumers.

## Forbidden Coupling

- No rendering concerns in session runtime.
- No window/input toolkit ownership.
- No app-level multiplexing or host workspace policy.
- No backend semantic rewrites for transport convenience.

