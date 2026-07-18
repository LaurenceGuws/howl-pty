# howl-pty Design

Updated: 2026-05-30.

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../project-memory.md`](../project-memory.md), [`../libs.yaml`](../libs.yaml)

## Purpose

`howl-pty` owns PTY-backed child transport orchestration.

It owns PTY variants, child I/O, resize delivery, control signals, wait/kick behavior, lifecycle/result truth, and transport state. It does not model terminal semantics, host event loops, VT parsing, rendering, or presentation.

## Embedding Surfaces

- The primary development contract is the `howl_pty` Zig module rooted at `src/howl_pty.zig`.
- The language-neutral contract is `include/howl_pty.h` plus exported `howl_pty_*` symbols.
- `src/libhowl_pty.zig` is the C ABI export root.
- Private implementation modules remain repo-local owners rather than direct embedding targets.
- This private project has no compatibility promise while its native owner boundaries mature.

## Owners

- `src/ffi.zig` translates the C ABI only.
- `src/session.zig` owns session lifecycle, queued host input, current geometry, transport state, counters, and lifecycle/result snapshots.
- `src/pty.zig` owns the internal PTY interface used by `Session`.
- `src/pty/posix.zig` owns POSIX PTY realization.
- `src/pty/unix.zig` owns Unix backend details behind the PTY interface.
- `src/pty/pty_test.zig` owns repo-local test PTY behavior only.

## Main Flow

1. Host initializes PTY session state through the native model or an opaque C ABI handle.
2. Host starts the session with host-owned launch policy and startup geometry.
3. Host publishes input bytes and pumps bounded outbound writes.
4. Host or a host wait thread waits for readability through the PTY ABI.
5. Host reads transport bytes and feeds them to VT.
6. Host resizes the session when render/VT geometry changes.
7. Host publishes typed control signals through the ABI.
8. Host stops/deinitializes the session and observes typed lifecycle/result truth.

## Invariants

- Session owns queued outbound input until transport accepts it.
- Startup geometry is session-owned and applied before child steady state.
- Wait/kick is a PTY-owner seam; hosts must not tear down transport just to break a wait.
- Child shell environment policy such as `TERM` is host-owned and inherited by PTY launch.
- Concrete PTY implementations stay internal behind `Session` and `Pty`.
- ABI results must distinguish lifecycle/transport truth instead of collapsing everything into booleans.

## Non-Goals

- Terminal parsing or screen state.
- Host input/event loops.
- Fonts, rendering, or presentation.
- Shell prompt customization.
