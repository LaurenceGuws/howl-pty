//! Responsibility: implement session lifecycle, queue, resize, control, and snapshot behavior.
//! Ownership: core runtime semantics for howl-session.
//! Reason: centralize deterministic state transitions and boundaries.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const transport_api = @import("../transport.zig");
const vt_core = @import("vt_core");
const state = @import("state.zig");
const lifecycle_impl = @import("lifecycle.zig");
const io_impl = @import("io.zig");
const resize_control_impl = @import("resize_control.zig");
const snapshot_ops_impl = @import("snapshot_ops.zig");

/// Session control signal enum.
pub const ControlSignal = types.ControlSignal;
/// Session lifecycle status enum.
pub const SessionStatus = types.SessionStatus;
/// Transport wrapper type.
pub const Transport = transport_api.Transport;

/// Session construction config.
pub const Config = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    transport: ?Transport = null,
};

/// Session snapshot payload.
pub const SessionSnapshot = struct {
    cols: u16,
    rows: u16,
    status: SessionStatus,
    resize_count: u32,
    last_control_signal: ?ControlSignal,
};

/// Session operations counters.
pub const SessionOps = state.SessionOps;

/// Core session runtime.
pub const Session = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    status: SessionStatus,
    pending: std.ArrayListUnmanaged(u8),
    pending_capacity: usize,
    transport: ?Transport,
    engine: vt_core.runtime.Engine,
    resize_count: u32,
    last_control_signal: ?ControlSignal,
    ops: SessionOps,

    /// Initialize session runtime.
    pub fn init(config: Config) anyerror!Session {
        if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
        if (config.pending_capacity == 0) return error.InvalidConfig;
        const engine = try vt_core.runtime.Engine.initWithCells(config.allocator, config.rows, config.cols);
        return .{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .status = .idle,
            .pending = .empty,
            .pending_capacity = config.pending_capacity,
            .transport = config.transport,
            .engine = engine,
            .resize_count = 0,
            .last_control_signal = null,
            .ops = std.mem.zeroes(SessionOps),
        };
    }

    /// Deinitialize session-owned resources.
    pub fn deinit(self: *Session) void {
        self.pending.deinit(self.allocator);
        self.engine.deinit();
        self.* = undefined;
    }

    /// Start session lifecycle and transport if attached.
    pub fn start(self: *Session) anyerror!void {
        try lifecycle_impl.start(self);
    }

    /// Stop session lifecycle.
    pub fn stop(self: *Session) void {
        lifecycle_impl.stop(self);
    }

    /// Queue outbound input bytes for apply.
    pub fn feed(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!void {
        try io_impl.feed(self, bytes);
    }

    /// Drain queued outbound bytes.
    pub fn apply(self: *Session) usize {
        return io_impl.apply(self);
    }

    /// Feed inbound process output bytes into VT core.
    pub fn feedProcessOutput(self: *Session, bytes: []const u8) anyerror!void {
        try io_impl.feedProcessOutput(self, bytes);
    }

    /// Clear outbound pending queue.
    pub fn reset(self: *Session) void {
        io_impl.reset(self);
    }

    /// Resize session dimensions and recreate backing engine.
    pub fn resize(self: *Session, cols: u16, rows: u16) anyerror!void {
        try resize_control_impl.resize(self, cols, rows);
    }

    /// Send control signal and record last sent value.
    pub fn control(self: *Session, signal: ControlSignal) void {
        resize_control_impl.control(self, signal);
    }

    /// Capture snapshot payload.
    pub fn snapshot(self: *const Session) SessionSnapshot {
        return snapshot_ops_impl.snapshot(self);
    }

    /// Restore snapshot payload fields.
    pub fn restore(self: *Session, snap: SessionSnapshot) error{InvalidSnapshot}!void {
        try snapshot_ops_impl.restore(self, snap);
    }
};
