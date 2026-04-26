//! Responsibility: provide deterministic in-memory transport implementations for tests.
//! Ownership: test-focused transport implementations.
//! Reason: enable fast, repeatable transport behavior validation.

const std = @import("std");
const interface = @import("interface.zig");
/// Transport view for the in-memory transport implementations in this file.
pub const Transport = interface.Transport;
const ControlSignal = interface.ControlSignal;

/// In-memory transport that records writes and serves reads from local buffers.
pub const MemTransport = struct {
    allocator: std.mem.Allocator,
    started: bool,
    rx: std.ArrayListUnmanaged(u8),
    tx: std.ArrayListUnmanaged(u8),
    last_cols: u16,
    last_rows: u16,
    last_signal: ?ControlSignal,

    /// Creates an empty in-memory transport backed by the supplied allocator.
    pub fn init(allocator: std.mem.Allocator) MemTransport {
        return .{
            .allocator = allocator,
            .started = false,
            .rx = .empty,
            .tx = .empty,
            .last_cols = 0,
            .last_rows = 0,
            .last_signal = null,
        };
    }

    /// Releases all buffered transport state and invalidates the instance.
    pub fn deinit(self: *MemTransport) void {
        self.rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes the transport through the shared transport interface.
    pub fn transport(self: *MemTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .start = startImpl,
        .stop = stopImpl,
        .write = writeImpl,
        .read = readImpl,
        .resize = resizeImpl,
        .control = controlImpl,
    };

    fn startImpl(ptr: *anyopaque) anyerror!void {
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        self.started = true;
    }

    fn stopImpl(ptr: *anyopaque) void {
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
        self.started = false;
    }

    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        try self.tx.appendSlice(self.allocator, bytes);
        return bytes.len;
    }

    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
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
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        self.last_cols = cols;
        self.last_rows = rows;
    }

    fn controlImpl(ptr: *anyopaque, signal: ControlSignal) void {
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
        self.last_signal = signal;
    }
};

test "start activates transport" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try std.testing.expect(!mt.started);
    try t.start();
    try std.testing.expect(mt.started);
}

test "start twice returns AlreadyStarted" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    try std.testing.expectError(error.AlreadyStarted, t.start());
}

test "stop deactivates transport" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    t.stop();
    try std.testing.expect(!mt.started);
}

test "stop on idle transport is safe" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    t.stop();
    try std.testing.expect(!mt.started);
}

test "write appends to tx buffer" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    const n = try t.write("hello");
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "hello", mt.tx.items);
}

test "write before start returns NotStarted" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try std.testing.expectError(error.NotStarted, t.write("hello"));
}

test "read drains rx buffer" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    try mt.rx.appendSlice(std.testing.allocator, "world");
    var buf: [8]u8 = undefined;
    const n = try t.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "world", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), mt.rx.items.len);
}

test "read before start returns NotStarted" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.NotStarted, t.read(&buf));
}

test "read on empty rx returns 0" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    var buf: [8]u8 = undefined;
    const n = try t.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "read partial drains only up to buf size" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    try mt.rx.appendSlice(std.testing.allocator, "abcdef");
    var buf: [3]u8 = undefined;
    const n = try t.read(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, "abc", buf[0..n]);
    try std.testing.expectEqualSlices(u8, "def", mt.rx.items);
}

test "resize records last dimensions" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    try t.resize(132, 50);
    try std.testing.expectEqual(@as(u16, 132), mt.last_cols);
    try std.testing.expectEqual(@as(u16, 50), mt.last_rows);
}

test "resize before start returns NotStarted" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try std.testing.expectError(error.NotStarted, t.resize(132, 50));
}

test "control records last signal" {
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var t = mt.transport();
    try t.start();
    t.control(.interrupt);
    try std.testing.expectEqual(ControlSignal.interrupt, mt.last_signal.?);
}

/// In-memory transport that limits each write to a fixed byte budget.
pub const PartialTransport = struct {
    allocator: std.mem.Allocator,
    started: bool,
    max_bytes: usize,
    tx: std.ArrayListUnmanaged(u8),

    /// Creates a transport that accepts at most `max_bytes` per write call.
    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) PartialTransport {
        return .{
            .allocator = allocator,
            .started = false,
            .max_bytes = max_bytes,
            .tx = .empty,
        };
    }

    /// Releases buffered bytes and invalidates the instance.
    pub fn deinit(self: *PartialTransport) void {
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes the transport through the shared transport interface.
    pub fn transport(self: *PartialTransport) Transport {
        return .{ .ptr = self, .vtable = &partialVtable };
    }

    const partialVtable: Transport.VTable = .{
        .start = startImpl,
        .stop = stopImpl,
        .write = writeImpl,
        .read = readImpl,
        .resize = resizeImpl,
        .control = controlImpl,
    };

    fn startImpl(ptr: *anyopaque) anyerror!void {
        const self: *PartialTransport = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        self.started = true;
    }

    fn stopImpl(ptr: *anyopaque) void {
        const self: *PartialTransport = @ptrCast(@alignCast(ptr));
        self.started = false;
    }

    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *PartialTransport = @ptrCast(@alignCast(ptr));
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

    fn controlImpl(ptr: *anyopaque, signal: ControlSignal) void {
        _ = ptr;
        _ = signal;
    }
};

test "PartialTransport write accepts only max_bytes" {
    var pt = PartialTransport.init(std.testing.allocator, 3);
    defer pt.deinit();
    var t = pt.transport();
    try t.start();
    const n = try t.write("hello");
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, "hel", pt.tx.items);
}

test "PartialTransport repeated writes accumulate" {
    var pt = PartialTransport.init(std.testing.allocator, 2);
    defer pt.deinit();
    var t = pt.transport();
    try t.start();
    const n1 = try t.write("hello");
    const n2 = try t.write("world");
    try std.testing.expectEqual(@as(usize, 2), n1);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqualSlices(u8, "hewo", pt.tx.items);
}
