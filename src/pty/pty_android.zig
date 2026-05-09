//! Responsibility: implement Android PTY creation.
//! Ownership: session PTY layer owns platform-specific PTY variants.
//! Reason: keeps Android process and terminal setup behind the session boundary.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("pty_platform.zig").Pty;
const ControlSignal = @import("pty_platform.zig").ControlSignal;
const common = @import("pty_platform.zig");
const c = common.c;

fn trace(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("HOWL_TRACE_STDOUT") == null) return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);
}
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;

pub const AndroidPty = struct {
    allocator: std.mem.Allocator,
    shell_path: [:0]u8,
    command: ?[:0]u8,
    command_ptr: ?[*:0]u8,
    start_path: ?[:0]u8,
    start_path_ptr: ?[*:0]u8,
    started: bool,
    master_fd: ?posix.fd_t,
    child_pid: ?posix.pid_t,
    last_cols: u16,
    last_rows: u16,

    pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, command: ?[]const u8, start_path: ?[]const u8) !AndroidPty {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .android) return error.UnsupportedPlatform;
        const shell_z = try allocator.dupeZ(u8, shell_path);
        errdefer allocator.free(shell_z);
        const command_z = if (command) |cmd| try allocator.dupeZ(u8, cmd) else null;
        errdefer if (command_z) |z| allocator.free(z);
        const start_path_z = if (start_path) |path| try allocator.dupeZ(u8, path) else null;
        errdefer if (start_path_z) |z| allocator.free(z);
        const command_ptr: ?[*:0]u8 = if (command_z) |cmd| @ptrFromInt(@intFromPtr(cmd.ptr)) else null;
        const start_path_ptr: ?[*:0]u8 = if (start_path_z) |path| @ptrFromInt(@intFromPtr(path.ptr)) else null;
        return .{ .allocator = allocator, .shell_path = shell_z, .command = command_z, .command_ptr = command_ptr, .start_path = start_path_z, .start_path_ptr = start_path_ptr, .started = false, .master_fd = null, .child_pid = null, .last_cols = 0, .last_rows = 0 };
    }

    pub fn deinit(self: *AndroidPty) void {
        self.stopInternal();
        self.allocator.free(self.shell_path);
        if (self.command) |cmd| self.allocator.free(cmd);
        if (self.start_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn pty(self: *AndroidPty) Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn startInternal(self: *AndroidPty) anyerror!void {
        if (self.started) return error.AlreadyStarted;
        try common.requireExecutable(self.shell_path);
        const master_fd = c.open("/dev/ptmx", c.O_RDWR, @as(c_int, 0));
        if (master_fd < 0) return error.OpenPtyFailed;
        var slave_fd: c_int = -1;
        errdefer {
            if (master_fd >= 0) _ = c.close(master_fd);
            if (slave_fd >= 0) _ = c.close(slave_fd);
        }
        if (grantpt(master_fd) != 0) return error.OpenPtyFailed;
        if (unlockpt(master_fd) != 0) return error.OpenPtyFailed;
        var slave_path_buf: [4096]u8 = undefined;
        if (ptsname_r(master_fd, &slave_path_buf, slave_path_buf.len) != 0) return error.OpenPtyFailed;
        const slave_path = std.mem.sliceTo(&slave_path_buf, 0);
        var slave_path_z: [4096:0]u8 = undefined;
        if (slave_path.len + 1 > slave_path_z.len) return error.OpenPtyFailed;
        @memcpy(slave_path_z[0..slave_path.len], slave_path);
        slave_path_z[slave_path.len] = 0;
        slave_fd = c.open(&slave_path_z, c.O_RDWR, @as(c_int, 0));
        if (slave_fd < 0) return error.OpenPtyFailed;

        try common.setNonBlocking(@intCast(master_fd));
        const pid = c.fork();
        if (pid < 0) return error.OpenPtyFailed;
        if (pid == 0) {
            common.childProcess(@intCast(slave_fd), self.shell_path, self.command_ptr, self.start_path_ptr, applyAndroidShellLayout) catch c._exit(127);
            unreachable;
        }
        _ = c.close(slave_fd);
        self.master_fd = @intCast(master_fd);
        self.child_pid = pid;
        self.started = true;
    }

    fn stopInternal(self: *AndroidPty) void {
        if (!self.started) return;
        if (self.child_pid) |pid| {
            common.sendGroupSignal(pid, .hangup);
            common.sendGroupSignal(pid, .terminate);
            common.sendGroupSignal(pid, .kill);
            common.reapChildNow(pid);
        }
        if (self.master_fd) |fd| _ = c.close(@intCast(fd));
        self.child_pid = null;
        self.master_fd = null;
        self.started = false;
    }

    fn refreshChildState(self: *AndroidPty) void {
        if (!self.started) return;
        const pid = self.child_pid orelse return;
        var status: c_int = 0;
        const res = c.waitpid(pid, &status, c.WNOHANG);
        if (res == pid) {
            if (self.master_fd) |fd| _ = c.close(@intCast(fd));
            self.master_fd = null;
            self.child_pid = null;
            self.started = false;
        }
    }

    const vtable: Pty.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .wait_readable = waitReadableImpl, .resize = resizeImpl, .control = controlImpl };
    fn startImpl(ptr: *anyopaque) anyerror!void {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        try self.startInternal();
    }
    fn stopImpl(ptr: *anyopaque) void {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        self.stopInternal();
    }
    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        self.refreshChildState();
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (bytes.len == 0) return 0;
        const n = c.write(self.master_fd.?, bytes.ptr, bytes.len);
        if (n < 0) {
            return switch (posix.errno(n)) {
                .AGAIN => error.WouldBlock,
                .INTR => error.Interrupted,
                else => error.WriteFailed,
            };
        }
        return @intCast(n);
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        self.refreshChildState();
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (buf.len == 0) return 0;
        const n = c.read(self.master_fd.?, buf.ptr, buf.len);
        if (n < 0) {
            trace("howl-pty event=read_error platform=android errno={}\n", .{@intFromEnum(posix.errno(n))});
            return switch (posix.errno(n)) {
                .AGAIN => error.WouldBlock,
                .INTR => error.Interrupted,
                else => error.ReadFailed,
            };
        }
        if (n == 0) return error.EndOfStream;
        trace("howl-pty event=read platform=android bytes={}\n", .{n});
        return @intCast(n);
    }
    fn waitReadableImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        self.refreshChildState();
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var fds = [_]posix.pollfd{.{ .fd = self.master_fd.?, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 }};
        const poll_timeout: i32 = if (timeout_ms < 0) -1 else 0;
        trace("howl-pty event=poll_enter platform=android timeout={} poll_timeout={} master_fd={}\n", .{ timeout_ms, poll_timeout, fds[0].fd });
        const ready = try posix.poll(&fds, poll_timeout);
        trace("howl-pty event=poll_leave platform=android ready={} master_revents={}\n", .{ ready, fds[0].revents });
        if (ready <= 0) return false;
        if ((fds[0].revents & posix.POLL.HUP) != 0) {
            self.refreshChildState();
            if (!self.started) return error.NotStarted;
        }
        return (fds[0].revents & posix.POLL.IN) != 0;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var winsize = c.struct_winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.ioctl(@intCast(self.master_fd.?), c.TIOCSWINSZ, &winsize) != 0) return error.ResizeFailed;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn controlImpl(ptr: *anyopaque, signal: ControlSignal) void {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started) return;
        if (self.child_pid) |pid| common.sendSignal(pid, signal);
    }
};

fn applyAndroidShellLayout(shell_path: [:0]const u8) void {
    const shell = shell_path[0..shell_path.len];
    const marker = "/usr/bin/";
    const usr_idx = std.mem.indexOf(u8, shell, marker) orelse return;
    if (usr_idx == 0) return;
    const app_root = shell[0..usr_idx];

    var app_data_buf: [std.fs.max_path_bytes]u8 = undefined;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ld_library_path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const app_data = std.fmt.bufPrintZ(&app_data_buf, "{s}", .{app_root}) catch return;
    const prefix = std.fmt.bufPrintZ(&prefix_buf, "{s}/usr", .{app_root}) catch return;
    const home = std.fmt.bufPrintZ(&home_buf, "{s}/home", .{app_root}) catch return;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/usr/tmp", .{app_root}) catch return;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/usr/bin:/system/bin", .{app_root}) catch return;
    const ld_library_path = std.fmt.bufPrintZ(&ld_library_path_buf, "{s}/usr/lib", .{app_root}) catch return;

    _ = c.setenv("APP_DATA_DIR", app_data.ptr, 1);
    _ = c.setenv("PREFIX", prefix.ptr, 1);
    _ = c.setenv("HOME", home.ptr, 1);
    _ = c.setenv("TMPDIR", tmp.ptr, 1);
    _ = c.setenv("PATH", path.ptr, 1);
    _ = c.setenv("LD_LIBRARY_PATH", ld_library_path.ptr, 1);
    _ = c.setenv("HOWL_PM_HOST_PLATFORM", "android", 1);
    _ = c.setenv("SHELL", shell_path.ptr, 1);

    _ = c.chdir(home.ptr);
}
