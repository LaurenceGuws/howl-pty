const std = @import("std");
const session_mod = @import("../session.zig");
const transport_mod = @import("../transport.zig");

const Session = session_mod.Session;
const testing = std.testing;

test "init invalid config" {
    try testing.expectError(error.InvalidConfig, Session.init(.{
        .allocator = testing.allocator,
        .cols = 0,
        .rows = 24,
        .pending_capacity = 32,
        .transport = null,
    }));
}

test "feed apply without transport drains queue" {
    var s = try Session.init(.{
        .allocator = testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .transport = null,
    });
    defer s.deinit();

    try s.feed("hello");
    try testing.expectEqual(@as(usize, 5), s.apply());
    try testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "start stop with mem transport" {
    var mt = transport_mod.MemTransport.init(testing.allocator);
    defer mt.deinit();

    var s = try Session.init(.{
        .allocator = testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    try testing.expectEqual(session_mod.SessionStatus.active, s.status);
    s.stop();
    try testing.expectEqual(session_mod.SessionStatus.stopped, s.status);
}

test "resize updates dims and counter" {
    var s = try Session.init(.{
        .allocator = testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .transport = null,
    });
    defer s.deinit();

    try s.resize(100, 40);
    try testing.expectEqual(@as(u16, 100), s.cols);
    try testing.expectEqual(@as(u16, 40), s.rows);
    try testing.expectEqual(@as(u32, 1), s.resize_count);
}

test "snapshot restore" {
    var s = try Session.init(.{
        .allocator = testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .transport = null,
    });
    defer s.deinit();

    try s.resize(90, 30);
    const snap = s.snapshot();

    try s.resize(120, 50);
    try s.restore(snap);
    try testing.expectEqual(@as(u16, 90), s.cols);
    try testing.expectEqual(@as(u16, 30), s.rows);
}
