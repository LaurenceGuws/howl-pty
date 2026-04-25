# Session API Contract

## Scope

This contract defines lifecycle and ownership boundaries for `howl-session`.
It does not define SDL types, renderer types, or terminal semantics.

## Types

### `ControlSignal`

Typed enum of control signals routable to the transport layer:
- `hangup` — transport peer disconnect equivalent (SIGHUP)
- `interrupt` — interrupt signal equivalent (SIGINT)
- `terminate` — graceful termination equivalent (SIGTERM)
- `resize_notify` — window resize notification (SIGWINCH)

### `SessionStatus`

Typed enum of observable session states:
- `idle` — session initialized, no active transport
- `active` — transport running
- `stopped` — transport stopped; session awaiting deinit or restart

### `TransportClass`

Typed enum of transport implementation classes (informational; not part of session runtime):
- `posix_pty` — POSIX PTY transport for Linux and macOS hosts
- `container_bridge` — Container bridge transport for Android, iOS, and platform-managed containers
- `conpty` — ConPTY transport for Windows hosts (future)

See `TRANSPORT_PORTABILITY.md` for platform abstraction details and transport class semantics.

## Ownership Boundaries

- `howl-session` owns session lifecycle and transport orchestration.
- Terminal semantics are external to this module; session consumes terminal-core public APIs only.
- Host apps own SDL/window/input/renderer concerns; session is host-neutral.

## Config Fields

| Field | Type | Constraint | Meaning |
| --- | --- | --- | --- |
| `allocator` | `std.mem.Allocator` | required | Allocator for all session-owned memory |
| `cols` | `u16` | non-zero | Initial terminal width in columns |
| `rows` | `u16` | non-zero | Initial terminal height in rows |
| `pending_capacity` | `usize` | non-zero | Maximum byte capacity of the in-memory pending queue |

## State Machine

```
init
 │
 ▼
idle ──start()──► active ──stop()──► stopped
                              ▲          │
                              └─start()──┘
                              (restart)

Any state ──deinit()──► (destroyed)
```

### Allowed Transitions

| From | Event | To | Notes |
| --- | --- | --- | --- |
| `idle` | `start()` | `active` | normal activation |
| `active` | `start()` | `active` | returns `error.AlreadyStarted`; no state change |
| `active` | `stop()` | `stopped` | normal deactivation |
| `idle` | `stop()` | `stopped` | safe; transport not called |
| `stopped` | `stop()` | `stopped` | idempotent; transport not called |
| `stopped` | `start()` | `active` | restart; transport.start() is called |
| any | `deinit()` | (destroyed) | only on successfully initialized handle |

### Repeated Call Behavior

- `start()` from `active`: returns `error.AlreadyStarted`; transport is not called.
- `stop()` from `idle` or `stopped`: sets status to `stopped`; transport is not called.
- `start()` from `stopped`: restart path; transport.start() is called; transitions to `active` on success.
- `feed/apply/reset`: valid in any state between init and deinit; no status check.
- `control`: valid in any state between init and deinit; routes to transport if attached.

## Lifecycle Boundaries

### init

- Caller provides allocator and configuration (opaque to host toolkit).
- Returns a `Session` handle.
- Does not start PTY, transport, or terminal engine; init only allocates and validates config.
- Error on invalid config (`cols == 0`, `rows == 0`, or `pending_capacity == 0`); no partial-init state is observable.
- Post-condition: `status == .idle`.

### start

- Signature: `start() anyerror!void`
- From `idle` or `stopped`: activates session; delegates to `transport.start()` if attached.
- From `active`: returns `error.AlreadyStarted` immediately; transport is not called; status unchanged.
- On success, `status` transitions to `active`.
- If transport start fails, the error is propagated and `status` remains unchanged.

### stop

- Signature: `stop() void`
- From `active`: deactivates session; delegates to `transport.stop()`.
- From `idle` or `stopped`: transport is not called; `status` transitions to `stopped`.
- `status` always transitions to `stopped` on return.
- Idempotent when already `stopped`.

### deinit

- Releases all session-owned resources.
- Caller must only call deinit on a successfully initialized session handle.
- Must be called exactly once per successful init.
- No callbacks fire after deinit returns.

## Feed / Apply / Reset Boundaries

### feed

- Signature: `feed(bytes: []const u8) error{OutOfMemory, QueueFull}!void`
- Caller delivers raw input bytes into the session.
- Session appends bytes to the in-memory pending queue; no terminal semantic interpretation.
- Overflow check is atomic: if `pending.len + bytes.len > pending_capacity`, returns `error.QueueFull` and no bytes are written.
- Returns `error.OutOfMemory` if queue allocation fails; caller must handle.
- Call only valid between init and deinit; calling outside this window is a contract violation.

### apply

- Signature: `apply() usize`
- With attached transport: attempts `transport.write(pending)` and drains only the written prefix.
- With no transport attached: feeds pending bytes directly to the engine and drains in full.
- Returns count of bytes drained in this call; returns 0 if queue was empty or write made no progress.
- Caller drives apply; session does not self-trigger application.

### reset

- Signature: `reset() void`
- Clears the in-memory pending queue; no terminal engine state is modified.
- Safe to call at any point between init and deinit.

## Resize / Control Boundaries

### resize

- Signature: `resize(cols: u16, rows: u16) anyerror!void`
- Dimensions must be non-zero; zero-dimension resize returns `error.InvalidDimensions` and no state changes.

**Sequencing guarantee:**
1. `cols` and `rows` are updated on the session (authoritative).
2. `resize_count` is incremented (wrapping) to mark a new resize epoch.
3. Transport is notified via `transport.resize()` if attached.

- Steps 1 and 2 occur unconditionally for any valid (non-zero) resize call; transport failure does not roll them back.
- A resize to the same current dimensions still increments `resize_count` and notifies transport.
- Transport errors are propagated; the session dims and counter are already committed.

**Repeated-call semantics:**
- Resize to same dims repeatedly: each call increments `resize_count` and notifies transport. No special casing.
- Resize after invalid attempt: previous invalid resize (zero dims) left session unchanged; next resize starts fresh.

**Transport failure post-conditions:**
- Session dims are authoritative: not rolled back even if transport.resize() fails.
- `resize_count` is committed: incremented before transport notification.
- Dims remain observable through `cols` and `rows` fields; count through `resize_count`.

### control

- Signature: `control(signal: ControlSignal) void`
- Caller delivers a typed `ControlSignal` value.

**Sequencing guarantee:**
1. `last_control_signal` is updated on the session.
2. Transport is notified via `transport.control()` if attached.

- Step 1 always occurs; transport attachment is not required for the session to record the signal.
- Fire-and-forget: no error channel; transport.control() is void.
- No terminal semantic reinterpretation; signal semantics are transport-defined.

**Repeated-call semantics:**
- Control signal recorded on every call: `last_control_signal` is overwritten with the latest signal.
- Multiple identical signals: each call records and routes the signal; no deduplication or coalescing.
- Control before start/after stop: signal is recorded and transport.control() is called; before-start behavior is transport-defined (may be no-op or queued).

**Transport independence:**
- Signal is always recorded, regardless of transport attachment or transport failure.
- Transport.control() is void: no error channel; call is fire-and-forget.
- Session remains in consistent state; all session-observable state (last_control_signal) is committed.

## Observability Fields

| Field | Type | Meaning |
| --- | --- | --- |
| `resize_count` | `u32` | Increments (wrapping) on every valid resize call; zero at init |
| `last_control_signal` | `?ControlSignal` | Last control signal delivered to session; null at init |

## Error Boundaries

### start() transport failure

- If `transport.start()` returns an error, the error is propagated to the caller.
- `status` remains unchanged (does not transition to `active`).
- The session is left in a consistent state; retry via `start()` is valid.

### resize() transport failure

- If `transport.resize()` returns an error, the error is propagated to the caller.
- Session `cols` and `rows` are retained at the new values; session dims are authoritative regardless of transport outcome.
- Caller receives the transport error as evidence of notification failure, not a dimension rejection.

### read/write delegation (future)

- When session gains explicit read/write delegation, failure post-conditions will follow the same pattern: propagate error, leave session queue state unchanged.
- Placeholder: no session queue mutation occurs on a failed delegation.

## Host-Facing API Surface (Frozen)

### Exported Root Symbols

Hosts access the following symbols exclusively via `root.zig`:
- `session` — module re-export from `session.zig`
- `Session` — opaque session handle type
- `SessionConfig` — configuration struct
- `ControlSignal` — enum of control signal variants
- `SessionStatus` — enum of observable session states
- `TransportClass` — enum of transport implementation classes (informational)
- `transport` — module re-export from `transport.zig`
- `Transport` — virtual interface for transport adapters
- `MemTransport` — in-memory test adapter
- `FailTransport` — failure-injection test adapter
- `UnixPtyTransport` — Unix PTY production adapter

### Session Type Observable Interface

Hosts observe the following fields and call the following methods on `Session`:

**Observable Fields (read-only from host perspective):**
- `status: SessionStatus` — current session state
- `cols: u16` — current terminal width
- `rows: u16` — current terminal height
- `resize_count: u32` — resize epoch counter
- `last_control_signal: ?ControlSignal` — most recent control signal

**Methods (host calls; no internal re-implementation allowed):**
- `init(config: SessionConfig) !Session` — initialize session
- `deinit(self: *Session) void` — release session resources
- `start(self: *Session) anyerror!void` — activate transport
- `stop(self: *Session) void` — deactivate transport
- `feed(self: *Session, bytes: []const u8) error{OutOfMemory, QueueFull}!void` — queue input
- `apply(self: *Session) usize` — attempt pending flush and report drained count
- `reset(self: *Session) void` — clear pending queue
- `resize(self: *Session, cols: u16, rows: u16) anyerror!void` — notify resize
- `control(self: *Session, signal: ControlSignal) void` — route control signal

### SessionConfig Type Interface

Hosts provide and observe the following fields:

| Field | Type | Required |
| --- | --- | --- |
| `allocator` | `std.mem.Allocator` | yes |
| `cols` | `u16` | yes |
| `rows` | `u16` | yes |
| `pending_capacity` | `usize` | yes |
| `transport` | `?Transport` | no (optional) |

### Transport Adapter Interface

Transport implementations are bound through `Transport.VTable` and must match:

- `start(ptr: *anyopaque) anyerror!void`
- `stop(ptr: *anyopaque) void`
- `write(ptr: *anyopaque, bytes: []const u8) anyerror!usize`
- `read(ptr: *anyopaque, buf: []u8) anyerror!usize`
- `resize(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void`
- `control(ptr: *anyopaque, signal: ControlSignal) void`

### Breaking-Change Rules

The following changes constitute breaking changes to the host API:

1. **Removing or renaming exported symbols** in `root.zig`
2. **Removing or renaming fields** in `Session`, `SessionConfig`, `ControlSignal`, or `SessionStatus`
3. **Changing method signatures** (parameters, return types, or error unions) on `Session`
4. **Removing or renaming variants** in `ControlSignal`, `SessionStatus`, or `TransportClass` enums
5. **Removing or changing transport vtable methods** (`Transport.start`, `.stop`, `.write`, `.read`, `.resize`, `.control`)
6. **Changing method semantics** in ways that would alter observable behavior from a host's perspective

The following changes are **not** breaking:

- Adding new exported symbols
- Adding new optional fields to `SessionConfig`
- Adding new enum variants to `ControlSignal`, `SessionStatus`, or `TransportClass`
- Changing internal module structure (e.g., moving implementation between sub-modules) if public symbols and signatures remain stable
- Improving error handling or diagnostics

## Stop Conditions

Engineer must stop and report if any API boundary requires:
- terminal-core semantic changes to satisfy the session contract.
- SDL or renderer types to express any session API parameter or return value.
