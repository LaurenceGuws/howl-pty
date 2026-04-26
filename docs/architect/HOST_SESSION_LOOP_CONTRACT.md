# Host Session Loop Contract

This contract defines the allowed operation order for code that drives
`howl-session` directly.

## Current Authority

Preferred product path:

`host platform events -> howl-term-surface TerminalSurface -> howl-session Session`

Direct session integration remains valid for focused tests and transport
development, but product hosts should consume `TerminalSurface` unless an
explicit transport milestone says otherwise.

## Session Owns

- lifecycle state transitions
- pending outbound queue behavior
- transport start, stop, write, read, resize, and control calls
- terminal engine input/output handoff
- resize counters and last control signal observability

## Host Or Surface Owns

- platform event collection
- pixel-to-cell sizing policy
- frame scheduling and presentation timing
- renderer selection
- user-visible error presentation

## Required Loop Order

A direct session loop must preserve this order:

1. collect host input
2. call `feed(bytes)` for outbound input
3. call `resize(cols, rows)` or `control(signal)` for immediate events
4. call `apply()` to flush queued outbound bytes to transport
5. read inbound bytes from transport
6. call `feedProcessOutput(bytes)` for inbound process output
7. query the owning surface or composed frame model after output is applied

`apply()` is outbound-only. It does not read process output.

## Error Routes

- `start()` failure leaves status unchanged.
- `feed()` can return `QueueFull` or `OutOfMemory`.
- `apply()` returns drained byte count and preserves unwritten bytes.
- `feedProcessOutput(bytes)` consumes already-read process output.
- `resize(cols, rows)` commits session dimensions before transport
  notification, except invalid dimensions are rejected before mutation.
- `control(signal)` records the signal and does not return an error.

## Boundary Rules

- Session APIs use plain Zig data and transport contracts only.
- Platform SDK types must not appear in session APIs.
- Hosts must not reimplement queue, lifecycle, resize, or control semantics.
- Hosts must not bypass session to call transport directly for operations
  already owned by session.
- Product hosts keep terminal orchestration in `TerminalSurface`, not in
  platform event-loop code.

## Validation Checklist

Direct session usage is acceptable when:

- input is queued before outbound flush
- outbound and inbound I/O phases are separate
- resize/control calls do not depend on render timing
- session lifecycle follows the documented state machine
- transport errors are handled without inventing alternate session state
- frame queries happen after inbound output has been fed

## References

- `app_architecture/contracts/API.md`
- `app_architecture/contracts/TRANSPORT_API.md`
- `../../../howl-term-surface/app_architecture/contracts/SURFACE_LIFECYCLE.md`
