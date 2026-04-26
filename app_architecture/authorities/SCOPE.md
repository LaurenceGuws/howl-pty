# Howl Session Scope Authority

Purpose: define what `howl-session` owns and what it does not own.

## Product Identity

`howl-session` is a shared host-session runtime module used by host apps.

## In Scope

- terminal engine lifecycle composition
- PTY/process transport lifecycle
- feed/apply/reset boundary orchestration
- resize/control boundary flow
- host-neutral session API for consumers

## Out of Scope

- platform window/input ownership
- renderer ownership
- terminal semantic ownership
- host app packaging/policy ownership
