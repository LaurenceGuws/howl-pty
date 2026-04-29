//! Responsibility: provide the full session and stable aliases.
//! Ownership: session lifecycle, I/O, resize/control, and snapshot behavior.
//! Reason: keep session imports stable in one file.

const std = @import("std");
const types = @import("types.zig");
const transport_api = @import("transport.zig");
const vt_core = @import("vt_core");

pub const ControlSignal = vt_core.ControlSignal;
pub const SessionStatus = types.SessionStatus;
pub const TransportClass = types.TransportClass;
pub const Transport = transport_api.Transport;

pub const Config = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    transport: ?Transport = null,
};

pub const SessionSnapshot = struct {
    cols: u16,
    rows: u16,
    status: SessionStatus,
    resize_count: u32,
    last_control_signal: ?ControlSignal,
};

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

pub const Session = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    status: SessionStatus,
    pending: std.ArrayListUnmanaged(u8),
    pending_capacity: usize,
    transport: ?Transport,
    resize_count: u32,
    last_control_signal: ?ControlSignal,
    ops: SessionOps,

    pub fn init(config: Config) anyerror!Session {
        if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
        if (config.pending_capacity == 0) return error.InvalidConfig;
        return .{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .status = .idle,
            .pending = .empty,
            .pending_capacity = config.pending_capacity,
            .transport = config.transport,
            .resize_count = 0,
            .last_control_signal = null,
            .ops = std.mem.zeroes(SessionOps),
        };
    }

    pub fn deinit(self: *Session) void {
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

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

    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        if (self.status == .active) {
            if (self.transport) |t| t.stop();
        }
        self.status = .stopped;
    }

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

    pub fn apply(self: *Session) usize {
        self.ops.apply_calls += 1;
        const n = self.pending.items.len;
        var drained: usize = 0;

        if (n > 0) {
            if (self.transport) |t| {
                const written = t.write(self.pending.items) catch {
                    self.ops.apply_transport_write_errors += 1;
                    return 0;
                };
                drained = written;
                if (written < n) {
                    std.mem.copyForwards(u8, self.pending.items[0 .. n - written], self.pending.items[written..n]);
                    self.pending.shrinkRetainingCapacity(n - written);
                } else {
                    self.pending.clearRetainingCapacity();
                }
            } else {
                drained = n;
                self.pending.clearRetainingCapacity();
            }
        }

        self.ops.bytes_applied += drained;
        return drained;
    }

    pub fn reset(self: *Session) void {
        self.ops.reset_calls += 1;
        self.pending.clearRetainingCapacity();
    }

    pub fn resize(self: *Session, cols: u16, rows: u16) anyerror!void {
        if (cols == 0 or rows == 0) {
            self.ops.resize_invalid_calls += 1;
            return error.InvalidDimensions;
        }

        self.cols = cols;
        self.rows = rows;
        self.resize_count +%= 1;
        self.ops.resize_valid_calls += 1;

        if (self.transport) |t| t.resize(cols, rows) catch |err| {
            self.ops.resize_transport_errors += 1;
            return err;
        };
    }

    pub fn control(self: *Session, signal: ControlSignal) void {
        self.ops.control_calls += 1;
        self.last_control_signal = signal;
        if (self.transport) |t| t.control(signal);
    }

    pub fn snapshot(self: *const Session) SessionSnapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .status = self.status,
            .resize_count = self.resize_count,
            .last_control_signal = self.last_control_signal,
        };
    }

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
