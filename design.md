# Design

Shared rules: [`../design/design-rules.md`](../design/design-rules.md)

## Purpose
`howl-pty` owns PTY-backed child transport orchestration.

It does not model terminal semantics. It owns queueing, transport start and stop, transport reads and writes, resize propagation, and transport selection.

## Public Surface
- The only shipped embedding contract is `include/howl_pty.h` plus `howl_pty_*` exported symbols.
- The only public root that may export that contract is `src/libhowl_pty.zig`.
- Opaque session handles plus typed status, snapshot, pump, and read structs are the public ABI.
- `src/howl_pty.zig` is not an embedding surface. If it survives, it is repo-local only.
- Internal workspace wiring is not a public contract and is not a preservation target.
- Accepted cleanup results now locked:
  - `src/session_namespace.zig` is deleted
  - the Zig-shaped host facade posture in `src/pty.zig` is removed
  - the Zig-shaped aggregation posture in `src/howl_pty.zig` is removed

```mermaid
classDiagram
    class HowlPtyAbi
    class Session {
      +init()
      +start()
      +stop()
      +publishHostInput()
      +flushOutboundInput()
      +waitReadable()
      +ingestTransport()
      +resize()
      +snapshot()
    }
    class OwnedPty {
      +init()
      +deinit()
      +pty()
      +class()
    }
    class Pty

    HowlPtyAbi --> Session
    Session --> Pty
    OwnedPty --> Pty
```

## Ownership Rules
- `Session` owns pending outbound input, current size, lifecycle state, and transport-facing counters.
- `OwnedPty` owns the concrete selected PTY implementation and cleanup.
- `Session` talks to the abstract `Pty` interface only.
- Test PTY variants are for repo-local conformance testing only.
- Concrete platform PTY implementations stay internal to `howl-pty`; host transport ownership stays behind `Session` and the C ABI.

## Lifecycle
```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Active: start()
    Active --> Stopped: stop()
    Active --> Stopped: transport failure
    Idle --> Stopped: stop()
    Stopped --> [*]
```

## Main Flows
### Host Input To PTY
```mermaid
sequenceDiagram
    participant Host
    participant S as Session
    participant P as Pty

    Host->>S: publishHostInput(bytes)
    Host->>S: flushOutboundInput()
    S->>P: write(bytes)
```

### PTY Output To Host Consumer
```mermaid
sequenceDiagram
    participant Host
    participant S as Session
    participant P as Pty
    participant Sink

    Host->>S: waitReadable(timeout)
    S->>P: waitReadable(timeout)
    Host->>S: ingestTransport(buf, sink)
    S->>P: read(buf)
    S->>Sink: onTransportBytes(bytes)
```

## API Contracts
- `howl_pty_session_init` returns an opaque owned session handle; callers must eventually call `howl_pty_session_deinit`.
- `howl_pty_session_start`, `howl_pty_session_stop`, `howl_pty_session_wait_readable`, and `howl_pty_session_read` cover the host transport lifecycle and read path.
- `howl_pty_session_publish_signal` publishes one typed PTY control signal from the shipped `HowlPtyControlSignal` contract.
- `howl_pty_session_publish_input` queues host input, and `howl_pty_session_pump_outbound` advances the bounded outbound step.
- `howl_pty_session_pending_bytes` and `howl_pty_session_bytes_applied` expose bounded transport accounting to hosts.
- `howl_pty_session_resize` and `howl_pty_session_snapshot` cover geometry and state observation.
- `HowlPtySessionStatus` and `HowlPtyControlSignal` are shipped header-declared contract values.
- Hosts and embedders consume that ABI through the header and exported symbols only.
- Zig root imports are not an acceptable host integration path and are not a preservation target.

## Internal Owner API
- `Session.initPty` is repo-local owner API for build-selected transport construction.
- It is not part of the shipped C ABI contract.

## Non-Goals
- Terminal parsing or screen state.
- Font or rendering concerns.
- Host event loops.

## Change Rules
- Keep the embedding boundary C ABI first in docs, roots, and build wiring.
- Delete wrapper namespace roots instead of preserving parallel Zig public stories.
- Concrete PTY implementations must stay behind `OwnedPty` and `Pty`.
- Queue policy belongs in `Session`, not in hosts.
- New transport variants should preserve the same owner/interface split.
