const builtin = @import("builtin");
const posix = @import("posix.zig");
const pty = @import("../pty.zig");
const c = posix.c;

pub const Pty = posix.make(struct {
    pub fn ensureSupported() pty.Pty.StartError!void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
            return error.UnsupportedPlatform;
        }
    }

    pub fn openTransport(cols: u16, rows: u16) pty.Pty.StartError!posix.Open {
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var winsize = c.struct_winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) {
            return error.OpenPtyFailed;
        }
        return .{ .master_fd = @intCast(master_fd), .slave_fd = @intCast(slave_fd) };
    }
});
