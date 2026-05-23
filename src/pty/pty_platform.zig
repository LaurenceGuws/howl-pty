const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const c = @cImport({
    @cDefine("_Nonnull", "");
    @cDefine("_Nullable", "");
    @cDefine("_Null_unspecified", "");
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

/// PTY interface boundary.
pub const Pty = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, cols: u16, rows: u16) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!usize,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        wait_readable: *const fn (ptr: *anyopaque, timeout_ms: i32) anyerror!bool,
        kick_wait: *const fn (ptr: *anyopaque) void,
        resize: *const fn (ptr: *anyopaque, cols: u16, rows: u16) anyerror!void,
        control: *const fn (ptr: *anyopaque, signal: ControlSignal) void,
    };

    pub fn start(self: Pty, cols: u16, rows: u16) anyerror!void {
        return self.vtable.start(self.ptr, cols, rows);
    }
    pub fn stop(self: Pty) void {
        self.vtable.stop(self.ptr);
    }
    pub fn write(self: Pty, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }
    pub fn read(self: Pty, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }
    pub fn waitReadable(self: Pty, timeout_ms: i32) anyerror!bool {
        return self.vtable.wait_readable(self.ptr, timeout_ms);
    }
    pub fn kickWait(self: Pty) void {
        self.vtable.kick_wait(self.ptr);
    }
    pub fn resize(self: Pty, cols: u16, rows: u16) anyerror!void {
        return self.vtable.resize(self.ptr, cols, rows);
    }
    pub fn control(self: Pty, signal: ControlSignal) void {
        self.vtable.control(self.ptr, signal);
    }
};

pub const ControlSignal = enum(u8) {
    hangup = 1,
    interrupt = 2,
    resize_notify = 3,
    kill = 9,
    terminate = 15,

    pub fn fromRaw(value: u8) error{InvalidControlSignal}!ControlSignal {
        return switch (value) {
            @intFromEnum(ControlSignal.hangup) => .hangup,
            @intFromEnum(ControlSignal.interrupt) => .interrupt,
            @intFromEnum(ControlSignal.resize_notify) => .resize_notify,
            @intFromEnum(ControlSignal.kill) => .kill,
            @intFromEnum(ControlSignal.terminate) => .terminate,
            else => error.InvalidControlSignal,
        };
    }

    pub fn raw(self: ControlSignal) u8 {
        return @intFromEnum(self);
    }

    pub fn posixSignal(self: ControlSignal) posix.SIG {
        return switch (self) {
            .hangup => .HUP,
            .interrupt => .INT,
            .resize_notify => .WINCH,
            .kill => .KILL,
            .terminate => .TERM,
        };
    }
};

pub const PtyClass = enum {
    posix_pty,
    android_pty,
};

pub fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.OpenPtyFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0) return error.OpenPtyFailed;
}

pub fn setCloseOnExec(fd: posix.fd_t) !void {
    const flags = c.fcntl(fd, c.F_GETFD, @as(c_int, 0));
    if (flags < 0) return error.OpenPtyFailed;
    if (c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC) != 0) return error.OpenPtyFailed;
}

pub fn requireExecutable(path: [:0]const u8) !void {
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

fn resetChildSignalDispositions() !void {
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

fn closeChildFdIfNeeded(fd: posix.fd_t) !void {
    if (fd <= 2) return;
    if (c.close(@intCast(fd)) != 0) return error.OpenPtyFailed;
}

fn setupChildProcessFds(fds: ChildProcessFds) !void {
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

pub fn childProcess(
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    wake_read_fd: ?posix.fd_t,
    wake_write_fd: ?posix.fd_t,
    shell_path: [:0]const u8,
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    setup: ?ChildProcessSetupFn,
) !void {
    try setupChildProcessFds(.{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
        .wake_read_fd = wake_read_fd,
        .wake_write_fd = wake_write_fd,
    });

    // PTY launch owns child session wiring, cwd, and exec only.
    // Host-owned shell environment policy must already be present in std.c.environ here.
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

pub fn sendSignal(pid: posix.pid_t, signal: ControlSignal) void {
    posix.kill(pid, signal.posixSignal()) catch {};
}

pub fn sendGroupSignal(pid: posix.pid_t, signal: ControlSignal) void {
    posix.kill(-pid, signal.posixSignal()) catch {};
}

pub fn reapChildNow(pid: posix.pid_t) void {
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, c.WNOHANG);
}
