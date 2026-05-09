//! Responsibility: implement Unix PTY creation.
//! Ownership: session PTY layer owns platform-specific PTY variants.
//! Reason: keeps Unix process and terminal setup behind the session boundary.

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

pub const UnixPty = struct {
    allocator: std.mem.Allocator,
    shell_path: [:0]u8,
    command: ?[:0]u8,
    command_ptr: ?[*:0]u8,
    start_path: ?[:0]u8,
    start_path_ptr: ?[*:0]u8,
    started: bool,
    master_fd: ?posix.fd_t,
    wake_read_fd: ?posix.fd_t,
    wake_write_fd: ?posix.fd_t,
    child_pid: ?posix.pid_t,
    last_cols: u16,
    last_rows: u16,

    pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, command: ?[]const u8, start_path: ?[]const u8) !UnixPty {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
        const shell_z = try allocator.dupeZ(u8, shell_path);
        errdefer allocator.free(shell_z);
        const command_z = if (command) |cmd| try allocator.dupeZ(u8, cmd) else null;
        errdefer if (command_z) |z| allocator.free(z);
        const start_path_z = if (start_path) |path| try allocator.dupeZ(u8, path) else null;
        errdefer if (start_path_z) |z| allocator.free(z);
        const command_ptr: ?[*:0]u8 = if (command_z) |cmd| @ptrFromInt(@intFromPtr(cmd.ptr)) else null;
        const start_path_ptr: ?[*:0]u8 = if (start_path_z) |path| @ptrFromInt(@intFromPtr(path.ptr)) else null;
        return .{ .allocator = allocator, .shell_path = shell_z, .command = command_z, .command_ptr = command_ptr, .start_path = start_path_z, .start_path_ptr = start_path_ptr, .started = false, .master_fd = null, .wake_read_fd = null, .wake_write_fd = null, .child_pid = null, .last_cols = 0, .last_rows = 0 };
    }

    pub fn deinit(self: *UnixPty) void {
        self.stopInternal();
        self.allocator.free(self.shell_path);
        if (self.command) |cmd| self.allocator.free(cmd);
        if (self.start_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn pty(self: *UnixPty) Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn startInternal(self: *UnixPty) anyerror!void {
        if (self.started) return error.AlreadyStarted;
        try common.requireExecutable(self.shell_path);
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var wake_fds = [_]c_int{ -1, -1 };
        trace("howl-pty event=start_enter platform=unix\n", .{});
        var winsize = c.struct_winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) return error.OpenPtyFailed;
        if (c.pipe(&wake_fds) != 0) return error.OpenPtyFailed;
        try common.setNonBlocking(@intCast(wake_fds[0]));
        try common.setNonBlocking(@intCast(wake_fds[1]));
        errdefer {
            if (master_fd >= 0) _ = c.close(master_fd);
            if (slave_fd >= 0) _ = c.close(slave_fd);
            if (wake_fds[0] >= 0) _ = c.close(wake_fds[0]);
            if (wake_fds[1] >= 0) _ = c.close(wake_fds[1]);
        }
        try common.setNonBlocking(@intCast(master_fd));
        const pid = c.fork();
        if (pid < 0) return error.OpenPtyFailed;
        if (pid == 0) {
            _ = c.close(wake_fds[0]);
            _ = c.close(wake_fds[1]);
            common.childProcess(@intCast(slave_fd), self.shell_path, self.command_ptr, self.start_path_ptr, null) catch c._exit(127);
            unreachable;
        }
        _ = c.close(slave_fd);
        self.master_fd = @intCast(master_fd);
        self.wake_read_fd = @intCast(wake_fds[0]);
        self.wake_write_fd = @intCast(wake_fds[1]);
        self.child_pid = pid;
        self.started = true;
        trace("howl-pty event=start_leave platform=unix pid={} master_fd={} wake_read_fd={} wake_write_fd={}\n", .{ pid, master_fd, wake_fds[0], wake_fds[1] });
    }

    fn stopInternal(self: *UnixPty) void {
        if (!self.started) return;
        trace("howl-pty event=stop_enter platform=unix pid_present={}\n", .{self.child_pid != null});
        if (self.wake_write_fd) |fd| {
            var byte: [1]u8 = .{1};
            _ = c.write(fd, &byte, 1);
            trace("howl-pty event=wake_pipe_write fd={}\n", .{fd});
        }
        if (self.child_pid) |pid| {
            common.sendGroupSignal(pid, .hangup);
            common.sendGroupSignal(pid, .terminate);
            common.sendGroupSignal(pid, .kill);
            common.reapChildNow(pid);
        }
        if (self.master_fd) |fd| _ = c.close(@intCast(fd));
        if (self.wake_read_fd) |fd| _ = c.close(@intCast(fd));
        if (self.wake_write_fd) |fd| _ = c.close(@intCast(fd));
        self.child_pid = null;
        self.master_fd = null;
        self.wake_read_fd = null;
        self.wake_write_fd = null;
        self.started = false;
        trace("howl-pty event=stop_leave platform=unix\n", .{});
    }

    fn refreshChildState(self: *UnixPty) void {
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
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        try self.startInternal();
    }
    fn stopImpl(ptr: *anyopaque) void {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        self.stopInternal();
    }
    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
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
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        self.refreshChildState();
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (buf.len == 0) return 0;
        const n = c.read(self.master_fd.?, buf.ptr, buf.len);
        if (n < 0) {
            trace("howl-pty event=read_error errno={}\n", .{@intFromEnum(posix.errno(n))});
            return switch (posix.errno(n)) {
                .AGAIN => error.WouldBlock,
                .INTR => error.Interrupted,
                else => error.ReadFailed,
            };
        }
        if (n == 0) return error.EndOfStream;
        trace("howl-pty event=read bytes={}\n", .{n});
        return @intCast(n);
    }
    fn waitReadableImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        self.refreshChildState();
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var fds = [_]posix.pollfd{
            .{ .fd = self.master_fd.?, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
            .{ .fd = self.wake_read_fd orelse return error.NotStarted, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
        };
        const poll_timeout: i32 = if (timeout_ms < 0) -1 else 0;
        trace("howl-pty event=poll_enter timeout={} poll_timeout={} master_fd={} wake_fd={}\n", .{ timeout_ms, poll_timeout, fds[0].fd, fds[1].fd });
        const ready = try posix.poll(&fds, poll_timeout);
        trace("howl-pty event=poll_leave ready={} master_revents={} wake_revents={}\n", .{ ready, fds[0].revents, fds[1].revents });
        if (ready <= 0) return false;
        if ((fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) return false;
        if ((fds[0].revents & posix.POLL.HUP) != 0) {
            self.refreshChildState();
            if (!self.started) return error.NotStarted;
        }
        return (fds[0].revents & posix.POLL.IN) != 0;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var winsize = c.struct_winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.ioctl(@intCast(self.master_fd.?), c.TIOCSWINSZ, &winsize) != 0) return error.ResizeFailed;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn controlImpl(ptr: *anyopaque, signal: ControlSignal) void {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        if (!self.started) return;
        if (self.child_pid) |pid| common.sendSignal(pid, signal);
    }
};
