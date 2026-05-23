const std = @import("std");
const posix = std.posix;
const platform = @import("pty_platform.zig");

const Pty = platform.Pty;
const ControlSignal = platform.ControlSignal;
const c = platform.c;

pub const TransportOpen = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
};

const WakePipe = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
};

pub fn PosixPty(comptime Backend: type) type {
    return struct {
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

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            shell_path: []const u8,
            command: ?[]const u8,
            start_path: ?[]const u8,
        ) (error{OutOfMemory} || Pty.StartError)!Self {
            try Backend.ensureSupported();

            const shell_path_z = try allocator.dupeZ(u8, shell_path);
            errdefer allocator.free(shell_path_z);

            const command_z = if (command) |bytes| try allocator.dupeZ(u8, bytes) else null;
            errdefer if (command_z) |bytes| allocator.free(bytes);

            const start_path_z = if (start_path) |bytes| try allocator.dupeZ(u8, bytes) else null;
            errdefer if (start_path_z) |bytes| allocator.free(bytes);

            return .{
                .allocator = allocator,
                .shell_path = shell_path_z,
                .command = command_z,
                .command_ptr = optionalZPtr(command_z),
                .start_path = start_path_z,
                .start_path_ptr = optionalZPtr(start_path_z),
                .started = false,
                .master_fd = null,
                .wake_read_fd = null,
                .wake_write_fd = null,
                .child_pid = null,
                .last_cols = 0,
                .last_rows = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stopTransport();
            self.allocator.free(self.shell_path);
            if (self.command) |bytes| self.allocator.free(bytes);
            if (self.start_path) |bytes| self.allocator.free(bytes);
            self.* = undefined;
        }

        pub fn pty(self: *Self) Pty {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn startTransport(self: *Self, cols: u16, rows: u16) Pty.StartError!void {
            if (self.started) return error.AlreadyStarted;
            std.debug.assert(cols > 0);
            std.debug.assert(rows > 0);

            try platform.requireExecutable(self.shell_path);
            const transport = try Backend.openTransport(cols, rows);
            errdefer closeTransport(transport);

            const wake = try openWakePipe();
            errdefer closeWakePipe(wake);

            try platform.setCloseOnExec(transport.master_fd);
            try platform.setNonBlocking(transport.master_fd);

            const pid = c.fork();
            if (pid < 0) return error.OpenPtyFailed;
            if (pid == 0) {
                platform.childProcess(
                    transport.master_fd,
                    transport.slave_fd,
                    wake.read_fd,
                    wake.write_fd,
                    self.shell_path,
                    self.command_ptr,
                    self.start_path_ptr,
                    null,
                ) catch c._exit(127);
                unreachable;
            }

            _ = c.close(@intCast(transport.slave_fd));
            self.master_fd = transport.master_fd;
            self.wake_read_fd = wake.read_fd;
            self.wake_write_fd = wake.write_fd;
            self.child_pid = pid;
            self.last_cols = cols;
            self.last_rows = rows;
            self.started = true;

            std.debug.assert(self.master_fd != null);
            std.debug.assert(self.wake_read_fd != null);
            std.debug.assert(self.wake_write_fd != null);
            std.debug.assert(self.child_pid != null);
        }

        fn stopTransport(self: *Self) void {
            if (!self.started) return;

            self.kickWait();
            if (self.child_pid) |pid| {
                platform.sendGroupSignal(pid, .hangup);
                platform.sendGroupSignal(pid, .terminate);
                platform.sendGroupSignal(pid, .kill);
                platform.reapChildNow(pid);
            }

            if (self.master_fd) |fd| _ = c.close(@intCast(fd));
            if (self.wake_read_fd) |fd| _ = c.close(@intCast(fd));
            if (self.wake_write_fd) |fd| _ = c.close(@intCast(fd));
            self.child_pid = null;
            self.master_fd = null;
            self.wake_read_fd = null;
            self.wake_write_fd = null;
            self.started = false;

            std.debug.assert(self.master_fd == null);
            std.debug.assert(self.wake_read_fd == null);
            std.debug.assert(self.wake_write_fd == null);
            std.debug.assert(self.child_pid == null);
        }

        fn refreshChildState(self: *Self) void {
            if (!self.started) return;
            const pid = self.child_pid orelse return;

            var status: c_int = 0;
            const res = c.waitpid(pid, &status, c.WNOHANG);
            if (res == pid) {
                self.child_pid = null;
            }
        }

        fn transportReady(self: *const Self) bool {
            if (!self.started) return false;
            if (self.master_fd == null) return false;
            if (self.child_pid == null) return false;
            return true;
        }

        fn kickWait(self: *Self) void {
            if (!self.started) return;
            if (self.wake_write_fd) |fd| {
                var byte: [1]u8 = .{1};
                _ = c.write(fd, &byte, 1);
            }
        }

        fn drainWakePipe(self: *Self) void {
            const fd = self.wake_read_fd orelse return;
            var buf: [32]u8 = undefined;
            const wake_chunk: isize = buf.len;
            while (true) {
                const n = c.read(fd, &buf, buf.len);
                if (n <= 0) return;
                if (n < wake_chunk) return;
            }
        }

        const vtable: Pty.VTable = .{
            .start = startPty,
            .stop = stopPty,
            .write = writePty,
            .read = readPty,
            .wait_readable = waitReadablePty,
            .kick_wait = kickWaitPty,
            .resize = resizePty,
            .control = controlPty,
        };

        fn startPty(ptr: *anyopaque, cols: u16, rows: u16) Pty.StartError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.startTransport(cols, rows);
        }

        fn stopPty(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopTransport();
        }

        fn writePty(ptr: *anyopaque, bytes: []const u8) Pty.WriteError!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.refreshChildState();
            if (!self.transportReady()) return error.NotStarted;
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

        fn readPty(ptr: *anyopaque, buf: []u8) Pty.ReadError!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.refreshChildState();
            if (!self.transportReady()) return error.NotStarted;
            if (buf.len == 0) return 0;

            const n = c.read(self.master_fd.?, buf.ptr, buf.len);
            if (n < 0) {
                return switch (posix.errno(n)) {
                    .AGAIN => error.WouldBlock,
                    .INTR => error.Interrupted,
                    else => error.ReadFailed,
                };
            }
            if (n == 0) return error.EndOfStream;
            return @intCast(n);
        }

        fn waitReadablePty(ptr: *anyopaque, timeout_ms: i32) Pty.WaitReadableError!bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.refreshChildState();
            if (!self.transportReady()) return error.NotStarted;
            std.debug.assert(self.wake_read_fd != null);

            var fds = [_]posix.pollfd{
                .{ .fd = self.master_fd.?, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
                .{ .fd = self.wake_read_fd orelse return error.NotStarted, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
            };
            const poll_timeout: i32 = if (timeout_ms < 0) -1 else timeout_ms;
            const ready = posix.poll(&fds, poll_timeout) catch return error.WaitFailed;
            if (ready <= 0) return false;

            if ((fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
                self.drainWakePipe();
                return false;
            }
            if ((fds[0].revents & posix.POLL.HUP) != 0) {
                self.refreshChildState();
                if (!self.transportReady()) return error.NotStarted;
            }
            return (fds[0].revents & posix.POLL.IN) != 0;
        }

        fn kickWaitPty(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.kickWait();
        }

        fn resizePty(ptr: *anyopaque, cols: u16, rows: u16) Pty.ResizeError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.refreshChildState();
            if (!self.transportReady()) return error.NotStarted;

            var winsize = c.struct_winsize{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };
            if (c.ioctl(@intCast(self.master_fd.?), c.TIOCSWINSZ, &winsize) != 0) {
                return error.ResizeFailed;
            }
            self.last_cols = cols;
            self.last_rows = rows;
        }

        fn controlPty(ptr: *anyopaque, signal: ControlSignal) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.refreshChildState();
            if (!self.transportReady()) return;
            if (self.child_pid) |pid| platform.sendSignal(pid, signal);
        }
    };
}

fn optionalZPtr(bytes: ?[:0]u8) ?[*:0]u8 {
    if (bytes) |value| {
        return @ptrFromInt(@intFromPtr(value.ptr));
    }
    return null;
}

fn closeTransport(transport: TransportOpen) void {
    _ = c.close(@intCast(transport.master_fd));
    _ = c.close(@intCast(transport.slave_fd));
}

fn openWakePipe() Pty.StartError!WakePipe {
    var fds = [_]c_int{ -1, -1 };
    if (c.pipe(&fds) != 0) return error.OpenPtyFailed;
    errdefer {
        if (fds[0] >= 0) _ = c.close(fds[0]);
        if (fds[1] >= 0) _ = c.close(fds[1]);
    }

    try platform.setCloseOnExec(@intCast(fds[0]));
    try platform.setCloseOnExec(@intCast(fds[1]));
    try platform.setNonBlocking(@intCast(fds[0]));
    try platform.setNonBlocking(@intCast(fds[1]));
    return .{ .read_fd = @intCast(fds[0]), .write_fd = @intCast(fds[1]) };
}

fn closeWakePipe(wake: WakePipe) void {
    _ = c.close(@intCast(wake.read_fd));
    _ = c.close(@intCast(wake.write_fd));
}
