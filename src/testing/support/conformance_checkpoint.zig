//! Responsibility: capture session conformance checkpoints for tests.
//! Ownership: test-support checkpoint helpers.
//! Reason: keep boundary assertions concise and reusable.

const types = @import("../../types.zig");
const vt_core = @import("vt_core");

/// Snapshot of observable session state used by conformance tests.
pub const ConformanceCheckpoint = struct {
    status: types.SessionStatus,
    cols: u16,
    rows: u16,
    resize_count: u32,
    last_control_signal: ?vt_core.ControlSignal,
    pending_len: usize,

    /// Copies the session state needed for boundary and conformance checks.
    pub fn capture(s: anytype) ConformanceCheckpoint {
        return .{
            .status = s.status,
            .cols = s.cols,
            .rows = s.rows,
            .resize_count = s.resize_count,
            .last_control_signal = s.last_control_signal,
            .pending_len = s.pending.items.len,
        };
    }

    /// Verifies that two conformance checkpoints describe the same state.
    pub fn expectEqual(expected: ConformanceCheckpoint, actual: ConformanceCheckpoint) !void {
        const std = @import("std");
        try std.testing.expectEqual(expected.status, actual.status);
        try std.testing.expectEqual(expected.cols, actual.cols);
        try std.testing.expectEqual(expected.rows, actual.rows);
        try std.testing.expectEqual(expected.resize_count, actual.resize_count);
        try std.testing.expectEqual(expected.last_control_signal, actual.last_control_signal);
        try std.testing.expectEqual(expected.pending_len, actual.pending_len);
    }
};
