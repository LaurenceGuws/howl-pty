# howl-pty

PTY-backed child transport library for Howl.

`howl-pty` owns process transport state: child I/O, lifecycle/result truth, resize delivery, wait/kick behavior, and typed control signals. It does not parse terminal data or own host event loops.

## Embedding surfaces

- Native Zig module: `howl_pty`
- Native root: `src/howl_pty.zig`
- C header: `include/howl_pty.h`
- C exports: `howl_pty_*`
- C root: `src/libhowl_pty.zig`

The native Zig model is the primary development surface. The C ABI remains
available as language-neutral glue while it continues to earn its maintenance
cost.

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
