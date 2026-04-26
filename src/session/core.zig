//! Responsibility: implement session lifecycle, queue, resize, control, and snapshot behavior.
//! Ownership: core runtime semantics for howl-session.
//! Reason: centralize deterministic state transitions and boundaries.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const transport_api = @import("../transport.zig");
const vt_core = @import("vt_core");

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
pub const SessionOps = struct {
    start_attempts: u32,
    start_successes: u32,
    start_failures: u32,
    stop_calls: u32,
    feed_accepted: u32,
    feed_rejected: u32,
    bytes_fed: u64,
    bytes_applied: u64,
    apply_calls: u32,
    apply_transport_write_errors: u32,
    reset_calls: u32,
    resize_valid_calls: u32,
    resize_invalid_calls: u32,
    resize_transport_errors: u32,
    control_calls: u32,
};

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
        self.ops.start_attempts += 1;
        if (self.status == .active) return error.AlreadyStarted;
        if (self.transport) |t| t.start() catch |err| {
            self.ops.start_failures += 1;
            return err;
        };
        self.status = .active;
        self.ops.start_successes += 1;
    }

    /// Stop session lifecycle.
    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        if (self.status == .active) {
            if (self.transport) |t| t.stop();
        }
        self.status = .stopped;
    }

    /// Queue outbound input bytes for apply.
    pub fn feed(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!void {
        const projected_len = std.math.add(usize, self.pending.items.len, bytes.len) catch {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        };
        if (projected_len > self.pending_capacity) {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        }
        try self.pending.appendSlice(self.allocator, bytes);
        self.ops.feed_accepted += 1;
        self.ops.bytes_fed += bytes.len;
    }

    /// Drain queued outbound bytes.
    pub fn apply(self: *Session) usize {
        self.ops.apply_calls += 1;
        const n = self.pending.items.len;
        var drained: usize = 0;

        if (n > 0) {
            if (self.transport) |t| {
                // Outbound: flush host input to transport (e.g., PTY stdin)
                const written = t.write(self.pending.items) catch {
                    self.ops.apply_transport_write_errors += 1;
                    // Write failed: preserve pending bytes for retry.
                    return 0;
                };
                drained = written;
                // Partial write: shift unwritten tail to front, then shrink
                if (written < n) {
                    std.mem.copyForwards(u8, self.pending.items[0 .. n - written], self.pending.items[written..n]);
                    self.pending.shrinkRetainingCapacity(n - written);
                } else {
                    // Full write: clear entire queue
                    self.pending.clearRetainingCapacity();
                }
            } else {
                // No transport: feed host input directly to engine (null-transport behavior)
                self.engine.feedSlice(self.pending.items);
                self.engine.apply();
                drained = n;
                self.pending.clearRetainingCapacity();
            }
        }

        self.ops.bytes_applied += drained;
        return drained;
    }

    /// Feed inbound process output bytes into VT core.
    pub fn feedProcessOutput(self: *Session, bytes: []const u8) anyerror!void {
        self.engine.feedSlice(bytes);
        self.engine.apply();
    }

    /// Clear outbound pending queue.
    pub fn reset(self: *Session) void {
        self.ops.reset_calls += 1;
        self.pending.clearRetainingCapacity();
    }

    /// Resize session dimensions and recreate backing engine.
    pub fn resize(self: *Session, cols: u16, rows: u16) anyerror!void {
        if (cols == 0 or rows == 0) {
            self.ops.resize_invalid_calls += 1;
            return error.InvalidDimensions;
        }

        // Create new engine first so failure leaves existing engine untouched.
        const new_engine = try vt_core.runtime.Engine.initWithCells(self.allocator, rows, cols);

        // Swap active engine only after successful allocation.
        var old_engine = self.engine;
        self.engine = new_engine;
        old_engine.deinit();

        // Commit dimension state after engine swap.
        self.cols = cols;
        self.rows = rows;
        self.resize_count +%= 1;
        self.ops.resize_valid_calls += 1;

        // Notify attached transport after local state commit.
        if (self.transport) |t| t.resize(cols, rows) catch |err| {
            self.ops.resize_transport_errors += 1;
            return err;
        };
    }

    /// Send control signal and record last sent value.
    pub fn control(self: *Session, signal: ControlSignal) void {
        self.ops.control_calls += 1;
        self.last_control_signal = signal;
        if (self.transport) |t| t.control(signal);
    }

    /// Capture snapshot payload.
    pub fn snapshot(self: *const Session) SessionSnapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .status = self.status,
            .resize_count = self.resize_count,
            .last_control_signal = self.last_control_signal,
        };
    }

    /// Restore snapshot payload fields.
    pub fn restore(self: *Session, snap: SessionSnapshot) error{InvalidSnapshot}!void {
        if (snap.cols == 0 or snap.rows == 0) return error.InvalidSnapshot;
        self.cols = snap.cols;
        self.rows = snap.rows;
        self.status = if (snap.status == .active) .stopped else snap.status;
        self.resize_count = snap.resize_count;
        self.last_control_signal = snap.last_control_signal;
        self.pending.clearRetainingCapacity();
    }
};
