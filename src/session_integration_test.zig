const builtin = @import("builtin");
const std = @import("std");
const session = @import("session.zig");

const real_pty_timeout_ms: i32 = 100;
const real_pty_max_turns: u32 = 50;

fn requireOwnedUnixPty() !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }
}

fn trimTransportLine(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, "\r\n \t");
}

fn waitForOwnedSessionStop(session_state: *session.Session) !void {
    var turns: u32 = 0;
    var scratch: [256]u8 = undefined;
    while (turns < real_pty_max_turns) : (turns += 1) {
        if (session_state.snapshot().status == .stopped) return;
        const ready = session_state.waitReadable(real_pty_timeout_ms);
        if (ready) {
            _ = session_state.readTransport(scratch[0..]);
        }
    }
    return error.TestTimeout;
}

fn readOwnedSessionLine(session_state: *session.Session, line_buf: []u8) ![]const u8 {
    var filled: usize = 0;
    var turns: u32 = 0;
    while (turns < real_pty_max_turns) : (turns += 1) {
        if (filled == line_buf.len) return error.TestBufferFull;
        const ready = session_state.waitReadable(real_pty_timeout_ms);
        if (!ready) {
            if (session_state.last_wait_outcome == .stopped) return error.UnexpectedTransportStop;
            continue;
        }
        const read_count = session_state.readTransport(line_buf[filled..]);
        try std.testing.expect(read_count > 0);
        filled += read_count;
        if (std.mem.indexOfScalar(u8, line_buf[0..filled], '\n') != null) break;
    }

    const line_end = std.mem.indexOfScalar(u8, line_buf[0..filled], '\n') orelse return error.TestTimeout;
    return trimTransportLine(line_buf[0..line_end]);
}

test "session constructs and owns build selected pty transport" {
    try requireOwnedUnixPty();

    var session_state = try session.Session.init(.{
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

test "owned unix session natural child exit stops and stays stable" {
    try requireOwnedUnixPty();

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .launch = .{ .shell_path = "/bin/sh", .command = "sleep 0.05" },
    });
    defer session_state.deinit();
    try session_state.start();

    try waitForOwnedSessionStop(&session_state);
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.stopped, snapshot.status);
    try std.testing.expectEqual(session.TerminalReason.child_exit, snapshot.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, snapshot.last_wait_outcome);
    try std.testing.expectEqual(session.TerminalReason.child_exit, session_state.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, session_state.last_wait_outcome);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), session_state.readTransport(buf[0..]));
    try std.testing.expect(!session_state.waitReadable(real_pty_timeout_ms));
    try std.testing.expectEqual(session.WaitOutcome.stopped, session_state.last_wait_outcome);
}

test "owned unix session explicit stop remains idempotent" {
    try requireOwnedUnixPty();

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .launch = .{ .shell_path = "/bin/sh", .command = "sleep 30" },
    });
    defer session_state.deinit();
    try session_state.start();

    session_state.stop();
    session_state.stop();

    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.stopped, snapshot.status);
    try std.testing.expectEqual(session.TerminalReason.explicit_stop, snapshot.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, snapshot.last_wait_outcome);
    try std.testing.expectEqual(session.TerminalReason.explicit_stop, session_state.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, session_state.last_wait_outcome);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), session_state.readTransport(buf[0..]));
    try std.testing.expect(!session_state.waitReadable(real_pty_timeout_ms));
    try std.testing.expectEqual(session.WaitOutcome.stopped, session_state.last_wait_outcome);

    try session_state.publishControlSignal(.interrupt);
    try session_state.resize(100, 40);
    try std.testing.expectEqual(session.Status.stopped, session_state.snapshot().status);
    try std.testing.expectEqual(session.TerminalReason.explicit_stop, session_state.terminal_reason.?);
}

test "owned unix session wake unblocks wait without terminal stop" {
    try requireOwnedUnixPty();

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .launch = .{ .shell_path = "/bin/sh", .command = "sleep 30" },
    });
    defer session_state.deinit();
    try session_state.start();

    const KickThread = struct {
        fn run(state: *session.Session) void {
            state.kickTransportWait();
        }
    };

    const thread = try std.Thread.spawn(.{}, KickThread.run, .{&session_state});
    defer thread.join();

    try std.testing.expect(!session_state.waitReadable(-1));
    try std.testing.expectEqual(session.WaitOutcome.wake, session_state.last_wait_outcome);
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.active, snapshot.status);
    try std.testing.expectEqual(@as(?session.TerminalReason, null), snapshot.terminal_reason);
    try std.testing.expectEqual(session.WaitOutcome.wake, snapshot.last_wait_outcome);
    try std.testing.expectEqual(@as(?session.TerminalReason, null), session_state.terminal_reason);

    session_state.stop();
}

test "owned unix session applies resize before start to child visible startup size" {
    try requireOwnedUnixPty();

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .launch = .{ .shell_path = "/bin/sh", .command = "stty size; sleep 30" },
    });
    defer session_state.deinit();

    try session_state.resize(132, 43);
    try session_state.start();

    var line_buf: [128]u8 = undefined;
    const line = try readOwnedSessionLine(&session_state, line_buf[0..]);
    try std.testing.expectEqualStrings("43 132", line);

    session_state.stop();
}
