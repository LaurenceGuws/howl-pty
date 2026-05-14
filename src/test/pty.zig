
const std = @import("std");
const pty = @import("../pty.zig");

test "pty control signals stay typed across the interface" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    try mem_pty.pty().start();
    defer mem_pty.pty().stop();

    mem_pty.pty().control(.terminate);
    try std.testing.expectEqual(pty.ControlSignal.terminate, mem_pty.last_signal.?);
}

test "pty doubles share resize and write semantics through the interface" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();
    try mem_pty.pty().start();
    defer mem_pty.pty().stop();

    try mem_pty.pty().resize(132, 43);
    try std.testing.expectEqual(@as(u16, 132), mem_pty.last_cols);
    try std.testing.expectEqual(@as(u16, 43), mem_pty.last_rows);

    const bytes = "hello";
    try std.testing.expectEqual(bytes.len, try mem_pty.pty().write(bytes));
    try std.testing.expectEqualStrings(bytes, mem_pty.tx.items);
}

test "partial pty preserves partial-write semantics through the interface" {
    const allocator = std.testing.allocator;

    var partial = pty.Partial.init(allocator, 2);
    defer partial.deinit();
    try partial.pty().start();
    defer partial.pty().stop();

    try std.testing.expectEqual(@as(usize, 2), try partial.pty().write("abcd"));
    try std.testing.expectEqualStrings("ab", partial.tx.items);
}

test "fail pty surfaces transport errors instead of swallowing them" {
    var fail_pty = pty.Fail.init();
    defer fail_pty.deinit();
    var buf = [_]u8{0};

    try std.testing.expectError(error.Failed, fail_pty.pty().start());
    try std.testing.expectError(error.Failed, fail_pty.pty().write("x"));
    try std.testing.expectError(error.Failed, fail_pty.pty().read(buf[0..]));
    try std.testing.expectError(error.Failed, fail_pty.pty().waitReadable(1));
    try std.testing.expectError(error.Failed, fail_pty.pty().resize(1, 1));
}
