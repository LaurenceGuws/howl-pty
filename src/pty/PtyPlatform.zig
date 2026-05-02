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
        control: *const fn (ptr: *anyopaque, signal: u8) void,
    };

    pub fn start(self: Pty) anyerror!void { return self.vtable.start(self.ptr); }
    pub fn stop(self: Pty) void { self.vtable.stop(self.ptr); }
    pub fn write(self: Pty, bytes: []const u8) anyerror!usize { return self.vtable.write(self.ptr, bytes); }
    pub fn read(self: Pty, buf: []u8) anyerror!usize { return self.vtable.read(self.ptr, buf); }
    pub fn waitReadable(self: Pty, timeout_ms: i32) anyerror!bool { return self.vtable.wait_readable(self.ptr, timeout_ms); }
    pub fn resize(self: Pty, cols: u16, rows: u16) anyerror!void { return self.vtable.resize(self.ptr, cols, rows); }
    pub fn control(self: Pty, signal: u8) void { self.vtable.control(self.ptr, signal); }
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

pub fn childProcess(slave_fd: posix.fd_t, shell_path: [:0]const u8, command: ?[:0]const u8) !void {
    _ = c.setsid();
    _ = c.ioctl(@intCast(slave_fd), c.TIOCSCTTY, @as(c_ulong, 0));

    if (c.dup2(slave_fd, 0) < 0) return error.OpenPtyFailed;
    if (c.dup2(slave_fd, 1) < 0) return error.OpenPtyFailed;
    if (c.dup2(slave_fd, 2) < 0) return error.OpenPtyFailed;
    if (slave_fd > 2) _ = c.close(slave_fd);

    _ = c.setenv("TERM", "xterm-256color", 1);
    _ = c.setenv("PS1", "howl$ ", 1);
    applyShellDerivedLayout(shell_path);

    if (command) |cmd| {
        const argv = [_:null]?[*:0]const u8{ shell_path.ptr, "-lc", cmd.ptr };
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@constCast(std.c.environ));
        _ = c.execve(shell_path.ptr, @ptrCast(&argv), @ptrCast(envp));
        c._exit(127);
    }

    const argv = [_:null]?[*:0]const u8{ shell_path.ptr, "-i" };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@constCast(std.c.environ));
    _ = c.execve(shell_path.ptr, @ptrCast(&argv), @ptrCast(envp));
    c._exit(127);
}

fn applyShellDerivedLayout(shell_path: [:0]const u8) void {
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

    const app_data = std.fmt.bufPrintZ(&app_data_buf, "{s}", .{app_root}) catch return;
    const prefix = std.fmt.bufPrintZ(&prefix_buf, "{s}/usr", .{app_root}) catch return;
    const home = std.fmt.bufPrintZ(&home_buf, "{s}/home", .{app_root}) catch return;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/usr/tmp", .{app_root}) catch return;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/usr/bin:/system/bin", .{app_root}) catch return;

    _ = c.setenv("APP_DATA_DIR", app_data.ptr, 1);
    _ = c.setenv("PREFIX", prefix.ptr, 1);
    _ = c.setenv("HOME", home.ptr, 1);
    _ = c.setenv("TMPDIR", tmp.ptr, 1);
    _ = c.setenv("PATH", path.ptr, 1);

    _ = c.chdir(home.ptr);
}

pub fn sendSignal(pid: posix.pid_t, sig: u8) void {
    const signal: posix.SIG = switch (sig) {
        1 => .HUP,
        2 => .INT,
        15 => .TERM,
        9 => .KILL,
        else => return,
    };
    posix.kill(pid, signal) catch {};
}

pub fn reapChild(pid: posix.pid_t, timeout_ms: i64) void {
    const max_wait_ticks: i64 = @max(1, @divTrunc(timeout_ms, 2));
    var waited_ticks: i64 = 0;
    while (true) {
        var status: c_int = 0;
        const res = c.waitpid(pid, &status, c.WNOHANG);
        if (res == pid) return;
        if (waited_ticks >= max_wait_ticks) {
            sendSignal(pid, @intFromEnum(posix.SIG.KILL));
            _ = c.waitpid(pid, &status, 0);
            return;
        }
        _ = c.usleep(2000);
        waited_ticks += 1;
    }
}
