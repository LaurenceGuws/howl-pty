//! Responsibility: capture session operation counters for tests.
//! Ownership: ops checkpoint test helpers.
//! Reason: compare operation deltas without duplicating extraction code.

/// Snapshot of session operation counters for comparing test runs.
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
    control_calls: u32,

    /// Copies the current session operation counters into a checkpoint value.
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
            .control_calls = s.ops.control_calls,
        };
    }

    /// Verifies that two checkpoints contain the same operation counts.
    pub fn expectEqual(expected: SessionOpsCheckpoint, actual: SessionOpsCheckpoint) !void {
        const std = @import("std");
        try std.testing.expectEqual(expected.start_attempts, actual.start_attempts);
        try std.testing.expectEqual(expected.start_successes, actual.start_successes);
        try std.testing.expectEqual(expected.start_failures, actual.start_failures);
        try std.testing.expectEqual(expected.stop_calls, actual.stop_calls);
        try std.testing.expectEqual(expected.feed_accepted, actual.feed_accepted);
        try std.testing.expectEqual(expected.feed_rejected, actual.feed_rejected);
        try std.testing.expectEqual(expected.bytes_fed, actual.bytes_fed);
        try std.testing.expectEqual(expected.bytes_applied, actual.bytes_applied);
        try std.testing.expectEqual(expected.apply_calls, actual.apply_calls);
        try std.testing.expectEqual(expected.reset_calls, actual.reset_calls);
        try std.testing.expectEqual(expected.resize_valid_calls, actual.resize_valid_calls);
        try std.testing.expectEqual(expected.resize_invalid_calls, actual.resize_invalid_calls);
        try std.testing.expectEqual(expected.resize_transport_errors, actual.resize_transport_errors);
        try std.testing.expectEqual(expected.control_calls, actual.control_calls);
    }
};
