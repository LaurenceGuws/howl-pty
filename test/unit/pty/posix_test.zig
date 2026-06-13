const std = @import("std");
const pty_api = @import("../../../src/pty.zig");
const posix_pty = @import("../../../src/pty/posix.zig");

test "pending child stop uses direct child ownership until session is live" {
    const pid = posix_pty.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = posix_pty.c.usleep(30 * std.time.us_per_s);
        posix_pty.c._exit(0);
    }

    var owned = try posix_pty.make(struct {
        pub fn ensureSupported() pty_api.Pty.StartError!void {}

        pub fn openTransport(cols: u16, rows: u16) pty_api.Pty.StartError!posix_pty.Open {
            _ = cols;
            _ = rows;
            return error.OpenPtyFailed;
        }
    }).init(std.testing.allocator, "/bin/sh", null, null);
    defer {
        owned.started = false;
        owned.child = .none;
        owned.deinit();
    }

    owned.started = true;
    owned.child = .{ .pending_session = pid };
    owned.pty().stop();

    try std.testing.expect(owned.child == .none);
}

test "wait classification does not treat hup as readable" {
    try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.timeout, posix_pty.testing.waitReadablePollResult(std.posix.POLL.HUP));
    try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.timeout, posix_pty.testing.waitReadablePollResult(std.posix.POLL.ERR));
    try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.ready, posix_pty.testing.waitReadablePollResult(std.posix.POLL.IN));
    try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.ready, posix_pty.testing.waitReadablePollResult(std.posix.POLL.IN | std.posix.POLL.HUP));
}
