const std = @import("std");
const posix = std.posix;

pub const Launch = struct {
    shell_path: ?[]const u8 = null,
    command: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub const Pty = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const StartError = error{
        AlreadyStarted,
        OpenPtyFailed,
        ShellUnavailable,
        UnsupportedPlatform,
    };

    pub const WriteError = error{
        Interrupted,
        NotStarted,
        WouldBlock,
        WriteFailed,
    };

    pub const ReadError = error{
        EndOfStream,
        Interrupted,
        NotStarted,
        ReadFailed,
        WouldBlock,
    };

    pub const WaitReadableError = error{
        Interrupted,
        NotStarted,
        WaitFailed,
        WouldBlock,
    };

    pub const ResizeError = error{
        NotStarted,
        ResizeFailed,
    };

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, cols: u16, rows: u16) StartError!void,
        stop: *const fn (ptr: *anyopaque) void,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) WriteError!usize,
        read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
        wait_readable: *const fn (ptr: *anyopaque, timeout_ms: i32) WaitReadableError!bool,
        kick_wait: *const fn (ptr: *anyopaque) void,
        resize: *const fn (ptr: *anyopaque, cols: u16, rows: u16) ResizeError!void,
        control: *const fn (ptr: *anyopaque, signal: ControlSignal) void,
    };

    pub fn start(self: Pty, cols: u16, rows: u16) StartError!void {
        return self.vtable.start(self.ptr, cols, rows);
    }

    pub fn stop(self: Pty) void {
        self.vtable.stop(self.ptr);
    }

    pub fn write(self: Pty, bytes: []const u8) WriteError!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn read(self: Pty, buf: []u8) ReadError!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn waitReadable(self: Pty, timeout_ms: i32) WaitReadableError!bool {
        return self.vtable.wait_readable(self.ptr, timeout_ms);
    }

    pub fn kickWait(self: Pty) void {
        self.vtable.kick_wait(self.ptr);
    }

    pub fn resize(self: Pty, cols: u16, rows: u16) ResizeError!void {
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

pub const Owned = @import("pty/unix.zig").Pty;
