//! Responsibility: validate host session-loop contracts against session contracts.
//! Ownership: conformance evidence test suite.
//! Reason: ensure loop and lifecycle behavior remain deterministic under composition.

// Integration tests for host integration contract using session + host_loop.
// Validates documented host loop end-to-end: feed → apply → feedProcessOutput.

const std = @import("std");
const session_mod = @import("../session.zig");
const host_loop = @import("../ops/host_loop.zig");
const transport_mem = @import("../transport/mem.zig");

const Session = session_mod.Session;
const HostLoopTick = host_loop.HostLoopTick;
const PartialTransport = transport_mem.PartialTransport;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "host loop: feed input → outbound drain via tick" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Precondition: feed input before tick
    try sess.feed("hello");

    // Execute tick (no transport input)
    const result = try host_loop.tick(&sess, "");

    // Validate outbound phase: pending queue drained
    try testing.expect(result.outbound_drained == 5); // "hello"
    try testing.expect(result.has_outbound);
    // No inbound phase
    try testing.expect(result.inbound_fed == 0);
    try testing.expect(!result.has_inbound);
    // Overall progress
    try testing.expect(result.hasProgress());
}

test "host loop: inbound transport bytes → feedProcessOutput via tick" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Precondition: no pending input; only transport output
    const transport_output = "response";

    // Execute tick with transport output
    const result = try host_loop.tick(&sess, transport_output);

    // Validate inbound phase: transport output fed to engine
    try testing.expect(result.inbound_fed == transport_output.len);
    try testing.expect(result.has_inbound);
    // No outbound (no pending)
    try testing.expect(result.outbound_drained == 0);
    try testing.expect(!result.has_outbound);
    // Overall progress
    try testing.expect(result.hasProgress());
}

test "host loop: both feed and transport output in single tick" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Precondition: feed input and have transport output ready
    try sess.feed("input");
    const transport_output = "output";

    // Execute tick (both directions)
    const result = try host_loop.tick(&sess, transport_output);

    // Validate both phases executed
    try testing.expect(result.outbound_drained == 5); // "input"
    try testing.expect(result.has_outbound);
    try testing.expect(result.inbound_fed == 6); // "output"
    try testing.expect(result.has_inbound);
    // Both made progress
    try testing.expect(result.hasProgress());
}

test "host loop: resize ordered before tick (state committed)" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Precondition: resize before I/O tick
    try sess.resize(100, 30);
    try testing.expect(sess.cols == 100);
    try testing.expect(sess.rows == 30);

    // Feed and tick
    try sess.feed("cmd");
    const result = try host_loop.tick(&sess, "");

    // Validate: dimensions are committed and tick proceeds normally
    try testing.expect(sess.cols == 100);
    try testing.expect(sess.rows == 30);
    try testing.expect(result.outbound_drained == 3);
}

test "host loop: control signal recorded before tick" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Precondition: send control signal before tick
    sess.control(.interrupt);
    try testing.expect(sess.last_control_signal == .interrupt);

    // Feed and tick
    try sess.feed("x");
    const result = try host_loop.tick(&sess, "");

    // Validate: signal is recorded and tick proceeds
    try testing.expect(sess.last_control_signal == .interrupt);
    try testing.expect(result.outbound_drained == 1);
}

test "host loop: repeated ticks with partial progress" {
    const allocator = testing.allocator;

    var mem_t = transport_mem.MemTransport.init(allocator);
    defer mem_t.deinit();

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = mem_t.transport(),
    });
    defer sess.deinit();

    try sess.start();

    // Tick 1: outbound only
    try sess.feed("a");
    const result1 = try host_loop.tick(&sess, "");
    try testing.expect(result1.outbound_drained == 1);
    try testing.expect(result1.inbound_fed == 0);

    // Tick 2: inbound only
    const result2 = try host_loop.tick(&sess, "b");
    try testing.expect(result2.outbound_drained == 0);
    try testing.expect(result2.inbound_fed == 1);

    // Tick 3: both directions
    try sess.feed("c");
    const result3 = try host_loop.tick(&sess, "d");
    try testing.expect(result3.outbound_drained == 1);
    try testing.expect(result3.inbound_fed == 1);

    sess.stop();
}

test "host loop: no-progress tick (idle)" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Tick with no pending input and no transport output
    const result = try host_loop.tick(&sess, "");

    // Validate: no progress in either direction
    try testing.expect(result.outbound_drained == 0);
    try testing.expect(!result.has_outbound);
    try testing.expect(result.inbound_fed == 0);
    try testing.expect(!result.has_inbound);
    try testing.expect(!result.hasProgress());
}

test "host loop: lifecycle with tick sequence (start → ticks → stop)" {
    const allocator = testing.allocator;

    var mem_t = transport_mem.MemTransport.init(allocator);
    defer mem_t.deinit();

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = mem_t.transport(),
    });
    defer sess.deinit();

    // Lifecycle: init → start
    try testing.expect(sess.status == .idle);
    try sess.start();
    try testing.expect(sess.status == .active);

    // I/O sequence with ticks
    try sess.feed("cmd1");
    const tick1 = try host_loop.tick(&sess, "");
    try testing.expect(tick1.outbound_drained == 4);

    try sess.feed("cmd2");
    const tick2 = try host_loop.tick(&sess, "resp");
    try testing.expect(tick2.outbound_drained == 4);
    try testing.expect(tick2.inbound_fed == 4);

    // Lifecycle: stop
    sess.stop();
    try testing.expect(sess.status == .stopped);
}

test "host loop: partial write handling with PartialTransport" {
    const allocator = testing.allocator;

    var partial_t = PartialTransport.init(allocator, 2);
    defer partial_t.deinit();

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = partial_t.transport(),
    });
    defer sess.deinit();

    try sess.start();

    // Feed 5 bytes; transport only accepts 2 per write
    try sess.feed("hello");

    // Tick 1: partial write (2 of 5 bytes)
    const tick1 = try host_loop.tick(&sess, "");
    try testing.expect(tick1.outbound_drained == 2);
    try testing.expect(sess.pending.items.len == 3); // 5 - 2 = 3 remain

    // Tick 2: partial write (2 of 3 bytes)
    const tick2 = try host_loop.tick(&sess, "");
    try testing.expect(tick2.outbound_drained == 2);
    try testing.expect(sess.pending.items.len == 1); // 3 - 2 = 1 remains

    // Tick 3: final write (1 byte)
    const tick3 = try host_loop.tick(&sess, "");
    try testing.expect(tick3.outbound_drained == 1);
    try testing.expect(sess.pending.items.len == 0); // all drained

    sess.stop();
}

test "host loop: multiple sequential ticks with interleaved input/output" {
    const allocator = testing.allocator;

    var mem_t = transport_mem.MemTransport.init(allocator);
    defer mem_t.deinit();

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = mem_t.transport(),
    });
    defer sess.deinit();

    try sess.start();

    // Simulation: host receives input and output in alternating rule
    var total_input: usize = 0;
    var total_output: usize = 0;

    // Tick 1: user types 'a'
    try sess.feed("a");
    var tick = try host_loop.tick(&sess, "");
    total_input += tick.outbound_drained;
    try testing.expect(tick.outbound_drained == 1);

    // Tick 2: terminal outputs response, user types 'b'
    try sess.feed("b");
    tick = try host_loop.tick(&sess, "echo a");
    total_input += tick.outbound_drained;
    total_output += tick.inbound_fed;
    try testing.expect(tick.outbound_drained == 1);
    try testing.expect(tick.inbound_fed == 6);

    // Tick 3: terminal outputs response, no new input
    tick = try host_loop.tick(&sess, "echo b");
    total_output += tick.inbound_fed;
    try testing.expect(tick.outbound_drained == 0);
    try testing.expect(tick.inbound_fed == 6);

    // Tick 4: idle (no new input/output)
    tick = try host_loop.tick(&sess, "");
    try testing.expect(!tick.hasProgress());

    // Verify totals
    try testing.expect(total_input == 2); // 'a' + 'b'
    try testing.expect(total_output == 12); // 2 x "echo X"

    sess.stop();
}

test "host loop: tick ordering invariant (feed before tick)" {
    const allocator = testing.allocator;

    var sess = try Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    // Verification: feeding before tick ensures apply sees pending bytes
    try sess.feed("pre");
    const tick1 = try host_loop.tick(&sess, "");
    try testing.expect(tick1.outbound_drained == 3); // "pre" flushed

    // After tick, feeding again works for next tick
    try sess.feed("post");
    const tick2 = try host_loop.tick(&sess, "");
    try testing.expect(tick2.outbound_drained == 4); // "post" flushed

    // Invariant: apply() always drains what was fed before tick
    try testing.expect(tick1.outbound_drained + tick2.outbound_drained == 7);
}
