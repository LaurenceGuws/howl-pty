//! Curates the owned native PTY transport used by howl-headless.

const std = @import("std");
const pty = @import("pty.zig");

/// Names signals accepted by the native PTY transport.
pub const ControlSignal = pty.ControlSignal;
/// Owns one native PTY, its launch strings, descriptors, and child process group.
pub const Owned = pty.Owned;

test {
    _ = pty;
}

const test_cols: u16 = 80;
const test_rows: u16 = 24;
const test_wait_ms: i32 = 100;
const test_waits_max: u8 = 50;

fn requireUnix() !void {
    const os = @import("builtin").os.tag;
    if (os != .linux and os != .macos) return error.SkipZigTest;
}

fn expectOutput(owned: *Owned, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var used: usize = 0;
    var waits: u8 = 0;
    while (waits < test_waits_max) : (waits += 1) {
        const outcome = owned.waitReadable(test_wait_ms) catch |failure| switch (failure) {
            error.NotStarted => break,
            else => return failure,
        };
        if (outcome != .ready) continue;
        const count = owned.read(buffer[used..]) catch |failure| switch (failure) {
            error.EndOfStream, error.NotStarted => break,
            else => return failure,
        };
        used += count;
        std.debug.assert(used <= buffer.len);
        if (std.mem.indexOf(u8, buffer[0..used], expected) != null) return;
        if (used == buffer.len) return error.TestBufferFull;
    }
    return error.TestTimeout;
}

fn initAllocation(allocator: std.mem.Allocator) !void {
    var owned = try Owned.init(allocator, "/bin/sh", "printf allocation", "/tmp");
    owned.deinit();
}

fn descriptorCountLinux() !usize {
    const directory = try std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer directory.close(std.testing.io);
    var entries = directory.iterate();
    var count: usize = 0;
    while (try entries.next(std.testing.io)) |_| count += 1;
    return count;
}

test "initialization releases every partial allocation" {
    try requireUnix();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initAllocation, .{});
}

test "pre-start operations fail exactly and the owner remains reusable" {
    try requireUnix();
    var owned = try Owned.init(std.testing.allocator, "/bin/sh", "read line; printf '%s' \"$line\"", null);
    defer owned.deinit();

    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.NotStarted, owned.write("hello\n"));
    try std.testing.expectError(error.NotStarted, owned.read(&buffer));
    try std.testing.expectError(error.NotStarted, owned.waitReadable(0));
    try std.testing.expectError(error.NotStarted, owned.resize(test_cols, test_rows));
    owned.kickWait();
    owned.control(.interrupt);
    owned.stop();

    try owned.start(test_cols, test_rows);
    try std.testing.expectEqual(@as(usize, 6), try owned.write("hello\n"));
    try expectOutput(&owned, "hello");
}

test "start rejects unavailable and duplicate child lifecycle transitions" {
    try requireUnix();
    var unavailable = try Owned.init(std.testing.allocator, "/definitely/missing/howl-shell", null, null);
    defer unavailable.deinit();
    try std.testing.expectError(error.ShellUnavailable, unavailable.start(test_cols, test_rows));
    try std.testing.expectError(error.ShellUnavailable, unavailable.start(test_cols, test_rows));

    var owned = try Owned.init(std.testing.allocator, "/bin/sh", "sleep 30", null);
    defer owned.deinit();
    try owned.start(test_cols, test_rows);
    try std.testing.expectError(error.AlreadyStarted, owned.start(test_cols, test_rows));
}

test "deinit closes every PTY descriptor while stopping a live child" {
    try requireUnix();
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const descriptors_before = try descriptorCountLinux();

    var owned = try Owned.init(std.testing.allocator, "/bin/sh", "sleep 30", null);
    try owned.start(test_cols, test_rows);
    try std.testing.expect(try descriptorCountLinux() > descriptors_before);
    owned.deinit();

    try std.testing.expectEqual(descriptors_before, try descriptorCountLinux());
}

test "wake resize write read and interrupt operate on one native owner" {
    try requireUnix();
    const command = "trap 'printf interrupted; exit 0' INT; printf ready; read line; stty size; printf '%s' \"$line\"; while :; do sleep 1; done";
    var owned = try Owned.init(std.testing.allocator, "/bin/sh", command, null);
    defer owned.deinit();
    try owned.start(test_cols, test_rows);

    try expectOutput(&owned, "ready");
    owned.kickWait();
    try std.testing.expectEqual(pty.WaitReadableResult.wake, try owned.waitReadable(test_wait_ms));
    try owned.resize(100, 40);
    try std.testing.expectEqual(@as(usize, 6), try owned.write("hello\n"));
    try expectOutput(&owned, "40 100");
    owned.control(.interrupt);
    try expectOutput(&owned, "interrupted");
}
