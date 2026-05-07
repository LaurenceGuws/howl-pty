const std = @import("std");
const HowlSession = @import("howl_session").HowlSession;

test "HowlSession facade methods remain available" {
    const allocator = std.testing.allocator;

    var mem_pty = HowlSession.MemPty.init(allocator);
    defer mem_pty.deinit();

    var session = try HowlSession.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();

    try std.testing.expectEqual(HowlSession.SessionStatus.idle, session.snapshot().status);
    try std.testing.expectEqual(HowlSession.PtyClass, @TypeOf(HowlSession.pty_class));
    try std.testing.expectEqual(@as(u8, 15), HowlSession.ControlSignal.terminate.raw());
    try std.testing.expectEqual(@as(u8, 3), HowlSession.ControlSignal.resize_notify.raw());
}

test "session flushes outbound input deterministically" {
    const allocator = std.testing.allocator;

    var mem_pty = HowlSession.MemPty.init(allocator);
    defer mem_pty.deinit();

    var session = try HowlSession.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();

    try session.start();
    try session.publishHostInput("ping");

    const drained = session.flushOutboundInput();
    try std.testing.expectEqual(@as(usize, 4), drained);
    try std.testing.expectEqualStrings("ping", mem_pty.tx.items);
    try std.testing.expectEqual(@as(u64, 4), session.ops.bytes_fed);
    try std.testing.expectEqual(@as(u64, 4), session.ops.bytes_applied);
    try std.testing.expectEqual(@as(usize, 0), session.pending.items.len);
}

test "session preserves remainder after partial transport write" {
    const allocator = std.testing.allocator;

    var partial_pty = HowlSession.PartialPty.init(allocator, 3);
    defer partial_pty.deinit();

    var session = try HowlSession.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = partial_pty.pty(),
    });
    defer session.deinit();

    try session.start();
    try session.publishHostInput("abcdef");

    try std.testing.expectEqual(@as(usize, 3), session.flushOutboundInput());
    try std.testing.expectEqualStrings("abc", partial_pty.tx.items);
    try std.testing.expectEqualStrings("def", session.pending.items);

    try std.testing.expectEqual(@as(usize, 3), session.flushOutboundInput());
    try std.testing.expectEqualStrings("abcdef", partial_pty.tx.items);
    try std.testing.expectEqual(@as(usize, 0), session.pending.items.len);
}

test "session restore normalizes active snapshots to stopped" {
    const allocator = std.testing.allocator;

    var session = try HowlSession.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
    });
    defer session.deinit();

    try session.restore(.{
        .cols = 132,
        .rows = 40,
        .status = .active,
        .resize_count = 7,
    });

    const snap = session.snapshot();
    try std.testing.expectEqual(@as(u16, 132), snap.cols);
    try std.testing.expectEqual(@as(u16, 40), snap.rows);
    try std.testing.expectEqual(HowlSession.SessionStatus.stopped, snap.status);
    try std.testing.expectEqual(@as(u32, 7), snap.resize_count);
}

test "session publishes typed control signals through the pty boundary" {
    const allocator = std.testing.allocator;

    var mem_pty = HowlSession.MemPty.init(allocator);
    defer mem_pty.deinit();

    var session = try HowlSession.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
    });
    defer session.deinit();

    try session.attachPty(mem_pty.pty());
    try session.publishControlSignal(.interrupt);
    try std.testing.expectEqual(HowlSession.ControlSignal.interrupt, mem_pty.last_signal.?);
}

test "session transport attachment is owned by session lifecycle" {
    const allocator = std.testing.allocator;

    var first = HowlSession.MemPty.init(allocator);
    defer first.deinit();
    var second = HowlSession.MemPty.init(allocator);
    defer second.deinit();

    var session = try HowlSession.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = first.pty(),
    });
    defer session.deinit();

    try session.attachPty(second.pty());
    try session.start();
    try std.testing.expectError(error.SessionActive, session.detachPty());
    session.stop();
    try session.detachPty();
    try std.testing.expectError(error.TransportUnavailable, session.publishControlSignal(.terminate));
}
