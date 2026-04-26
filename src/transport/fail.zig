//! Responsibility: provide a deterministic always-failing transport implementation.
//! Ownership: error-path transport testing.
//! Reason: validate failure boundaries without external dependencies.

const interface = @import("interface.zig");
pub const Transport = interface.Transport;
const ControlSignal = interface.ControlSignal;

pub const FailTransport = struct {
    pub fn init() FailTransport {
        return .{};
    }

    pub fn deinit(self: *FailTransport) void {
        _ = self;
    }

    pub fn transport(self: *FailTransport) Transport {
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
        _ = ptr;
        return error.TransportFailed;
    }

    fn stopImpl(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        _ = ptr;
        _ = bytes;
        return error.TransportFailed;
    }

    fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        _ = ptr;
        _ = buf;
        return error.TransportFailed;
    }

    fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
        _ = ptr;
        _ = cols;
        _ = rows;
        return error.TransportFailed;
    }

    fn controlImpl(ptr: *anyopaque, signal: ControlSignal) void {
        _ = ptr;
        _ = signal;
    }
};
