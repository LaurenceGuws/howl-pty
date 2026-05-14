# Howl PTY ABI Sprint

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../WORKFLOW.md`](../WORKFLOW.md),
[`../design/style-law.md`](../design/style-law.md),
[`../design/tigerbeetle-style-sprint.md`](../design/tigerbeetle-style-sprint.md)

## Purpose

This sprint resets `howl-pty` around one acceptable outcome only:

- TigerBeetle-style discipline
- C ABI embeddability as the real product boundary
- no Zig-shaped host facades
- no Zig-shaped module roots preserved as integration surfaces

Everything else is secondary.

## Roles

The architect and reviewer is the last line of defense before code goes into git.

That role must:

- reject unclear ownership
- reject wrapper theater
- reject hidden control flow
- reject stale public symbols
- reject compatibility posture that preserves the wrong boundary
- reject any checkpoint that is not simple, unambiguous, and effective

The git gatekeeper closes only on TigerBeetle-style outcomes. Near-miss cleanup does not pass.

## North Star

`howl-pty` is a PTY state-machine contract exposed for embedders through C ABI.

It is not a Zig module integration surface.

It is not a host convenience facade.

It is not a place to preserve old roots for comfort.

## Deletion Policy

- All Zig-shaped host facades in `howl-pty` are deletion targets, not preservation targets.
- All Zig-shaped module roots in `howl-pty` are deletion targets, not preservation targets.
- Wrapper namespaces that only forward are deletion targets.
- Stale symbols are deletion targets.
- Convenience ABI combo steps that blur the state machine are deletion targets unless the owner can
  prove they are the true contract.

## Required End State

- one explicit shipped contract: `include/howl_pty.h`
- one explicit ABI export root: `src/libhowl_pty.zig`
- owner files own state and mutation directly
- FFI translates the contract only
- no host-facing Zig import story remains in docs, roots, or build wiring
- no stale exported symbols remain
- Linux host consumes the cleaned ABI only

## Checkpoints

### Checkpoint 1

Theme: contract lock.

Must do:

- rewrite `design.md` facts to describe C ABI as the only real embedding boundary
- name every Zig-shaped facade or root that is scheduled for deletion
- remove any wording that preserves Zig-root consumption as an acceptable integration path

Closes when:

- the boundary language is explicit
- deletion targets are named exactly
- no conflicting public-surface wording remains

### Checkpoint 2

Theme: root and facade deletion.

Must do:

- delete `src/session_namespace.zig`
- stop `src/howl_pty.zig` from acting as host-facing convenience aggregation
- add `src/libhowl_pty.zig` as the explicit ABI export root
- remove build wiring that preserves fake dual-surface posture

Closes when:

- no wrapper namespace root remains
- ABI root and internal package root are distinct
- build wiring no longer preserves the old integration shape

### Checkpoint 3

Theme: ABI sharpening.

Must do:

- remove stale symbols
- remove exported constant getter functions when header constants or enums are the true contract
- replace integer-handle posture with a stricter opaque-handle contract if the host can consume it
- remove ABI combo steps that are not owner-true

Closes when:

- every exported symbol justifies its existence as part of the state machine
- the header reads like a contract, not a bag of helpers
- no stale or convenience-only symbol survives

### Checkpoint 4

Theme: owner cleanup.

Must do:

- keep queue policy in `Session`
- keep transport implementation details internal
- remove any remaining public shape that suggests host-facing Zig transport ownership
- tighten sized-state and assertion posture in touched files

Closes when:

- the owner story is singular and direct
- touched files are clean against the style gate
- the host boundary reads as ABI-first everywhere

### Checkpoint 5

Theme: Linux host proof.

Must do:

- update `howl-linux-host` to the cleaned PTY ABI as needed
- remove any stale assumptions about deleted symbols
- prove the host still builds and runs on the owned path

Closes when:

- host build passes against the new ABI
- no compatibility layer was added to soften the cleanup

## Proof Gates

Each checkpoint must close with all of the following:

- `zig build test` in `howl-pty`
- `nu "./style.nu" --touched-files`
- `nu "./style.nu" --failures`
- `git diff --check`
- when ABI changes reach the host seam, `zig build` in `howl-linux-host`

## Review Gates

A checkpoint fails review if it does any of the following:

- preserves a Zig-shaped facade or root because it is convenient
- adds a compatibility wrapper
- keeps duplicate public stories alive in parallel
- exports a symbol that exists only to mirror Zig internals
- leaves ownership unclear between session, transport, and FFI
- keeps hidden policy in a root or wrapper
- claims C ABI first while preserving Zig integration as a practical bypass
- closes without exact proof on the changed path

## Commit Gate

Do not commit unless the architect/reviewer says all of the following are true:

- the checkpoint scope stayed narrow
- the boundary got sharper
- the deletion happened for real
- the proof gates passed
- the result matches TigerBeetle style, not just local improvement

If the change is merely better than before, it is not ready.
