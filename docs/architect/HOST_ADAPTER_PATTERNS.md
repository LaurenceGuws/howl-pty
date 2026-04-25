# Host Adapter Patterns for Howl Session Integration

## Purpose

This guide defines responsibility boundaries and integration patterns for host adapters wiring session + surface to a host application (e.g., SDL2 window, Android activity, browser tab).

**Scope:** Session acts as a shared host-session runtime. Hosts own SDL/window/input/renderer concerns. This document defines the seam between them.

---

## Host Adapter Responsibilities and Boundaries

### Host Adapter Owns
- SDL2/Cocoa/Android window and input event loop
- Renderer invocation (draw calls, frame presentation)
- Keyboard/mouse input collection and dispatch
- Window resize event capture
- Application lifecycle (startup, foreground/background, shutdown)

### Session Owns (Do Not Reimplement)
- Terminal engine lifecycle (PTY, process, screen state)
- Feed/apply/reset queue orchestration
- Resize/control signal routing to transport
- Lifecycle state machine (idle → active → stopped)
- Partial-write handling and backpressure

### Surface Owns (Do Not Couple to Session Lifecycle)
- Frame buffer (cell grid, styled glyphs)
- Dirty state tracking and frame composition
- Render backend binding (to OpenGL, Vulkan, software renderer, etc.)
- Read-after-write semantics for display queries

---

## Async Feed/Apply Loop Pattern and Ordering Guarantees

### The Event Loop Envelope

A host adapter drives session through a single logical event loop:

```
LOOP: poll SDL/input events
  ├─ for each keyboard event:
  │   └─ session.feed(bytes)  [queue input; no processing]
  │
  ├─ for each resize event:
  │   └─ session.resize(cols, rows)  [commit dims; notify transport]
  │
  ├─ for each control signal (Ctrl+C, etc):
  │   └─ session.control(signal)  [record signal; notify transport]
  │
  └─ APPLY PHASE:
      ├─ written = session.apply()  [attempt pending → transport]
      ├─ read_output = session.feedProcessOutput(buf)  [drive engine]
      └─ if written > 0 or read_output > 0:
          └─ surface.updateCells(engine.cells())  [refresh display]
```

### Ordering Guarantees

1. **Input feeds precede apply:** All `feed()` calls must happen before `apply()` in the loop.
   - Rationale: `apply()` drains the queue; feeding after would delay dispatch to the next loop.

2. **Apply is atomic from host perspective:** One `apply()` call drains all written bytes and feeds output to engine.
   - Rationale: Transport.write() is async; multiple apply() calls in one loop risk out-of-order writes.

3. **Resize and control are async:** Resize/control are recorded and routed to transport immediately.
   - Not queued; safe to call at any point in the loop.
   - If transport fails, dims/signal are still committed on session.

4. **Display refresh follows output:** Query surface state **after** `feedProcessOutput()` completes.
   - Rationale: Engine state must settle before querying frame data.

---

## Error-Handling Pattern for start/write/read/resize/control

### Error Routes by Operation

#### `session.start()` on Idle or Stopped
```zig
session.start() catch |err| {
  switch (err) {
    error.AlreadyStarted => {
      // Should not happen if checking status first
      // No state change; session still active
    },
    else => {
      // Transport.start() failed (PTY, container bridge, etc.)
      // Session remains in `idle` state; can retry start()
      // Display error UI; do not attempt apply/feed
    }
  }
}
```

#### `session.feed()`
```zig
session.feed(bytes) catch |err| {
  switch (err) {
    error.QueueFull => {
      // Pending queue cannot accept more bytes
      // Apply pending before re-attempting feed
      // If apply() returns 0 (no progress), back off and retry next loop
    },
    error.OutOfMemory => {
      // Allocation failed; catastrophic
      // Likely unrecoverable; surface graceful shutdown
    }
  }
}
```

#### `session.apply()`
```zig
written = session.apply();
// Returns 0 or count of bytes drained
// No error: applies atomically or returns 0 (no progress)
// Partial-write contract: if transport.write() returns < requested,
// only the returned byte count is drained; remainder shifts to queue front
if (written == 0) {
  // Queue was empty, or write() made no progress
  // Normal; do not treat as error
}
```

#### `session.feedProcessOutput()`
```zig
read_output = session.feedProcessOutput(buf) catch |err| {
  switch (err) {
    else => {
      // Engine feed failed (very rare; engine does not allocate)
      // Log error; do not retry (engine may be corrupted)
      // Consider shutdown
    }
  }
}
// Returns count of bytes fed to engine
// If 0, no data was available; normal, do not retry
```

#### `session.resize(cols, rows)`
```zig
session.resize(cols, rows) catch |err| {
  switch (err) {
    error.InvalidDimensions => {
      // cols or rows was 0; session unchanged
      // Retry with valid dimensions on next event
    },
    else => {
      // Transport.resize() failed (not a dimension rejection)
      // Session dims are already committed; this is a notification failure
      // Log error; transport is out of sync
      // May proceed; session state is consistent
    }
  }
}
```

#### `session.control(signal)`
```zig
session.control(signal);
// Never errors; fire-and-forget
// Signal is recorded; transport is notified if attached
// Safe to call before start or after stop
// (Behavior before start is transport-defined)
```

---

## Resize Coordination Pattern Across Session/Host

### Resize Sequencing

```
HOST EVENT (window resize → 80×24)
  │
  ├─ 1. session.resize(80, 24)
  │     └─ Session dims committed immediately
  │     └─ resize_count incremented
  │     └─ Transport notified (if attached)
  │
  ├─ 2. surface.resize(80, 24)
  │     └─ Allocate new cell grid
  │     └─ Initialize cells (may be transactional)
  │
  └─ 3. Display refresh
        └─ Query surface.frameData()
        └─ Draw cells to renderer
        └─ Present frame
```

### Resize State Consistency

- **Session dims are authoritative:** If transport.resize() fails, session dims are still updated.
  - Host should not roll back; treat as transport notification failure, not dimension rejection.
  
- **Resize epoch tracking:** `session.resize_count` increments on every resize call (including no-op resizes to same dims).
  - Use this counter to detect resize events missed due to buffering or async delay.
  
- **Multi-step safety:** Surface resize is logically separate from session resize.
  - If surface.resize() fails (allocation error), session dims are already committed.
  - Host must handle gracefully (e.g., don't query surface state until resize succeeds).

---

## Minimal SDL Fixture Pattern (Test-Only Reference)

A minimal SDL host fixture demonstrates the pattern without production concerns:

### SDL Host Init
```zig
var session = try Session.init(allocator, SessionConfig{
  .allocator = allocator,
  .cols = 80,
  .rows = 24,
  .pending_capacity = 4096,
  .transport = sdl_pty_transport,  // UnixPtyTransport wrapped
});

var surface = try Surface.init(allocator, SurfaceConfig{
  .allocator = allocator,
  .cols = 80,
  .rows = 24,
  .session = @ptrCast(&session),  // opaque pointer; avoid cross-module dependency
});

try session.start();
```

### SDL Event Loop Envelope
```zig
while (running) {
  var event: sdl.SDL_Event = undefined;
  while (sdl.SDL_PollEvent(&event) != 0) {
    switch (event.type) {
      sdl.SDL_KEYDOWN => {
        var utf8: [4]u8 = undefined;
        var len = encodeKeyToUtf8(event.key.keysym.sym, &utf8);
        session.feed(utf8[0..len]) catch |err| {
          if (err == error.QueueFull) {
            _ = session.apply();  // drain; retry
            session.feed(utf8[0..len]) catch {};
          }
        };
      },
      sdl.SDL_VIDEORESIZE => {
        var cols = @as(u16, @intCast(event.window.data1 / char_width));
        var rows = @as(u16, @intCast(event.window.data2 / char_height));
        session.resize(cols, rows) catch {};
        surface.resize(cols, rows) catch {};
      },
      sdl.SDL_QUIT => running = false,
    }
  }

  // Apply phase
  _ = session.apply();
  var buf: [2048]u8 = undefined;
  _ = session.feedProcessOutput(&buf) catch {};
  
  // Render phase
  surface.updateCells(engine.cells());
  renderFrameToSDL(surface);
  sdl.SDL_RenderPresent(renderer);
}

session.stop();
session.deinit();
surface.deinit();
```

### Key Properties
- Single loop; no background threads
- Feed/apply/feedProcessOutput ordered as documented
- Resize separate from session lifecycle
- No performance optimization; straightforward blocking calls
- Test-only reference; production SDL host will differ (e.g., async rendering, VSync, compositor integration)

---

## Non-Goals and Explicit Boundaries

### Non-Goals
1. **Multi-session management** — Host owns managing multiple session instances (if desired).
2. **Session pooling or thread affinity** — Session does not define worker pool or affinity.
3. **Renderer optimization** — Display refresh cadence (VSync, dirty regions, partial rendering) is host responsibility.
4. **Input buffering** — Host collects and buffers input; session consumes from the buffer.
5. **Platform-specific event handling** — IME, accessibility, drag-and-drop are host-owned.
6. **Async transport loop** — Session feed/apply are synchronous; async transport (e.g., async I/O) is abstracted behind Transport vtable.

### Explicit Boundaries (Do Not Cross)
- Session does not know SDL types, window dimensions in pixels, DPI, or renderer state.
- Host does not reimplement feed/apply/reset or call transport directly.
- Surface does not couple to session state; session resizes do not implicitly resize surface.
- Terminal semantics (ANSI escape codes, control flow) are engine-owned, not session-owned.

---

## Pattern Validation Against Current API.md

### Feed / Apply / Reset Boundary Compliance
| Pattern Element | API.md Contract | Fixture Compliance |
| --- | --- | --- |
| Feed queues input without processing | `feed(bytes: []const u8) → {QueueFull, OutOfMemory}` | ✓ SDL keydown → feed() |
| Apply drains and respects partial-write | `apply() → usize` (returns drained count) | ✓ Drains written, leaves remainder |
| Reset clears queue | `reset() → void` | ✓ Available; used on error recovery |
| No automatic application | Session never self-triggers apply | ✓ Explicit session.apply() in loop |

### Resize / Control Boundary Compliance
| Pattern Element | API.md Contract | Fixture Compliance |
| --- | --- | --- |
| Resize commits dims before transport notification | Dims authoritative; not rolled back on transport error | ✓ session.resize() commits; surface.resize() separate |
| Resize increments epoch counter | `resize_count` increments on every valid resize | ✓ Checked by test; fixture does not read, but guaranteed |
| Control records signal and routes to transport | `last_control_signal` recorded; transport.control() called | ✓ session.control() alone is safe |
| Sequencing guarantee on resize/control | Valid in any state between init and deinit | ✓ No state guard; safe before/after start/stop |

### Lifecycle Boundary Compliance
| Pattern Element | API.md Contract | Fixture Compliance |
| --- | --- | --- |
| start() activates transport | `start() → anyerror!void` (from idle/stopped only) | ✓ Single session.start() before loop |
| stop() deactivates transport | `stop() → void` (idempotent) | ✓ Single session.stop() on quit |
| Repeated start() after stop() is valid | Restart from stopped is supported | ✓ Can call start() again (not exercised in fixture) |
| deinit() releases all resources | Must be called exactly once per init | ✓ Single session.deinit() and surface.deinit() |

### State Machine Compliance
| Transition | API.md Contract | Fixture Compliance |
| --- | --- | --- |
| idle → active (start) | Valid; transport activated | ✓ One session.start() in init |
| active → stopped (stop) | Valid; transport deactivated | ✓ One session.stop() on quit |
| stopped → active (restart) | Valid; transport reactivated | ✓ start() after stop() is safe (not used in fixture) |
| Any state → deinit | Valid; releases all resources | ✓ Final deinit() after stop() |

---

## Test Validation Checklist

A host adapter pattern is correct if:

1. **Feed/apply ordering:** All feed() calls precede apply() in the event loop.
2. **Resize handling:** Both session.resize() and surface.resize() are called for each resize event.
3. **Partial-write handling:** If apply() returns < pending queue size, no error is thrown; flow continues.
4. **Lifecycle ordering:** start() called before apply/feed; stop() called after loop; deinit() after stop().
5. **Error routes:** Each operation's error cases are handled explicitly (QueueFull, AlreadyStarted, InvalidDimensions).
6. **No direct transport calls:** Host never calls transport methods; only session methods.
7. **No session re-implementation:** Host does not reimplement apply or feed semantics.
8. **State machine:** Status transitions follow idle → active → stopped → active or deinit.

---

## Further References

- **Session API Contract:** `app_architecture/contracts/API.md` — Detailed lifecycle, state machine, and host-facing API boundaries.
- **Transport Portability:** `app_architecture/contracts/TRANSPORT_PORTABILITY.md` — Platform transport abstractions and vtable requirements.
- **Scope Authority:** `app_architecture/authorities/SCOPE.md` — Session ownership boundaries vs. host, renderer, terminal-core.
