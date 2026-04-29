//! Responsibility: publish stable howl-session package API.
//! Ownership: package export boundary and local test wiring.
//! Reason: keep consumers decoupled from internal file topology.

const std = @import("std");

pub const session = @import("session.zig");
pub const Session = session.Session;
pub const SessionConfig = session.Config;
pub const SessionStatus = session.Status;
pub const TransportClass = session.TransportClass;

pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const Mem = transport.Mem;
pub const Partial = transport.Partial;
pub const Fail = transport.Fail;
pub const AndroidPty = transport.AndroidPty;
pub const UnixPty = transport.UnixPty;
pub const Lane = transport.Lane;
pub const transport_class = transport.transport_class;
pub const init = transport.init;

// Compatibility aliases for in-file migrated tests.
pub const MemTransport = Mem;
pub const PartialTransport = Partial;
pub const FailTransport = Fail;
pub const AndroidPtyTransport = AndroidPty;
pub const UnixPtyTransport = UnixPty;
pub const initTransport = init;

test "facade wiring" {
    const s = @import("session.zig");
    const t = @import("transport.zig");
    comptime {
        std.debug.assert(Session == s.Session);
        std.debug.assert(SessionConfig == s.Config);
        std.debug.assert(Transport == t.Transport);
        std.debug.assert(Mem == t.Mem);
        std.debug.assert(Fail == t.Fail);
    }
}

test "api exports compile" {
    _ = Session;
    _ = SessionConfig;
    _ = SessionStatus;
    _ = TransportClass;
    _ = Transport;
    _ = MemTransport;
    _ = PartialTransport;
    _ = FailTransport;
    _ = AndroidPtyTransport;
    _ = UnixPtyTransport;
    _ = transport_class;
    _ = initTransport;
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
        .transport = null,
    }));
}

test "feed apply without transport drains queue" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .transport = null,
    });
    defer s.deinit();

    try s.feed("hello");
    try std.testing.expectEqual(@as(usize, 5), s.apply());
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "start stop with mem transport" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();

    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 64,
        .transport = mt.transport(),
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
        .transport = null,
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
        .transport = null,
    });
    defer s.deinit();

    try s.resize(90, 30);
    const snap = s.snapshot();

    try s.resize(120, 50);
    try s.restore(snap);
    try std.testing.expectEqual(@as(u16, 90), s.cols);
    try std.testing.expectEqual(@as(u16, 30), s.rows);
}

// Responsibility: assert equality across snapshot payload fields.
pub fn expectSnapshotEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(expected.cols, actual.cols);
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.status, actual.status);
    try std.testing.expectEqual(expected.resize_count, actual.resize_count);
}

// Responsibility: capture session operation counters for tests.
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

// Responsibility: capture session checkpoints for tests.
pub const ConformanceCheckpoint = struct {
    status: SessionStatus,
    cols: u16,
    rows: u16,
    resize_count: u32,
    pending_len: usize,

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
