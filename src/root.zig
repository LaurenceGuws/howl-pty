//! Responsibility: publish stable howl-session package API.
//! Ownership: package export boundary and local test wiring.
//! Reason: keep consumers decoupled from internal file topology.

const std = @import("std");

/// Session implementation module.
pub const session = @import("session.zig");
/// Session runtime type.
pub const Session = session.Session;
/// Session config type.
pub const SessionConfig = session.Config;
/// Session lifecycle status type.
pub const SessionStatus = session.Status;
/// PTY class enum.
pub const PtyClass = session.PtyClass;

/// PTY implementation module.
pub const pty = @import("pty.zig");
/// PTY interface type.
pub const Pty = pty.Pty;
/// In-memory PTY implementation.
pub const Mem = pty.Mem;
/// Partial-write PTY implementation.
pub const Partial = pty.Partial;
/// Failing PTY implementation.
pub const Fail = pty.Fail;
/// Android PTY implementation.
pub const AndroidPty = pty.AndroidPty;
/// Unix PTY implementation.
pub const UnixPty = pty.UnixPty;
/// Build-selected PTY implementation type.
pub const PtyImpl = pty.PtyImpl;
/// Build-selected PTY class value.
pub const pty_class = pty.pty_class;
/// PTY initializer function alias.
pub const init_pty = pty.init;

/// Compatibility alias for in-file migrated tests.
pub const MemPty = Mem;
/// Compatibility alias for in-file migrated tests.
pub const PartialPty = Partial;
/// Compatibility alias for in-file migrated tests.
pub const FailPty = Fail;
/// Compatibility alias for in-file migrated tests.
pub const AndroidPtyImpl = AndroidPty;
/// Compatibility alias for in-file migrated tests.
pub const UnixPtyImpl = UnixPty;
/// Compatibility alias for in-file migrated tests.
pub const initPty = init_pty;

test "facade wiring" {
    const s = @import("session.zig");
    const t = @import("pty.zig");
    comptime {
        std.debug.assert(Session == s.Session);
        std.debug.assert(SessionConfig == s.Config);
        std.debug.assert(Pty == t.Pty);
        std.debug.assert(Mem == t.Mem);
        std.debug.assert(Fail == t.Fail);
    }
}

test "api exports compile" {
    _ = Session;
    _ = SessionConfig;
    _ = SessionStatus;
    _ = PtyClass;
    _ = Pty;
    _ = MemPty;
    _ = PartialPty;
    _ = FailPty;
    _ = AndroidPtyImpl;
    _ = UnixPtyImpl;
    _ = pty_class;
    _ = initPty;
}

test "session method surface" {
    comptime {
        _ = Session.init;
        _ = Session.deinit;
        _ = Session.start;
        _ = Session.stop;
        _ = Session.feed;
        _ = Session.apply;
        _ = Session.reset;
        _ = Session.resize;
        _ = Session.snapshot;
        _ = Session.restore;
        std.debug.assert(@hasField(Session, "cols"));
        std.debug.assert(@hasField(Session, "rows"));
        std.debug.assert(@hasField(Session, "status"));
    }
}

test "init invalid config" {
    try std.testing.expectError(error.InvalidConfig, Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 0,
        .rows = 24,
        .pending_capacity = 32,
        .pty = null,
    }));
}

test "feed apply without pty drains queue" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .pty = null,
    });
    defer s.deinit();

    try s.feed("hello");
    try std.testing.expectEqual(@as(usize, 5), s.apply());
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "start stop with mem pty" {
    var mt = MemPty.init(std.testing.allocator);
    defer mt.deinit();

    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .pty = mt.pty(),
    });
    defer s.deinit();

    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

test "resize updates dims and counter" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .pty = null,
    });
    defer s.deinit();

    try s.resize(100, 40);
    try std.testing.expectEqual(@as(u16, 100), s.cols);
    try std.testing.expectEqual(@as(u16, 40), s.rows);
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
}

test "snapshot restore" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .pty = null,
    });
    defer s.deinit();

    try s.resize(90, 30);
    const snap = s.snapshot();

    try s.resize(120, 50);
    try s.restore(snap);
    try std.testing.expectEqual(@as(u16, 90), s.cols);
    try std.testing.expectEqual(@as(u16, 30), s.rows);
}

/// Assert equality across snapshot payload fields.
pub fn expectSnapshotEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(expected.cols, actual.cols);
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.status, actual.status);
    try std.testing.expectEqual(expected.resize_count, actual.resize_count);
}

/// Capture session operation counters for tests.
pub const SessionOpsCheckpoint = struct {
    start_attempts: u32,
    start_successes: u32,
    start_failures: u32,
    stop_calls: u32,
    feed_accepted: u32,
    feed_rejected: u32,
    bytes_fed: u64,
    bytes_applied: u64,
    apply_calls: u32,
    reset_calls: u32,
    resize_valid_calls: u32,
    resize_invalid_calls: u32,
    resize_transport_errors: u32,

    /// Capture counters from session-like object.
    pub fn capture(s: anytype) SessionOpsCheckpoint {
        return .{
            .start_attempts = s.ops.start_attempts,
            .start_successes = s.ops.start_successes,
            .start_failures = s.ops.start_failures,
            .stop_calls = s.ops.stop_calls,
            .feed_accepted = s.ops.feed_accepted,
            .feed_rejected = s.ops.feed_rejected,
            .bytes_fed = s.ops.bytes_fed,
            .bytes_applied = s.ops.bytes_applied,
            .apply_calls = s.ops.apply_calls,
            .reset_calls = s.ops.reset_calls,
            .resize_valid_calls = s.ops.resize_valid_calls,
            .resize_invalid_calls = s.ops.resize_invalid_calls,
            .resize_transport_errors = s.ops.resize_transport_errors,
        };
    }
};

/// Capture session checkpoints for tests.
pub const ConformanceCheckpoint = struct {
    status: SessionStatus,
    cols: u16,
    rows: u16,
    resize_count: u32,
    pending_len: usize,

    /// Capture checkpoint from session-like object.
    pub fn capture(s: anytype) ConformanceCheckpoint {
        return .{
            .status = s.status,
            .cols = s.cols,
            .rows = s.rows,
            .resize_count = s.resize_count,
            .pending_len = s.pending.items.len,
        };
    }
};
