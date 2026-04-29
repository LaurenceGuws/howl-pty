//! Responsibility: capture session checkpoints for tests.
//! Ownership: test helper for session observability assertions.
//! Reason: keep checkpoint assertions concise.

const types = @import("../../types.zig");

pub const ConformanceCheckpoint = struct {
    status: types.SessionStatus,
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

    pub fn expectEqual(expected: ConformanceCheckpoint, actual: ConformanceCheckpoint) !void {
        const std = @import("std");
        try std.testing.expectEqual(expected.status, actual.status);
        try std.testing.expectEqual(expected.cols, actual.cols);
        try std.testing.expectEqual(expected.rows, actual.rows);
        try std.testing.expectEqual(expected.resize_count, actual.resize_count);
        try std.testing.expectEqual(expected.pending_len, actual.pending_len);
    }
};
