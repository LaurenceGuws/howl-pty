const std = @import("std");
const posix = std.posix;
const pty = @import("pty.zig");

pub const c = @cImport({
    @cDefine("_Nonnull", "");
    @cDefine("_Nullable", "");
    @cDefine("_Null_unspecified", "");
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    if (@import("builtin").os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

const Pty = pty.Pty;
const ControlSignal = pty.ControlSignal;
const WaitReadableResult = pty.Pty.WaitReadableResult;

pub const Open = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
};

pub const Wake = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
};

const ChildReady = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
};

const SignalResult = enum {
    delivered,
    missing,
};

const stop_hangup_grace_ns = 50 * std.time.ns_per_ms;
const stop_terminate_grace_ns = 50 * std.time.ns_per_ms;
const stop_wait_slice_ns = std.time.ns_per_ms;

pub fn make(comptime Backend: type) type {
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
        child: Child,
        last_cols: u16,
        last_rows: u16,

        const Self = @This();
        const Child = union(enum) {
            none,
            pending_session: posix.pid_t,
            live: posix.pid_t,
        };

        const StartPipes = struct {
            wake: Wake,
            child_ready: ChildReady,
        };

        pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, command: ?[]const u8, start_path: ?[]const u8) (error{OutOfMemory} || Pty.StartError)!Self {
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
                .child = .none,
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

            try requireExecutable(self.shell_path);
            const transport = try Backend.openTransport(cols, rows);
            errdefer closeTransport(transport);

            const pipes = try openStartPipes();
            errdefer closeStartPipes(pipes);

            try configureMaster(transport.master_fd);
            const pid = try self.forkChild(transport, pipes);
            self.adoptParentTransport(transport, pipes, pid, cols, rows);
            errdefer self.stopTransport();

            try self.awaitChildSession(pipes.child_ready.read_fd);
            self.child = .{ .live = pid };
            self.assertStarted();
        }

        fn openStartPipes() Pty.StartError!StartPipes {
            const wake = try openWakePipe();
            errdefer closeWakePipe(wake);

            const child_ready = try openChildReadyPipe();
            errdefer closeChildReadyPipe(child_ready);

            return .{ .wake = wake, .child_ready = child_ready };
        }

        fn closeStartPipes(pipes: StartPipes) void {
            closeChildReadyPipe(pipes.child_ready);
            closeWakePipe(pipes.wake);
        }

        fn configureMaster(master_fd: posix.fd_t) Pty.StartError!void {
            try setCloseOnExec(master_fd);
            try setNonBlocking(master_fd);
        }

        fn forkChild(self: *Self, transport: Open, pipes: StartPipes) Pty.StartError!posix.pid_t {
            const pid = c.fork();
            if (pid < 0) return error.OpenPtyFailed;
            if (pid == 0) {
                _ = c.close(@intCast(pipes.child_ready.read_fd));
                childProcess(
                    transport.master_fd,
                    transport.slave_fd,
                    pipes.wake.read_fd,
                    pipes.wake.write_fd,
                    pipes.child_ready.write_fd,
                    self.shell_path,
                    self.command_ptr,
                    self.start_path_ptr,
                    null,
                ) catch c._exit(127);
                unreachable;
            }
            return pid;
        }

        fn adoptParentTransport(self: *Self, transport: Open, pipes: StartPipes, pid: posix.pid_t, cols: u16, rows: u16) void {
            _ = c.close(@intCast(transport.slave_fd));
            _ = c.close(@intCast(pipes.child_ready.write_fd));
            self.master_fd = transport.master_fd;
            self.wake_read_fd = pipes.wake.read_fd;
            self.wake_write_fd = pipes.wake.write_fd;
            self.child = .{ .pending_session = pid };
            self.last_cols = cols;
            self.last_rows = rows;
            self.started = true;
        }

        fn assertStarted(self: *const Self) void {
            std.debug.assert(self.master_fd != null);
            std.debug.assert(self.wake_read_fd != null);
            std.debug.assert(self.wake_write_fd != null);
            std.debug.assert(self.childPid() != null);
        }

        fn stopTransport(self: *Self) void {
            if (!self.started) return;

            self.kickWait();
            self.stopChild();

            if (self.master_fd) |fd| _ = c.close(@intCast(fd));
            if (self.wake_read_fd) |fd| _ = c.close(@intCast(fd));
            if (self.wake_write_fd) |fd| _ = c.close(@intCast(fd));
            self.child = .none;
            self.master_fd = null;
            self.wake_read_fd = null;
            self.wake_write_fd = null;
            self.started = false;

            std.debug.assert(self.master_fd == null);
            std.debug.assert(self.wake_read_fd == null);
            std.debug.assert(self.wake_write_fd == null);
            std.debug.assert(self.childPid() == null);
        }

        fn refreshChildState(self: *Self) void {
            if (!self.started) return;
            const pid = self.childPid() orelse return;
            switch (waitChildNoHang(pid)) {
                .alive => {},
                .reaped => {
                    self.child = .none;
                },
            }
        }

        fn transportReady(self: *const Self) bool {
            if (!self.started) return false;
            if (self.master_fd == null) return false;
            if (self.child != .live) return false;
            return true;
        }

        fn childPid(self: *const Self) ?posix.pid_t {
            return switch (self.child) {
                .none => null,
                .pending_session => |pid| pid,
                .live => |pid| pid,
            };
        }

        fn awaitChildSession(self: *Self, ready_fd: posix.fd_t) Pty.StartError!void {
            defer _ = c.close(@intCast(ready_fd));
            var byte: [1]u8 = undefined;
            while (true) {
                const n = c.read(ready_fd, &byte, byte.len);
                if (n == 1) return;
                if (n == 0) {
                    self.refreshChildState();
                    return error.OpenPtyFailed;
                }
                switch (posix.errno(n)) {
                    .INTR => continue,
                    else => return error.OpenPtyFailed,
                }
            }
        }

        fn stopChild(self: *Self) void {
            switch (self.child) {
                .none => {},
                .pending_session => |pid| stopPendingChild(self, pid),
                .live => |pid| stopLiveChild(self, pid),
            }
        }

        fn stopPendingChild(self: *Self, pid: posix.pid_t) void {
            std.debug.assert(pid > 0);
            _ = sendSignal(pid, .terminate);
            if (waitChildWithDeadline(pid, stop_terminate_grace_ns)) {
                self.child = .none;
                return;
            }
            _ = sendSignal(pid, .kill);
            waitChildBlocking(pid);
            self.child = .none;
        }

        fn stopLiveChild(self: *Self, pid: posix.pid_t) void {
            std.debug.assert(pid > 0);
            _ = sendGroupSignal(pid, .hangup);
            if (waitChildWithDeadline(pid, stop_hangup_grace_ns) and waitProcessGroupMissing(pid, stop_hangup_grace_ns)) {
                self.child = .none;
                return;
            }
            _ = sendGroupSignal(pid, .terminate);
            if (waitChildWithDeadline(pid, stop_terminate_grace_ns) and waitProcessGroupMissing(pid, stop_terminate_grace_ns)) {
                self.child = .none;
                return;
            }
            _ = sendGroupSignal(pid, .kill);
            waitChildBlocking(pid);
            _ = waitProcessGroupMissing(pid, stop_terminate_grace_ns);
            self.child = .none;
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
            if (!self.started) return error.NotStarted;
            const master_fd = self.master_fd orelse return error.NotStarted;
            if (buf.len == 0) return 0;

            const n = c.read(master_fd, buf.ptr, buf.len);
            if (n < 0) {
                return switch (posix.errno(n)) {
                    .AGAIN => {
                        self.refreshChildState();
                        if (!self.transportReady()) return error.NotStarted;
                        return error.WouldBlock;
                    },
                    .IO => {
                        self.refreshChildState();
                        if (!self.transportReady()) return error.NotStarted;
                        return error.ReadFailed;
                    },
                    .INTR => error.Interrupted,
                    else => error.ReadFailed,
                };
            }
            if (n == 0) {
                self.refreshChildState();
                if (!self.transportReady()) return error.NotStarted;
                return error.EndOfStream;
            }
            return @intCast(n);
        }

        fn waitReadablePty(ptr: *anyopaque, timeout_ms: i32) Pty.WaitReadableError!WaitReadableResult {
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
            if (ready <= 0) return .timeout;

            if ((fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
                self.drainWakePipe();
                return .wake;
            }
            if ((fds[0].revents & posix.POLL.IN) != 0) return .ready;
            if ((fds[0].revents & posix.POLL.HUP) != 0) {
                self.refreshChildState();
                if (!self.transportReady()) return error.NotStarted;
            }
            return waitReadablePollResult(fds[0].revents);
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
            if (self.childPid()) |pid| _ = sendGroupSignal(pid, signal);
        }
    };
}

fn waitReadablePollResult(revents: i16) WaitReadableResult {
    if ((revents & posix.POLL.IN) != 0) return .ready;
    return .timeout;
}

fn optionalZPtr(bytes: ?[:0]u8) ?[*:0]u8 {
    if (bytes) |value| {
        return @ptrFromInt(@intFromPtr(value.ptr));
    }
    return null;
}

fn closeTransport(transport: Open) void {
    _ = c.close(@intCast(transport.master_fd));
    _ = c.close(@intCast(transport.slave_fd));
}

pub fn openWake() Pty.StartError!Wake {
    var fds = [_]c_int{ -1, -1 };
    if (c.pipe(&fds) != 0) return error.OpenPtyFailed;
    errdefer {
        if (fds[0] >= 0) _ = c.close(fds[0]);
        if (fds[1] >= 0) _ = c.close(fds[1]);
    }

    try setCloseOnExec(@intCast(fds[0]));
    try setCloseOnExec(@intCast(fds[1]));
    try setNonBlocking(@intCast(fds[0]));
    try setNonBlocking(@intCast(fds[1]));
    return .{ .read_fd = @intCast(fds[0]), .write_fd = @intCast(fds[1]) };
}

pub fn closeWake(wake: Wake) void {
    _ = c.close(@intCast(wake.read_fd));
    _ = c.close(@intCast(wake.write_fd));
}

fn openWakePipe() Pty.StartError!Wake {
    return openWake();
}

fn closeWakePipe(wake: Wake) void {
    closeWake(wake);
}

fn openChildReadyPipe() Pty.StartError!ChildReady {
    var fds = [_]c_int{ -1, -1 };
    if (c.pipe(&fds) != 0) return error.OpenPtyFailed;
    errdefer {
        if (fds[0] >= 0) _ = c.close(fds[0]);
        if (fds[1] >= 0) _ = c.close(fds[1]);
    }

    try setCloseOnExec(@intCast(fds[0]));
    try setCloseOnExec(@intCast(fds[1]));
    return .{ .read_fd = @intCast(fds[0]), .write_fd = @intCast(fds[1]) };
}

fn closeChildReadyPipe(pipe: ChildReady) void {
    _ = c.close(@intCast(pipe.read_fd));
    _ = c.close(@intCast(pipe.write_fd));
}

pub fn setNonBlocking(fd: posix.fd_t) Pty.StartError!void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.OpenPtyFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0) return error.OpenPtyFailed;
}

pub fn setCloseOnExec(fd: posix.fd_t) Pty.StartError!void {
    const flags = c.fcntl(fd, c.F_GETFD, @as(c_int, 0));
    if (flags < 0) return error.OpenPtyFailed;
    if (c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC) != 0) return error.OpenPtyFailed;
}

pub fn requireExecutable(path: [:0]const u8) Pty.StartError!void {
    if (c.access(path.ptr, c.X_OK) != 0) return error.ShellUnavailable;
}

fn cArg(path: [*:0]const u8) [*c]u8 {
    return @ptrFromInt(@intFromPtr(path));
}

pub const ChildProcessSetupFn = *const fn (shell_path: [:0]const u8) void;

const ChildProcessFds = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    wake_read_fd: ?posix.fd_t,
    wake_write_fd: ?posix.fd_t,
};

fn resetChildSignalDispositions() Pty.StartError!void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    if (c.sigaction(@intFromEnum(posix.SIG.ABRT), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.ALRM), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.BUS), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.CHLD), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.FPE), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.HUP), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.ILL), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.INT), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.PIPE), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.QUIT), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.SEGV), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.TERM), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
    if (c.sigaction(@intFromEnum(posix.SIG.TRAP), @ptrCast(&sa), null) != 0) return error.OpenPtyFailed;
}

fn closeChildFdIfNeeded(fd: posix.fd_t) Pty.StartError!void {
    if (fd <= 2) return;
    if (c.close(@intCast(fd)) != 0) return error.OpenPtyFailed;
}

fn setupChildProcessFds(fds: ChildProcessFds) Pty.StartError!void {
    try resetChildSignalDispositions();
    if (c.setsid() < 0) return error.OpenPtyFailed;
    if (c.ioctl(@intCast(fds.slave_fd), c.TIOCSCTTY, @as(c_ulong, 0)) != 0) return error.OpenPtyFailed;
    if (c.dup2(fds.slave_fd, 0) < 0) return error.OpenPtyFailed;
    if (c.dup2(fds.slave_fd, 1) < 0) return error.OpenPtyFailed;
    if (c.dup2(fds.slave_fd, 2) < 0) return error.OpenPtyFailed;
    try closeChildFdIfNeeded(fds.master_fd);
    if (fds.wake_read_fd) |fd| try closeChildFdIfNeeded(fd);
    if (fds.wake_write_fd) |fd| try closeChildFdIfNeeded(fd);
    try closeChildFdIfNeeded(fds.slave_fd);
}

fn notifyParentChildSessionReady(ready_write_fd: ?posix.fd_t) Pty.StartError!void {
    const fd = ready_write_fd orelse return;
    defer closeChildFdIfNeeded(fd) catch unreachable;
    var byte: [1]u8 = .{1};
    while (true) {
        const n = c.write(fd, &byte, byte.len);
        if (n == 1) return;
        switch (posix.errno(n)) {
            .INTR => continue,
            else => return error.OpenPtyFailed,
        }
    }
}

pub fn childProcess(
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    wake_read_fd: ?posix.fd_t,
    wake_write_fd: ?posix.fd_t,
    ready_write_fd: ?posix.fd_t,
    shell_path: [:0]const u8,
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    setup: ?ChildProcessSetupFn,
) Pty.StartError!void {
    try setupChildProcessFds(.{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
        .wake_read_fd = wake_read_fd,
        .wake_write_fd = wake_write_fd,
    });
    try notifyParentChildSessionReady(ready_write_fd);

    if (cwd) |dir| {
        if (c.chdir(dir) != 0) c._exit(127);
    }
    if (setup) |hook| hook(shell_path);

    if (command) |cmd| {
        const argv = [_:null][*c]u8{ cArg(shell_path.ptr), cArg("-c"), cArg(cmd) };
        const envp: [*c]const [*c]u8 = @ptrCast(@constCast(std.c.environ));
        _ = c.execve(shell_path.ptr, argv[0..].ptr, envp);
        c._exit(127);
    }

    const argv = [_:null][*c]u8{ cArg(shell_path.ptr), cArg("-i") };
    const envp: [*c]const [*c]u8 = @ptrCast(@constCast(std.c.environ));
    _ = c.execve(shell_path.ptr, argv[0..].ptr, envp);
    c._exit(127);
}

fn waitChildNoHang(pid: posix.pid_t) enum { alive, reaped } {
    std.debug.assert(pid > 0);
    var status: c_int = 0;
    while (true) {
        const res = c.waitpid(pid, &status, c.WNOHANG);
        if (res == 0) return .alive;
        if (res == pid) return .reaped;
        switch (posix.errno(res)) {
            .INTR => continue,
            .CHILD => return .reaped,
            else => return .reaped,
        }
    }
}

fn waitChildWithDeadline(pid: posix.pid_t, timeout_ns: u64) bool {
    std.debug.assert(pid > 0);
    const wait_slices = @max(1, timeout_ns / stop_wait_slice_ns);
    var slice_index: u64 = 0;
    while (slice_index < wait_slices) : (slice_index += 1) {
        if (waitChildNoHang(pid) == .reaped) return true;
        _ = c.usleep(@intCast(stop_wait_slice_ns / std.time.ns_per_us));
    }
    return waitChildNoHang(pid) == .reaped;
}

fn waitChildBlocking(pid: posix.pid_t) void {
    std.debug.assert(pid > 0);
    var status: c_int = 0;
    while (true) {
        const res = c.waitpid(pid, &status, 0);
        if (res == pid) return;
        switch (posix.errno(res)) {
            .INTR => continue,
            .CHILD => return,
            else => return,
        }
    }
}

fn waitProcessGroupMissing(pid: posix.pid_t, timeout_ns: u64) bool {
    std.debug.assert(pid > 0);
    return waitSignalTargetMissing(-pid, timeout_ns);
}

fn waitSignalTargetMissing(target: posix.pid_t, timeout_ns: u64) bool {
    const wait_slices = @max(1, timeout_ns / stop_wait_slice_ns);
    var slice_index: u64 = 0;
    while (slice_index < wait_slices) : (slice_index += 1) {
        if (!signalTargetExists(target)) return true;
        _ = c.usleep(@intCast(stop_wait_slice_ns / std.time.ns_per_us));
    }
    return !signalTargetExists(target);
}

fn signalTargetExists(target: posix.pid_t) bool {
    while (true) {
        const res = c.kill(target, 0);
        if (res == 0) return true;
        switch (posix.errno(res)) {
            .INTR => continue,
            .SRCH => return false,
            else => return true,
        }
    }
}

fn sendSignal(pid: posix.pid_t, signal: ControlSignal) SignalResult {
    return sendSignalTarget(pid, signal);
}

fn sendGroupSignal(pid: posix.pid_t, signal: ControlSignal) SignalResult {
    std.debug.assert(pid > 0);
    return sendSignalTarget(-pid, signal);
}

fn sendSignalTarget(target: posix.pid_t, signal: ControlSignal) SignalResult {
    while (true) {
        const res = c.kill(target, @intCast(@intFromEnum(signal.posixSignal())));
        if (res == 0) return .delivered;
        switch (posix.errno(res)) {
            .INTR => continue,
            .SRCH => return .missing,
            else => return .missing,
        }
    }
}

pub const testing = struct {
    pub fn waitReadablePollResult(revents: i16) WaitReadableResult {
        return @import("posix.zig").waitReadablePollResult(revents);
    }
};
