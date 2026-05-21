
const std = @import("std");
const Pty = @import("pty_platform.zig").Pty;
const ControlSignal = @import("pty_platform.zig").ControlSignal;

pub const Mem = struct {
    allocator: std.mem.Allocator,
    started: bool,
    rx: std.ArrayListUnmanaged(u8),
    tx: std.ArrayListUnmanaged(u8),
    last_cols: u16,
    last_rows: u16,
    last_signal: ?ControlSignal,

    pub fn init(allocator: std.mem.Allocator) Mem {
        return .{ .allocator = allocator, .started = false, .rx = .empty, .tx = .empty, .last_cols = 0, .last_rows = 0, .last_signal = null };
    }
    pub fn deinit(self: *Mem) void {
        self.rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn pty(self: *Mem) Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Pty.VTable = .{ .start = startPty, .stop = stopPty, .write = writePty, .read = readPty, .wait_readable = waitReadablePty, .kick_wait = kickWaitPty, .resize = resizePty, .control = controlPty };
    fn startPty(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn stopPty(ptr: *anyopaque) void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        self.started = false;
    }
    fn writePty(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        try self.tx.appendSlice(self.allocator, bytes);
        return bytes.len;
    }
    fn readPty(ptr: *anyopaque, buf: []u8) anyerror!usize {
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
    fn waitReadablePty(ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        _ = timeout_ms;
        return self.rx.items.len > 0;
    }
    fn kickWaitPty(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn resizePty(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        self.last_cols = cols;
        self.last_rows = rows;
    }
    fn controlPty(ptr: *anyopaque, signal: ControlSignal) void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        self.last_signal = signal;
    }
};

pub const Partial = struct {
    allocator: std.mem.Allocator,
    started: bool,
    max_bytes: u32,
    tx: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator, max_bytes: u32) Partial {
        return .{ .allocator = allocator, .started = false, .max_bytes = max_bytes, .tx = .empty };
    }
    pub fn deinit(self: *Partial) void {
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn pty(self: *Partial) Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Pty.VTable = .{ .start = startPty, .stop = stopPty, .write = writePty, .read = readPty, .wait_readable = waitReadablePty, .kick_wait = kickWaitPty, .resize = resizePty, .control = controlPty };
    fn startPty(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *Partial = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        _ = cols;
        _ = rows;
        self.started = true;
    }
    fn stopPty(ptr: *anyopaque) void {
        const self: *Partial = @ptrCast(@alignCast(ptr));
        self.started = false;
    }
    fn writePty(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Partial = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        const byte_count: u32 = @intCast(bytes.len);
        const n = @min(byte_count, self.max_bytes);
        try self.tx.appendSlice(self.allocator, bytes[0..@intCast(n)]);
        return @intCast(n);
    }
    fn readPty(ptr: *anyopaque, buf: []u8) anyerror!usize {
        _ = ptr;
        _ = buf;
        return 0;
    }
    fn waitReadablePty(ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
        _ = ptr;
        _ = timeout_ms;
        return false;
    }
    fn kickWaitPty(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn resizePty(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        _ = ptr;
        _ = cols;
        _ = rows;
    }
    fn controlPty(ptr: *anyopaque, signal: ControlSignal) void {
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
    pub fn pty(self: *Fail) Pty {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Pty.VTable = .{ .start = startPty, .stop = stopPty, .write = writePty, .read = readPty, .wait_readable = waitReadablePty, .kick_wait = kickWaitPty, .resize = resizePty, .control = controlPty };
    fn startPty(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        _ = ptr;
        _ = cols;
        _ = rows;
        return error.Failed;
    }
    fn stopPty(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn writePty(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        _ = ptr;
        _ = bytes;
        return error.Failed;
    }
    fn readPty(ptr: *anyopaque, buf: []u8) anyerror!usize {
        _ = ptr;
        _ = buf;
        return error.Failed;
    }
    fn waitReadablePty(ptr: *anyopaque, timeout_ms: i32) anyerror!bool {
        _ = ptr;
        _ = timeout_ms;
        return error.Failed;
    }
    fn kickWaitPty(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn resizePty(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        _ = ptr;
        _ = cols;
        _ = rows;
        return error.Failed;
    }
    fn controlPty(ptr: *anyopaque, signal: ControlSignal) void {
        _ = ptr;
        _ = signal;
    }
};
