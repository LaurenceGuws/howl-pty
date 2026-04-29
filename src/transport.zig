//! Responsibility: publish transport interface, implementations, and selection.
//! Ownership: host-to-session transport boundary and lane binding.
//! Reason: keep transport imports stable for hosts and tests in one file.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const posix = std.posix;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("signal.h");
});

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!usize,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        resize: *const fn (ptr: *anyopaque, cols: u16, rows: u16) anyerror!void,
        control: *const fn (ptr: *anyopaque, signal: u8) void,
    };

    pub fn start(self: Transport) anyerror!void {
        return self.vtable.start(self.ptr);
    }
    pub fn stop(self: Transport) void {
        self.vtable.stop(self.ptr);
    }
    pub fn write(self: Transport, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }
    pub fn read(self: Transport, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }
    pub fn resize(self: Transport, cols: u16, rows: u16) anyerror!void {
        return self.vtable.resize(self.ptr, cols, rows);
    }
    pub fn control(self: Transport, signal: u8) void {
        self.vtable.control(self.ptr, signal);
    }
};
///  portability class used for host-level selection.
pub const Class = enum {
    /// POSIX PTY transport for Linux and macOS hosts.
    /// Uses fork(), openpty(), and POSIX process control (signals, ioctl).
    posix_pty,
    /// Android PTY transport for Android hosts.
    /// Routes I/O through Android shell PTY
    android_pty,
    /// ConPTY transport for Windows hosts (future).
    /// Uses Windows ConPTY API and Windows process management.
    conpty,
};

pub const Mem = struct {
    allocator: std.mem.Allocator,
    started: bool,
    rx: std.ArrayListUnmanaged(u8),
    tx: std.ArrayListUnmanaged(u8),
    last_cols: u16,
    last_rows: u16,
    last_signal: ?u8,

    pub fn init(allocator: std.mem.Allocator) Mem {
        return .{ .allocator = allocator, .started = false, .rx = .empty, .tx = .empty, .last_cols = 0, .last_rows = 0, .last_signal = null };
    }

    pub fn deinit(self: *Mem) void {
        self.rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transport(self: *Mem) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .resize = resizeImpl, .control = controlImpl };

    fn startImpl(ptr: *anyopaque) anyerror!void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        self.started = true;
    }
    fn stopImpl(ptr: *anyopaque) void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        self.started = false;
    }
    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        try self.tx.appendSlice(self.allocator, bytes);
        return bytes.len;
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        const n = @min(buf.len, self.rx.items.len);
        if (n == 0) return 0;
        @memcpy(buf[0..n], self.rx.items[0..n]);
        const remaining = self.rx.items.len - n;
        std.mem.copyForwards(u8, self.rx.items[0..remaining], self.rx.items[n..]);
        self.rx.shrinkRetainingCapacity(remaining);
        return n;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn controlImpl(ptr: *anyopaque, signal: u8) void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        self.last_signal = signal;
    }
};

pub const Partial = struct {
    allocator: std.mem.Allocator,
    started: bool,
    max_bytes: usize,
    tx: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) Partial {
        return .{ .allocator = allocator, .started = false, .max_bytes = max_bytes, .tx = .empty };
    }

    pub fn deinit(self: *Partial) void {
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transport(self: *Partial) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .resize = resizeImpl, .control = controlImpl };

    fn startImpl(ptr: *anyopaque) anyerror!void {
        const self: *Partial = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        self.started = true;
    }
    fn stopImpl(ptr: *anyopaque) void {
        const self: *Partial = @ptrCast(@alignCast(ptr));
        self.started = false;
    }
    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Partial = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        const n = @min(bytes.len, self.max_bytes);
        try self.tx.appendSlice(self.allocator, bytes[0..n]);
        return n;
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        _ = ptr;
        _ = buf;
        return 0;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        _ = ptr;
        _ = cols;
        _ = rows;
    }
    fn controlImpl(ptr: *anyopaque, signal: u8) void {
        _ = ptr;
        _ = signal;
    }
};

pub const Fail = struct {
    pub fn init() Fail {
        return .{};
    }
    pub fn deinit(self: *Fail) void {
        _ = self;
    }
    pub fn transport(self: *Fail) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .resize = resizeImpl, .control = controlImpl };
    fn startImpl(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        return error.Failed;
    }
    fn stopImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        _ = ptr;
        _ = bytes;
        return error.Failed;
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        _ = ptr;
        _ = buf;
        return error.Failed;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        _ = ptr;
        _ = cols;
        _ = rows;
        return error.Failed;
    }
    fn controlImpl(ptr: *anyopaque, signal: u8) void {
        _ = ptr;
        _ = signal;
    }
};

pub const UnixPty = struct {
    allocator: std.mem.Allocator,
    shell_path: [:0]u8,
    command: ?[:0]u8,
    started: bool,
    master_fd: ?posix.fd_t,
    child_pid: ?posix.pid_t,
    last_cols: u16,
    last_rows: u16,

    pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, command: ?[]const u8) !UnixPty {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
        const shell_z = try allocator.dupeZ(u8, shell_path);
        errdefer allocator.free(shell_z);
        const command_z = if (command) |cmd| try allocator.dupeZ(u8, cmd) else null;
        errdefer if (command_z) |z| allocator.free(z);
        return .{ .allocator = allocator, .shell_path = shell_z, .command = command_z, .started = false, .master_fd = null, .child_pid = null, .last_cols = 0, .last_rows = 0 };
    }

    pub fn deinit(self: *UnixPty) void {
        self.stopInternal();
        self.allocator.free(self.shell_path);
        if (self.command) |cmd| self.allocator.free(cmd);
        self.* = undefined;
    }

    pub fn transport(self: *UnixPty) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn startInternal(self: *UnixPty) anyerror!void {
        if (self.started) return error.AlreadyStarted;
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;
        var winsize = c.struct_winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) return error.OpenPtyFailed;
        errdefer {
            if (master_fd >= 0) posix.close(@intCast(master_fd));
            if (slave_fd >= 0) posix.close(@intCast(slave_fd));
        }
        try setNonBlocking(@intCast(master_fd));
        const pid = try posix.fork();
        if (pid == 0) {
            childProcess(@intCast(slave_fd), self.shell_path, self.command) catch posix.exit(127);
            unreachable;
        }
        posix.close(@intCast(slave_fd));
        self.master_fd = @intCast(master_fd);
        self.child_pid = pid;
        self.started = true;
    }

    fn stopInternal(self: *UnixPty) void {
        if (!self.started) return;
        if (self.child_pid) |pid| {
            sendSignal(pid, @intCast(posix.SIG.TERM));
            reapChild(pid, 30);
        }
        if (self.master_fd) |fd| posix.close(fd);
        self.child_pid = null;
        self.master_fd = null;
        self.started = false;
    }

    const vtable: Transport.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .resize = resizeImpl, .control = controlImpl };
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
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (bytes.len == 0) return 0;
        const n = posix.write(self.master_fd.?, bytes) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
        return n;
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (buf.len == 0) return 0;
        const n = posix.read(self.master_fd.?, buf) catch |err| switch (err) {
            error.WouldBlock, error.InputOutput => return 0,
            else => return err,
        };
        return n;
    }
    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        var winsize = c.struct_winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.ioctl(@intCast(self.master_fd.?), c.TIOCSWINSZ, &winsize) != 0) return error.ResizeFailed;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn controlImpl(ptr: *anyopaque, signal: u8) void {
        const self: *UnixPty = @ptrCast(@alignCast(ptr));
        if (!self.started) return;
        if (self.child_pid) |pid| sendSignal(pid, signal);
    }
};

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

    pub fn transport(self: *AndroidPty) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

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
        try setNonBlocking(@intCast(master_fd));
        const pid = try posix.fork();
        if (pid == 0) {
            childProcess(@intCast(slave_fd), self.shell_path, self.command) catch posix.exit(127);
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
            sendSignal(pid, @intCast(posix.SIG.TERM));
            reapChild(pid, 30);
        }
        if (self.master_fd) |fd| posix.close(fd);
        self.child_pid = null;
        self.master_fd = null;
        self.started = false;
    }

    const vtable: Transport.VTable = .{ .start = startImpl, .stop = stopImpl, .write = writeImpl, .read = readImpl, .resize = resizeImpl, .control = controlImpl };
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
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (bytes.len == 0) return 0;
        const n = posix.write(self.master_fd.?, bytes) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
        return n;
    }
    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *AndroidPty = @ptrCast(@alignCast(ptr));
        if (!self.started or self.master_fd == null) return error.NotStarted;
        if (buf.len == 0) return 0;
        const n = posix.read(self.master_fd.?, buf) catch |err| switch (err) {
            error.WouldBlock, error.InputOutput => return 0,
            else => return err,
        };
        return n;
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
        if (self.child_pid) |pid| sendSignal(pid, signal);
    }
};

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return error.OpenPtyFailed;
    _ = posix.fcntl(fd, posix.F.SETFL, @as(u32, @intCast(flags)) | c.O_NONBLOCK) catch return error.OpenPtyFailed;
}

fn childProcess(slave_fd: posix.fd_t, shell_path: [:0]const u8, command: ?[:0]const u8) !void {
    _ = posix.setsid() catch {};
    _ = c.ioctl(@intCast(slave_fd), c.TIOCSCTTY, @as(c_ulong, 0));

    try posix.dup2(slave_fd, 0);
    try posix.dup2(slave_fd, 1);
    try posix.dup2(slave_fd, 2);
    if (slave_fd > 2) posix.close(slave_fd);

    if (command) |cmd| {
        const argv = [_:null]?[*:0]const u8{ shell_path.ptr, "-lc", cmd.ptr };
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@constCast(std.c.environ));
        _ = posix.execvpeZ(shell_path.ptr, &argv, envp) catch {};
        posix.exit(127);
    }

    const argv = [_:null]?[*:0]const u8{shell_path.ptr};
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(@constCast(std.c.environ));
    _ = posix.execvpeZ(shell_path.ptr, &argv, envp) catch {};
    posix.exit(127);
}

fn sendSignal(pid: posix.pid_t, sig: u8) void {
    posix.kill(pid, sig) catch {};
}

fn reapChild(pid: posix.pid_t, timeout_ms: i64) void {
    const start_ms = std.time.milliTimestamp();
    while (true) {
        const res = posix.waitpid(pid, posix.W.NOHANG);
        if (res.pid != 0) return;
        if (std.time.milliTimestamp() - start_ms > timeout_ms) {
            sendSignal(pid, @intCast(posix.SIG.KILL));
            _ = posix.waitpid(pid, 0);
            return;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

pub const Lane = switch (build_options.transport_variant) {
    .unix_pty => UnixPty,
    .android_pty => AndroidPty,
};

pub const transport_class = switch (build_options.transport_variant) {
    .unix_pty => Class.posix_pty,
    .android_pty => Class.android_pty,
};

pub fn init(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !Lane {
    return switch (build_options.transport_variant) {
        .unix_pty => Lane.init(allocator, shell_path orelse "/bin/sh", command),
        .android_pty => Lane.init(allocator, shell_path orelse (if (builtin.target.abi == .android) "/system/bin/sh" else "/bin/sh"), command),
    };
}
