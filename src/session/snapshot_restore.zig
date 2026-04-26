//! Responsibility: define snapshot assertions for session test coverage.
//! Ownership: snapshot/restore test support.
//! Reason: keep snapshot comparison logic explicit and shared.

const std = @import("std");
const core = @import("core.zig");
const Session = core.Session;
const SessionSnapshot = core.SessionSnapshot;
const SessionStatus = core.SessionStatus;
const ControlSignal = core.ControlSignal;
const transport_api = @import("../transport.zig");
const snapshot_assert = @import("../test_support/snapshot_assert.zig");
const ops_checkpoint = @import("../test_support/session_ops_checkpoint.zig");

test "snapshot/restore: round-trip identity" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(132, 50);
    s.control(.interrupt);

    const sn = s.snapshot();
    try snapshot_assert.expectSnapshotEqual(sn, s.snapshot());

    try s.resize(200, 60);
    s.control(.terminate);
    try s.feed("mutated");

    try s.restore(sn);

    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
    try std.testing.expectEqual(ControlSignal.interrupt, s.last_control_signal.?);
    try std.testing.expectEqual(sn.resize_count, s.resize_count);
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "snapshot/restore: restore replaces state after mutations" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    const baseline = s.snapshot();

    try s.resize(100, 40);
    s.control(.hangup);
    try s.feed("queued bytes");

    try std.testing.expect(s.cols != baseline.cols or s.resize_count != baseline.resize_count);

    try s.restore(baseline);

    try snapshot_assert.expectSnapshotEqual(baseline, s.snapshot());
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "snapshot/restore: restore is idempotent" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(120, 48);
    const sn = s.snapshot();

    try s.restore(sn);
    const after_first = s.snapshot();
    try s.restore(sn);
    const after_second = s.snapshot();

    try snapshot_assert.expectSnapshotEqual(after_first, after_second);
}

test "snapshot/restore: invalid snapshot rejected with no partial mutation" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(100, 40);
    s.control(.terminate);
    const before = s.snapshot();

    const bad_cols = SessionSnapshot{
        .cols = 0,
        .rows = 24,
        .status = .idle,
        .resize_count = 0,
        .last_control_signal = null,
    };
    try std.testing.expectError(error.InvalidSnapshot, s.restore(bad_cols));
    try snapshot_assert.expectSnapshotEqual(before, s.snapshot());

    const bad_rows = SessionSnapshot{
        .cols = 80,
        .rows = 0,
        .status = .idle,
        .resize_count = 0,
        .last_control_signal = null,
    };
    try std.testing.expectError(error.InvalidSnapshot, s.restore(bad_rows));
    try snapshot_assert.expectSnapshotEqual(before, s.snapshot());
}

test "snapshot/restore: active status in snapshot restores as stopped" {
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
    try std.testing.expectEqual(SessionStatus.active, s.status);

    const active_snap = s.snapshot();
    try std.testing.expectEqual(SessionStatus.active, active_snap.status);

    s.stop();
    try s.restore(active_snap);
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

test "snapshot/restore: transport attachment unchanged by restore" {
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

    const sn = s.snapshot();
    try s.restore(sn);

    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    s.stop();
}

test "snapshot/restore: pending queue cleared on restore" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    const sn = s.snapshot();

    try s.feed("some bytes");
    try std.testing.expect(s.pending.items.len > 0);

    try s.restore(sn);
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
    try std.testing.expectEqual(@as(usize, 256), s.pending_capacity);
}

test "snapshot/restore: ops counters unaffected by restore" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
    });
    defer s.deinit();

    try s.feed("data");
    _ = s.apply();
    s.control(.interrupt);

    const ops_before = ops_checkpoint.SessionOpsCheckpoint.capture(&s);
    const sn = s.snapshot();

    try s.resize(100, 40);
    const ops_pre_restore = ops_checkpoint.SessionOpsCheckpoint.capture(&s);
    try s.restore(sn);

    const ops_after = ops_checkpoint.SessionOpsCheckpoint.capture(&s);

    try std.testing.expectEqual(ops_before.resize_valid_calls + 1, ops_pre_restore.resize_valid_calls);
    try ops_checkpoint.SessionOpsCheckpoint.expectEqual(ops_pre_restore, ops_after);
}
