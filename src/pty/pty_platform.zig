//! Responsibility: define shared native PTY platform bindings.
//! Ownership: session PTY layer owns OS C imports and PTY interface wiring.
//! Reason: keeps platform PTY details behind session-owned variants.

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
        start: *const fn (ptr: *anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!usize,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        wait_readable: *const fn (ptr: *anyopaque, timeout_ms: i32) anyerror!bool,
        resize: *const fn (ptr: *anyopaque, cols: u16, rows: u16) anyerror!void,
        control: *const fn (ptr: *anyopaque, signal: ControlSignal) void,
    };

    pub fn start(self: Pty) anyerror!void {
        return self.vtable.start(self.ptr);
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
    conpty,
};

pub fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.OpenPtyFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0) return error.OpenPtyFailed;
}

pub fn requireExecutable(path: [:0]const u8) !void {
    if (c.access(path.ptr, c.X_OK) != 0) return error.ShellUnavailable;
}

fn cArg(path: [*:0]const u8) [*c]u8 {
    return @ptrFromInt(@intFromPtr(path));
}

pub const ChildProcessSetupFn = *const fn (shell_path: [:0]const u8) void;

pub fn childProcess(
    slave_fd: posix.fd_t,
    shell_path: [:0]const u8,
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    setup: ?ChildProcessSetupFn,
) !void {
    _ = c.setsid();
    _ = c.ioctl(@intCast(slave_fd), c.TIOCSCTTY, @as(c_ulong, 0));

    if (c.dup2(slave_fd, 0) < 0) return error.OpenPtyFailed;
    if (c.dup2(slave_fd, 1) < 0) return error.OpenPtyFailed;
    if (c.dup2(slave_fd, 2) < 0) return error.OpenPtyFailed;
    if (slave_fd > 2) _ = c.close(slave_fd);

    _ = c.setenv("TERM", "xterm-256color", 1);
    _ = c.setenv("PS1", "howl$ ", 1);
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
