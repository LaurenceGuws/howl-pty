const std = @import("std");
const Session = @import("../session.zig").Session;
const host_loop = @import("../host_loop.zig");

const testing = std.testing;

test "host loop outbound and inbound accounting" {
    var sess = try Session.init(.{
        .allocator = testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 256,
        .transport = null,
    });
    defer sess.deinit();

    try sess.feed("abc");
    const tick = try host_loop.tick(&sess, "xyz");
    try testing.expectEqual(@as(usize, 3), tick.outbound_drained);
    try testing.expectEqual(@as(usize, 3), tick.inbound_fed);
    try testing.expect(tick.hasProgress());
}
