# Howl Session Scope Authority

Purpose: define what `howl-session` owns and what it does not own.

## Product Identity

`howl-session` is the shared terminal process/runtime module. It is consumed
primarily by the primary terminal boundary (`howl-term`, currently housed in the
`howl-term-surface` repo) and may also be consumed directly by advanced hosts or
headless tools.

## In Scope

- session lifecycle around one attached terminal process/runtime
- PTY/process transport lifecycle and transport abstraction pressure
- feed/apply/reset boundary orchestration
- resize/control flow between caller, transport, and VT runtime
- host-neutral terminal runtime API for upstream consumers

## Out of Scope

- platform window/input/app lifecycle ownership
- renderer ownership or render planning policy
- terminal semantic ownership (belongs to `howl-vt-core`)
- host packaging, multiplexing, or app policy ownership

