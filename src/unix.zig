//! Selects the native Linux and macOS PTY open operation.

const builtin = @import("builtin");
const posix = @import("posix.zig");
const pty = @import("pty.zig");
const c = posix.c;

/// Owns one supported Unix PTY and its child process group.
pub const Pty = posix.make(struct {
    /// Accepts the Linux and macOS implementations selected by this file.
    pub fn ensureSupported() pty.StartError!void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
            return error.UnsupportedPlatform;
        }
    }

    /// Opens one master/slave PTY pair at the requested dimensions.
    pub fn openTransport(cols: u16, rows: u16) pty.StartError!posix.Open {
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
