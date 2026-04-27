//! Responsibility: implement container runtime transport operations.
//! Ownership: Android/container transport implementation.
//! Reason: provide a non-POSIX transport lane with deterministic semantics.

const std = @import("std");
const interface = @import("interface.zig");

/// Transport view for the container runtime transport implementation.
pub const Transport = interface.Transport;
const ControlSignal = interface.ControlSignal;

/// Transport implementation that models host-managed container I/O.
pub const ContainerTransport = struct {
    allocator: std.mem.Allocator,
    started: bool,
    rx: std.ArrayListUnmanaged(u8),
    tx: std.ArrayListUnmanaged(u8),
    last_cols: u16,
    last_rows: u16,
    last_signal: ?ControlSignal,

    /// Creates an empty container transport backed by the supplied allocator.
    pub fn init(allocator: std.mem.Allocator) ContainerTransport {
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
    pub fn deinit(self: *ContainerTransport) void {
        self.rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes the container transport through the shared transport interface.
    pub fn transport(self: *ContainerTransport) Transport {
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
        const self: *ContainerTransport = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        self.started = true;
    }

    fn stopImpl(ptr: *anyopaque) void {
        const self: *ContainerTransport = @ptrCast(@alignCast(ptr));
        self.started = false;
    }

    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *ContainerTransport = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        try self.tx.appendSlice(self.allocator, bytes);
        return bytes.len;
    }

    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *ContainerTransport = @ptrCast(@alignCast(ptr));
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
        const self: *ContainerTransport = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        self.last_cols = cols;
        self.last_rows = rows;
    }

    fn controlImpl(ptr: *anyopaque, signal: ControlSignal) void {
        const self: *ContainerTransport = @ptrCast(@alignCast(ptr));
        self.last_signal = signal;
    }
};

test "container transport lifecycle is deterministic" {
    var ct = ContainerTransport.init(std.testing.allocator);
    defer ct.deinit();
    var t = ct.transport();

    try std.testing.expect(!ct.started);
    try t.start();
    try std.testing.expect(ct.started);
    try std.testing.expectError(error.AlreadyStarted, t.start());
    t.stop();
    try std.testing.expect(!ct.started);
    t.stop();
    try std.testing.expect(!ct.started);
}

test "container transport read and write path is deterministic" {
    var ct = ContainerTransport.init(std.testing.allocator);
    defer ct.deinit();
    var t = ct.transport();

    try std.testing.expectError(error.NotStarted, t.write("abc"));
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.NotStarted, t.read(&out));

    try t.start();
    try ct.rx.appendSlice(std.testing.allocator, "hello");
    const read_n = try t.read(&out);
    try std.testing.expectEqual(@as(usize, 5), read_n);
    try std.testing.expectEqualSlices(u8, "hello", out[0..read_n]);

    const write_n = try t.write("xyz");
    try std.testing.expectEqual(@as(usize, 3), write_n);
    try std.testing.expectEqualSlices(u8, "xyz", ct.tx.items);
}

test "container transport resize and control record last values" {
    var ct = ContainerTransport.init(std.testing.allocator);
    defer ct.deinit();
    var t = ct.transport();

    try std.testing.expectError(error.NotStarted, t.resize(120, 40));

    try t.start();
    try t.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), ct.last_cols);
    try std.testing.expectEqual(@as(u16, 40), ct.last_rows);

    t.control(.interrupt);
    try std.testing.expectEqual(ControlSignal.interrupt, ct.last_signal.?);
}
