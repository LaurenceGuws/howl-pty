//! Responsibility: define the transport contract vtable.
//! Ownership: host-to-session transport boundary.
//! Reason: support pluggable transport implementations with consistent semantics.

const types = @import("../types.zig");
/// Re-exported control signal type for transport vtable signatures.
pub const ControlSignal = types.ControlSignal;

/// Host transport wrapper with function-table dispatch.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Transport operation function table.
    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!usize,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        resize: *const fn (ptr: *anyopaque, cols: u16, rows: u16) anyerror!void,
        control: *const fn (ptr: *anyopaque, signal: ControlSignal) void,
    };

    /// Start transport lifecycle.
    pub fn start(self: Transport) anyerror!void {
        return self.vtable.start(self.ptr);
    }

    /// Stop transport lifecycle.
    pub fn stop(self: Transport) void {
        self.vtable.stop(self.ptr);
    }

    /// Write outbound bytes to transport sink.
    pub fn write(self: Transport, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    /// Read inbound bytes from transport source.
    pub fn read(self: Transport, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    /// Notify transport of terminal dimension changes.
    pub fn resize(self: Transport, cols: u16, rows: u16) anyerror!void {
        return self.vtable.resize(self.ptr, cols, rows);
    }

    /// Send a control signal through transport.
    pub fn control(self: Transport, signal: ControlSignal) void {
        self.vtable.control(self.ptr, signal);
    }
};
