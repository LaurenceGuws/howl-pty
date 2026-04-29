//! Responsibility: assert equality across snapshot payload fields.

pub fn expectSnapshotEqual(expected: anytype, actual: anytype) !void {
    const std = @import("std");
    try std.testing.expectEqual(expected.cols, actual.cols);
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.status, actual.status);
    try std.testing.expectEqual(expected.resize_count, actual.resize_count);
}
