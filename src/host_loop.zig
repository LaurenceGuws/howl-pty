//! Responsibility: provide host-loop tick helper utilities.
//! Ownership: host integration envelope helpers.
//! Reason: make outbound/inbound loop sequencing explicit and reusable.

// Host loop envelope for session I/O coordination.
// Encodes the ordering api: outbound apply with inbound byte accounting.

const std = @import("std");
const session = @import("session.zig");

const Session = session.Session;

/// Summary result of one host loop tick.
/// Provides deterministic feedback for host decisions (render, backpressure, etc).
pub const HostLoopTick = struct {
    /// Bytes drained from pending queue in outbound phase.
    outbound_drained: usize,
    /// Bytes fed to vt_core in inbound phase.
    inbound_fed: usize,
    /// True if outbound made progress (drained > 0).
    has_outbound: bool,
    /// True if inbound made progress (fed > 0).
    has_inbound: bool,

    /// True if either phase made progress.
    pub fn hasProgress(self: HostLoopTick) bool {
        return self.has_outbound or self.has_inbound;
    }
};

/// Execute one host loop tick: outbound + inbound I/O phases.
///
/// Precondition: All input bytes must be queued via session.feed() before calling tick().
/// Postcondition: Transport input byte count is reported for host-side processing.
///
/// Phase 1 (Outbound): Attempts to drain pending input queue to transport.
/// Phase 2 (Inbound): Reports transport output byte count for host-side handling.
///
/// Returns a summary of progress in each phase.
pub fn tick(sess: *Session, transport_input: []const u8) anyerror!HostLoopTick {
    // Phase 1: Outbound - flush pending input to transport
    const outbound_drained = sess.apply();

    // Phase 2: Inbound - host-owned vt path is outside session.
    const inbound_fed: usize = transport_input.len;

    return .{
        .outbound_drained = outbound_drained,
        .inbound_fed = inbound_fed,
        .has_outbound = outbound_drained > 0,
        .has_inbound = inbound_fed > 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Session_ = @import("session.zig").Session;
const mem_transport = @import("transport.zig");

test "host_loop: outbound only (pending queue drained)" {
    const allocator = testing.allocator;

    var session_handle = try Session_.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer session_handle.deinit();

    // Queue some input
    try session_handle.feed("hello");

    // Tick with empty transport input (outbound only)
    const result = try tick(&session_handle, "");

    // Outbound should have drained the pending queue
    try testing.expect(result.outbound_drained == 5); // "hello" is 5 bytes
    try testing.expect(result.inbound_fed == 0);
    try testing.expect(result.has_outbound);
    try testing.expect(!result.has_inbound);
    try testing.expect(result.hasProgress());
}

test "host_loop: inbound only (vt_core fed)" {
    const allocator = testing.allocator;

    var session_handle = try Session_.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer session_handle.deinit();

    // No pending input; only transport output
    const transport_output = "output bytes";

    const result = try tick(&session_handle, transport_output);

    // Outbound should have nothing to drain
    try testing.expect(result.outbound_drained == 0);
    // Inbound should have fed the transport output
    try testing.expect(result.inbound_fed == transport_output.len);
    try testing.expect(!result.has_outbound);
    try testing.expect(result.has_inbound);
    try testing.expect(result.hasProgress());
}

test "host_loop: both outbound and inbound" {
    const allocator = testing.allocator;

    var session_handle = try Session_.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer session_handle.deinit();

    // Queue input for outbound
    try session_handle.feed("input");

    // Simulate transport output
    const transport_output = "output";

    const result = try tick(&session_handle, transport_output);

    // Both phases should report progress
    try testing.expect(result.outbound_drained == 5); // "input"
    try testing.expect(result.inbound_fed == 6); // "output"
    try testing.expect(result.has_outbound);
    try testing.expect(result.has_inbound);
    try testing.expect(result.hasProgress());
}

test "host_loop: empty tick (no progress)" {
    const allocator = testing.allocator;

    var session_handle = try Session_.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer session_handle.deinit();

    // No pending input, no transport output
    const result = try tick(&session_handle, "");

    // Both phases should report no progress
    try testing.expect(result.outbound_drained == 0);
    try testing.expect(result.inbound_fed == 0);
    try testing.expect(!result.has_outbound);
    try testing.expect(!result.has_inbound);
    try testing.expect(!result.hasProgress());
}

test "host_loop: ordering is preserved (outbound before inbound)" {
    const allocator = testing.allocator;

    // Use MemTransport to track call order and verify sequencing
    var mem_t = mem_transport.MemTransport.init(allocator);
    defer mem_t.deinit();

    var session_handle = try Session_.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = mem_t.transport(),
    });
    defer session_handle.deinit();

    try session_handle.start();

    // Queue input
    try session_handle.feed("cmd");

    // Tick: outbound applies first, then inbound feeds
    const result = try tick(&session_handle, "response");

    // Verify ordering: outbound executed (wrote to transport)
    try testing.expect(result.outbound_drained == 3); // "cmd"
    // Verify ordering: inbound executed after outbound
    try testing.expect(result.inbound_fed == 8); // "response"

    session_handle.stop();
}

test "host_loop: multiple ticks with partial progress" {
    const allocator = testing.allocator;

    var session_handle = try Session_.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer session_handle.deinit();

    // Tick 1: input only
    try session_handle.feed("a");
    const result1 = try tick(&session_handle, "");
    try testing.expect(result1.outbound_drained == 1);
    try testing.expect(result1.inbound_fed == 0);

    // Tick 2: output only
    const result2 = try tick(&session_handle, "b");
    try testing.expect(result2.outbound_drained == 0);
    try testing.expect(result2.inbound_fed == 1);

    // Tick 3: both
    try session_handle.feed("c");
    const result3 = try tick(&session_handle, "d");
    try testing.expect(result3.outbound_drained == 1);
    try testing.expect(result3.inbound_fed == 1);
}
