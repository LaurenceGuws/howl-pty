const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("PtyPlatform.zig").Pty;
const common = @import("PtyPlatform.zig");
const c = common.c;

pub const AndroidPty = struct {
    allocator: std.mem.Allocator,
    shell_path: [:0]u8,
    command: ?[:0]u8,
    started: bool,
    master_fd: ?posix.fd_t,
    child_pid: ?posix.pid_t,
    last_cols: u16,
    last_rows: u16,

    pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, command: ?[]const u8) !AndroidPty {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .android) return error.UnsupportedPlatform;
        const shell_z = try allocator.dupeZ(u8, shell_path);
        errdefer allocator.free(shell_z);
        const command_z = if (command) |cmd| try allocator.dupeZ(u8, cmd) else null;
        errdefer if (command_z) |z| allocator.free(z);
        return .{ .allocator = allocator, .shell_path = shell_z, .command = command_z, .started = false, .master_fd = null, .child_pid = null, .last_cols = 0, .last_rows = 0 };
    }

    pub fn deinit(self: *AndroidPty) void {
        self.stopInternal();
        self.allocator.free(self.shell_path);
        if (self.command) |cmd| self.allocator.free(cmd);
        self.* = undefined;
    }

    pub fn pty(self: *AndroidPty) Pty { return .{ .ptr = self, .vtable = &vtable }; }

    fn startInternal(self: *AndroidPty) anyerror!void {
        if (self.started) return error.AlreadyStarted;
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var winsize = c.struct_winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) return error.OpenPtyFailed;
        errdefer {
            if (master_fd >= 0) posix.close(@intCast(master_fd));
            if (slave_fd >= 0) posix.close(@intCast(slave_fd));
        }
        try common.setNonBlocking(@intCast(master_fd));
        const pid = try posix.fork();
        if (pid == 0) {
            common.childProcess(@intCast(slave_fd), self.shell_path, self.command) catch posix.exit(127);
            unreachable;
        }
        posix.close(@intCast(slave_fd));
        self.master_fd = @intCast(master_fd);
        self.child_pid = pid;
        self.started = true;
    }

    fn stopInternal(self: *AndroidPty) void {
        if (!self.started) return;
        if (self.child_pid) |pid| {
            common.sendSignal(pid, @intCast(posix.SIG.TERM));
            common.reapChild(pid, 30);
        }
        if (self.master_fd) |fd| posix.close(fd);
        self.child_pid = null;
        self.master_fd = null;
        self.started = false;
    }

    const vtable: Pty.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .wait_readable = waitReadableImpl, .resize = resizeImpl, .control = controlImpl };
    fn startImpl(ptr: *anyopaque) anyerror!void { const self: *AndroidPty = @ptrCast(@alignCast(ptr)); try self.startInternal(); }
    fn stopImpl(ptr: *anyopaque) void { const self: *AndroidPty = @ptrCast(@alignCast(ptr)); self.stopInternal(); }
    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (bytes.len == 0) return 0;
        const n = posix.write(self.master_fd.?, bytes) catch |err| switch (err) { error.WouldBlock => return 0, else => return err };
        return n;
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (buf.len == 0) return 0;
        const n = posix.read(self.master_fd.?, buf) catch |err| switch (err) { error.WouldBlock, error.InputOutput => return 0, else => return err };
        return n;
    }
    fn waitReadableImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var fds = [_]posix.pollfd{.{ .fd = self.master_fd.?, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 }};
        const ready = try posix.poll(&fds, timeout_ms);
        if (ready <= 0) return false;
        return (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var winsize = c.struct_winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.ioctl(@intCast(self.master_fd.?), c.TIOCSWINSZ, &winsize) != 0) return error.ResizeFailed;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn controlImpl(ptr: *anyopaque, signal: u8) void {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started) return;
        if (self.child_pid) |pid| common.sendSignal(pid, signal);
    }
};
