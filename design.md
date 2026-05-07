# Design

Shared rules: [`../design/design-rules.md`](../design/design-rules.md)

## Purpose
`howl-session` owns terminal session I/O orchestration around a PTY transport.

It does not model terminal semantics. It owns queueing, transport start/stop, transport reads/writes, resize propagation, and transport selection.

## Public Surface
- `HowlSession`: package owner.
- `Session`: queue/lifecycle owner.
- `OwnedPty`: build-selected PTY owner.
- `Pty`: transport interface contract.
- `ControlSignal`: typed control signal vocabulary for the PTY boundary.

```mermaid
classDiagram
    class HowlSession
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

    HowlSession --> Session
    HowlSession --> OwnedPty
    Session --> Pty
    OwnedPty --> Pty
```

## Ownership Rules
- `Session` owns pending outbound input, current size, lifecycle state, and transport-facing counters.
- `OwnedPty` owns the concrete selected PTY implementation and cleanup.
- `Session` talks to the abstract `Pty` interface only.
- Test PTY variants are exported for conformance testing, not as host architecture.
- Concrete platform PTY implementations stay internal to `howl-session`; hosts consume `OwnedPty` or `Pty`, not `UnixPty`/`AndroidPty` directly.

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
- `initPty` returns an owned transport; callers must eventually call `deinit` on that owner.
- `Session.init` does not start the transport.
- `Session.attachPty` and `Session.detachPty` are the supported transport replacement hooks while inactive.
- `start` transitions to active and starts the transport if present.
- `publishControlSignal` accepts a typed `ControlSignal`, not a raw signal byte.
- `publishHostInput` only queues bytes; `flushOutboundInput` performs writes.
- `resize` updates tracked geometry and forwards to transport.
- Transport failures move the session to `stopped`.

## Non-Goals
- Terminal parsing or screen state.
- Font or rendering concerns.
- Host event loops.

## Change Rules
- Concrete PTY implementations must stay behind `OwnedPty` and `Pty`.
- Queue policy belongs in `Session`, not in hosts.
- New transport variants should preserve the same owner/interface split.
