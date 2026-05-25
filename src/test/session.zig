const builtin = @import("builtin");
const std = @import("std");
const session = @import("../session.zig");
const pty_api = @import("../pty.zig");
const pty = @import("../pty/pty_test.zig");

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

const ScriptedPty = struct {
    started: bool = false,
    stop_calls: u32 = 0,
    write_calls: u32 = 0,
    wait_index: usize = 0,
    read_index: usize = 0,
    wait_steps: []const WaitStep = &.{},
    read_steps: []const ReadStep = &.{},
    write_step: WriteStep = .ok,

    const WaitStep = union(enum) {
        ready,
        timeout,
        wake,
        err: pty_api.Pty.WaitReadableError,
    };

    const ReadStep = union(enum) {
        bytes: []const u8,
        err: pty_api.Pty.ReadError,
    };

    const WriteStep = union(enum) {
        ok,
        err: pty_api.Pty.WriteError,
    };

    fn pty(self: *ScriptedPty) pty_api.Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: pty_api.Pty.VTable = .{
        .start = startPty,
        .stop = stopPty,
        .write = writePty,
        .read = readPty,
        .wait_readable = waitReadablePty,
        .kick_wait = kickWaitPty,
        .resize = resizePty,
        .control = controlPty,
    };

    fn startPty(ptr: *anyopaque, cols: u16, rows: u16) pty_api.Pty.StartError!void {
        const self: *ScriptedPty = @ptrCast(@alignCast(ptr));
        _ = cols;
        _ = rows;
        if (self.started) return error.AlreadyStarted;
        self.started = true;
    }

    fn stopPty(ptr: *anyopaque) void {
        const self: *ScriptedPty = @ptrCast(@alignCast(ptr));
        self.stop_calls += 1;
        self.started = false;
    }

    fn writePty(ptr: *anyopaque, bytes: []const u8) pty_api.Pty.WriteError!usize {
        const self: *ScriptedPty = @ptrCast(@alignCast(ptr));
        self.write_calls += 1;
        if (!self.started) return error.NotStarted;
        return switch (self.write_step) {
            .ok => bytes.len,
            .err => |err| err,
        };
    }

    fn readPty(ptr: *anyopaque, buf: []u8) pty_api.Pty.ReadError!usize {
        const self: *ScriptedPty = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        std.debug.assert(self.read_index < self.read_steps.len);
        const step = self.read_steps[self.read_index];
        self.read_index += 1;
        return switch (step) {
            .bytes => |bytes| blk: {
                std.debug.assert(bytes.len <= buf.len);
                @memcpy(buf[0..bytes.len], bytes);
                break :blk bytes.len;
            },
            .err => |err| err,
        };
    }

    fn waitReadablePty(ptr: *anyopaque, timeout_ms: i32) pty_api.Pty.WaitReadableError!pty_api.Pty.WaitReadableResult {
        const self: *ScriptedPty = @ptrCast(@alignCast(ptr));
        _ = timeout_ms;
        if (!self.started) return error.NotStarted;
        std.debug.assert(self.wait_index < self.wait_steps.len);
        const step = self.wait_steps[self.wait_index];
        self.wait_index += 1;
        return switch (step) {
            .ready => .ready,
            .timeout => .timeout,
            .wake => .wake,
            .err => |err| err,
        };
    }

    fn kickWaitPty(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn resizePty(ptr: *anyopaque, cols: u16, rows: u16) pty_api.Pty.ResizeError!void {
        _ = ptr;
        _ = cols;
        _ = rows;
    }

    fn controlPty(ptr: *anyopaque, signal: pty_api.ControlSignal) void {
        _ = ptr;
        _ = signal;
    }
};

fn expectPendingBytes(state: *const session.Session, expected: []const u8) !void {
    try std.testing.expectEqual(expected.len, state.pending.count);
    if (state.pending.count == 0) return;
    const first_len = @min(state.pending.count, state.pending.buffer.len - state.pending.head);
    const first = state.pending.buffer[state.pending.head .. state.pending.head + first_len];
    try std.testing.expect(expected.len >= first.len);
    try std.testing.expectEqualSlices(u8, expected[0..first.len], first);

    const second_len = expected.len - first.len;
    if (second_len == 0) return;
    try std.testing.expectEqualSlices(u8, expected[first.len..], state.pending.buffer[0..second_len]);
}

test "session owner and internal pty plumbing interoperate" {
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
    try std.testing.expectEqual(@as(u8, 15), pty_api.ControlSignal.terminate.raw());
    try std.testing.expectEqual(@as(u8, 3), pty_api.ControlSignal.resize_notify.raw());
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
    try std.testing.expectEqual(@as(u32, 0), session_state.pending.count);
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
    try expectPendingBytes(&session_state, "def");

    try std.testing.expectEqual(@as(u32, 3), session_state.flushOutboundInput());
    try std.testing.expectEqualStrings("abcdef", partial_pty.tx.items);
    try std.testing.expectEqual(@as(u32, 0), session_state.pending.count);
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
    try expectPendingBytes(&session_state, "def");
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
    try expectPendingBytes(&session_state, "abc");

    const pumped = session_state.pumpOutboundInput(false);
    try std.testing.expect(pumped.had_pending);
    try std.testing.expectEqual(@as(u32, 0), pumped.drained);
    try std.testing.expect(pumped.has_pending);
    try std.testing.expect(!pumped.wait_readable);
}

test "session reuses preallocated outbound queue across wraparound" {
    const allocator = std.testing.allocator;

    var partial_pty = pty.Partial.init(allocator, 3);
    defer partial_pty.deinit();

    var session_state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 6,
        .pty = partial_pty.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    try session_state.publishHostInput("abcdef");
    try std.testing.expectEqual(@as(u32, 3), session_state.flushOutboundInput());
    try expectPendingBytes(&session_state, "def");

    try session_state.publishHostInput("gh");
    try expectPendingBytes(&session_state, "defgh");

    try std.testing.expectEqual(@as(u32, 3), session_state.flushOutboundInput());
    try expectPendingBytes(&session_state, "gh");

    try std.testing.expectEqual(@as(u32, 2), session_state.flushOutboundInput());
    try std.testing.expectEqualStrings("abcdefgh", partial_pty.tx.items);
    try std.testing.expectEqual(@as(u32, 0), session_state.pending.count);
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

test "session publishes typed control signals through the pty boundary" {
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

    try session_state.publishControlSignal(.interrupt);
    try std.testing.expectEqual(pty_api.ControlSignal.interrupt, mem_pty.last_signal.?);
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

test "session wake breaks wait without terminal stop" {
    var scripted = ScriptedPty{
        .wait_steps = &.{.wake},
    };

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = scripted.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    try std.testing.expect(!session_state.waitReadable(1));
    try std.testing.expectEqual(session.WaitOutcome.wake, session_state.last_wait_outcome);
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.active, snapshot.status);
    try std.testing.expectEqual(@as(?session.TerminalReason, null), snapshot.terminal_reason);
    try std.testing.expectEqual(session.WaitOutcome.wake, snapshot.last_wait_outcome);
    try std.testing.expectEqual(@as(?session.TerminalReason, null), session_state.terminal_reason);
    try std.testing.expectEqual(@as(u32, 0), scripted.stop_calls);
}

test "session timeout leaves session non terminal" {
    var scripted = ScriptedPty{
        .wait_steps = &.{.timeout},
    };

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = scripted.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    try std.testing.expect(!session_state.waitReadable(1));
    try std.testing.expectEqual(session.WaitOutcome.timeout, session_state.last_wait_outcome);
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.active, snapshot.status);
    try std.testing.expectEqual(@as(?session.TerminalReason, null), snapshot.terminal_reason);
    try std.testing.expectEqual(session.WaitOutcome.timeout, snapshot.last_wait_outcome);
    try std.testing.expectEqual(@as(?session.TerminalReason, null), session_state.terminal_reason);
    try std.testing.expectEqual(@as(u32, 0), scripted.stop_calls);
}

test "session read fatal path stops once and stays stable" {
    var scripted = ScriptedPty{
        .read_steps = &.{.{ .err = error.ReadFailed }},
    };

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = scripted.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), session_state.readTransport(buf[0..]));
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.stopped, snapshot.status);
    try std.testing.expectEqual(session.TerminalReason.transport_failure, snapshot.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, snapshot.last_wait_outcome);
    try std.testing.expectEqual(session.TerminalReason.transport_failure, session_state.terminal_reason.?);
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);

    try std.testing.expectEqual(@as(u32, 0), session_state.readTransport(buf[0..]));
    try std.testing.expect(!session_state.waitReadable(1));
    try std.testing.expectEqual(session.WaitOutcome.stopped, session_state.last_wait_outcome);
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);
}

test "session write fatal path stops once and stays stable" {
    var scripted = ScriptedPty{
        .write_step = .{ .err = error.WriteFailed },
    };

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = scripted.pty(),
    });
    defer session_state.deinit();
    try session_state.start();
    try session_state.publishHostInput("x");

    try std.testing.expectEqual(@as(u32, 0), session_state.flushOutboundInput());
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.stopped, snapshot.status);
    try std.testing.expectEqual(session.TerminalReason.transport_failure, snapshot.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, snapshot.last_wait_outcome);
    try std.testing.expectEqual(session.TerminalReason.transport_failure, session_state.terminal_reason.?);
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);
    try std.testing.expectEqual(@as(u32, 1), scripted.write_calls);

    try std.testing.expectEqual(@as(u32, 0), session_state.flushOutboundInput());
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);
    try std.testing.expectEqual(@as(u32, 1), scripted.write_calls);
}

test "session child exit path stops once and stays stopped" {
    var scripted = ScriptedPty{
        .wait_steps = &.{.{ .err = error.NotStarted }},
    };

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = scripted.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    try std.testing.expect(!session_state.waitReadable(1));
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.stopped, snapshot.status);
    try std.testing.expectEqual(session.TerminalReason.child_exit, snapshot.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, snapshot.last_wait_outcome);
    try std.testing.expectEqual(session.TerminalReason.child_exit, session_state.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, session_state.last_wait_outcome);
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);

    try std.testing.expectEqual(@as(u32, 0), session_state.flushOutboundInput());
    try std.testing.expect(!session_state.waitReadable(1));
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);
}

test "session eof path stops once and stays stopped" {
    var scripted = ScriptedPty{
        .read_steps = &.{.{ .err = error.EndOfStream }},
    };

    var session_state = try session.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = scripted.pty(),
    });
    defer session_state.deinit();
    try session_state.start();

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), session_state.readTransport(buf[0..]));
    const snapshot = session_state.snapshot();
    try std.testing.expectEqual(session.Status.stopped, snapshot.status);
    try std.testing.expectEqual(session.TerminalReason.transport_eof, snapshot.terminal_reason.?);
    try std.testing.expectEqual(session.WaitOutcome.stopped, snapshot.last_wait_outcome);
    try std.testing.expectEqual(session.TerminalReason.transport_eof, session_state.terminal_reason.?);
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);

    try std.testing.expectEqual(@as(u32, 0), session_state.readTransport(buf[0..]));
    try std.testing.expectEqual(@as(u32, 1), scripted.stop_calls);
}

test "session constructs and owns build selected pty transport" {
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
