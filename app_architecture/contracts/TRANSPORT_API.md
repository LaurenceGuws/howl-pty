# Transport API Contract

## Scope

This contract defines the host-neutral transport API consumed by `howl-session`.
It does not define platform specifics (PTY, pipes, sockets, or OS APIs).
It does not define terminal semantics or rendering concerns.

For transport class portability (POSIX PTY, container bridge, ConPTY, and future transports),
see `TRANSPORT_PORTABILITY.md`.

## Ownership Boundaries

- `howl-session` consumes the transport API; it does not own transport implementations.
- Concrete transport implementations (PTY, in-memory, pipe) implement this API and are owned by host or platform layers.
- Session is decoupled from all platform specifics via this API.

## Interface

The transport API is expressed as a vtable-backed interface type (`Transport`) with an opaque pointer to the concrete implementation.
Session holds an optional `?Transport`; a null transport means no transport is attached.

## Types

### `TransportError`

Error values that transport operations may return:
- `AlreadyStarted` — start called on an already-running transport
- `NotStarted` — write/read/resize called before start
- `WriteFailed` — write operation rejected by transport
- `ReadFailed` — read operation rejected by transport
- `ResizeFailed` — resize notification rejected by transport

## Transport Boundaries

### start

- Signature: `start() anyerror!void`
- Activates the transport; subsequent write/read/resize calls are valid.
- Returns `error.AlreadyStarted` if called on an active transport.

### stop

- Signature: `stop() void`
- Deactivates the transport; write/read/resize are not valid after stop returns.
- Idempotent on an already-stopped transport.

### write

- Signature: `write(bytes: []const u8) anyerror!usize`
- Delivers bytes from session to the transport peer.
- Returns count of bytes accepted; a partial write is a valid result.
- Call only valid on a started transport.

### read

- Signature: `read(buf: []u8) anyerror!usize`
- Reads bytes available from the transport peer into `buf`.
- Returns count of bytes read; returns 0 if no bytes are available (non-blocking).
- Call only valid on a started transport.

### resize

- Signature: `resize(cols: u16, rows: u16) anyerror!void`
- Delivers a terminal dimension change notification to the transport peer.
- Call only valid on a started transport.

### control

- Signature: `control(signal: ControlSignal) void`
- Routes a typed control signal to the transport peer.
- No terminal semantic reinterpretation; signal semantics are transport-defined.
- Fire-and-forget: no error channel is provided.
- Before start/after stop behavior is implementation-defined.

## Unix PTY/Process Adapter Guarantees

The Unix PTY implementation (`UnixPtyTransport`) is the canonical process-based transport implementation.

### Platform Guarantees

- Linux and macOS only; `init()` returns `error.UnsupportedPlatform` on all other targets.
- Uses system `openpty` and `fork` APIs; no fallback or emulation.

### Lifecycle Guarantees

- `start()` forks a child process, allocates a PTY master fd, sets it non-blocking, and spawns a shell.
- Multiple `start()` calls without intervening `stop()` return `error.AlreadyStarted` with no state change.
- `stop()` is idempotent: signals the child with SIGTERM, reaps with timeout, closes fds, and succeeds whether or not process had already exited.
- Child process lifecycle (SIGHUP, SIGINT, SIGTERM, SIGWINCH) is deterministic and bounded; no orphaned processes after `stop()`.

### I/O Guarantees

- `read()` is non-blocking: returns 0 if no bytes available; never blocks on started transport.
- `write()` is non-blocking: returns WouldBlock as 0 bytes written; never blocks.
- Both return `error.NotStarted` if called before `start()` or after `stop()`.
- Partial writes are valid: callers must loop.

### Resize and Control Guarantees

- `resize()` updates TIOCSWINSZ on the master fd; failure returns `error.ResizeFailed`.
- `control()` sends signals to child process; before start or after stop is safe (no-op).
- Both are deterministic and cannot corrupt transport state.

## Stop Conditions

Engineer must stop and report if any transport boundary requires:
- SDL or renderer types to express any parameter or return value.
- terminal-core semantic changes to satisfy the transport contract.
