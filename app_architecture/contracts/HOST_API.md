# Host Session API Contract

## Scope

This contract defines the stable public surface exposed to host applications via `howl-session`.
It governs what host implementations may depend on and what constitutes a breaking change.

## Stable Surface

All symbols listed below are exported from `src/root.zig` and are part of the frozen host-facing API.

### Types

| Symbol | Kind | Stability |
| --- | --- | --- |
| `Session` | struct | stable |
| `SessionConfig` | struct | stable |
| `SessionStatus` | enum | stable |
| `ControlSignal` | enum | stable |
| `Transport` | interface struct | stable |
| `MemTransport` | concrete implementation | stable |
| `FailTransport` | test implementation | stable (test scope) |

### `SessionConfig` Required Fields

| Field | Type | Constraint |
| --- | --- | --- |
| `allocator` | `std.mem.Allocator` | required |
| `cols` | `u16` | non-zero |
| `rows` | `u16` | non-zero |
| `pending_capacity` | `usize` | non-zero |
| `transport` | `?Transport` | optional; default null |

### `Session` Required Methods

| Method | Signature | Notes |
| --- | --- | --- |
| `init` | `(Config) error{InvalidConfig}!Session` | allocates; validates config |
| `deinit` | `(*Session) void` | releases all session resources |
| `start` | `(*Session) anyerror!void` | activates session; may delegate to transport |
| `stop` | `(*Session) void` | deactivates session; always succeeds |
| `feed` | `(*Session, []const u8) error{OutOfMemory,QueueFull}!void` | queues bytes |
| `apply` | `(*Session) usize` | drains queue; returns count |
| `reset` | `(*Session) void` | clears queue |
| `resize` | `(*Session, u16, u16) anyerror!void` | updates dims + notifies transport |
| `control` | `(*Session, ControlSignal) void` | records signal + routes to transport |

### `Session` Observability Fields

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | `SessionStatus` | current lifecycle state |
| `cols` | `u16` | current terminal width |
| `rows` | `u16` | current terminal height |
| `resize_count` | `u32` | wrapping counter; increments per valid resize |
| `last_control_signal` | `?ControlSignal` | last signal seen by session; null if none |

### `ControlSignal` Variants

`hangup`, `interrupt`, `terminate`, `resize_notify`

### `SessionStatus` Variants

`idle`, `active`, `stopped`

## Breaking Change Rules

The following changes to the stable surface are breaking and require a major version bump or explicit host implementation migration:

- Removing or renaming any exported symbol above.
- Removing or renaming a `SessionConfig` field without a default.
- Removing or renaming a `Session` method.
- Changing a method's parameter types or return error set in a non-additive way.
- Removing a `ControlSignal` or `SessionStatus` variant.
- Removing an observability field.

The following changes are NOT breaking:

- Adding new methods to `Session`.
- Adding new `ControlSignal` or `SessionStatus` variants.
- Adding new optional `SessionConfig` fields with defaults.
- Adding new transport implementation types.
- Internal implementation changes that preserve observable behavior.

## Non-Goals

- Owning or exposing SDL/window/input/renderer types.
- Owning terminal semantic types.
- Providing host app policy or packaging.
- Providing compatibility shims or fallback paths for removed symbols.
