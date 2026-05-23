const std = @import("std");
const builtin = @import("builtin");
const posix_owner = @import("pty_posix_owner.zig");
const common = @import("pty_platform.zig");
const c = common.c;

extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;

pub const AndroidPty = posix_owner.PosixPty(struct {
    pub fn ensureSupported() !void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .android) {
            return error.UnsupportedPlatform;
        }
    }

    pub fn openTransport(cols: u16, rows: u16) !posix_owner.TransportOpen {
        const master_fd = c.open("/dev/ptmx", c.O_RDWR, @as(c_int, 0));
        if (master_fd < 0) return error.OpenPtyFailed;

        var slave_fd: c_int = -1;
        errdefer {
            if (slave_fd >= 0) _ = c.close(slave_fd);
            _ = c.close(master_fd);
        }

        if (grantpt(master_fd) != 0) return error.OpenPtyFailed;
        if (unlockpt(master_fd) != 0) return error.OpenPtyFailed;

        var slave_path_buf: [4096]u8 = undefined;
        if (ptsname_r(master_fd, &slave_path_buf, slave_path_buf.len) != 0) {
            return error.OpenPtyFailed;
        }

        const slave_path = std.mem.sliceTo(&slave_path_buf, 0);
        var slave_path_z: [4096:0]u8 = undefined;
        if (slave_path.len + 1 > slave_path_z.len) return error.OpenPtyFailed;
        @memcpy(slave_path_z[0..slave_path.len], slave_path);
        slave_path_z[slave_path.len] = 0;

        slave_fd = c.open(&slave_path_z, c.O_RDWR, @as(c_int, 0));
        if (slave_fd < 0) return error.OpenPtyFailed;

        var winsize = c.struct_winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(slave_fd, c.TIOCSWINSZ, &winsize) != 0) return error.OpenPtyFailed;

        return .{ .master_fd = @intCast(master_fd), .slave_fd = @intCast(slave_fd) };
    }
});
