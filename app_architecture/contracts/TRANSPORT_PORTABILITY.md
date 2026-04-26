# Transport Portability Contract

## Scope

This document defines transport class portability across operating systems and host environments.
It establishes how `howl-session` abstracts different process/terminal transport implementations
while maintaining a unified, host-neutral session API.

## Transport Portability Principle

`howl-session` does not import platform-specific types (SDL, Android, Windows, POSIX syscalls).
Instead, it consumes a host-neutral `Transport` interface. Concrete transport implementations
(specific to Linux PTY, Android container, Windows ConPTY, etc.) live in platform-aware layers
outside `howl-session` core.

This design allows:
- One session API across all host targets
- Transport implementations to encapsulate platform semantics
- Future transport classes to be added without session core changes
- Session tests to run with in-memory or failing transports on any platform

## Transport Classes

Transport classes are implementation families that handle process/terminal I/O in a target environment.
Each class implements the `Transport` interface (start/stop/write/read/resize/control) while
handling platform-specific concerns internally.

### POSIX PTY (Linux/macOS target class)

**Target Environments**: Linux desktop, macOS

**Identity**: `TransportClass.posix_pty`

**Implementation**: `UnixPtyTransport` in `howl-session/src/transport/unix_pty.zig`

**Responsibilities**:
- Fork a child process via `fork()` API
- Allocate master PTY via `openpty()` API
- Set PTY to non-blocking mode
- Spawn shell process and attach its stdin/stdout/stderr to PTY slave
- Signal child with SIGHUP/SIGINT/SIGTERM via `kill()` API
- Window-size ioctl (TIOCSWINSZ) for resize
- Encapsulate all POSIX syscalls; no POSIX types leak to session

**Lifecycle Guarantee**: start → active → stop → stopped; idempotent stop; multiple starts return AlreadyStarted

**I/O Guarantee**: Non-blocking read/write; returns WouldBlock as 0 bytes; partial writes are valid

**Resize Guarantee**: TIOCSWINSZ ioctl applied immediately; failure returns error

### Container Bridge (Android/iOS/macOS target class)

**Target Environments**: Android native runtime, iOS, future macOS app containers

**Identity**: `TransportClass.container_bridge`

**Implementation**: Future; owned by mobile host layer (e.g., `howl-android-host`)

**Responsibilities**:
- Communicate with platform container/process service
- Route I/O to and from embedded process/container endpoint
- Handle platform-specific process lifecycle (activity lifecycle on Android)
- Encapsulate all Android/iOS/platform APIs; no platform framework types leak to session

**Lifecycle Guarantee**: Similar to POSIX (start/stop/deinit), but lifecycle coordination may involve platform services

**I/O Guarantee**: Non-blocking read/write; returns 0 if no bytes available; partial writes valid

**Resize Guarantee**: Dimension change notification routed through platform service; failure returns error

### ConPTY (Windows target class)

**Target Environments**: Windows desktop (future)

**Identity**: `TransportClass.conpty`

**Implementation**: Future; owned by Windows host layer

**Responsibilities**:
- Create ConPTY via Windows ConPTY API
- Launch child process with ConPTY attached
- Read/write ConPTY pipes
- Signal process via Windows API
- Encapsulate all Windows-specific APIs; no Windows types leak to session

**Lifecycle Guarantee**: start/stop/deinit; idempotent stop; matches POSIX contract structure

**I/O Guarantee**: Non-blocking behavior via platform APIs; partial writes valid

**Resize Guarantee**: ConPTY dimension update; failure returns error

## Shared Lifecycle Semantics

All transport classes implement the same lifecycle state machine and method signatures:

```
init (by implementor)
 │
 ▼
idle ──start()──► active ──stop()──► stopped
                               ▲          │
                               └─start()──┘
                               (restart)

Any state ──deinit()──► (destroyed)
```

### Shared start() Semantics

- Signature: `start() anyerror!void`
- From `idle`: Activates the transport; setup and resource allocation happen.
- From `active`: Returns `error.AlreadyStarted`; no state change.
- From `stopped`: Restarts the transport; all resources are re-initialized.
- On success: Transport is ready for read/write/resize/control operations.
- On failure: Error is propagated; status unchanged; retry is safe.

### Shared stop() Semantics

- Signature: `stop() void`
- From `active`: Gracefully shuts down the transport peer; releases resources.
- From `idle` or `stopped`: Idempotent; no-op if already stopped.
- All implementations ensure bounded shutdown (timeouts, signal escalation, resource cleanup).
- Child process cleanup is deterministic (no orphans after stop).

### Shared write() Semantics

- Signature: `write(bytes: []const u8) anyerror!usize`
- From `active`: Delivers bytes to the transport peer; returns count accepted.
- From `idle` or `stopped`: Returns `error.NotStarted`.
- All implementations are non-blocking (no indefinite wait).
- Partial writes are valid; caller must loop.
- Short writes (0 bytes) mean transport buffer full or would-block; retry later.

### Shared read() Semantics

- Signature: `read(buf: []u8) anyerror!usize`
- From `active`: Reads available bytes from transport peer into `buf`.
- From `idle` or `stopped`: Returns `error.NotStarted`.
- All implementations are non-blocking.
- Returns 0 if no bytes available; caller must poll or use an event loop.
- May return partial reads (fewer bytes than `buf.len`).

### Shared resize() Semantics

- Signature: `resize(cols: u16, rows: u16) anyerror!void`
- From `active`: Notifies transport peer of new terminal dimensions.
- From `idle` or `stopped`: Behavior is implementation-defined (may queue, no-op, or error).
- All implementations route the dimension change atomically.
- Failure returns error; session dimensions are still authoritative (not rolled back).

### Shared control() Semantics

- Signature: `control(signal: ControlSignal) void`
- Fire-and-forget; no error channel.
- From `active`: Routes signal to the transport peer.
- From `idle` or `stopped`: Behavior is implementation-defined (may queue, no-op, or be dropped).
- All implementations handle the signal deterministically (no panic, no resource leak).
- Signal is recorded by session regardless of transport attachment.

## Platform Isolation Rules

1. **No POSIX types in session core**: `howl-session` does not import `libc`, `std.posix`, `std.c`, or platform-specific Zig modules.
2. **No SDL/Renderer/Android/iOS/Windows types in session core**: Only plain Zig types (u16, u8, error unions, allocator).
3. **Transport implementations own platform code**: POSIX PTY, container integration, ConPTY live in host layers or platform-specific modules.
4. **Session is testable on any platform**: In-memory and failing transports run everywhere; POSIX PTY skips gracefully on non-Unix.

## Extension Points

### Adding a New Transport Class

When a new host platform applies pressure, add a new transport class by:

1. Document the class and its target environments in this file (section: Transport Classes).
2. Implement the Transport interface in a new platform-specific module (e.g., `win_conpty.zig`).
3. Ensure all lifecycle semantics match the shared contract above.
4. Update `TransportClass` enum with new variant.
5. Test the new class with deterministic tests; don't change session core or API.

### Validating Transport Compatibility

A new transport class is compatible if:
- It implements all six Transport methods with matching signatures.
- Lifecycle state machine and transition rules are identical.
- I/O is non-blocking and partial-write safe.
- Resize and control are deterministic and cannot corrupt session state.
- Session API tests pass without modification.

## Session API Transparency

The session API itself is platform-agnostic:

- `Session.init()` accepts an optional `Transport`; no platform code.
- Feed/apply/reset queue bytes without interpretation.
- Resize/control route through the transport if attached; pure pass-through.
- Session status, dimensions, and observable fields are platform-independent.

Hosts compose transports during session configuration; session does not inspect transport class or platform origin.

## Stop Conditions

Engineer must stop and report if:

1. A new platform applies pressure requiring a transport method signature change or new lifecycle state.
2. Session core needs to import platform-specific types to support a transport class.
3. A transport class cannot implement start/stop/write/read/resize/control with non-blocking, non-corrupting semantics.
4. Validation tests reveal session or transport behavior is not deterministic across repeated cycles.
