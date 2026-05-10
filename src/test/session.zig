//! Responsibility: cover session queue and lifecycle behavior.
//! Ownership: howl-session tests own session regression checks.
//! Reason: keeps session behavior coverage separate from runtime modules.

const std = @import("std");
const howl_session = @import("howl_session");

test "howl_session root methods remain available" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_session.testing.Pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session = try howl_session.runtime.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();

    try std.testing.expectEqual(howl_session.runtime.Status.idle, session.snapshot().status);
    try std.testing.expectEqual(howl_session.pty.Class, @TypeOf(howl_session.pty.class));
    try std.testing.expectEqual(@as(u8, 15), howl_session.pty.ControlSignal.terminate.raw());
    try std.testing.expectEqual(@as(u8, 3), howl_session.pty.ControlSignal.resize_notify.raw());
}

test "session flushes outbound input deterministically" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_session.testing.Pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session = try howl_session.runtime.Session.init(.{
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

    var partial_pty = howl_session.testing.Pty.Partial.init(allocator, 3);
    defer partial_pty.deinit();

    var session = try howl_session.runtime.Session.init(.{
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

    var session = try howl_session.runtime.Session.init(.{
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
    try std.testing.expectEqual(howl_session.runtime.Status.stopped, snap.status);
    try std.testing.expectEqual(@as(u32, 7), snap.resize_count);
}

test "session publishes typed control signals through the pty boundary" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_session.testing.Pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session = try howl_session.runtime.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
    });
    defer session.deinit();

    try session.attachPty(mem_pty.pty());
    try session.publishControlSignal(.interrupt);
    try std.testing.expectEqual(howl_session.pty.ControlSignal.interrupt, mem_pty.last_signal.?);
}

test "session transport attachment is owned by session lifecycle" {
    const allocator = std.testing.allocator;

    var first = howl_session.testing.Pty.Mem.init(allocator);
    defer first.deinit();
    var second = howl_session.testing.Pty.Mem.init(allocator);
    defer second.deinit();

    var session = try howl_session.runtime.Session.init(.{
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
