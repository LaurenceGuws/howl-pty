const std = @import("std");
const session = @import("../session.zig");
const pty = @import("../pty.zig");

test "session and pty owners stay directly importable" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer state.deinit();

    try std.testing.expectEqual(session.Status.idle, state.snapshot().status);
    try std.testing.expectEqual(pty.PtyClass, @TypeOf(pty.pty_class));
    try std.testing.expectEqual(@as(u8, 15), pty.ControlSignal.terminate.raw());
    try std.testing.expectEqual(@as(u8, 3), pty.ControlSignal.resize_notify.raw());
}

test "session flushes outbound input deterministically" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session_state.deinit();

    try session_state.start();
    try std.testing.expect(session_state.isActive());
    try session_state.publishHostInput("ping");

    const drained = session_state.flushOutboundInput();
    try std.testing.expectEqual(@as(u32, 4), drained);
    try std.testing.expectEqualStrings("ping", mem_pty.tx.items);
    try std.testing.expectEqual(@as(u64, 4), session_state.ops.bytes_fed);
    try std.testing.expectEqual(@as(u64, 4), session_state.ops.bytes_applied);
    try std.testing.expect(session_state.pending.items.len == 0);
    session_state.stop();
    try std.testing.expect(!session_state.isActive());
}

test "session start applies owned initial size to transport" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 132,
        .rows = 43,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session_state.deinit();

    try session_state.start();
    try std.testing.expectEqual(@as(u16, 132), mem_pty.last_cols);
    try std.testing.expectEqual(@as(u16, 43), mem_pty.last_rows);
}

test "session preserves remainder after partial transport write" {
    const allocator = std.testing.allocator;

    var partial_pty = pty.Partial.init(allocator, 3);
    defer partial_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = partial_pty.pty(),
    });
    defer session_state.deinit();

    try session_state.start();
    try session_state.publishHostInput("abcdef");

    try std.testing.expectEqual(@as(u32, 3), session_state.flushOutboundInput());
    try std.testing.expectEqualStrings("abc", partial_pty.tx.items);
    try std.testing.expectEqualStrings("def", session_state.pending.items);

    try std.testing.expectEqual(@as(u32, 3), session_state.flushOutboundInput());
    try std.testing.expectEqualStrings("abcdef", partial_pty.tx.items);
    try std.testing.expect(session_state.pending.items.len == 0);
}

test "session pumps outbound input and reports readable wait policy" {
    const allocator = std.testing.allocator;

    var partial_pty = pty.Partial.init(allocator, 3);
    defer partial_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = partial_pty.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    const idle = session_state.pumpOutboundInput(false);
    try std.testing.expect(!idle.had_pending);
    try std.testing.expectEqual(@as(u32, 0), idle.drained);
    try std.testing.expect(!idle.has_pending);
    try std.testing.expect(idle.wait_readable);

    try session_state.publishHostInput("abcdef");
    const active = session_state.pumpOutboundInput(false);
    try std.testing.expect(active.had_pending);
    try std.testing.expectEqual(@as(u32, 3), active.drained);
    try std.testing.expect(active.has_pending);
    try std.testing.expect(!active.wait_readable);
    try std.testing.expectEqualStrings("abc", partial_pty.tx.items);
    try std.testing.expectEqualStrings("def", session_state.pending.items);
}

test "session preserves outbound input when no transport is attached" {
    const allocator = std.testing.allocator;

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
    });
    defer session_state.deinit();

    try session_state.publishHostInput("abc");
    try std.testing.expectEqual(@as(u32, 0), session_state.flushOutboundInput());
    try std.testing.expectEqualStrings("abc", session_state.pending.items);

    const pumped = session_state.pumpOutboundInput(false);
    try std.testing.expect(pumped.had_pending);
    try std.testing.expectEqual(@as(u32, 0), pumped.drained);
    try std.testing.expect(pumped.has_pending);
    try std.testing.expect(!pumped.wait_readable);
}

test "session publishes and pumps host input for thread backlog" {
    const allocator = std.testing.allocator;

    var partial_pty = pty.Partial.init(allocator, 2);
    defer partial_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = partial_pty.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    const pumped = try session_state.publishHostInputAndPump("hello");
    try std.testing.expect(pumped.had_pending);
    try std.testing.expectEqual(@as(u32, 2), pumped.drained);
    try std.testing.expect(pumped.has_pending);
    try std.testing.expect(!pumped.wait_readable);
    try std.testing.expectEqualStrings("he", partial_pty.tx.items);
    try std.testing.expectEqualStrings("llo", session_state.pending.items);
}

test "session pumps bounded transport reads into caller sink" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();
    try mem_pty.rx.appendSlice(allocator, "abcdef");

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

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

    const result = session_state.pumpTransport(scratch[0..], Sink{ .out = &out, .allocator = allocator }, .{
        .chunk_bytes = session.transport_chunk_bytes,
        .max_reads = 2,
        .max_bytes = 5,
    });
    try std.testing.expect(result.any_read);
    try std.testing.expectEqual(@as(u32, 2), result.reads);
    try std.testing.expectEqual(@as(u32, 5), result.bytes_read);
    try std.testing.expectEqualStrings("abcde", out.items);
    try std.testing.expectEqualStrings("f", mem_pty.rx.items);
}

test "session owns transport pump modes" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();
    var input: [200 * 1024]u8 = undefined;
    @memset(input[0..], 'x');
    try mem_pty.rx.appendSlice(allocator, input[0..]);

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 16,
        .pty = mem_pty.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    const Sink = struct {
        pub fn onTransportBytes(_: @This(), _: []const u8) void {}
    };
    const limits = session.Session.transportPumpLimits(.normal);
    try std.testing.expectEqual(session.transport_chunk_bytes, limits.chunk_bytes);
    var scratch: [session.transport_chunk_bytes]u8 = undefined;

    const constrained = session_state.pumpTransportMode(scratch[0..], Sink{}, .constrained);
    try std.testing.expect(constrained.any_read);
    try std.testing.expectEqual(@as(u32, 2), constrained.reads);
    try std.testing.expectEqual(@as(u32, 128 * 1024), constrained.bytes_read);

    const normal = session_state.pumpTransportMode(scratch[0..], Sink{}, .normal);
    try std.testing.expect(normal.any_read);
    try std.testing.expectEqual(@as(u32, 2), normal.reads);
    try std.testing.expectEqual(@as(u32, 72 * 1024), normal.bytes_read);

    const constrained_limits = session.Session.transportPumpLimits(.constrained);
    try std.testing.expectEqual(session.transport_chunk_bytes, constrained_limits.chunk_bytes);
}

test "session restore normalizes active snapshots to stopped" {
    const allocator = std.testing.allocator;

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
    });
    defer session_state.deinit();

    try session_state.restore(.{
        .cols = 132,
        .rows = 40,
        .status = .active,
        .resize_count = 7,
    });

    const snap = session_state.snapshot();
    try std.testing.expectEqual(@as(u16, 132), snap.cols);
    try std.testing.expectEqual(@as(u16, 40), snap.rows);
    try std.testing.expectEqual(session.Status.stopped, snap.status);
    try std.testing.expectEqual(@as(u32, 7), snap.resize_count);
}

test "session publishes typed control signals through the pty boundary" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
    });
    defer session_state.deinit();

    try session_state.attachPty(mem_pty.pty());
    try session_state.publishControlSignal(.interrupt);
    try std.testing.expectEqual(pty.ControlSignal.interrupt, mem_pty.last_signal.?);
}

test "session transport attachment is owned by session lifecycle" {
    const allocator = std.testing.allocator;

    var first = pty.Mem.init(allocator);
    defer first.deinit();
    var second = pty.Mem.init(allocator);
    defer second.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = first.pty(),
    });
    defer session_state.deinit();

    try session_state.attachPty(second.pty());
    try session_state.start();
    try std.testing.expectError(error.SessionActive, session_state.detachPty());
    session_state.stop();
    try session_state.detachPty();
    try std.testing.expectError(error.TransportUnavailable, session_state.publishControlSignal(.terminate));
}

test "session stops transport on fatal write failure" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = mem_pty.pty(),
    });
    defer session_state.deinit();

    try session_state.start();
    try session_state.publishHostInput("x");
    mem_pty.pty().stop();

    try std.testing.expectEqual(@as(u32, 0), session_state.flushOutboundInput());
    try std.testing.expectEqual(session.Status.stopped, session_state.snapshot().status);
}

test "session constructs and owns build selected pty transport" {
    var session_state = try session.Session.initPty(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .launch = .{ .shell_path = "/bin/sh" },
    });
    defer session_state.deinit();

    try std.testing.expectEqual(session.Status.idle, session_state.snapshot().status);
    try std.testing.expect(!session_state.hasOutboundInputBacklog());
}
