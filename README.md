# howl-pty

PTY-backed child transport library for Howl.

`howl-pty` owns process transport state: child I/O, lifecycle/result truth, resize delivery, wait/kick behavior, and typed control signals. It does not parse terminal data or own host event loops.

## Public ABI

- Header: `include/howl_pty.h`
- Exported symbols: `howl_pty_*`
- Public root: `src/libhowl_pty.zig`

Internal Zig files are not host integration surfaces.

## Build

```sh
zig build check
zig build test
```

## Boundary

- PTY owns transport and child process interaction.
- VT owns terminal semantics.
- Hosts own launch policy, event loops, wake scheduling, and presentation.

See `design.md` for the current owner map and invariants.
