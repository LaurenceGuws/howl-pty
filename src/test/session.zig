//! Responsibility: cover session queue and lifecycle behavior.
//! Ownership: howl-pty tests own session regression checks.
//! Reason: keeps session behavior coverage separate from runtime modules.

const std = @import("std");
const howl_pty = @import("howl_pty");

test "howl_pty root methods remain available" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_pty.testing.Transport.Mem.init(allocator);
    defer mem_pty.deinit();

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();

    try std.testing.expectEqual(howl_pty.Status.idle, session.snapshot().status);
    try std.testing.expectEqual(howl_pty.transport.Class, @TypeOf(howl_pty.transport.class));
    try std.testing.expectEqual(@as(u8, 15), howl_pty.transport.ControlSignal.terminate.raw());
    try std.testing.expectEqual(@as(u8, 3), howl_pty.transport.ControlSignal.resize_notify.raw());
}

test "session flushes outbound input deterministically" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_pty.testing.Transport.Mem.init(allocator);
    defer mem_pty.deinit();

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();

    try session.start();
    try std.testing.expect(session.isActive());
    try session.publishHostInput("ping");

    const drained = session.flushOutboundInput();
    try std.testing.expectEqual(@as(usize, 4), drained);
    try std.testing.expectEqualStrings("ping", mem_pty.tx.items);
    try std.testing.expectEqual(@as(u64, 4), session.ops.bytes_fed);
    try std.testing.expectEqual(@as(u64, 4), session.ops.bytes_applied);
    try std.testing.expectEqual(@as(usize, 0), session.pending.items.len);
    session.stop();
    try std.testing.expect(!session.isActive());
}

test "session preserves remainder after partial transport write" {
    const allocator = std.testing.allocator;

    var partial_pty = howl_pty.testing.Transport.Partial.init(allocator, 3);
    defer partial_pty.deinit();

    var session = try howl_pty.Session.init(.{
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

test "session pumps outbound input and reports readable wait policy" {
    const allocator = std.testing.allocator;

    var partial_pty = howl_pty.testing.Transport.Partial.init(allocator, 3);
    defer partial_pty.deinit();

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = partial_pty.pty(),
    });
    defer session.deinit();
    try session.start();

    const idle = session.pumpOutboundInput(false);
    try std.testing.expect(!idle.had_pending);
    try std.testing.expectEqual(@as(usize, 0), idle.drained);
    try std.testing.expect(!idle.has_pending);
    try std.testing.expect(idle.wait_readable);

    try session.publishHostInput("abcdef");
    const active = session.pumpOutboundInput(false);
    try std.testing.expect(active.had_pending);
    try std.testing.expectEqual(@as(usize, 3), active.drained);
    try std.testing.expect(active.has_pending);
    try std.testing.expect(!active.wait_readable);
    try std.testing.expectEqualStrings("abc", partial_pty.tx.items);
    try std.testing.expectEqualStrings("def", session.pending.items);
}

test "session publishes and pumps host input for thread backlog" {
    const allocator = std.testing.allocator;

    var partial_pty = howl_pty.testing.Transport.Partial.init(allocator, 2);
    defer partial_pty.deinit();

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = partial_pty.pty(),
    });
    defer session.deinit();
    try session.start();

    const pumped = try session.publishHostInputAndPump("hello");
    try std.testing.expect(pumped.had_pending);
    try std.testing.expectEqual(@as(usize, 2), pumped.drained);
    try std.testing.expect(pumped.has_pending);
    try std.testing.expect(!pumped.wait_readable);
    try std.testing.expectEqualStrings("he", partial_pty.tx.items);
    try std.testing.expectEqualStrings("llo", session.pending.items);
}

test "session pumps bounded transport reads into caller sink" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_pty.testing.Transport.Mem.init(allocator);
    defer mem_pty.deinit();
    try mem_pty.rx.appendSlice(allocator, "abcdef");

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();
    try session.start();

    const Sink = struct {
        out: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,

        pub fn onTransportBytes(self: @This(), bytes: []const u8) void {
            self.out.appendSlice(self.allocator, bytes) catch unreachable;
        }
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var scratch: [3]u8 = undefined;

    const result = session.pumpTransport(scratch[0..], Sink{ .out = &out, .allocator = allocator }, .{ .max_reads = 2, .max_bytes = 5 });
    try std.testing.expect(result.any_read);
    try std.testing.expectEqual(@as(usize, 2), result.reads);
    try std.testing.expectEqual(@as(usize, 5), result.bytes_read);
    try std.testing.expectEqualStrings("abcde", out.items);
    try std.testing.expectEqualStrings("f", mem_pty.rx.items);
}

test "session owns transport pump modes" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_pty.testing.Transport.Mem.init(allocator);
    defer mem_pty.deinit();
    var input: [200 * 1024]u8 = undefined;
    @memset(input[0..], 'x');
    try mem_pty.rx.appendSlice(allocator, input[0..]);

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session.deinit();
    try session.start();

    const Sink = struct {
        pub fn onTransportBytes(_: @This(), _: []const u8) void {}
    };
    var scratch: [64 * 1024]u8 = undefined;

    const constrained = session.pumpTransportMode(scratch[0..], Sink{}, .constrained);
    try std.testing.expect(constrained.any_read);
    try std.testing.expectEqual(@as(usize, 2), constrained.reads);
    try std.testing.expectEqual(@as(usize, 128 * 1024), constrained.bytes_read);

    const normal = session.pumpTransportMode(scratch[0..], Sink{}, .normal);
    try std.testing.expect(normal.any_read);
    try std.testing.expectEqual(@as(usize, 2), normal.reads);
    try std.testing.expectEqual(@as(usize, 72 * 1024), normal.bytes_read);
}

test "session restore normalizes active snapshots to stopped" {
    const allocator = std.testing.allocator;

    var session = try howl_pty.Session.init(.{
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
    try std.testing.expectEqual(howl_pty.Status.stopped, snap.status);
    try std.testing.expectEqual(@as(u32, 7), snap.resize_count);
}

test "session publishes typed control signals through the pty boundary" {
    const allocator = std.testing.allocator;

    var mem_pty = howl_pty.testing.Transport.Mem.init(allocator);
    defer mem_pty.deinit();

    var session = try howl_pty.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
    });
    defer session.deinit();

    try session.attachPty(mem_pty.pty());
    try session.publishControlSignal(.interrupt);
    try std.testing.expectEqual(howl_pty.transport.ControlSignal.interrupt, mem_pty.last_signal.?);
}

test "session transport attachment is owned by session lifecycle" {
    const allocator = std.testing.allocator;

    var first = howl_pty.testing.Transport.Mem.init(allocator);
    defer first.deinit();
    var second = howl_pty.testing.Transport.Mem.init(allocator);
    defer second.deinit();

    var session = try howl_pty.Session.init(.{
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

test "session constructs and owns build selected pty transport" {
    var session = try howl_pty.Session.initPty(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .launch = .{ .shell_path = "/bin/sh" },
    });
    defer session.deinit();

    try std.testing.expectEqual(howl_pty.Status.idle, session.snapshot().status);
    try std.testing.expect(!session.hasOutboundInputBacklog());
}
