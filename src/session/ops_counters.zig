//! Responsibility: define session operations checkpoint semantics for tests.
//! Ownership: session observability helpers.
//! Reason: keep operation-counter expectations deterministic and reusable.

const std = @import("std");
const core = @import("core.zig");
const Session = core.Session;
const transport_api = @import("../transport.zig");
const ops_checkpoint = @import("../test_support/session_ops_checkpoint.zig");

test "ops: lifecycle attempt/success/failure boundaries" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try std.testing.expectEqual(@as(u32, 0), s.ops.start_attempts);
    try s.start();
    try std.testing.expectEqual(@as(u32, 1), s.ops.start_attempts);
    try std.testing.expectEqual(@as(u32, 1), s.ops.start_successes);
    try std.testing.expectEqual(@as(u32, 0), s.ops.start_failures);

    const already = s.start();
    try std.testing.expectError(error.AlreadyStarted, already);
    try std.testing.expectEqual(@as(u32, 2), s.ops.start_attempts);
    try std.testing.expectEqual(@as(u32, 1), s.ops.start_successes);
    try std.testing.expectEqual(@as(u32, 0), s.ops.start_failures);

    s.stop();
    try std.testing.expectEqual(@as(u32, 1), s.ops.stop_calls);
    s.stop();
    try std.testing.expectEqual(@as(u32, 2), s.ops.stop_calls);

    s2: {
        var sf = try Session.init(.{
            .allocator = std.testing.allocator,
            .cols = 80,
            .rows = 24,
            .pending_capacity = 256,
            .transport = ft.transport(),
        });
        defer sf.deinit();
        const err = sf.start();
        try std.testing.expectError(error.TransportFailed, err);
        try std.testing.expectEqual(@as(u32, 1), sf.ops.start_attempts);
        try std.testing.expectEqual(@as(u32, 0), sf.ops.start_successes);
        try std.testing.expectEqual(@as(u32, 1), sf.ops.start_failures);
        break :s2;
    }
}

test "ops: queue feed accepted/rejected and apply drain accounting" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 10,
    });
    defer s.deinit();

    try s.feed("hello");
    try std.testing.expectEqual(@as(u32, 1), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u32, 0), s.ops.feed_rejected);
    try std.testing.expectEqual(@as(u64, 5), s.ops.bytes_fed);

    const overflow = s.feed("overflow_exceeds_cap");
    try std.testing.expectError(error.QueueFull, overflow);
    try std.testing.expectEqual(@as(u32, 1), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u32, 1), s.ops.feed_rejected);
    try std.testing.expectEqual(@as(u64, 5), s.ops.bytes_fed);

    try std.testing.expectEqual(@as(u32, 0), s.ops.apply_calls);
    const n = s.apply();
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u32, 1), s.ops.apply_calls);
    try std.testing.expectEqual(@as(u64, 5), s.ops.bytes_applied);

    _ = s.apply();
    try std.testing.expectEqual(@as(u32, 2), s.ops.apply_calls);
    try std.testing.expectEqual(@as(u64, 5), s.ops.bytes_applied);

    try s.feed("ab");
    try s.feed("cd");
    try std.testing.expectEqual(@as(u32, 3), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u64, 9), s.ops.bytes_fed);
}

test "ops: feed OutOfMemory does not increment feed_rejected" {
    var buffer: [4]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var s = try Session.init(.{
        .allocator = fba.allocator(),
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
    });
    defer s.deinit();

    const r = s.feed("0123456789");
    try std.testing.expectError(error.OutOfMemory, r);
    try std.testing.expectEqual(@as(u32, 0), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u32, 0), s.ops.feed_rejected);
    try std.testing.expectEqual(@as(u64, 0), s.ops.bytes_fed);
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "ops: reset_calls accounting" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try std.testing.expectEqual(@as(u32, 0), s.ops.reset_calls);
    s.reset();
    try std.testing.expectEqual(@as(u32, 1), s.ops.reset_calls);
    s.reset();
    try std.testing.expectEqual(@as(u32, 2), s.ops.reset_calls);

    try s.feed("data");
    s.reset();
    try std.testing.expectEqual(@as(u32, 1), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u32, 3), s.ops.reset_calls);
    try std.testing.expectEqual(@as(u32, 0), s.ops.apply_calls);
}

test "ops: resize/control accounting" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(100, 40);
    try std.testing.expectEqual(@as(u32, 1), s.ops.resize_valid_calls);
    try std.testing.expectEqual(@as(u32, 0), s.ops.resize_invalid_calls);
    try std.testing.expectEqual(@as(u32, 0), s.ops.resize_transport_errors);

    const inv = s.resize(0, 40);
    try std.testing.expectError(error.InvalidDimensions, inv);
    try std.testing.expectEqual(@as(u32, 1), s.ops.resize_valid_calls);
    try std.testing.expectEqual(@as(u32, 1), s.ops.resize_invalid_calls);

    var sf = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer sf.deinit();
    const rerr = sf.resize(120, 40);
    try std.testing.expectError(error.TransportFailed, rerr);
    try std.testing.expectEqual(@as(u32, 1), sf.ops.resize_valid_calls);
    try std.testing.expectEqual(@as(u32, 1), sf.ops.resize_transport_errors);
    try std.testing.expectEqual(@as(u16, 120), sf.cols);

    try std.testing.expectEqual(@as(u32, 0), s.ops.control_calls);
    s.control(.interrupt);
    try std.testing.expectEqual(@as(u32, 1), s.ops.control_calls);
    s.control(.hangup);
    s.control(.terminate);
    try std.testing.expectEqual(@as(u32, 3), s.ops.control_calls);
}

test "ops: counters accumulate across lifecycle transitions" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    try s.feed("abc");
    _ = s.apply();
    s.stop();

    try std.testing.expectEqual(@as(u32, 1), s.ops.start_successes);
    try std.testing.expectEqual(@as(u32, 1), s.ops.stop_calls);
    try std.testing.expectEqual(@as(u32, 1), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u64, 3), s.ops.bytes_fed);
    try std.testing.expectEqual(@as(u64, 3), s.ops.bytes_applied);

    try s.start();
    try s.feed("de");
    _ = s.apply();
    s.stop();

    try std.testing.expectEqual(@as(u32, 2), s.ops.start_successes);
    try std.testing.expectEqual(@as(u32, 2), s.ops.stop_calls);
    try std.testing.expectEqual(@as(u32, 2), s.ops.feed_accepted);
    try std.testing.expectEqual(@as(u64, 5), s.ops.bytes_fed);
    try std.testing.expectEqual(@as(u64, 5), s.ops.bytes_applied);
}

test "ops: SessionOpsCheckpoint captures all counter fields" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    const before = ops_checkpoint.SessionOpsCheckpoint.capture(&s);
    try s.feed("hello");
    _ = s.apply();
    s.control(.interrupt);
    const after = ops_checkpoint.SessionOpsCheckpoint.capture(&s);

    try std.testing.expectEqual(@as(u32, 0), before.feed_accepted);
    try std.testing.expectEqual(@as(u32, 1), after.feed_accepted);
    try std.testing.expectEqual(@as(u64, 5), after.bytes_fed);
    try std.testing.expectEqual(@as(u64, 5), after.bytes_applied);
    try std.testing.expectEqual(@as(u32, 1), after.apply_calls);
    try std.testing.expectEqual(@as(u32, 1), after.control_calls);
}
